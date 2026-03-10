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

container_project_dir="$(resolve_container_dbt_project_dir "${project_slug}")"

run_with_retry "${SNOW_DBT_RETRY_ATTEMPTS:-4}" "${SNOW_DBT_RETRY_SLEEP_SECONDS:-5}" \
  docker compose run --rm --no-deps dbt-executor \
    python /opt/platform/dbt/scripts/snow_dbt_cli.py \
      deploy \
      --project-dir "${container_project_dir}" \
      --project-name "${project_name}" \
      --database "${database_name}" \
      --schema "${schema_name}" \
      --target-name "${target_name}"
