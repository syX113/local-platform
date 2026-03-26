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
project_dir="$(resolve_container_dbt_project_dir "${project_slug}")"
project_kind="$(project_registry_lookup "${project_slug}" kind)"
case "${project_kind}" in
  source)
    default_core_schema_env="SNOWFLAKE_SDP_CORE_SCHEMA"
    ;;
  edp|domain)
    default_core_schema_env="SNOWFLAKE_EDP_CORE_SCHEMA"
    ;;
  *)
    echo "unsupported dbt project slug for Snowflake target preparation: ${project_slug}" >&2
    exit 1
    ;;
esac

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
      --project-slug "${project_slug}" \
      --database "${database_name}" \
      --schema "${schema_name}" \
      --target-name "${target_name}" \
      --schemas "${schemas[@]}"
}

while IFS='|' read -r database_env schema_envs_csv; do
  [ -n "${database_env}" ] || continue
  database_name="${!database_env:-}"
  if [ -z "${database_name}" ]; then
    echo "missing required Snowflake database environment variable: ${database_env}" >&2
    exit 1
  fi

  schemas=()
  IFS=',' read -r -a schema_envs <<< "${schema_envs_csv}"
  for schema_env in "${schema_envs[@]}"; do
    schema_name="${!schema_env:-}"
    if [ -z "${schema_name}" ]; then
      echo "missing required Snowflake schema environment variable: ${schema_env}" >&2
      exit 1
    fi
    schemas+=("${schema_name}")
  done

  run_prepare \
    "${project_dir}" \
    "${SNOW_DBT_TARGET_NAME:-dev}" \
    "${!default_core_schema_env:-CORE}" \
    "${database_name}" \
    "${schemas[@]}"
done < <(project_registry_prepare_targets "${project_slug}")
