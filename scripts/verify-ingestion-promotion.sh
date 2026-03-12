#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "$(dirname "${SCRIPT_DIR}")")" = "ci" ]; then
  ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
else
  ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
cd "${ROOT_DIR}"

source "${SCRIPT_DIR}/common.sh"
ensure_platform_env

ARTIFACT_DIR="${ROOT_DIR}/artifacts/ingestion"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

scope="${SOURCE_SCOPE:-all}"
while [ $# -gt 0 ]; do
  case "${1}" in
    --scope)
      scope="${2:?scope value is required}"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done
export SOURCE_SCOPE="${scope}"

iceberg_catalog_name="${ICEBERG_CATALOG_NAME:-default}"
iceberg_namespace="${ICEBERG_NAMESPACE:-landing}"
catalog_namespace="$(printf '%s' "${iceberg_namespace}" | tr '[:upper:]' '[:lower:]')"
execution_date="${1:-2026-03-07}"
if [ -n "${2:-}" ]; then
  dag_id="${2}"
elif [ -n "${AIRFLOW_SANDBOX_DAG_ID:-}" ]; then
  dag_id="${AIRFLOW_SANDBOX_DAG_ID}"
else
  dag_id="${DEV_AIRFLOW_DAG_ID:-DEV_local_platform_ingest}"
fi

if [ -n "${3:-}" ]; then
  dag_subdir="${3}"
elif [ -n "${AIRFLOW_SANDBOX_DAG_ID:-}" ]; then
  dag_subdir="/opt/airflow/dags/deployed/$(sanitize_branch_token "${AIRFLOW_SANDBOX_DAG_ID}").py"
else
  dag_subdir="/opt/airflow/dags/deployed/${AIRFLOW_ACTIVE_DAG_FILENAME:-${DEV_AIRFLOW_DAG_FILENAME:-dev_local_platform_ingest.py}}"
fi

# The ingestion promotion validates the PostgreSQL -> Airflow/dlt -> MinIO/Iceberg path only.
export SNOWFLAKE_ACCOUNT=""
export SNOWFLAKE_USER=""
export SNOWFLAKE_PASSWORD=""
export OPEN_CATALOG_URI=""
export OPEN_CATALOG_NAME=""
export OPEN_CATALOG_CLIENT_ID=""
export OPEN_CATALOG_CLIENT_SECRET=""
export SNOWFLAKE_LOCAL_RAW_SYNC="false"

"${SCRIPT_DIR}/test-airflow-dag.sh" "${execution_date}" "${dag_id}" "${dag_subdir}" | tee "${ARTIFACT_DIR}/airflow_dag.log"

source_counts="$(
  docker compose exec -T source-postgres-db \
    psql -U "${SOURCE_POSTGRES_USER}" -d "${SOURCE_POSTGRES_DB}" -At -F ',' -c "
      select
        (select count(*) from customers),
        (select count(*) from orders),
        (select count(*) from order_items),
        (select count(*) from raw_customers_export),
        (select count(*) from raw_orders_export),
        (select count(*) from raw_order_items_export);
    "
)"
printf '%s\n' "${source_counts}" | tee "${ARTIFACT_DIR}/source_counts.csv"

IFS=',' read -r customer_count order_count order_item_count raw_customers_count raw_orders_count raw_order_items_count <<<"${source_counts}"

[ "${customer_count}" = "12" ] || { echo "expected 12 customers, got ${customer_count}" >&2; exit 1; }
[ "${order_count}" = "30" ] || { echo "expected 30 orders, got ${order_count}" >&2; exit 1; }
[ "${order_item_count}" = "60" ] || { echo "expected 60 order items, got ${order_item_count}" >&2; exit 1; }
[ "${raw_customers_count}" = "12" ] || { echo "expected 12 raw customers export rows, got ${raw_customers_count}" >&2; exit 1; }
[ "${raw_orders_count}" = "30" ] || { echo "expected 30 raw orders export rows, got ${raw_orders_count}" >&2; exit 1; }
[ "${raw_order_items_count}" = "60" ] || { echo "expected 60 raw order item export rows, got ${raw_order_items_count}" >&2; exit 1; }

catalog_rows="$(
  docker compose exec -T airflow-metadata-db \
    psql -U "${AIRFLOW_METADATA_DB_USER}" -d iceberg_catalog -At -F ',' -c "
      select catalog_name, table_namespace, table_name, metadata_location
      from iceberg_tables
      where catalog_name = '${iceberg_catalog_name}'
        and table_namespace = '${catalog_namespace}'
      order by table_name;
    "
)"
printf '%s\n' "${catalog_rows}" | tee "${ARTIFACT_DIR}/iceberg_catalog.csv"

catalog_count="$(printf '%s\n' "${catalog_rows}" | sed '/^$/d' | wc -l | tr -d ' ')"
case "${scope}" in
  orders)
    printf '%s\n' "${catalog_rows}" | grep -q "^${iceberg_catalog_name},${catalog_namespace},raw_order_items," || { echo "missing ${iceberg_catalog_name}.${catalog_namespace}.raw_order_items catalog entry" >&2; exit 1; }
    printf '%s\n' "${catalog_rows}" | grep -q "^${iceberg_catalog_name},${catalog_namespace},raw_orders," || { echo "missing ${iceberg_catalog_name}.${catalog_namespace}.raw_orders catalog entry" >&2; exit 1; }
    ;;
  customers)
    printf '%s\n' "${catalog_rows}" | grep -q "^${iceberg_catalog_name},${catalog_namespace},raw_customers," || { echo "missing ${iceberg_catalog_name}.${catalog_namespace}.raw_customers catalog entry" >&2; exit 1; }
    ;;
  all)
    printf '%s\n' "${catalog_rows}" | grep -q "^${iceberg_catalog_name},${catalog_namespace},raw_customers," || { echo "missing ${iceberg_catalog_name}.${catalog_namespace}.raw_customers catalog entry" >&2; exit 1; }
    printf '%s\n' "${catalog_rows}" | grep -q "^${iceberg_catalog_name},${catalog_namespace},raw_order_items," || { echo "missing ${iceberg_catalog_name}.${catalog_namespace}.raw_order_items catalog entry" >&2; exit 1; }
    printf '%s\n' "${catalog_rows}" | grep -q "^${iceberg_catalog_name},${catalog_namespace},raw_orders," || { echo "missing ${iceberg_catalog_name}.${catalog_namespace}.raw_orders catalog entry" >&2; exit 1; }
    ;;
  *)
    echo "unsupported ingestion scope: ${scope}" >&2
    exit 1
    ;;
esac

docker compose run --rm --no-deps dlt-extractor python - <<'PY' | tee "${ARTIFACT_DIR}/minio_iceberg_summary.txt"
from io import BytesIO
import json
import os
import sys
from urllib.parse import urlparse

import boto3
import pyarrow.parquet as pq

bucket_uri = os.environ["OBJECT_STORE_BUCKET"]
parsed = urlparse(bucket_uri)
bucket = parsed.netloc
prefix = parsed.path.lstrip("/")
namespace = os.environ["ICEBERG_NAMESPACE"]

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["OBJECT_STORE_ENDPOINT_URL"],
    aws_access_key_id=os.environ["OBJECT_STORE_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["OBJECT_STORE_SECRET_ACCESS_KEY"],
    region_name=os.environ["OBJECT_STORE_REGION"],
)

response = s3.list_objects_v2(Bucket=bucket, Prefix=f"{prefix}/{namespace}/")
objects = response.get("Contents", [])
keys = [obj["Key"] for obj in objects]
metadata_keys = sorted(key for key in keys if "/metadata/" in key and key.endswith(".metadata.json"))
parquet_keys = sorted(key for key in keys if key.endswith(".parquet"))

if len(metadata_keys) < 6:
    raise SystemExit(f"expected at least 6 metadata files, found {len(metadata_keys)}")
if len(parquet_keys) < 3:
    raise SystemExit(f"expected at least 3 parquet data files, found {len(parquet_keys)}")

print(f"metadata_files={len(metadata_keys)}")
print(f"parquet_files_total={len(parquet_keys)}")

for key in metadata_keys:
    body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    doc = json.loads(body)
    print(
        "metadata",
        key,
        f"format_version={doc.get('format-version')}",
        f"current_snapshot_id={doc.get('current-snapshot-id')}",
    )

latest_parquet_keys: dict[str, tuple[str, object]] = {}
for key in parquet_keys:
    parts = key.split("/")
    try:
        namespace_index = parts.index(namespace)
        table_name = parts[namespace_index + 1]
    except (ValueError, IndexError) as exc:
        raise SystemExit(f"unable to resolve table name from object key: {key}") from exc
    matching_object = next(obj for obj in objects if obj["Key"] == key)
    last_modified = matching_object["LastModified"]
    current = latest_parquet_keys.get(table_name)
    if current is None or last_modified > current[1]:
        latest_parquet_keys[table_name] = (key, last_modified)

scope = os.environ.get("SOURCE_SCOPE", "all").strip().lower()
if scope == "orders":
    expected = {"raw_orders": 30, "raw_order_items": 60}
elif scope == "customers":
    expected = {"raw_customers": 12}
else:
    expected = {"raw_orders": 30, "raw_order_items": 60, "raw_customers": 12}
for table_name, expected_rows in expected.items():
    latest_key = latest_parquet_keys.get(table_name)
    if latest_key is None:
        raise SystemExit(f"missing parquet data for {table_name}")
    payload = s3.get_object(Bucket=bucket, Key=latest_key[0])["Body"].read()
    current_rows = pq.read_table(BytesIO(payload)).num_rows
    if current_rows != expected_rows:
        raise SystemExit(f"expected {expected_rows} rows for latest {table_name} parquet, found {current_rows}")
    print(f"parquet_latest_key {table_name}={latest_key[0]}")
    print(f"parquet_rows_current {table_name}={current_rows}")

print("ingestion_promotion=passed")
sys.stdout.flush()
os._exit(0)
PY

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
Ingestion promotion succeeded.
source.customers=${customer_count}
source.orders=${order_count}
source.order_items=${order_item_count}
source.raw_customers_export=${raw_customers_count}
source.raw_orders_export=${raw_orders_count}
source.raw_order_items_export=${raw_order_items_count}
iceberg.catalog_entries=${catalog_count}
iceberg.catalog=${iceberg_catalog_name}
iceberg.namespace=${catalog_namespace}
ingestion.scope=${scope}
object_store.bucket=${OBJECT_STORE_BUCKET}
airflow.dag_id=${dag_id}
EOF
