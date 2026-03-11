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

snowflake_host_root="${ROOT_DIR}/snowflake"
snowflake_container_root="/opt/platform/snowflake"
if [ ! -d "${snowflake_host_root}" ] && [ -d "${ROOT_DIR}/ci/snowflake" ]; then
  snowflake_host_root="${ROOT_DIR}/ci/snowflake"
  snowflake_container_root="/opt/platform/ci/snowflake"
fi

required_vars=(
  SNOWFLAKE_ACCOUNT
  SNOWFLAKE_USER
  SNOWFLAKE_PASSWORD
  SNOWFLAKE_ROLE
  SNOWFLAKE_WAREHOUSE
  SNOWFLAKE_CONTROL_DATABASE
  SNOWFLAKE_CONTROL_SCHEMA
  SNOWFLAKE_DBT_STAGE
)

for key in "${required_vars[@]}"; do
  if [ -z "${!key:-}" ]; then
    echo "missing required Snowflake variable: ${key}" >&2
    exit 1
  fi
done

sql_files=(
  "${snowflake_container_root}/sql/01_snowflake_foundation.sql.tpl"
)

if [ -d "${snowflake_host_root}/sql/products" ]; then
  while IFS= read -r sql_file; do
    sql_files+=("${snowflake_container_root}/sql/products/$(basename "${sql_file}")")
  done < <(find "${snowflake_host_root}/sql/products" -maxdepth 1 -type f -name '*.sql.tpl' | sort)
fi

if [ -n "${OPEN_CATALOG_URI:-}" ] && [ -n "${OPEN_CATALOG_NAME:-}" ] && [ -n "${OPEN_CATALOG_CLIENT_ID:-}" ] && [ -n "${OPEN_CATALOG_CLIENT_SECRET:-}" ]; then
  if [ -f "${snowflake_host_root}/sql/02_open_catalog_integration.sql.tpl" ] && [ -f "${snowflake_host_root}/sql/03_catalog_linked_database.sql.tpl" ]; then
    sql_files+=(
      "${snowflake_container_root}/sql/02_open_catalog_integration.sql.tpl"
      "${snowflake_container_root}/sql/03_catalog_linked_database.sql.tpl"
    )
  fi
else
  echo "Skipping Open Catalog foundation because OPEN_CATALOG_* variables are incomplete"
fi

docker compose run --rm --no-deps dbt-executor \
  python /opt/platform/dbt/scripts/apply_sql.py "${sql_files[@]}"
