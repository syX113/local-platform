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

run_with_retry() {
  local attempts="${1:?attempt count is required}"
  local sleep_seconds="${2:?sleep interval is required}"
  shift 2

  local try=1
  while true; do
    if "$@"; then
      return 0
    fi

    if [ "${try}" -ge "${attempts}" ]; then
      return 1
    fi

    echo "retrying command (${try}/${attempts}) after ${sleep_seconds}s: $*" >&2
    try=$((try + 1))
    sleep "${sleep_seconds}"
  done
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

snowflake_control_database() {
  printf '%s' "${SNOWFLAKE_CONTROL_DATABASE:-LOCAL_PLATFORM_CONTROL}"
}

snowflake_control_schema() {
  printf '%s' "${SNOWFLAKE_CONTROL_SCHEMA:-OPERATIONS}"
}

snowflake_dbt_stage_name() {
  printf '%s' "${SNOWFLAKE_DBT_STAGE:-DBT_PROJECT_STAGE}"
}

snowflake_dbt_stage_fqn() {
  printf '%s.%s.%s' "$(snowflake_control_database)" "$(snowflake_control_schema)" "$(snowflake_dbt_stage_name)"
}

snowflake_dbt_project_object_name() {
  local product_slug="${1:?product slug is required}"
  local prefix="${2:-}"
  local base_name

  base_name="DBT_PROJECT_$(printf '%s' "${product_slug}" | tr '[:lower:]' '[:upper:]')"
  if [ -n "${prefix}" ]; then
    base_name="$(prefixed_identifier "${base_name}" "${prefix}")"
  fi
  printf '%s' "${base_name}"
}

source_system_slug() {
  printf '%s' "${SOURCE_SYSTEM_SLUG:-postgres}"
}

object_store_config_prefix() {
  printf '%s' "${OBJECT_STORE_CONFIG_PREFIX:-config}"
}

source_orders_pipeline_basename() {
  printf '%s' "${SOURCE_ORDERS_PIPELINE_BASENAME:-local_platform_orders_ingest}"
}

source_customers_pipeline_basename() {
  printf '%s' "${SOURCE_CUSTOMERS_PIPELINE_BASENAME:-local_platform_customers_ingest}"
}

activate_source_scope_runtime() {
  local scope="${1:?source scope is required (orders|customers)}"
  local scope_upper base_pipeline_name dlt_pipeline_name dag_id dag_id_var dlt_name_var

  scope_upper="$(printf '%s' "${scope}" | tr '[:lower:]' '[:upper:]')"

  case "${scope}" in
    orders)
      base_pipeline_name="$(source_orders_pipeline_basename)"
      export DLT_COMMAND="python /opt/platform/dlt/pipeline_orders.py"
      export SNOWFLAKE_RAW_SYNC_SCOPE="orders"
      export SNOWFLAKE_SDP_DBT_SELECT="orders"
      ;;
    customers)
      base_pipeline_name="$(source_customers_pipeline_basename)"
      export DLT_COMMAND="python /opt/platform/dlt/pipeline_customers.py"
      export SNOWFLAKE_RAW_SYNC_SCOPE="customers"
      export SNOWFLAKE_SDP_DBT_SELECT="customers"
      ;;
    *)
      echo "unsupported source scope: ${scope}" >&2
      return 1
      ;;
  esac

  if [ -n "${CI_SANDBOX_KIND:-}" ]; then
    dlt_name_var="SOURCE_${scope_upper}_DLT_PIPELINE_NAME"
    dag_id_var="AIRFLOW_SANDBOX_${scope_upper}_DAG_ID"
    dlt_pipeline_name="${!dlt_name_var:-${DLT_PIPELINE_NAME}_${scope}}"
    dag_id="${!dag_id_var:-${AIRFLOW_SANDBOX_DAG_ID}_${scope}}"
  elif [ "${ACTIVE_RUNTIME_ENV:-}" = "prd" ]; then
    dlt_name_var="PRD_SOURCE_${scope_upper}_DLT_PIPELINE_NAME"
    dag_id_var="PRD_${scope_upper}_AIRFLOW_DAG_ID"
    dlt_pipeline_name="${!dlt_name_var:-$(prefixed_identifier "${base_pipeline_name}" "${PRD_DEPLOYMENT_PREFIX:-PRD}")}"
    dag_id="${!dag_id_var:-$(prefixed_identifier "${base_pipeline_name}" "${PRD_DEPLOYMENT_PREFIX:-PRD}")}"
  else
    dlt_name_var="DEV_SOURCE_${scope_upper}_DLT_PIPELINE_NAME"
    dag_id_var="DEV_${scope_upper}_AIRFLOW_DAG_ID"
    dlt_pipeline_name="${!dlt_name_var:-$(prefixed_identifier "${base_pipeline_name}" "${DEV_DEPLOYMENT_PREFIX:-DEV}")}"
    dag_id="${!dag_id_var:-$(prefixed_identifier "${base_pipeline_name}" "${DEV_DEPLOYMENT_PREFIX:-DEV}")}"
  fi

  export ACTIVE_SOURCE_SCOPE="${scope}"
  export SOURCE_SCOPE="${scope}"
  export SOURCE_PIPELINE_BASENAME="${base_pipeline_name}"
  export DLT_PIPELINE_NAME="${dlt_pipeline_name}"
  export AIRFLOW_ACTIVE_DAG_ID="${dag_id}"
  export AIRFLOW_ACTIVE_MODULE_PREFIX="$(sanitize_branch_token "${AIRFLOW_ACTIVE_DAG_ID}")"
  export AIRFLOW_ACTIVE_DAG_FILENAME="${AIRFLOW_ACTIVE_MODULE_PREFIX}.py"
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

remove_deployed_airflow_dag() {
  local dag_id="${1:?dag id is required}"
  local module_prefix="${2:-$(sanitize_branch_token "${dag_id}")}"
  local deployed_dir="${ROOT_DIR}/airflow/dags/deployed"
  local scheduler_container_id

  python3 - "${deployed_dir}" "${module_prefix}" <<'PY'
from pathlib import Path
import sys

deployed_dir = Path(sys.argv[1])
module_prefix = sys.argv[2]

for path in (
    deployed_dir / f"{module_prefix}.py",
    deployed_dir / f"{module_prefix}_platform_support.py",
    deployed_dir / f"{module_prefix}_pipeline_impl.py",
):
    path.unlink(missing_ok=True)
PY

  scheduler_container_id="$(docker compose ps -q airflow-scheduler 2>/dev/null || true)"
  if [ -n "${scheduler_container_id}" ]; then
    docker compose exec -T airflow-scheduler python3 - "${module_prefix}" <<'PY' >/dev/null 2>&1 || true
from pathlib import Path
import sys

module_prefix = sys.argv[1]
deployed_dir = Path("/opt/airflow/dags/deployed")

for path in (
    deployed_dir / f"{module_prefix}.py",
    deployed_dir / f"{module_prefix}_platform_support.py",
    deployed_dir / f"{module_prefix}_pipeline_impl.py",
):
    path.unlink(missing_ok=True)
PY
    docker compose exec -T airflow-scheduler \
      airflow dags delete --yes "${dag_id}" >/dev/null 2>&1 || true
  fi
}

ensure_shared_airflow_services() {
  if [ "${LOCAL_PLATFORM_SHARED_STACK:-false}" != "true" ]; then
    return 0
  fi

  local scheduler_container_id webserver_container_id
  scheduler_container_id="$(docker compose ps -q airflow-scheduler 2>/dev/null || true)"
  webserver_container_id="$(docker compose ps -q airflow-webserver 2>/dev/null || true)"

  if [ -n "${scheduler_container_id}" ] && [ -n "${webserver_container_id}" ]; then
    return 0
  fi

  docker compose up -d airflow-webserver airflow-scheduler >/dev/null
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

  export SNOWFLAKE_CONTROL_DATABASE="${SNOWFLAKE_CONTROL_DATABASE:-$(snowflake_control_database)}"
  export SNOWFLAKE_CONTROL_SCHEMA="${SNOWFLAKE_CONTROL_SCHEMA:-$(snowflake_control_schema)}"
  export SNOWFLAKE_DBT_STAGE="${SNOWFLAKE_DBT_STAGE:-$(snowflake_dbt_stage_name)}"
  export SOURCE_SYSTEM_SLUG="${SOURCE_SYSTEM_SLUG:-$(source_system_slug)}"
  export OBJECT_STORE_CONFIG_PREFIX="${OBJECT_STORE_CONFIG_PREFIX:-$(object_store_config_prefix)}"
  export ICEBERG_CATALOG_NAME="${ICEBERG_CATALOG_NAME:-dev}"
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
  local source_sdp_database source_sdp_customers_database
  local source_edp_database source_edp_customers_database
  local source_system_slug_value

  prd_prefix="${PRD_DEPLOYMENT_PREFIX:-PRD}"
  source_system_slug_value="$(source_system_slug)"
  source_dlt_pipeline="${PRD_SOURCE_DLT_PIPELINE_NAME:-${DLT_PIPELINE_NAME:-local_platform_ingest}}"
  source_iceberg_namespace="${PRD_SOURCE_ICEBERG_NAMESPACE:-${source_system_slug_value}}"
  source_minio_prefix="${PRD_SOURCE_MINIO_PREFIX:-landing/prd}"
  source_sdp_database="${PRD_SOURCE_SDP_DATABASE:-${SNOWFLAKE_SDP_DATABASE_BASE:-${SNOWFLAKE_SDP_DATABASE}}}"
  source_sdp_customers_database="${PRD_SOURCE_SDP_CUSTOMERS_DATABASE:-${SNOWFLAKE_SDP_CUSTOMERS_DATABASE_BASE:-${SNOWFLAKE_SDP_CUSTOMERS_DATABASE}}}"
  source_edp_database="${PRD_SOURCE_EDP_DATABASE:-${SNOWFLAKE_EDP_DATABASE_BASE:-${SNOWFLAKE_EDP_DATABASE}}}"
  source_edp_customers_database="${PRD_SOURCE_EDP_CUSTOMERS_DATABASE:-${SNOWFLAKE_EDP_CUSTOMERS_DATABASE_BASE:-${SNOWFLAKE_EDP_CUSTOMERS_DATABASE}}}"

  export PRD_DEPLOYMENT_PREFIX="${prd_prefix}"
  export ACTIVE_RUNTIME_ENV="prd"
  export SNOWFLAKE_CONTROL_DATABASE="${SNOWFLAKE_CONTROL_DATABASE:-$(snowflake_control_database)}"
  export SNOWFLAKE_CONTROL_SCHEMA="${SNOWFLAKE_CONTROL_SCHEMA:-$(snowflake_control_schema)}"
  export SNOWFLAKE_DBT_STAGE="${SNOWFLAKE_DBT_STAGE:-$(snowflake_dbt_stage_name)}"
  export PRD_SOURCE_DLT_PIPELINE_NAME="${source_dlt_pipeline}"
  export PRD_SOURCE_ORDERS_DLT_PIPELINE_NAME="${PRD_SOURCE_ORDERS_DLT_PIPELINE_NAME:-$(prefixed_identifier "$(source_orders_pipeline_basename)" "${prd_prefix}")}"
  export PRD_SOURCE_CUSTOMERS_DLT_PIPELINE_NAME="${PRD_SOURCE_CUSTOMERS_DLT_PIPELINE_NAME:-$(prefixed_identifier "$(source_customers_pipeline_basename)" "${prd_prefix}")}"
  export PRD_SOURCE_ICEBERG_NAMESPACE="${source_iceberg_namespace}"
  export PRD_SOURCE_MINIO_PREFIX="${source_minio_prefix}"
  export PRD_SOURCE_SDP_DATABASE="${source_sdp_database}"
  export PRD_SOURCE_SDP_CUSTOMERS_DATABASE="${source_sdp_customers_database}"
  export PRD_SOURCE_EDP_DATABASE="${source_edp_database}"
  export PRD_SOURCE_EDP_CUSTOMERS_DATABASE="${source_edp_customers_database}"

  export PRD_AIRFLOW_DAG_ID="${PRD_AIRFLOW_DAG_ID:-$(prefixed_identifier "${source_dlt_pipeline}" "${prd_prefix}")}"
  export PRD_ORDERS_AIRFLOW_DAG_ID="${PRD_ORDERS_AIRFLOW_DAG_ID:-$(prefixed_identifier "$(source_orders_pipeline_basename)" "${prd_prefix}")}"
  export PRD_CUSTOMERS_AIRFLOW_DAG_ID="${PRD_CUSTOMERS_AIRFLOW_DAG_ID:-$(prefixed_identifier "$(source_customers_pipeline_basename)" "${prd_prefix}")}"
  export PRD_AIRFLOW_MODULE_PREFIX="${PRD_AIRFLOW_MODULE_PREFIX:-$(sanitize_branch_token "${PRD_AIRFLOW_DAG_ID}")}"
  export PRD_AIRFLOW_DAG_FILENAME="${PRD_AIRFLOW_DAG_FILENAME:-${PRD_AIRFLOW_MODULE_PREFIX}.py}"
  export PRD_DLT_PIPELINE_NAME="${PRD_DLT_PIPELINE_NAME:-$(prefixed_identifier "${source_dlt_pipeline}" "${prd_prefix}")}"
  export PRD_ICEBERG_CATALOG_NAME="${PRD_ICEBERG_CATALOG_NAME:-prd}"
  export PRD_ICEBERG_NAMESPACE="${PRD_ICEBERG_NAMESPACE:-${source_iceberg_namespace}}"
  export PRD_MINIO_PREFIX="${PRD_MINIO_PREFIX:-${source_minio_prefix}}"
  export PRD_SNOWFLAKE_SDP_DATABASE="${PRD_SNOWFLAKE_SDP_DATABASE:-$(prefixed_identifier "${source_sdp_database}" "${prd_prefix}")}"
  export PRD_SNOWFLAKE_SDP_ORDERS_DATABASE="${PRD_SNOWFLAKE_SDP_ORDERS_DATABASE:-${PRD_SNOWFLAKE_SDP_DATABASE}}"
  export PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE="${PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE:-$(prefixed_identifier "${source_sdp_customers_database}" "${prd_prefix}")}"
  export PRD_SNOWFLAKE_EDP_DATABASE="${PRD_SNOWFLAKE_EDP_DATABASE:-$(prefixed_identifier "${source_edp_database}" "${prd_prefix}")}"
  export PRD_SNOWFLAKE_EDP_ORDERS_DATABASE="${PRD_SNOWFLAKE_EDP_ORDERS_DATABASE:-${PRD_SNOWFLAKE_EDP_DATABASE}}"
  export PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE="${PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE:-$(prefixed_identifier "${source_edp_customers_database}" "${prd_prefix}")}"
  export PRD_SDP_RUNTIME_IMAGE_PREFIX="${PRD_SDP_RUNTIME_IMAGE_PREFIX:-local-platform-prd-sdp}"
  export PRD_EDP_RUNTIME_IMAGE_PREFIX="${PRD_EDP_RUNTIME_IMAGE_PREFIX:-local-platform-prd-edp}"
  export PRD_SNOWFLAKE_SDP_DBT_PROJECT="${PRD_SNOWFLAKE_SDP_DBT_PROJECT:-$(snowflake_dbt_project_object_name source_finnova "${prd_prefix}")}"
  export PRD_SNOWFLAKE_EDP_DBT_PROJECT="${PRD_SNOWFLAKE_EDP_DBT_PROJECT:-$(snowflake_dbt_project_object_name edp_orders "${prd_prefix}")}"
  export PRD_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT="${PRD_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT:-$(snowflake_dbt_project_object_name edp_customers "${prd_prefix}")}"
  export PRD_SNOW_DBT_TARGET_NAME="${PRD_SNOW_DBT_TARGET_NAME:-prd}"

  export SNOWFLAKE_SDP_DATABASE_BASE="${source_sdp_database}"
  export SNOWFLAKE_SDP_ORDERS_DATABASE_BASE="${source_sdp_database}"
  export SNOWFLAKE_SDP_CUSTOMERS_DATABASE_BASE="${source_sdp_customers_database}"
  export SNOWFLAKE_EDP_DATABASE_BASE="${source_edp_database}"
  export SNOWFLAKE_EDP_ORDERS_DATABASE_BASE="${source_edp_database}"
  export SNOWFLAKE_EDP_CUSTOMERS_DATABASE_BASE="${source_edp_customers_database}"
  export SNOWFLAKE_SDP_DATABASE="${PRD_SNOWFLAKE_SDP_DATABASE}"
  export SNOWFLAKE_SDP_ORDERS_DATABASE="${PRD_SNOWFLAKE_SDP_ORDERS_DATABASE}"
  export SNOWFLAKE_SDP_CUSTOMERS_DATABASE="${PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE}"
  export SNOWFLAKE_EDP_DATABASE="${PRD_SNOWFLAKE_EDP_DATABASE}"
  export SNOWFLAKE_EDP_ORDERS_DATABASE="${PRD_SNOWFLAKE_EDP_ORDERS_DATABASE}"
  export SNOWFLAKE_EDP_CUSTOMERS_DATABASE="${PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE}"
  export SNOWFLAKE_SDP_DBT_PROJECT="${PRD_SNOWFLAKE_SDP_DBT_PROJECT}"
  export SNOWFLAKE_EDP_DBT_PROJECT="${PRD_SNOWFLAKE_EDP_DBT_PROJECT}"
  export SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT="${PRD_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT}"
  export SNOW_DBT_TARGET_NAME="${PRD_SNOW_DBT_TARGET_NAME}"
  export DLT_PIPELINE_NAME="${PRD_DLT_PIPELINE_NAME}"
  export ICEBERG_CATALOG_NAME="${PRD_ICEBERG_CATALOG_NAME}"
  export ICEBERG_NAMESPACE="${PRD_ICEBERG_NAMESPACE}"
  export MINIO_PREFIX="${PRD_MINIO_PREFIX}"
  export OBJECT_STORE_BUCKET="s3://${MINIO_BUCKET}/${MINIO_PREFIX}"
}

export_dev_runtime_env() {
  local dev_prefix source_dlt_pipeline source_iceberg_namespace source_minio_prefix
  local source_sdp_database source_sdp_customers_database
  local source_edp_database source_edp_customers_database
  local source_system_slug_value

  dev_prefix="${DEV_DEPLOYMENT_PREFIX:-DEV}"
  source_system_slug_value="$(source_system_slug)"
  source_dlt_pipeline="${DEV_SOURCE_DLT_PIPELINE_NAME:-${DLT_PIPELINE_NAME:-local_platform_ingest}}"
  source_iceberg_namespace="${DEV_SOURCE_ICEBERG_NAMESPACE:-${source_system_slug_value}}"
  source_minio_prefix="${DEV_SOURCE_MINIO_PREFIX:-landing/dev}"
  source_sdp_database="${DEV_SOURCE_SDP_DATABASE:-${SNOWFLAKE_SDP_DATABASE_BASE:-${SNOWFLAKE_SDP_DATABASE}}}"
  source_sdp_customers_database="${DEV_SOURCE_SDP_CUSTOMERS_DATABASE:-${SNOWFLAKE_SDP_CUSTOMERS_DATABASE_BASE:-${SNOWFLAKE_SDP_CUSTOMERS_DATABASE}}}"
  source_edp_database="${DEV_SOURCE_EDP_DATABASE:-${SNOWFLAKE_EDP_DATABASE_BASE:-${SNOWFLAKE_EDP_DATABASE}}}"
  source_edp_customers_database="${DEV_SOURCE_EDP_CUSTOMERS_DATABASE:-${SNOWFLAKE_EDP_CUSTOMERS_DATABASE_BASE:-${SNOWFLAKE_EDP_CUSTOMERS_DATABASE}}}"

  export DEV_DEPLOYMENT_PREFIX="${dev_prefix}"
  export ACTIVE_RUNTIME_ENV="dev"
  export SNOWFLAKE_CONTROL_DATABASE="${SNOWFLAKE_CONTROL_DATABASE:-$(snowflake_control_database)}"
  export SNOWFLAKE_CONTROL_SCHEMA="${SNOWFLAKE_CONTROL_SCHEMA:-$(snowflake_control_schema)}"
  export SNOWFLAKE_DBT_STAGE="${SNOWFLAKE_DBT_STAGE:-$(snowflake_dbt_stage_name)}"
  export DEV_SOURCE_DLT_PIPELINE_NAME="${source_dlt_pipeline}"
  export DEV_SOURCE_ORDERS_DLT_PIPELINE_NAME="${DEV_SOURCE_ORDERS_DLT_PIPELINE_NAME:-$(prefixed_identifier "$(source_orders_pipeline_basename)" "${dev_prefix}")}"
  export DEV_SOURCE_CUSTOMERS_DLT_PIPELINE_NAME="${DEV_SOURCE_CUSTOMERS_DLT_PIPELINE_NAME:-$(prefixed_identifier "$(source_customers_pipeline_basename)" "${dev_prefix}")}"
  export DEV_SOURCE_ICEBERG_NAMESPACE="${source_iceberg_namespace}"
  export DEV_SOURCE_MINIO_PREFIX="${source_minio_prefix}"
  export DEV_SOURCE_SDP_DATABASE="${source_sdp_database}"
  export DEV_SOURCE_SDP_CUSTOMERS_DATABASE="${source_sdp_customers_database}"
  export DEV_SOURCE_EDP_DATABASE="${source_edp_database}"
  export DEV_SOURCE_EDP_CUSTOMERS_DATABASE="${source_edp_customers_database}"

  export DEV_AIRFLOW_DAG_ID="${DEV_AIRFLOW_DAG_ID:-$(prefixed_identifier "${source_dlt_pipeline}" "${dev_prefix}")}"
  export DEV_ORDERS_AIRFLOW_DAG_ID="${DEV_ORDERS_AIRFLOW_DAG_ID:-$(prefixed_identifier "$(source_orders_pipeline_basename)" "${dev_prefix}")}"
  export DEV_CUSTOMERS_AIRFLOW_DAG_ID="${DEV_CUSTOMERS_AIRFLOW_DAG_ID:-$(prefixed_identifier "$(source_customers_pipeline_basename)" "${dev_prefix}")}"
  export DEV_AIRFLOW_MODULE_PREFIX="${DEV_AIRFLOW_MODULE_PREFIX:-$(sanitize_branch_token "${DEV_AIRFLOW_DAG_ID}")}"
  export DEV_AIRFLOW_DAG_FILENAME="${DEV_AIRFLOW_DAG_FILENAME:-${DEV_AIRFLOW_MODULE_PREFIX}.py}"
  export DEV_DLT_PIPELINE_NAME="${DEV_DLT_PIPELINE_NAME:-$(prefixed_identifier "${source_dlt_pipeline}" "${dev_prefix}")}"
  export DEV_ICEBERG_CATALOG_NAME="${DEV_ICEBERG_CATALOG_NAME:-dev}"
  export DEV_ICEBERG_NAMESPACE="${DEV_ICEBERG_NAMESPACE:-${source_iceberg_namespace}}"
  export DEV_MINIO_PREFIX="${DEV_MINIO_PREFIX:-${source_minio_prefix}}"
  export DEV_SNOWFLAKE_SDP_DATABASE="${DEV_SNOWFLAKE_SDP_DATABASE:-${source_sdp_database}}"
  export DEV_SNOWFLAKE_SDP_ORDERS_DATABASE="${DEV_SNOWFLAKE_SDP_ORDERS_DATABASE:-${DEV_SNOWFLAKE_SDP_DATABASE}}"
  export DEV_SNOWFLAKE_SDP_CUSTOMERS_DATABASE="${DEV_SNOWFLAKE_SDP_CUSTOMERS_DATABASE:-${source_sdp_customers_database}}"
  export DEV_SNOWFLAKE_EDP_DATABASE="${DEV_SNOWFLAKE_EDP_DATABASE:-${source_edp_database}}"
  export DEV_SNOWFLAKE_EDP_ORDERS_DATABASE="${DEV_SNOWFLAKE_EDP_ORDERS_DATABASE:-${DEV_SNOWFLAKE_EDP_DATABASE}}"
  export DEV_SNOWFLAKE_EDP_CUSTOMERS_DATABASE="${DEV_SNOWFLAKE_EDP_CUSTOMERS_DATABASE:-${source_edp_customers_database}}"
  export DEV_SDP_RUNTIME_IMAGE_PREFIX="${DEV_SDP_RUNTIME_IMAGE_PREFIX:-local-platform-dev-sdp}"
  export DEV_EDP_RUNTIME_IMAGE_PREFIX="${DEV_EDP_RUNTIME_IMAGE_PREFIX:-local-platform-dev-edp}"
  export DEV_SNOWFLAKE_SDP_DBT_PROJECT="${DEV_SNOWFLAKE_SDP_DBT_PROJECT:-$(snowflake_dbt_project_object_name source_finnova "${dev_prefix}")}"
  export DEV_SNOWFLAKE_EDP_DBT_PROJECT="${DEV_SNOWFLAKE_EDP_DBT_PROJECT:-$(snowflake_dbt_project_object_name edp_orders "${dev_prefix}")}"
  export DEV_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT="${DEV_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT:-$(snowflake_dbt_project_object_name edp_customers "${dev_prefix}")}"
  export DEV_SNOW_DBT_TARGET_NAME="${DEV_SNOW_DBT_TARGET_NAME:-dev}"

  export SNOWFLAKE_SDP_DATABASE_BASE="${source_sdp_database}"
  export SNOWFLAKE_SDP_ORDERS_DATABASE_BASE="${source_sdp_database}"
  export SNOWFLAKE_SDP_CUSTOMERS_DATABASE_BASE="${source_sdp_customers_database}"
  export SNOWFLAKE_EDP_DATABASE_BASE="${source_edp_database}"
  export SNOWFLAKE_EDP_ORDERS_DATABASE_BASE="${source_edp_database}"
  export SNOWFLAKE_EDP_CUSTOMERS_DATABASE_BASE="${source_edp_customers_database}"
  export SNOWFLAKE_SDP_DATABASE="${DEV_SNOWFLAKE_SDP_DATABASE}"
  export SNOWFLAKE_SDP_ORDERS_DATABASE="${DEV_SNOWFLAKE_SDP_ORDERS_DATABASE}"
  export SNOWFLAKE_SDP_CUSTOMERS_DATABASE="${DEV_SNOWFLAKE_SDP_CUSTOMERS_DATABASE}"
  export SNOWFLAKE_EDP_DATABASE="${DEV_SNOWFLAKE_EDP_DATABASE}"
  export SNOWFLAKE_EDP_ORDERS_DATABASE="${DEV_SNOWFLAKE_EDP_ORDERS_DATABASE}"
  export SNOWFLAKE_EDP_CUSTOMERS_DATABASE="${DEV_SNOWFLAKE_EDP_CUSTOMERS_DATABASE}"
  export SNOWFLAKE_SDP_DBT_PROJECT="${DEV_SNOWFLAKE_SDP_DBT_PROJECT}"
  export SNOWFLAKE_EDP_DBT_PROJECT="${DEV_SNOWFLAKE_EDP_DBT_PROJECT}"
  export SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT="${DEV_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT}"
  export SNOW_DBT_TARGET_NAME="${DEV_SNOW_DBT_TARGET_NAME}"
  export DLT_PIPELINE_NAME="${DEV_DLT_PIPELINE_NAME}"
  export ICEBERG_CATALOG_NAME="${DEV_ICEBERG_CATALOG_NAME}"
  export ICEBERG_NAMESPACE="${DEV_ICEBERG_NAMESPACE}"
  export MINIO_PREFIX="${DEV_MINIO_PREFIX}"
  export OBJECT_STORE_BUCKET="s3://${MINIO_BUCKET}/${MINIO_PREFIX}"
}
