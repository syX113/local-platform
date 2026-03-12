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
  SNOWFLAKE_SDP_CUSTOMERS_DATABASE
  SNOWFLAKE_EDP_DATABASE
  SNOWFLAKE_EDP_CUSTOMERS_DATABASE
  PRD_SNOWFLAKE_SDP_DATABASE
  PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE
  PRD_SNOWFLAKE_EDP_DATABASE
  PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE
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

echo "dropping Snowflake control and all data product databases for a clean rebuild"
docker compose run --rm --no-deps dbt-executor python - <<'PY'
import os

import snowflake.connector


def ident(name: str) -> str:
    return f'"{name}"'


database_names = [
    os.environ["PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE"],
    os.environ["PRD_SNOWFLAKE_EDP_DATABASE"],
    os.environ["PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE"],
    os.environ["PRD_SNOWFLAKE_SDP_DATABASE"],
    os.environ["SNOWFLAKE_EDP_CUSTOMERS_DATABASE"],
    os.environ["SNOWFLAKE_EDP_DATABASE"],
    os.environ["SNOWFLAKE_SDP_CUSTOMERS_DATABASE"],
    os.environ["SNOWFLAKE_SDP_DATABASE"],
]

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
        for database_name in database_names:
            cursor.execute(f'drop database if exists {ident(database_name)}')
finally:
    connection.close()

print({"dropped_databases": database_names})
PY

echo "recreating Snowflake foundation"
bash ./scripts/ensure-snowflake-foundation.sh

echo "deploying DEV source data products"
bash ./scripts/deploy-sdp-dev.sh

echo "deploying PRD source data products"
bash ./scripts/deploy-sdp-prd.sh

echo "deploying DEV EDP customers data product"
bash ./scripts/deploy-edp-customers-dev.sh

echo "deploying PRD EDP customers data product"
bash ./scripts/deploy-edp-customers-prd.sh

echo "deploying DEV EDP orders dbt project object without materializing DEV objects"
export_dev_runtime_env
export SNOWFLAKE_EDP_DATABASE="${SNOWFLAKE_CONTROL_DATABASE}"
export SNOWFLAKE_EDP_IN_SCHEMA="${SNOWFLAKE_CONTROL_SCHEMA}"
export SNOWFLAKE_EDP_CORE_SCHEMA="${SNOWFLAKE_CONTROL_SCHEMA}"
export SNOWFLAKE_EDP_ACC_SCHEMA="${SNOWFLAKE_CONTROL_SCHEMA}"
bash ./scripts/deploy-snowflake-dbt-project.sh \
  proj_edp_orders \
  "${DEV_SNOWFLAKE_EDP_DBT_PROJECT}" \
  "${SNOWFLAKE_CONTROL_DATABASE}" \
  "${SNOWFLAKE_CONTROL_SCHEMA}" \
  "dev"

echo "deploying PRD EDP orders dbt project object without materializing PRD objects"
export_prd_runtime_env
export SNOWFLAKE_EDP_DATABASE="${SNOWFLAKE_CONTROL_DATABASE}"
export SNOWFLAKE_EDP_IN_SCHEMA="${SNOWFLAKE_CONTROL_SCHEMA}"
export SNOWFLAKE_EDP_CORE_SCHEMA="${SNOWFLAKE_CONTROL_SCHEMA}"
export SNOWFLAKE_EDP_ACC_SCHEMA="${SNOWFLAKE_CONTROL_SCHEMA}"
bash ./scripts/deploy-snowflake-dbt-project.sh \
  proj_edp_orders \
  "${PRD_SNOWFLAKE_EDP_DBT_PROJECT}" \
  "${SNOWFLAKE_CONTROL_DATABASE}" \
  "${SNOWFLAKE_CONTROL_SCHEMA}" \
  "prd"

export_dev_runtime_env

echo "validating initialized DEV/PRD source products, deployed EDP customers, and undeployed EDP orders state"
docker compose run --rm --no-deps dbt-executor python - <<'PY'
import os

import snowflake.connector


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


required_databases = [
    os.environ["SNOWFLAKE_SDP_DATABASE"],
    os.environ["SNOWFLAKE_SDP_CUSTOMERS_DATABASE"],
    os.environ["SNOWFLAKE_EDP_CUSTOMERS_DATABASE"],
    os.environ["PRD_SNOWFLAKE_SDP_DATABASE"],
    os.environ["PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE"],
    os.environ["PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE"],
]
required_projects = [
    os.environ["DEV_SNOWFLAKE_SDP_DBT_PROJECT"],
    os.environ["DEV_SNOWFLAKE_EDP_DBT_PROJECT"],
    os.environ["DEV_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT"],
    os.environ["PRD_SNOWFLAKE_SDP_DBT_PROJECT"],
    os.environ["PRD_SNOWFLAKE_EDP_DBT_PROJECT"],
    os.environ["PRD_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT"],
]
forbidden_databases = [
    os.environ["SNOWFLAKE_EDP_DATABASE"],
    os.environ["PRD_SNOWFLAKE_EDP_DATABASE"],
]

connection = snowflake.connector.connect(
    account=os.environ["SNOWFLAKE_ACCOUNT"],
    user=os.environ["SNOWFLAKE_USER"],
    password=os.environ["SNOWFLAKE_PASSWORD"],
    role=os.environ["SNOWFLAKE_ROLE"],
    warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
)

try:
    with connection.cursor() as cursor:
        cursor.execute("show databases")
        databases = {row[1] for row in cursor.fetchall()}
        missing_databases = sorted(set(required_databases) - databases)
        if missing_databases:
            raise SystemExit(f"missing initialized databases: {', '.join(missing_databases)}")
        unexpected_databases = sorted(set(forbidden_databases) & databases)
        if unexpected_databases:
            raise SystemExit(f"unexpected EDP databases after initialization: {', '.join(unexpected_databases)}")

        cursor.execute(
            f"show dbt projects in schema {ident(os.environ['SNOWFLAKE_CONTROL_DATABASE'], os.environ['SNOWFLAKE_CONTROL_SCHEMA'])}"
        )
        cursor.execute('select "name" from table(result_scan(last_query_id()))')
        dbt_projects = {row[0] for row in cursor.fetchall()}
        missing_projects = sorted(set(required_projects) - dbt_projects)
        if missing_projects:
            raise SystemExit(f"missing initialized dbt projects: {', '.join(missing_projects)}")
finally:
    connection.close()

print(
    {
        "initialized_databases": required_databases,
        "initialized_projects": required_projects,
        "undeployed_databases": forbidden_databases,
        "undeployed_orders_projects_materialization_only": [
            os.environ["DEV_SNOWFLAKE_EDP_DBT_PROJECT"],
            os.environ["PRD_SNOWFLAKE_EDP_DBT_PROJECT"],
        ],
    }
)
PY

echo "snowflake-only bootstrap complete"
