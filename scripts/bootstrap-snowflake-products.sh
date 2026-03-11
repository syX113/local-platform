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

echo "reloading deterministic source sample data"
./scripts/load-source-sample-data.sh

if [ "${ICEBERG_CATALOG_TYPE:-sql}" = "sql" ]; then
  echo "clearing local SQL Iceberg catalog entries"
  docker compose exec -T airflow-metadata-db \
    psql -U "${AIRFLOW_METADATA_DB_USER}" -d iceberg_catalog \
    -c "truncate table iceberg_tables, iceberg_namespace_properties restart identity cascade;" >/dev/null
fi

echo "dropping lingering Snowflake CI clone databases"
bash ./scripts/cleanup-snowflake-ci-clones.sh

echo "dropping Snowflake control, SDP, and EDP databases for a clean rebuild"
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
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_CONTROL_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_EDP_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_SDP_DATABASE"])}')
finally:
    connection.close()

print(
    {
        "dropped_control_database": os.environ["SNOWFLAKE_CONTROL_DATABASE"],
        "dropped_sdp_database": os.environ["SNOWFLAKE_SDP_DATABASE"],
        "dropped_edp_database": os.environ["SNOWFLAKE_EDP_DATABASE"],
    }
)
PY

echo "recreating Snowflake foundation"
bash ./scripts/ensure-snowflake-foundation.sh

export_dev_runtime_env

echo "refreshing DEV Iceberg artifacts"
docker compose run --rm --no-deps dlt-extractor python /opt/platform/dlt/pipeline.py

echo "syncing inbound Snowflake raw tables"
docker compose run --rm --no-deps dlt-extractor python /opt/platform/dlt/snowflake_raw_sync.py

echo "deploying DEV Snowflake dbt projects"
bash ./scripts/deploy-snowflake-dbt-project.sh \
  proj_sdp_orders \
  "${SNOWFLAKE_SDP_DBT_PROJECT}" \
  "${SNOWFLAKE_SDP_DATABASE}" \
  "${SNOWFLAKE_SDP_CORE_SCHEMA}" \
  dev
bash ./scripts/deploy-snowflake-dbt-project.sh \
  proj_edp_orders \
  "${SNOWFLAKE_EDP_DBT_PROJECT}" \
  "${SNOWFLAKE_EDP_DATABASE}" \
  "${SNOWFLAKE_EDP_CORE_SCHEMA}" \
  dev

echo "building SDP data product"
bash ./scripts/execute-snowflake-dbt-project.sh "${SNOWFLAKE_SDP_DBT_PROJECT}" build

echo "building EDP data product"
bash ./scripts/execute-snowflake-dbt-project.sh "${SNOWFLAKE_EDP_DBT_PROJECT}" build

echo "verifying rebuilt SDP without rerunning dbt"
./scripts/verify-sdp-promotion.sh --skip-foundation --skip-raw-sync --skip-dbt

echo "verifying rebuilt EDP without rerunning dbt"
./scripts/verify-edp-promotion.sh --skip-foundation --skip-dbt

echo "snowflake-only bootstrap complete"
