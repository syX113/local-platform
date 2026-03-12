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

project_slug="${1:?dbt project slug is required}"
project_name="${2:?Snowflake dbt project name is required}"
database_name="${3:?database is required}"
schema_name="${4:?schema is required}"
target_name="${5:-${SNOW_DBT_TARGET_NAME:-dev}}"
profile_database="${SNOWFLAKE_CONTROL_DATABASE}"
profile_schema="${SNOWFLAKE_CONTROL_SCHEMA}"
target_kind=""

container_project_dir="$(resolve_container_dbt_project_dir "${project_slug}")"

case "${project_slug}" in
  proj_source_finnova)
    target_kind="source"
    ;;
esac

if [ -n "${target_kind}" ]; then
  run_with_retry "${SNOW_DBT_RETRY_ATTEMPTS:-4}" "${SNOW_DBT_RETRY_SLEEP_SECONDS:-5}" \
    docker compose run --rm --no-deps \
      -e "SNOWFLAKE_ACCOUNT=${SNOWFLAKE_ACCOUNT}" \
      -e "SNOWFLAKE_USER=${SNOWFLAKE_USER}" \
      -e "SNOWFLAKE_PASSWORD=${SNOWFLAKE_PASSWORD}" \
      -e "SNOWFLAKE_ROLE=${SNOWFLAKE_ROLE}" \
      -e "SNOWFLAKE_WAREHOUSE=${SNOWFLAKE_WAREHOUSE}" \
      -e "SNOWFLAKE_SDP_DATABASE=${SNOWFLAKE_SDP_DATABASE:-}" \
      -e "SNOWFLAKE_SDP_CUSTOMERS_DATABASE=${SNOWFLAKE_SDP_CUSTOMERS_DATABASE:-}" \
      -e "SNOWFLAKE_SDP_IN_SCHEMA=${SNOWFLAKE_SDP_IN_SCHEMA:-}" \
      -e "SNOWFLAKE_SDP_CORE_SCHEMA=${SNOWFLAKE_SDP_CORE_SCHEMA:-}" \
      -e "SNOWFLAKE_SDP_ACC_SCHEMA=${SNOWFLAKE_SDP_ACC_SCHEMA:-}" \
      -e "SNOWFLAKE_EDP_DATABASE=${SNOWFLAKE_EDP_DATABASE:-}" \
      -e "SNOWFLAKE_EDP_IN_SCHEMA=${SNOWFLAKE_EDP_IN_SCHEMA:-}" \
      -e "SNOWFLAKE_EDP_CORE_SCHEMA=${SNOWFLAKE_EDP_CORE_SCHEMA:-}" \
      -e "SNOWFLAKE_EDP_ACC_SCHEMA=${SNOWFLAKE_EDP_ACC_SCHEMA:-}" \
      dbt-executor \
      python /opt/platform/dbt/scripts/ensure_target_databases.py \
        "${target_kind}"
fi

run_with_retry "${SNOW_DBT_RETRY_ATTEMPTS:-4}" "${SNOW_DBT_RETRY_SLEEP_SECONDS:-5}" \
  docker compose run --rm --no-deps \
    -e "SNOWFLAKE_ACCOUNT=${SNOWFLAKE_ACCOUNT}" \
    -e "SNOWFLAKE_USER=${SNOWFLAKE_USER}" \
    -e "SNOWFLAKE_PASSWORD=${SNOWFLAKE_PASSWORD}" \
    -e "SNOWFLAKE_ROLE=${SNOWFLAKE_ROLE}" \
    -e "SNOWFLAKE_WAREHOUSE=${SNOWFLAKE_WAREHOUSE}" \
    -e "SNOWFLAKE_CONTROL_DATABASE=${SNOWFLAKE_CONTROL_DATABASE}" \
    -e "SNOWFLAKE_CONTROL_SCHEMA=${SNOWFLAKE_CONTROL_SCHEMA}" \
    -e "SNOWFLAKE_DBT_STAGE=${SNOWFLAKE_DBT_STAGE}" \
    -e "SNOWFLAKE_SDP_DATABASE=${SNOWFLAKE_SDP_DATABASE:-}" \
    -e "SNOWFLAKE_SDP_CUSTOMERS_DATABASE=${SNOWFLAKE_SDP_CUSTOMERS_DATABASE:-}" \
    -e "SNOWFLAKE_SDP_IN_SCHEMA=${SNOWFLAKE_SDP_IN_SCHEMA:-}" \
    -e "SNOWFLAKE_SDP_CORE_SCHEMA=${SNOWFLAKE_SDP_CORE_SCHEMA:-}" \
    -e "SNOWFLAKE_SDP_ACC_SCHEMA=${SNOWFLAKE_SDP_ACC_SCHEMA:-}" \
    -e "SNOWFLAKE_EDP_DATABASE=${SNOWFLAKE_EDP_DATABASE:-}" \
    -e "SNOWFLAKE_EDP_CUSTOMERS_DATABASE=${SNOWFLAKE_EDP_CUSTOMERS_DATABASE:-}" \
    -e "SNOWFLAKE_EDP_IN_SCHEMA=${SNOWFLAKE_EDP_IN_SCHEMA:-}" \
    -e "SNOWFLAKE_EDP_CORE_SCHEMA=${SNOWFLAKE_EDP_CORE_SCHEMA:-}" \
    -e "SNOWFLAKE_EDP_ACC_SCHEMA=${SNOWFLAKE_EDP_ACC_SCHEMA:-}" \
    dbt-executor \
    python /opt/platform/dbt/scripts/snow_dbt_cli.py \
      deploy \
      --project-dir "${container_project_dir}" \
      --project-name "${project_name}" \
      --database "${profile_database}" \
      --schema "${profile_schema}" \
      --target-name "${target_name}"
