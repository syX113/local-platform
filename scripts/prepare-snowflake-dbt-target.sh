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

project_slug="${1:?project slug is required}"

resolve_project_dir() {
  local slug="$1"

  if [ -f "${ROOT_DIR}/dbt/dbt_project.yml" ]; then
    printf '%s' "/opt/platform/dbt"
    return 0
  fi

  if [ -f "${ROOT_DIR}/dbt/projects/${slug}/dbt_project.yml" ]; then
    printf '%s' "/opt/platform/dbt/projects/${slug}"
    return 0
  fi

  echo "unable to resolve dbt project directory for ${slug}" >&2
  exit 1
}

run_prepare() {
  local project_dir="$1"
  local target_name="$2"
  local schema_name="$3"
  shift 3
  local database_name="$1"
  shift
  local schemas=("$@")

  docker compose run --rm --no-deps dbt-executor \
    python /opt/platform/dbt/scripts/snow_dbt_cli.py \
      prepare-target \
      --project-dir "${project_dir}" \
      --database "${database_name}" \
      --schema "${schema_name}" \
      --target-name "${target_name}" \
      --schemas "${schemas[@]}"
}

case "${project_slug}" in
  proj_source_finnova)
    run_prepare \
      "$(resolve_project_dir "proj_source_finnova")" \
      "${SNOW_DBT_TARGET_NAME:-dev}" \
      "${SNOWFLAKE_SDP_CORE_SCHEMA:-CORE}" \
      "${SNOWFLAKE_SDP_DATABASE}" \
      "${SNOWFLAKE_SDP_IN_SCHEMA:-INBOUND}" \
      "${SNOWFLAKE_SDP_CORE_SCHEMA:-CORE}" \
      "${SNOWFLAKE_SDP_ACC_SCHEMA:-ACCESS}"
    run_prepare \
      "$(resolve_project_dir "proj_source_finnova")" \
      "${SNOW_DBT_TARGET_NAME:-dev}" \
      "${SNOWFLAKE_SDP_CORE_SCHEMA:-CORE}" \
      "${SNOWFLAKE_SDP_CUSTOMERS_DATABASE}" \
      "${SNOWFLAKE_SDP_IN_SCHEMA:-INBOUND}" \
      "${SNOWFLAKE_SDP_CORE_SCHEMA:-CORE}" \
      "${SNOWFLAKE_SDP_ACC_SCHEMA:-ACCESS}"
    ;;
  proj_edp_orders|proj_edp_customers)
    run_prepare \
      "$(resolve_project_dir "${project_slug}")" \
      "${SNOW_DBT_TARGET_NAME:-dev}" \
      "${SNOWFLAKE_EDP_CORE_SCHEMA:-CORE}" \
      "${SNOWFLAKE_EDP_DATABASE}" \
      "${SNOWFLAKE_EDP_IN_SCHEMA:-INBOUND}" \
      "${SNOWFLAKE_EDP_CORE_SCHEMA:-CORE}" \
      "${SNOWFLAKE_EDP_ACC_SCHEMA:-ACCESS}"
    ;;
  *)
    echo "unsupported dbt project slug for Snowflake target preparation: ${project_slug}" >&2
    exit 1
    ;;
esac
