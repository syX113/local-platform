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

project_name="${1:?Snowflake dbt project name is required}"
dbt_command="${2:?dbt command is required}"
shift 2

project_slug="$(project_registry_project_slug_for_name "${project_name}")"
ensure_dbt_loom_manifest_for_project "${project_slug}"

run_with_retry "${SNOW_DBT_RETRY_ATTEMPTS:-4}" "${SNOW_DBT_RETRY_SLEEP_SECONDS:-5}" \
  docker compose run --rm --no-deps dbt-executor \
    python /opt/platform/dbt/scripts/snow_dbt_cli.py \
      execute \
      --project-name "${project_name}" \
      "${dbt_command}" \
      "$@"
