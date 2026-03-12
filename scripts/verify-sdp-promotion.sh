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
scope="${SOURCE_SCOPE:-all}"

skip_foundation="false"
skip_raw_sync="false"
skip_dbt="false"

while [ $# -gt 0 ]; do
  case "${1}" in
    --scope)
      scope="${2:?scope value is required}"
      shift
      ;;
    --skip-foundation)
      skip_foundation="true"
      ;;
    --skip-raw-sync)
      skip_raw_sync="true"
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
export SOURCE_SCOPE="${scope}"

ARTIFACT_DIR="${ROOT_DIR}/artifacts/sdp"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

required_vars=(
  SNOWFLAKE_ACCOUNT
  SNOWFLAKE_USER
  SNOWFLAKE_PASSWORD
  SNOWFLAKE_ROLE
  SNOWFLAKE_WAREHOUSE
  SNOWFLAKE_SDP_DATABASE
  SNOWFLAKE_SDP_CUSTOMERS_DATABASE
  SNOWFLAKE_SDP_IN_SCHEMA
  SNOWFLAKE_SDP_CORE_SCHEMA
  SNOWFLAKE_SDP_ACC_SCHEMA
)

for key in "${required_vars[@]}"; do
  if [ -z "${!key:-}" ]; then
    echo "missing required SDP promotion variable: ${key}" >&2
    exit 1
  fi
done

if [ "${SNOWFLAKE_LOCAL_RAW_SYNC:-false}" != "true" ] && {
  [ -z "${OPEN_CATALOG_URI:-}" ] || [ -z "${OPEN_CATALOG_NAME:-}" ] || [ -z "${OPEN_CATALOG_CLIENT_ID:-}" ] || [ -z "${OPEN_CATALOG_CLIENT_SECRET:-}" ];
}; then
  echo "SDP promotion requires either SNOWFLAKE_LOCAL_RAW_SYNC=true or complete OPEN_CATALOG_* configuration" >&2
  exit 1
fi

if [ "${skip_foundation}" != "true" ]; then
  bash "${SCRIPT_DIR}/ensure-snowflake-foundation.sh" | tee "${ARTIFACT_DIR}/snowflake_bootstrap.log"
fi

if [ "${skip_raw_sync}" != "true" ] && [ "${SNOWFLAKE_LOCAL_RAW_SYNC:-false}" = "true" ]; then
  docker compose run --rm --no-deps dlt-extractor \
    bash -lc "RAW_SYNC_SCOPE=${scope} python /opt/platform/dlt/snowflake_raw_sync.py" | tee "${ARTIFACT_DIR}/snowflake_raw_sync.log"
fi

docker compose run --rm --no-deps -e SOURCE_SCOPE="${scope}" dbt-executor python - <<'PY' | tee "${ARTIFACT_DIR}/sdp_inbound_contract.txt"
import os

import snowflake.connector


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


scope = os.environ.get("SOURCE_SCOPE", "all").strip().lower()
queries = {}
if scope in {"all", "orders"}:
    queries.update(
        {
            "sdp_ext_raw_orders": (
                f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_IN_SCHEMA'], 'EXT_ORDERS_RAW')}",
                30,
            ),
            "sdp_ext_raw_order_items": (
                f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_IN_SCHEMA'], 'EXT_ORDER_ITEMS_RAW')}",
                60,
            ),
        }
    )
if scope in {"all", "customers"}:
    queries.update(
        {
            "sdp_customers_ext_customers_raw": (
                f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_CUSTOMERS_DATABASE'], os.environ['SNOWFLAKE_SDP_IN_SCHEMA'], 'EXT_CUSTOMERS_RAW')}",
                12,
            ),
        }
    )

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
            try:
                cursor.execute(sql)
            except Exception as exc:  # pragma: no cover - surfaced as process failure
                raise SystemExit(
                    f"required inbound SDP table is missing for {name}. Promote the ingestion flow first. Original error: {exc}"
                ) from exc
            actual = cursor.fetchone()[0]
            if actual != expected:
                raise SystemExit(f"expected {expected} rows for {name}, found {actual}")
            print(f"{name}={actual}")
finally:
    connection.close()

print("sdp_inbound_contract=passed")
PY

if [ "${skip_dbt}" != "true" ]; then
  dbt_select_args=()
  if [ "${scope}" != "all" ]; then
    dbt_select_args=(--select "${scope}")
  fi

  bash "${SCRIPT_DIR}/deploy-snowflake-dbt-project.sh" \
    proj_source_finnova \
    "${SNOWFLAKE_SDP_DBT_PROJECT}" \
    "${SNOWFLAKE_SDP_DATABASE}" \
    "${SNOWFLAKE_SDP_CORE_SCHEMA}" \
    "${dbt_target_name}" | tee "${ARTIFACT_DIR}/dbt_deploy.log"

  bash "${SCRIPT_DIR}/execute-snowflake-dbt-project.sh" \
    "${SNOWFLAKE_SDP_DBT_PROJECT}" \
    parse | tee "${ARTIFACT_DIR}/dbt_parse.log"

  bash "${SCRIPT_DIR}/prepare-snowflake-dbt-target.sh" \
    proj_source_finnova \
    "${SNOWFLAKE_SDP_DBT_PROJECT}" | tee "${ARTIFACT_DIR}/dbt_prepare.log"

  bash "${SCRIPT_DIR}/execute-snowflake-dbt-project.sh" \
    "${SNOWFLAKE_SDP_DBT_PROJECT}" \
    build "${dbt_select_args[@]}" | tee "${ARTIFACT_DIR}/dbt_build.log"
fi

docker compose run --rm --no-deps -e SOURCE_SCOPE="${scope}" dbt-executor python - <<'PY' | tee "${ARTIFACT_DIR}/snowflake_validation.txt"
import os

import snowflake.connector


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


scope = os.environ.get("SOURCE_SCOPE", "all").strip().lower()
queries = {}
if scope in {"all", "orders"}:
    queries.update(
        {
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
            "sdp_access_order_lines_order_grain": (
                f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], 'T_ORDER_LINES_ORDER_GRAIN')}",
                60,
            ),
        }
    )
if scope in {"all", "customers"}:
    queries.update(
        {
            "sdp_customers_ext_customers_raw": (
                f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_CUSTOMERS_DATABASE'], os.environ['SNOWFLAKE_SDP_IN_SCHEMA'], 'EXT_CUSTOMERS_RAW')}",
                12,
            ),
            "sdp_customers_core_customers_clean": (
                f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_CUSTOMERS_DATABASE'], os.environ['SNOWFLAKE_SDP_CORE_SCHEMA'], 'T_CUSTOMERS_CLEAN')}",
                12,
            ),
            "sdp_customers_core_customer_region_summary": (
                f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_CUSTOMERS_DATABASE'], os.environ['SNOWFLAKE_SDP_CORE_SCHEMA'], 'T_CUSTOMER_REGION_SUMMARY')}",
                3,
            ),
            "sdp_customers_core_customer_segment_summary": (
                f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_CUSTOMERS_DATABASE'], os.environ['SNOWFLAKE_SDP_CORE_SCHEMA'], 'T_CUSTOMER_SEGMENT_SUMMARY')}",
                3,
            ),
            "sdp_customers_access_entity_grain": (
                f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_CUSTOMERS_DATABASE'], os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], 'T_CUSTOMERS_ENTITY_GRAIN')}",
                12,
            ),
            "sdp_customers_access_region_grain": (
                f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_CUSTOMERS_DATABASE'], os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], 'T_CUSTOMERS_REGION_GRAIN')}",
                3,
            ),
            "sdp_customers_access_segment_grain": (
                f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_CUSTOMERS_DATABASE'], os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], 'T_CUSTOMERS_SEGMENT_GRAIN')}",
                3,
            ),
        }
    )

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

print("sdp_promotion=passed")
PY

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
SDP promotion succeeded.
source.scope=${scope}
snowflake.sdp_dbt_project=${SNOWFLAKE_SDP_DBT_PROJECT}
snowflake.dbt_target=${dbt_target_name}
EOF
