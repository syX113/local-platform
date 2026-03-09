#!/usr/bin/env bash

docker_compose_run_stderr_filter() {
  awk 'index($0, "No services to build") == 0 && index($0, "Found orphan containers") == 0 { print > "/dev/stderr" }'
}

runtime_image_prefix() {
  printf '%s' "${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-local-platform}}"
}

runtime_image_ref() {
  local service_name="${1:?service name is required}"
  printf '%s/%s:dev' "$(runtime_image_prefix)" "${service_name}"
}

resolve_platform_root() {
  if [ -n "${LOCAL_PLATFORM_ROOT:-}" ]; then
    printf '%s\n' "${LOCAL_PLATFORM_ROOT}"
    return 0
  fi

  printf '%s\n' "${ROOT_DIR:-$(pwd)}"
}

docker() {
  if [ "${1:-}" = "compose" ] && [ "${2:-}" = "run" ]; then
    shift 2
    command docker compose run "$@" 2> >(docker_compose_run_stderr_filter)
    return $?
  fi

  command docker "$@"
}

trim_identifier() {
  local value="${1:?value is required}"
  local max_len="${2:?max length is required}"
  printf '%s' "${value:0:${max_len}}"
}

stable_token() {
  local raw="${1:?raw token is required}"
  cksum <<<"${raw}" | awk '{print $1}'
}

sanitize_branch_token() {
  local raw="${1:?raw token is required}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "${raw}" | tr -cs 'a-z0-9' '_')"
  raw="${raw#_}"
  raw="${raw%_}"
  printf '%s' "${raw}"
}

prefixed_identifier() {
  local value="${1:?value is required}"
  local prefix="${2:-${PRD_DEPLOYMENT_PREFIX:-PRD}}"

  if [[ "${value}" == "${prefix}_"* ]]; then
    printf '%s' "${value}"
    return 0
  fi

  printf '%s_%s' "${prefix}" "${value}"
}

build_clone_database_name() {
  local base_name="${1:?base name is required}"
  local owner_token="${2:?owner token is required}"
  local branch_token_raw="${3:?branch token is required}"
  local max_len="${4:?max length is required}"

  local branch_upper prefix prefix_len remaining hash suffix_len trimmed_len branch_trimmed

  branch_upper="$(printf '%s' "${branch_token_raw}" | tr '[:lower:]' '[:upper:]')"
  prefix="${base_name}_CI_CLO_${owner_token}_"
  prefix_len="${#prefix}"

  if [ "${prefix_len}" -ge "${max_len}" ]; then
    printf '%s' "$(trim_identifier "${prefix}" "${max_len}")"
    return 0
  fi

  remaining=$((max_len - prefix_len))
  if [ "${#branch_upper}" -le "${remaining}" ]; then
    printf '%s%s' "${prefix}" "${branch_upper}"
    return 0
  fi

  hash="$(stable_token "${base_name}_${owner_token}_${branch_token_raw}")"
  suffix_len=$((1 + ${#hash}))
  trimmed_len=$((remaining - suffix_len))
  if [ "${trimmed_len}" -lt 1 ]; then
    printf '%s%s' "${prefix}" "$(trim_identifier "${hash}" "${remaining}")"
    return 0
  fi

  branch_trimmed="$(trim_identifier "${branch_upper}" "${trimmed_len}")"
  printf '%s%s_%s' "${prefix}" "${branch_trimmed}" "${hash}"
}

load_env_preserving_existing() {
  local env_file="${1:?env file is required}"

  if [ ! -f "${env_file}" ]; then
    return 0
  fi

  local preserved_env
  preserved_env="$(mktemp)"

  # Use null-delimited env output so CI variables containing newlines do not
  # corrupt the restore file.
  while IFS='=' read -r -d '' key value; do
    printf 'export %s=%q\n' "${key}" "${value}"
  done < <(env -0) > "${preserved_env}"

  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a

  # shellcheck disable=SC1090
  source "${preserved_env}"

  rm -f "${preserved_env}"
}

ensure_platform_env() {
  if [ ! -f .env ]; then
    if [ -f .env.example ]; then
      cp .env.example .env
    elif [ -f ci/.env.example ]; then
      cp ci/.env.example .env
    else
      echo "unable to create .env: no .env.example or ci/.env.example found" >&2
      return 1
    fi
    echo "created .env from .env.example"
  fi

  load_env_preserving_existing .env

  local root_dir="${ROOT_DIR:-$(pwd)}"
  local platform_root="${LOCAL_PLATFORM_ROOT:-}"

  if [ -z "${platform_root}" ]; then
    platform_root="${root_dir}"
    export LOCAL_PLATFORM_ROOT="${platform_root}"

    local temp_env
    temp_env="$(mktemp)"
    awk -v root="${platform_root}" '
      BEGIN { updated = 0 }
      /^LOCAL_PLATFORM_ROOT=/ {
        print "LOCAL_PLATFORM_ROOT=\"" root "\""
        updated = 1
        next
      }
      { print }
      END {
        if (!updated) {
          print "LOCAL_PLATFORM_ROOT=\"" root "\""
        }
      }
    ' .env > "${temp_env}"
    mv "${temp_env}" .env
  fi
}

resolve_host_dbt_project_dir() {
  local project_slug="${1:?dbt project slug is required}"

  if [ -f "${ROOT_DIR}/dbt/projects/${project_slug}/dbt_project.yml" ]; then
    printf '%s/dbt/projects/%s\n' "${ROOT_DIR}" "${project_slug}"
    return 0
  fi

  if [ -f "${ROOT_DIR}/dbt/dbt_project.yml" ]; then
    printf '%s/dbt\n' "${ROOT_DIR}"
    return 0
  fi

  echo "unable to resolve dbt project dir for ${project_slug}" >&2
  return 1
}

resolve_container_dbt_project_dir() {
  local project_slug="${1:?dbt project slug is required}"

  if [ -f "${ROOT_DIR}/dbt/projects/${project_slug}/dbt_project.yml" ]; then
    printf '/opt/platform/dbt/projects/%s\n' "${project_slug}"
    return 0
  fi

  if [ -f "${ROOT_DIR}/dbt/dbt_project.yml" ]; then
    printf '/opt/platform/dbt\n'
    return 0
  fi

  echo "unable to resolve container dbt project dir for ${project_slug}" >&2
  return 1
}

export_prd_runtime_env() {
  local prd_prefix source_dlt_pipeline source_iceberg_namespace source_minio_prefix
  local source_sdp_database source_edp_database

  prd_prefix="${PRD_DEPLOYMENT_PREFIX:-PRD}"
  source_dlt_pipeline="${PRD_SOURCE_DLT_PIPELINE_NAME:-${DLT_PIPELINE_NAME:-local_platform_ingest}}"
  source_iceberg_namespace="${PRD_SOURCE_ICEBERG_NAMESPACE:-${ICEBERG_NAMESPACE:-landing}}"
  source_minio_prefix="${PRD_SOURCE_MINIO_PREFIX:-${MINIO_PREFIX:-platform}}"
  source_sdp_database="${PRD_SOURCE_SDP_DATABASE:-${SNOWFLAKE_SDP_DATABASE_BASE:-${SNOWFLAKE_SDP_DATABASE}}}"
  source_edp_database="${PRD_SOURCE_EDP_DATABASE:-${SNOWFLAKE_EDP_DATABASE_BASE:-${SNOWFLAKE_EDP_DATABASE}}}"

  export PRD_DEPLOYMENT_PREFIX="${prd_prefix}"
  export PRD_SOURCE_DLT_PIPELINE_NAME="${source_dlt_pipeline}"
  export PRD_SOURCE_ICEBERG_NAMESPACE="${source_iceberg_namespace}"
  export PRD_SOURCE_MINIO_PREFIX="${source_minio_prefix}"
  export PRD_SOURCE_SDP_DATABASE="${source_sdp_database}"
  export PRD_SOURCE_EDP_DATABASE="${source_edp_database}"

  export PRD_AIRFLOW_DAG_ID="${PRD_AIRFLOW_DAG_ID:-$(prefixed_identifier "${source_dlt_pipeline}" "${prd_prefix}")}"
  export PRD_AIRFLOW_MODULE_PREFIX="${PRD_AIRFLOW_MODULE_PREFIX:-$(sanitize_branch_token "${PRD_AIRFLOW_DAG_ID}")}"
  export PRD_AIRFLOW_DAG_FILENAME="${PRD_AIRFLOW_DAG_FILENAME:-${PRD_AIRFLOW_MODULE_PREFIX}.py}"
  export PRD_DLT_PIPELINE_NAME="${PRD_DLT_PIPELINE_NAME:-$(prefixed_identifier "${source_dlt_pipeline}" "${prd_prefix}")}"
  export PRD_ICEBERG_NAMESPACE="${PRD_ICEBERG_NAMESPACE:-$(sanitize_branch_token "$(prefixed_identifier "${source_iceberg_namespace}" "${prd_prefix}")")}"
  export PRD_MINIO_PREFIX="${PRD_MINIO_PREFIX:-${source_minio_prefix}/${prd_prefix}/${source_dlt_pipeline}}"
  export PRD_SNOWFLAKE_SDP_DATABASE="${PRD_SNOWFLAKE_SDP_DATABASE:-$(prefixed_identifier "${source_sdp_database}" "${prd_prefix}")}"
  export PRD_SNOWFLAKE_EDP_DATABASE="${PRD_SNOWFLAKE_EDP_DATABASE:-$(prefixed_identifier "${source_edp_database}" "${prd_prefix}")}"
  export PRD_SDP_RUNTIME_IMAGE_PREFIX="${PRD_SDP_RUNTIME_IMAGE_PREFIX:-local-platform-prd-sdp}"
  export PRD_EDP_RUNTIME_IMAGE_PREFIX="${PRD_EDP_RUNTIME_IMAGE_PREFIX:-local-platform-prd-edp}"

  export SNOWFLAKE_SDP_DATABASE_BASE="${source_sdp_database}"
  export SNOWFLAKE_EDP_DATABASE_BASE="${source_edp_database}"
  export SNOWFLAKE_SDP_DATABASE="${PRD_SNOWFLAKE_SDP_DATABASE}"
  export SNOWFLAKE_EDP_DATABASE="${PRD_SNOWFLAKE_EDP_DATABASE}"
  export DLT_PIPELINE_NAME="${PRD_DLT_PIPELINE_NAME}"
  export ICEBERG_NAMESPACE="${PRD_ICEBERG_NAMESPACE}"
  export MINIO_PREFIX="${PRD_MINIO_PREFIX}"
  export OBJECT_STORE_BUCKET="s3://${MINIO_BUCKET}/${MINIO_PREFIX}"
}
