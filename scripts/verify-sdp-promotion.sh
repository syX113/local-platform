#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

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

container_dbt_project_dir="$(resolve_container_dbt_project_dir proj_sdp_orders)"

./scripts/bootstrap-snowflake.sh | tee "${ARTIFACT_DIR}/snowflake_bootstrap.log"

docker compose run --rm --no-deps dbt-executor python - <<'PY' | tee "${ARTIFACT_DIR}/sdp_inbound_contract.txt"
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

docker compose run --rm --no-deps dbt-executor \
  dbt parse --project-dir "${container_dbt_project_dir}" --profiles-dir /opt/platform/dbt/profiles \
  | tee "${ARTIFACT_DIR}/dbt_parse.log"

docker compose run --rm --no-deps dbt-executor \
  dbt build --project-dir "${container_dbt_project_dir}" --profiles-dir /opt/platform/dbt/profiles \
  | tee "${ARTIFACT_DIR}/dbt_build.log"

docker compose run --rm --no-deps dbt-executor python - <<'PY' | tee "${ARTIFACT_DIR}/snowflake_validation.txt"
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
    "sdp_access_order_lines_order_grain": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], 'T_ORDER_LINES_ORDER_GRAIN')}",
        60,
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

print("sdp_promotion=passed")
PY

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
SDP promotion succeeded.
snowflake.sdp_ext_raw_orders=30
snowflake.sdp_ext_raw_order_items=60
snowflake.sdp_core_orders_clean=30
snowflake.sdp_core_order_items_clean=60
snowflake.sdp_access_orders_order_grain=30
snowflake.sdp_access_orders_customer_grain=12
snowflake.sdp_access_order_lines_order_grain=60
EOF
