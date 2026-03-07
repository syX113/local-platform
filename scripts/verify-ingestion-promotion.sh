#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

ARTIFACT_DIR="${ROOT_DIR}/artifacts/ingestion"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

# The ingestion promotion validates the PostgreSQL -> Airflow/dlt -> MinIO/Iceberg path only.
export SNOWFLAKE_ACCOUNT=""
export SNOWFLAKE_USER=""
export SNOWFLAKE_PASSWORD=""
export OPEN_CATALOG_URI=""
export OPEN_CATALOG_NAME=""
export OPEN_CATALOG_CLIENT_ID=""
export OPEN_CATALOG_CLIENT_SECRET=""
export SNOWFLAKE_LOCAL_RAW_SYNC="false"

./scripts/test-airflow-dag.sh "${1:-2026-03-07}" | tee "${ARTIFACT_DIR}/airflow_dag.log"

source_counts="$(
  docker compose exec -T source-postgres-db \
    psql -U "${SOURCE_POSTGRES_USER}" -d "${SOURCE_POSTGRES_DB}" -At -F ',' -c "
      select
        (select count(*) from customers),
        (select count(*) from orders),
        (select count(*) from order_items),
        (select count(*) from raw_orders_export),
        (select count(*) from raw_order_items_export);
    "
)"
printf '%s\n' "${source_counts}" | tee "${ARTIFACT_DIR}/source_counts.csv"

IFS=',' read -r customer_count order_count order_item_count raw_orders_count raw_order_items_count <<<"${source_counts}"

[ "${customer_count}" = "12" ] || { echo "expected 12 customers, got ${customer_count}" >&2; exit 1; }
[ "${order_count}" = "30" ] || { echo "expected 30 orders, got ${order_count}" >&2; exit 1; }
[ "${order_item_count}" = "60" ] || { echo "expected 60 order items, got ${order_item_count}" >&2; exit 1; }
[ "${raw_orders_count}" = "30" ] || { echo "expected 30 raw orders export rows, got ${raw_orders_count}" >&2; exit 1; }
[ "${raw_order_items_count}" = "60" ] || { echo "expected 60 raw order item export rows, got ${raw_order_items_count}" >&2; exit 1; }

catalog_rows="$(
  docker compose exec -T airflow-metadata-db \
    psql -U "${AIRFLOW_METADATA_DB_USER}" -d iceberg_catalog -At -F ',' -c "
      select table_namespace, table_name, metadata_location
      from iceberg_tables
      order by table_name;
    "
)"
printf '%s\n' "${catalog_rows}" | tee "${ARTIFACT_DIR}/iceberg_catalog.csv"

catalog_count="$(printf '%s\n' "${catalog_rows}" | sed '/^$/d' | wc -l | tr -d ' ')"
[ "${catalog_count}" = "2" ] || { echo "expected 2 Iceberg catalog entries, got ${catalog_count}" >&2; exit 1; }
printf '%s\n' "${catalog_rows}" | grep -q '^landing,raw_order_items,' || { echo "missing landing.raw_order_items catalog entry" >&2; exit 1; }
printf '%s\n' "${catalog_rows}" | grep -q '^landing,raw_orders,' || { echo "missing landing.raw_orders catalog entry" >&2; exit 1; }

docker compose run --rm --no-deps dlt-extractor python - <<'PY' | tee "${ARTIFACT_DIR}/minio_iceberg_summary.txt"
from io import BytesIO
import json
import sys

import boto3
import pyarrow.parquet as pq

s3 = boto3.client(
    "s3",
    endpoint_url="http://lakehouse-object-store:9000",
    aws_access_key_id="minioadmin",
    aws_secret_access_key="minioadmin123",
    region_name="us-east-1",
)

response = s3.list_objects_v2(Bucket="lakehouse", Prefix="platform/landing/")
keys = [obj["Key"] for obj in response.get("Contents", [])]
metadata_keys = sorted(key for key in keys if "/metadata/" in key and key.endswith(".metadata.json"))
parquet_keys = sorted(key for key in keys if key.endswith(".parquet"))

if len(metadata_keys) < 4:
    raise SystemExit(f"expected at least 4 metadata files, found {len(metadata_keys)}")
if len(parquet_keys) != 2:
    raise SystemExit(f"expected 2 parquet data files, found {len(parquet_keys)}")

print(f"metadata_files={len(metadata_keys)}")
print(f"parquet_files={len(parquet_keys)}")

for key in metadata_keys:
    body = s3.get_object(Bucket="lakehouse", Key=key)["Body"].read()
    doc = json.loads(body)
    print(
        "metadata",
        key,
        f"format_version={doc.get('format-version')}",
        f"current_snapshot_id={doc.get('current-snapshot-id')}",
    )

row_totals: dict[str, int] = {}
for key in parquet_keys:
    payload = s3.get_object(Bucket="lakehouse", Key=key)["Body"].read()
    row_count = pq.read_table(BytesIO(payload)).num_rows
    table_name = key.split("/")[2]
    row_totals[table_name] = row_totals.get(table_name, 0) + row_count

expected = {"raw_orders": 30, "raw_order_items": 60}
for table_name, expected_rows in expected.items():
    actual_rows = row_totals.get(table_name)
    if actual_rows != expected_rows:
        raise SystemExit(f"expected {expected_rows} rows for {table_name}, found {actual_rows}")
    print(f"parquet_rows {table_name}={actual_rows}")

print("ingestion_promotion=passed")
PY

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
Ingestion promotion succeeded.
source.customers=${customer_count}
source.orders=${order_count}
source.order_items=${order_item_count}
source.raw_orders_export=${raw_orders_count}
source.raw_order_items_export=${raw_order_items_count}
iceberg.catalog_entries=${catalog_count}
EOF
