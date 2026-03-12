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

ARTIFACT_DIR="${ROOT_DIR}/artifacts/edp_customers"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

required_vars=(
  SNOWFLAKE_ACCOUNT
  SNOWFLAKE_USER
  SNOWFLAKE_PASSWORD
  SNOWFLAKE_ROLE
  SNOWFLAKE_WAREHOUSE
  SNOWFLAKE_SDP_CUSTOMERS_DATABASE
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
    "T_CUSTOMERS_ENTITY_GRAIN": 12,
    "T_CUSTOMERS_REGION_GRAIN": 3,
    "T_CUSTOMERS_SEGMENT_GRAIN": 3,
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
                    f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_CUSTOMERS_DATABASE'], os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], table_name)}"
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
    proj_edp_customers \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    "${SNOWFLAKE_EDP_DATABASE}" \
    "${SNOWFLAKE_EDP_CORE_SCHEMA}" \
    "${dbt_target_name}" | tee "${ARTIFACT_DIR}/dbt_deploy.log"

  bash "${SCRIPT_DIR}/execute-snowflake-dbt-project.sh" \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    parse | tee "${ARTIFACT_DIR}/dbt_parse.log"

  bash "${SCRIPT_DIR}/prepare-snowflake-dbt-target.sh" \
    proj_edp_customers \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" | tee "${ARTIFACT_DIR}/dbt_prepare.log"

  bash "${SCRIPT_DIR}/execute-snowflake-dbt-project.sh" \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    build | tee "${ARTIFACT_DIR}/dbt_build.log"
fi

docker compose run --rm --no-deps -e SNOWFLAKE_ZERO_COPY_FACT_TABLE=FCT_CUSTOMER_VALUE_STAR dbt-executor \
  python /opt/platform/dbt/scripts/zero_copy_clone_check.py | tee "${ARTIFACT_DIR}/zero_copy_clone.log"

docker compose run --rm --no-deps dbt-executor python - <<'PY' | tee "${ARTIFACT_DIR}/snowflake_validation.txt"
import os

import snowflake.connector


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


queries = {
    "edp_customers_in_entity_grain": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_CUSTOMERS_ENTITY_GRAIN')}",
        12,
    ),
    "edp_customers_in_region_grain": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_CUSTOMERS_REGION_GRAIN')}",
        3,
    ),
    "edp_customers_in_segment_grain": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_CUSTOMERS_SEGMENT_GRAIN')}",
        3,
    ),
    "edp_customers_core_dim_regions": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'DIM_REGIONS')}",
        3,
    ),
    "edp_customers_core_dim_segments": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'DIM_SEGMENTS')}",
        3,
    ),
    "edp_customers_core_customers_3nf": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'T_CUSTOMERS_3NF')}",
        12,
    ),
    "edp_customers_fact_customer_value_star": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'FCT_CUSTOMER_VALUE_STAR')}",
        12,
    ),
    "edp_customers_access_only": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_CUSTOMERS_ONLY')}",
        12,
    ),
    "edp_customers_access_complete": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_CUSTOMERS_COMPLETE')}",
        12,
    ),
    "edp_customers_access_high_value": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_CUSTOMERS_HIGH_VALUE')}",
        4,
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
