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

docker compose run --rm --no-deps dbt-executor python - <<'PY'
import os
import snowflake.connector


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


control_database = os.environ["SNOWFLAKE_CONTROL_DATABASE"]
control_schema = os.environ["SNOWFLAKE_CONTROL_SCHEMA"]
control_stage = os.environ["SNOWFLAKE_DBT_STAGE"]

connection = snowflake.connector.connect(
    account=os.environ["SNOWFLAKE_ACCOUNT"],
    user=os.environ["SNOWFLAKE_USER"],
    password=os.environ["SNOWFLAKE_PASSWORD"],
    role=os.environ["SNOWFLAKE_ROLE"],
    warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
)

try:
    with connection.cursor() as cursor:
        cursor.execute(f"show databases like '{control_database}'")
        if not cursor.fetchall():
            raise SystemExit(f"missing Snowflake control database: {control_database}")

        cursor.execute(f"show schemas like '{control_schema}' in database {ident(control_database)}")
        if not cursor.fetchall():
            raise SystemExit(
                f"missing Snowflake control schema: {control_database}.{control_schema}"
            )

        cursor.execute(
            f"show stages like '{control_stage}' in schema {ident(control_database, control_schema)}"
        )
        if not cursor.fetchall():
            raise SystemExit(
                f"missing Snowflake dbt stage: {control_database}.{control_schema}.{control_stage}"
            )
finally:
    connection.close()

print(
    {
        "control_database": control_database,
        "control_schema": control_schema,
        "control_stage": control_stage,
    }
)
PY
