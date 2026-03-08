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
  SNOWFLAKE_SDP_DATABASE
  SNOWFLAKE_EDP_DATABASE
)

for key in "${required_vars[@]}"; do
  if [ -z "${!key:-}" ]; then
    echo "missing required Snowflake variable: ${key}" >&2
    exit 1
  fi
done

sdp_container_dbt_project_dir="$(resolve_container_dbt_project_dir proj_sdp_orders)"
edp_container_dbt_project_dir="$(resolve_container_dbt_project_dir proj_edp_orders)"

echo "starting local source dependencies"
docker compose up -d source-postgres-db

echo "reloading deterministic source sample data"
./scripts/load-source-sample-data.sh

echo "dropping Snowflake SDP and EDP databases for a clean rebuild"
docker compose run --rm --no-deps dbt-executor python - <<'PY'
import os

import snowflake.connector


def ident(name: str) -> str:
    return f'"{name}"'


connection = snowflake.connector.connect(
    account=os.environ["SNOWFLAKE_ACCOUNT"],
    user=os.environ["SNOWFLAKE_USER"],
    password=os.environ["SNOWFLAKE_PASSWORD"],
    role=os.environ["SNOWFLAKE_ROLE"],
    warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
    autocommit=True,
)

try:
    with connection.cursor() as cursor:
        cursor.execute(f'use role {ident(os.environ["SNOWFLAKE_ROLE"])}')
        cursor.execute(f'use warehouse {ident(os.environ["SNOWFLAKE_WAREHOUSE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_EDP_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_SDP_DATABASE"])}')
finally:
    connection.close()

print(
    {
        "dropped_sdp_database": os.environ["SNOWFLAKE_SDP_DATABASE"],
        "dropped_edp_database": os.environ["SNOWFLAKE_EDP_DATABASE"],
    }
)
PY

echo "recreating Snowflake foundation"
bash ./scripts/ensure-snowflake-foundation.sh

echo "syncing inbound Snowflake raw tables"
docker compose run --rm --no-deps dlt-extractor python /opt/platform/dlt/snowflake_raw_sync.py

echo "building SDP data product"
docker compose run --rm --no-deps dbt-executor \
  dbt build --project-dir "${sdp_container_dbt_project_dir}" --profiles-dir /opt/platform/dbt/profiles

echo "building EDP data product"
docker compose run --rm --no-deps dbt-executor \
  dbt build --project-dir "${edp_container_dbt_project_dir}" --profiles-dir /opt/platform/dbt/profiles

echo "validating rebuilt SDP"
./scripts/verify-sdp-promotion.sh

echo "validating rebuilt EDP"
./scripts/verify-edp-promotion.sh

echo "snowflake-only bootstrap complete"
