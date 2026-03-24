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

dbt_target_name="${SNOW_DBT_TARGET_NAME:-dev}"
project_slug="proj_edp_orders"

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
    -*)
      echo "unsupported argument: ${1}" >&2
      exit 1
      ;;
    *)
      if [ "${project_slug}" = "proj_edp_orders" ]; then
        project_slug="${1}"
      else
        echo "unsupported positional argument: ${1}" >&2
        exit 1
      fi
      ;;
  esac
  shift
done

project_scope="$(project_registry_lookup "${project_slug}" scope)"
ARTIFACT_DIR="${ROOT_DIR}/artifacts/${project_slug}"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"
export PROJECT_SCOPE="${project_scope}"

database_env_name="$(project_registry_lookup "${project_slug}" default_database_env)"
export SNOWFLAKE_EDP_DATABASE="${!database_env_name:-${SNOWFLAKE_EDP_DATABASE}}"

if [ -z "${SNOWFLAKE_EDP_DBT_PROJECT:-}" ]; then
  export SNOWFLAKE_EDP_DBT_PROJECT="$(project_registry_project_name_for_target "${project_slug}" "${SNOW_DBT_TARGET_NAME:-dev}")"
fi

required_vars=(
  SNOWFLAKE_ACCOUNT
  SNOWFLAKE_USER
  SNOWFLAKE_PASSWORD
  SNOWFLAKE_ROLE
  SNOWFLAKE_WAREHOUSE
  SNOWFLAKE_EDP_DATABASE
  SNOWFLAKE_EDP_IN_SCHEMA
  SNOWFLAKE_EDP_CORE_SCHEMA
  SNOWFLAKE_EDP_ACC_SCHEMA
)

if [ "${project_scope}" = "customers" ]; then
  required_vars+=(
    SNOWFLAKE_SDP_CUSTOMERS_DATABASE
    SNOWFLAKE_SDP_ACC_SCHEMA
  )
else
  required_vars+=(
    SNOWFLAKE_SDP_DATABASE
    SNOWFLAKE_SDP_ACC_SCHEMA
  )
fi

for key in "${required_vars[@]}"; do
  if [ -z "${!key:-}" ]; then
    echo "missing required EDP promotion variable: ${key}" >&2
    exit 1
  fi
done

if [ "${skip_foundation}" != "true" ]; then
  bash "${SCRIPT_DIR}/ensure-snowflake-foundation.sh" | tee "${ARTIFACT_DIR}/snowflake_bootstrap.log"
fi

docker compose run --rm --no-deps -e "PROJECT_SCOPE=${project_scope}" dbt-executor python - <<'PY' | tee "${ARTIFACT_DIR}/sdp_contract_check.txt"
import os
import sys

import snowflake.connector


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


project_scope = os.environ["PROJECT_SCOPE"]
if project_scope == "customers":
    tables = {
        "T_CUSTOMERS_ENTITY_GRAIN": 12,
        "T_CUSTOMERS_REGION_GRAIN": 3,
        "T_CUSTOMERS_SEGMENT_GRAIN": 3,
    }
    source_database = os.environ["SNOWFLAKE_SDP_CUSTOMERS_DATABASE"]
else:
    tables = {
        "T_ORDERS_ORDER_GRAIN": 30,
        "T_ORDERS_CUSTOMER_GRAIN": 12,
        "T_ORDER_LINES_ORDER_GRAIN": 60,
    }
    source_database = os.environ["SNOWFLAKE_SDP_DATABASE"]

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
                    f"select count(*) from {ident(source_database, os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], table_name)}"
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
  export PROJECT_SCOPE="${project_scope}"
  bash "${SCRIPT_DIR}/deploy-snowflake-dbt-project.sh" \
    "${project_slug}" \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    "${SNOWFLAKE_EDP_DATABASE}" \
    "${SNOWFLAKE_EDP_CORE_SCHEMA}" \
    "${dbt_target_name}" | tee "${ARTIFACT_DIR}/dbt_deploy.log"

  bash "${SCRIPT_DIR}/execute-snowflake-dbt-project.sh" \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    parse | tee "${ARTIFACT_DIR}/dbt_parse.log"

  bash "${SCRIPT_DIR}/prepare-snowflake-dbt-target.sh" \
    "${project_slug}" \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" | tee "${ARTIFACT_DIR}/dbt_prepare.log"

  bash "${SCRIPT_DIR}/execute-snowflake-dbt-project.sh" \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    build | tee "${ARTIFACT_DIR}/dbt_build.log"
fi

docker compose run --rm --no-deps \
  -e "PROJECT_SLUG=${project_slug}" \
  -e "PROJECT_SCOPE=${project_scope}" \
  dbt-executor \
  python /opt/platform/dbt/scripts/zero_copy_clone_check.py | tee "${ARTIFACT_DIR}/zero_copy_clone.log"

docker compose run --rm --no-deps -e "PROJECT_SCOPE=${project_scope}" dbt-executor python - <<'PY' | tee "${ARTIFACT_DIR}/snowflake_validation.txt"
import os

import snowflake.connector


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


project_scope = os.environ["PROJECT_SCOPE"]
if project_scope == "customers":
    queries = {
        "edp_in_customers_entity_grain": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_CUSTOMERS_ENTITY_GRAIN')}",
            12,
        ),
        "edp_in_customers_region_grain": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_CUSTOMERS_REGION_GRAIN')}",
            3,
        ),
        "edp_in_customers_segment_grain": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_CUSTOMERS_SEGMENT_GRAIN')}",
            3,
        ),
        "edp_core_dim_regions": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'DIM_REGIONS')}",
            3,
        ),
        "edp_core_dim_segments": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'DIM_SEGMENTS')}",
            3,
        ),
        "edp_core_customers_3nf": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'T_CUSTOMERS_3NF')}",
            12,
        ),
        "edp_fact_customer_value_star": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'FCT_CUSTOMER_VALUE_STAR')}",
            12,
        ),
        "edp_access_customers_only": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_CUSTOMERS_ONLY')}",
            12,
        ),
        "edp_access_customers_complete": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_CUSTOMERS_COMPLETE')}",
            12,
        ),
        "edp_access_customers_high_value": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_CUSTOMERS_HIGH_VALUE')}",
            4,
        ),
    }
else:
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

if [ "${project_scope}" = "customers" ]; then
  cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
EDP customers promotion succeeded.
snowflake.edp_customers_in_entity_grain=12
snowflake.edp_customers_in_region_grain=3
snowflake.edp_customers_in_segment_grain=3
snowflake.edp_customers_core_dim_regions=3
snowflake.edp_customers_core_dim_segments=3
snowflake.edp_customers_core_customers_3nf=12
snowflake.edp_customers_fact_customer_value_star=12
snowflake.edp_customers_access_only=12
snowflake.edp_customers_access_complete=12
snowflake.edp_customers_access_high_value=4
snowflake.edp_dbt_project=${SNOWFLAKE_EDP_DBT_PROJECT}
snowflake.dbt_target=${dbt_target_name}
EOF
else
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
fi
