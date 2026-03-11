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
    -c "do \$\$ begin if to_regclass('public.iceberg_tables') is not null and to_regclass('public.iceberg_namespace_properties') is not null then execute 'truncate table iceberg_tables, iceberg_namespace_properties restart identity cascade'; end if; end \$\$;" >/dev/null
fi

echo "dropping lingering Snowflake CI clone databases"
bash ./scripts/cleanup-snowflake-ci-clones.sh

echo "dropping Snowflake control, SDP, and EDP databases for a clean rebuild"
docker compose run --rm --no-deps \
  -e "PRD_SNOWFLAKE_SDP_DATABASE=${PRD_SNOWFLAKE_SDP_DATABASE}" \
  -e "PRD_SNOWFLAKE_EDP_DATABASE=${PRD_SNOWFLAKE_EDP_DATABASE}" \
  -e "PRD_SNOWFLAKE_SDP_DBT_PROJECT=${PRD_SNOWFLAKE_SDP_DBT_PROJECT}" \
  -e "PRD_SNOWFLAKE_EDP_DBT_PROJECT=${PRD_SNOWFLAKE_EDP_DBT_PROJECT}" \
  dbt-executor python - <<'PY'
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
        cursor.execute(f'drop database if exists {ident(os.environ["PRD_SNOWFLAKE_EDP_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["PRD_SNOWFLAKE_SDP_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_EDP_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_SDP_DATABASE"])}')
finally:
    connection.close()

print(
    {
        "dropped_control_database": os.environ["SNOWFLAKE_CONTROL_DATABASE"],
        "dropped_sdp_database": os.environ["SNOWFLAKE_SDP_DATABASE"],
        "dropped_edp_database": os.environ["SNOWFLAKE_EDP_DATABASE"],
        "dropped_prd_sdp_database": os.environ["PRD_SNOWFLAKE_SDP_DATABASE"],
        "dropped_prd_edp_database": os.environ["PRD_SNOWFLAKE_EDP_DATABASE"],
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

echo "building SDP data product"
bash ./scripts/execute-snowflake-dbt-project.sh "${SNOWFLAKE_SDP_DBT_PROJECT}" build

echo "verifying rebuilt SDP without rerunning dbt"
./scripts/verify-sdp-promotion.sh --skip-foundation --skip-raw-sync --skip-dbt

echo "verifying only SDP exists after initialization"
docker compose run --rm --no-deps \
  -e "PRD_SNOWFLAKE_SDP_DATABASE=${PRD_SNOWFLAKE_SDP_DATABASE}" \
  -e "PRD_SNOWFLAKE_EDP_DATABASE=${PRD_SNOWFLAKE_EDP_DATABASE}" \
  -e "PRD_SNOWFLAKE_SDP_DBT_PROJECT=${PRD_SNOWFLAKE_SDP_DBT_PROJECT}" \
  -e "PRD_SNOWFLAKE_EDP_DBT_PROJECT=${PRD_SNOWFLAKE_EDP_DBT_PROJECT}" \
  dbt-executor python - <<'PY'
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
)

sdp_database = os.environ["SNOWFLAKE_SDP_DATABASE"]
edp_database = os.environ["SNOWFLAKE_EDP_DATABASE"]
prd_sdp_database = os.environ["PRD_SNOWFLAKE_SDP_DATABASE"]
prd_edp_database = os.environ["PRD_SNOWFLAKE_EDP_DATABASE"]
sdp_project_name = os.environ["SNOWFLAKE_SDP_DBT_PROJECT"]
edp_project_name = os.environ["SNOWFLAKE_EDP_DBT_PROJECT"]
prd_sdp_project_name = os.environ["PRD_SNOWFLAKE_SDP_DBT_PROJECT"]
prd_edp_project_name = os.environ["PRD_SNOWFLAKE_EDP_DBT_PROJECT"]

try:
    with connection.cursor() as cursor:
        cursor.execute(
            f"show dbt projects in schema {ident(os.environ['SNOWFLAKE_CONTROL_DATABASE'])}.{ident(os.environ['SNOWFLAKE_CONTROL_SCHEMA'])}"
        )
        cursor.execute("select \"name\" from table(result_scan(last_query_id()))")
        dbt_projects = {row[0] for row in cursor.fetchall()}
        if sdp_project_name not in dbt_projects:
            raise SystemExit(f"expected SDP dbt project object to exist after initialization: {sdp_project_name}")
        if edp_project_name in dbt_projects:
            raise SystemExit(f"unexpected EDP dbt project object present after initialization: {edp_project_name}")
        if prd_sdp_project_name in dbt_projects:
            raise SystemExit(f"unexpected PRD SDP dbt project object present after initialization: {prd_sdp_project_name}")
        if prd_edp_project_name in dbt_projects:
            raise SystemExit(f"unexpected PRD EDP dbt project object present after initialization: {prd_edp_project_name}")

        cursor.execute("show databases")
        databases = {row[1] for row in cursor.fetchall()}
        if sdp_database not in databases:
            raise SystemExit(f"expected SDP database to exist after initialization: {sdp_database}")
        if edp_database in databases:
            raise SystemExit(f"unexpected EDP database present after initialization: {edp_database}")
        if prd_sdp_database in databases:
            raise SystemExit(f"unexpected PRD SDP database present after initialization: {prd_sdp_database}")
        if prd_edp_database in databases:
            raise SystemExit(f"unexpected PRD EDP database present after initialization: {prd_edp_database}")

        print(
            {
                "sdp_deployed": True,
                "edp_deployed": False,
                "prd_deployed": False,
                "sdp_database_present": sdp_database,
            }
        )
finally:
    connection.close()
PY

echo "snowflake-only bootstrap complete"
