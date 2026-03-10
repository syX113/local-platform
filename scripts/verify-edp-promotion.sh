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

if [ -z "${CI_SANDBOX_KIND:-}" ]; then
  export_dev_runtime_env
fi

dbt_target_name="${SNOW_DBT_TARGET_NAME:-dev}"

skip_foundation="false"
skip_dbt="false"

while [ $# -gt 0 ]; do
  case "${1}" in
    --skip-foundation)
      skip_foundation="true"
      ;;
    --skip-dbt)
      skip_dbt="true"
      ;;
    *)
      echo "unsupported argument: ${1}" >&2
      exit 1
      ;;
  esac
  shift
done

ARTIFACT_DIR="${ROOT_DIR}/artifacts/edp"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

required_vars=(
  SNOWFLAKE_ACCOUNT
  SNOWFLAKE_USER
  SNOWFLAKE_PASSWORD
  SNOWFLAKE_ROLE
  SNOWFLAKE_WAREHOUSE
  SNOWFLAKE_SDP_DATABASE
  SNOWFLAKE_SDP_ACC_SCHEMA
  SNOWFLAKE_EDP_DATABASE
  SNOWFLAKE_EDP_IN_SCHEMA
  SNOWFLAKE_EDP_CORE_SCHEMA
  SNOWFLAKE_EDP_ACC_SCHEMA
)

for key in "${required_vars[@]}"; do
  if [ -z "${!key:-}" ]; then
    echo "missing required EDP promotion variable: ${key}" >&2
    exit 1
  fi
done

if [ "${skip_foundation}" != "true" ]; then
  bash "${SCRIPT_DIR}/ensure-snowflake-foundation.sh" | tee "${ARTIFACT_DIR}/snowflake_bootstrap.log"
fi

docker compose run --rm --no-deps dbt-executor python - <<'PY' | tee "${ARTIFACT_DIR}/sdp_contract_check.txt"
import os
import sys

import snowflake.connector


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


tables = {
    "T_ORDERS_ORDER_GRAIN": 30,
    "T_ORDERS_CUSTOMER_GRAIN": 12,
    "T_ORDER_LINES_ORDER_GRAIN": 60,
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
        for table_name, expected in tables.items():
            try:
                cursor.execute(
                    f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], table_name)}"
                )
            except Exception as exc:  # pragma: no cover - surfaced as process failure
                raise SystemExit(
                    f"required upstream SDP table is missing: {table_name}. Promote the SDP project first. Original error: {exc}"
                ) from exc
            actual = cursor.fetchone()[0]
            if actual != expected:
                raise SystemExit(f"expected {expected} rows for upstream {table_name}, found {actual}")
            print(f"upstream_{table_name.lower()}={actual}")
finally:
    connection.close()

print("sdp_contract=passed")
PY

if [ "${skip_dbt}" != "true" ]; then
  bash "${SCRIPT_DIR}/deploy-snowflake-dbt-project.sh" \
    proj_edp_orders \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    "${SNOWFLAKE_EDP_DATABASE}" \
    "${SNOWFLAKE_EDP_CORE_SCHEMA}" \
    "${dbt_target_name}" | tee "${ARTIFACT_DIR}/dbt_deploy.log"

  bash "${SCRIPT_DIR}/execute-snowflake-dbt-project.sh" \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    parse | tee "${ARTIFACT_DIR}/dbt_parse.log"

  bash "${SCRIPT_DIR}/execute-snowflake-dbt-project.sh" \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    run | tee "${ARTIFACT_DIR}/dbt_run.log"

  bash "${SCRIPT_DIR}/execute-snowflake-dbt-project.sh" \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    test | tee "${ARTIFACT_DIR}/dbt_test.log"
fi

docker compose run --rm --no-deps dbt-executor \
  python /opt/platform/dbt/scripts/zero_copy_clone_check.py | tee "${ARTIFACT_DIR}/zero_copy_clone.log"

docker compose run --rm --no-deps dbt-executor python - <<'PY' | tee "${ARTIFACT_DIR}/snowflake_validation.txt"
import os

import snowflake.connector


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


queries = {
    "edp_in_orders_order_grain": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_ORDERS_ORDER_GRAIN')}",
        30,
    ),
    "edp_in_orders_customer_grain": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_ORDERS_CUSTOMER_GRAIN')}",
        12,
    ),
    "edp_in_order_lines_order_grain": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_ORDER_LINES_ORDER_GRAIN')}",
        60,
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

print("edp_promotion=passed")
PY

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
EDP promotion succeeded.
snowflake.edp_in_orders_order_grain=30
snowflake.edp_in_orders_customer_grain=12
snowflake.edp_in_order_lines_order_grain=60
snowflake.edp_core_dim_customers=12
snowflake.edp_core_dim_order_status=3
snowflake.edp_core_orders_3nf=30
snowflake.edp_fact_order_revenue_star=30
snowflake.edp_access_orders_only=30
snowflake.edp_access_orders_complete=30
snowflake.edp_access_orders_fulfilled=20
snowflake.edp_dbt_project=${SNOWFLAKE_EDP_DBT_PROJECT}
snowflake.dbt_target=${dbt_target_name}
EOF
