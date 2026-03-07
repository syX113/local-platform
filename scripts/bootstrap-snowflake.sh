#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

required_vars=(
  SNOWFLAKE_ACCOUNT
  SNOWFLAKE_USER
  SNOWFLAKE_PASSWORD
  SNOWFLAKE_ROLE
  SNOWFLAKE_WAREHOUSE
  SNOWFLAKE_TARGET_DATABASE
  SNOWFLAKE_TARGET_SCHEMA
)

for key in "${required_vars[@]}"; do
  if [ -z "${!key:-}" ]; then
    echo "missing required Snowflake variable: ${key}" >&2
    exit 1
  fi
done

sql_files=(
  /opt/platform/snowflake/sql/01_snowflake_foundation.sql.tpl
)

if [ -n "${OPEN_CATALOG_URI:-}" ] && [ -n "${OPEN_CATALOG_NAME:-}" ] && [ -n "${OPEN_CATALOG_CLIENT_ID:-}" ] && [ -n "${OPEN_CATALOG_CLIENT_SECRET:-}" ]; then
  sql_files+=(
    /opt/platform/snowflake/sql/02_open_catalog_integration.sql.tpl
    /opt/platform/snowflake/sql/03_catalog_linked_database.sql.tpl
  )
else
  echo "Skipping Open Catalog bootstrap because OPEN_CATALOG_* variables are incomplete"
fi

docker compose run --rm dbt-executor \
  python /opt/platform/dbt/scripts/apply_sql.py "${sql_files[@]}"
