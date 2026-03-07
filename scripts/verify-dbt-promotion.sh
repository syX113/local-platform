#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

ARTIFACT_DIR="${ROOT_DIR}/artifacts/dbt"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

required_vars=(
  SNOWFLAKE_ACCOUNT
  SNOWFLAKE_USER
  SNOWFLAKE_PASSWORD
  SNOWFLAKE_ROLE
  SNOWFLAKE_WAREHOUSE
  SNOWFLAKE_TARGET_DATABASE
  SNOWFLAKE_TARGET_SCHEMA
  SNOWFLAKE_RAW_DATABASE
)

for key in "${required_vars[@]}"; do
  if [ -z "${!key:-}" ]; then
    echo "missing required dbt promotion variable: ${key}" >&2
    exit 1
  fi
done

docker compose up -d airflow-metadata-db source-postgres-db lakehouse-object-store
docker compose run --rm lakehouse-bucket-init | tee "${ARTIFACT_DIR}/bucket_init.log"
./scripts/load-source-sample-data.sh | tee "${ARTIFACT_DIR}/source_seed.log"
docker compose run --rm dlt-extractor python /opt/platform/dlt/pipeline.py | tee "${ARTIFACT_DIR}/dlt_pipeline.log"
./scripts/bootstrap-snowflake.sh | tee "${ARTIFACT_DIR}/snowflake_bootstrap.log"

if [ "${SNOWFLAKE_LOCAL_RAW_SYNC:-false}" = "true" ]; then
  docker compose run --rm dlt-extractor python /opt/platform/dlt/snowflake_raw_sync.py | tee "${ARTIFACT_DIR}/snowflake_raw_sync.log"
elif [ -z "${OPEN_CATALOG_URI:-}" ] || [ -z "${OPEN_CATALOG_NAME:-}" ] || [ -z "${OPEN_CATALOG_CLIENT_ID:-}" ] || [ -z "${OPEN_CATALOG_CLIENT_SECRET:-}" ]; then
  echo "dbt promotion requires either SNOWFLAKE_LOCAL_RAW_SYNC=true or complete OPEN_CATALOG_* configuration" >&2
  exit 1
fi

docker compose run --rm --no-deps dbt-executor \
  dbt parse --project-dir /opt/platform/dbt --profiles-dir /opt/platform/dbt/profiles | tee "${ARTIFACT_DIR}/dbt_parse.log"
docker compose run --rm dbt-executor \
  dbt build --project-dir /opt/platform/dbt --profiles-dir /opt/platform/dbt/profiles | tee "${ARTIFACT_DIR}/dbt_build.log"
docker compose run --rm dbt-executor \
  python /opt/platform/dbt/scripts/zero_copy_clone_check.py | tee "${ARTIFACT_DIR}/zero_copy_clone.log"

docker compose run --rm dbt-executor python - <<'PY' | tee "${ARTIFACT_DIR}/snowflake_validation.txt"
import os

import snowflake.connector

queries = {
    "raw_orders": (
        f"select count(*) from {os.environ['SNOWFLAKE_RAW_DATABASE']}.LANDING.RAW_ORDERS",
        30,
    ),
    "raw_order_items": (
        f"select count(*) from {os.environ['SNOWFLAKE_RAW_DATABASE']}.LANDING.RAW_ORDER_ITEMS",
        60,
    ),
    "stg_raw_orders": (
        f"select count(*) from {os.environ['SNOWFLAKE_TARGET_DATABASE']}.{os.environ['SNOWFLAKE_TARGET_SCHEMA']}.STG_RAW_ORDERS",
        30,
    ),
    "fct_order_revenue": (
        f"select count(*) from {os.environ['SNOWFLAKE_TARGET_DATABASE']}.{os.environ['SNOWFLAKE_TARGET_SCHEMA']}.FCT_ORDER_REVENUE",
        30,
    ),
}

connection = snowflake.connector.connect(
    account=os.environ["SNOWFLAKE_ACCOUNT"],
    user=os.environ["SNOWFLAKE_USER"],
    password=os.environ["SNOWFLAKE_PASSWORD"],
    role=os.environ["SNOWFLAKE_ROLE"],
    warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
)

try:
    with connection.cursor() as cursor:
        for name, (sql, expected) in queries.items():
            cursor.execute(sql)
            actual = cursor.fetchone()[0]
            if actual != expected:
                raise SystemExit(f"expected {expected} rows for {name}, found {actual}")
            print(f"{name}={actual}")
finally:
    connection.close()

print("dbt_promotion=passed")
PY

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
DBT promotion succeeded.
snowflake.raw_orders=30
snowflake.raw_order_items=60
snowflake.stg_raw_orders=30
snowflake.fct_order_revenue=30
EOF
