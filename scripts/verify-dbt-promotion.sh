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
  SNOWFLAKE_SDP_DATABASE
  SNOWFLAKE_SDP_IN_SCHEMA
  SNOWFLAKE_SDP_ACC_SCHEMA
  SNOWFLAKE_EDP_DATABASE
  SNOWFLAKE_EDP_CORE_SCHEMA
  SNOWFLAKE_EDP_ACC_SCHEMA
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

def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)

queries = {
    "sdp_ext_raw_orders": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_IN_SCHEMA'], 'EXT_ORDERS_RAW')}",
        30,
    ),
    "sdp_ext_raw_order_items": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_IN_SCHEMA'], 'EXT_ORDER_ITEMS_RAW')}",
        60,
    ),
    "sdp_core_orders_clean": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_CORE_SCHEMA'], 'T_ORDERS_CLEAN')}",
        30,
    ),
    "sdp_core_order_items_clean": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_CORE_SCHEMA'], 'T_ORDER_ITEMS_CLEAN')}",
        60,
    ),
    "sdp_access_orders_order_grain": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], 'T_ORDERS_ORDER_GRAIN')}",
        30,
    ),
    "sdp_access_orders_customer_grain": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], 'T_ORDERS_CUSTOMER_GRAIN')}",
        12,
    ),
    "edp_core_dim_customers": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'DIM_CUSTOMERS')}",
        12,
    ),
    "edp_core_dim_order_status": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'DIM_ORDER_STATUS')}",
        3,
    ),
    "edp_core_orders_3nf": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'T_ORDERS_3NF')}",
        30,
    ),
    "edp_fact_order_revenue_star": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'FCT_ORDER_REVENUE_STAR')}",
        30,
    ),
    "edp_access_orders_only": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_ORDERS_ONLY')}",
        30,
    ),
    "edp_access_orders_complete": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_ORDERS_COMPLETE')}",
        30,
    ),
    "edp_access_orders_fulfilled": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_ORDERS_FULFILLED')}",
        20,
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
snowflake.sdp_ext_raw_orders=30
snowflake.sdp_ext_raw_order_items=60
snowflake.sdp_core_orders_clean=30
snowflake.sdp_core_order_items_clean=60
snowflake.sdp_access_orders_order_grain=30
snowflake.sdp_access_orders_customer_grain=12
snowflake.edp_core_dim_customers=12
snowflake.edp_core_dim_order_status=3
snowflake.edp_core_orders_3nf=30
snowflake.edp_fact_order_revenue_star=30
snowflake.edp_access_orders_only=30
snowflake.edp_access_orders_complete=30
snowflake.edp_access_orders_fulfilled=20
EOF
