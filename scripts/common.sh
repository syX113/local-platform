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

docker_cli_bin_dir() {
  local candidates=(
    "/Applications/Rancher Desktop.app/Contents/Resources/resources/darwin/bin"
    "${HOME}/.rd/bin"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -x "${candidate}/docker" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

docker_cli_plugin_dir_for_bin() {
  local bin_dir="${1:?docker bin dir is required}"
  local candidate="${bin_dir%/bin}/docker-cli-plugins"

  if [ -d "${candidate}" ]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  return 1
}

ensure_docker_cli_runtime() {
  local bin_dir candidate plugin_dir plugin_home

  if ! type -P docker >/dev/null 2>&1; then
    if bin_dir="$(docker_cli_bin_dir 2>/dev/null)"; then
      case ":${PATH}:" in
        *":${bin_dir}:"*) ;;
        *) export PATH="${bin_dir}:${PATH}" ;;
      esac
    fi
  fi

  if docker compose version >/dev/null 2>&1; then
    return 0
  fi

  for candidate in \
    "${bin_dir:-}" \
    "/Applications/Rancher Desktop.app/Contents/Resources/resources/darwin/bin" \
    "${HOME}/.rd/bin" \
    "${HOME}/.docker/cli-plugins" \
    "/usr/local/lib/docker/cli-plugins" \
    "/usr/lib/docker/cli-plugins"; do
    if [ -n "${candidate}" ] && [ -d "${candidate}/../docker-cli-plugins" ]; then
      plugin_dir="${candidate}/../docker-cli-plugins"
      break
    fi
    if [ -n "${candidate}" ] && [ -x "${candidate}/docker-compose" ]; then
      plugin_dir="${candidate}"
      break
    fi
  done

  if [ -n "${plugin_dir:-}" ] && [ -x "${plugin_dir}/docker-compose" ]; then
    export DOCKER_CLI_PLUGIN_PATH="${plugin_dir}"
    if [ -z "${DOCKER_CONFIG:-}" ]; then
      export DOCKER_CONFIG="${HOME}/.docker"
    fi
    plugin_home="${DOCKER_CONFIG}/cli-plugins"
    mkdir -p "${plugin_home}"
    rm -f "${plugin_home}/docker-compose"
    ln -s "${plugin_dir}/docker-compose" "${plugin_home}/docker-compose"
    if [ -x "${plugin_dir}/docker-buildx" ]; then
      rm -f "${plugin_home}/docker-buildx"
      ln -s "${plugin_dir}/docker-buildx" "${plugin_home}/docker-buildx"
    fi
  fi

  return 0
}

ensure_docker_socket_access() {
  local socket_host socket_path

  socket_host="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -n 1 || true)"
  case "${socket_host}" in
    unix://*)
      socket_path="${socket_host#unix://}"
      chmod a+rw "${socket_path}" 2>/dev/null || true
      ;;
  esac
}

# Resolve a reachable Docker daemon endpoint.
#
# On macOS the default /var/run/docker.sock is often a stale symlink left behind
# by a previously installed Docker Desktop, while the active runtime (Rancher
# Desktop, Colima, OrbStack, Podman) listens on its own user-scoped socket.
# Without this, every `docker compose` call in the platform scripts fails with
# "failed to connect to the docker API".
ensure_docker_daemon_endpoint() {
  if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    return 0
  fi

  local candidate
  for candidate in \
    "${HOME}/.rd/docker.sock" \
    "${HOME}/.colima/default/docker.sock" \
    "${HOME}/.docker/run/docker.sock" \
    "${HOME}/.orbstack/run/docker.sock" \
    "${HOME}/.local/share/containers/podman/machine/podman.sock" \
    "/var/run/docker.sock"; do
    [ -S "${candidate}" ] || continue
    if DOCKER_HOST="unix://${candidate}" docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      export DOCKER_HOST="unix://${candidate}"
      echo "using docker endpoint: ${DOCKER_HOST}" >&2
      return 0
    fi
  done

  echo "no reachable Docker daemon found; start Docker Desktop, Rancher Desktop, Colima, or OrbStack first" >&2
  return 1
}

project_registry_script_path() {
  local candidates=(
    "${ROOT_DIR}/dbt/scripts/project_registry.py"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -f "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  echo "unable to locate project registry helper" >&2
  return 1
}

project_registry_lookup() {
  local project_slug="${1:?project slug is required}"
  local field="${2:?registry field is required}"
  local default_value="${3:-}"

  python3 "$(project_registry_script_path)" lookup \
    --project-slug "${project_slug}" \
    --field "${field}" \
    --default "${default_value}"
}

project_registry_manifest_key() {
  local project_slug="${1:?project slug is required}"
  project_registry_lookup "${project_slug}" manifest_object_key
}

project_registry_manifest_publish_keys() {
  local project_slug="${1:?project slug is required}"
  python3 "$(project_registry_script_path)" manifest-publish-keys \
    --project-slug "${project_slug}"
}

project_registry_product_scopes() {
  local project_slug="${1:?project slug is required}"
  python3 "$(project_registry_script_path)" product-scopes \
    --project-slug "${project_slug}"
}

project_registry_prepare_targets() {
  local project_slug="${1:?project slug is required}"
  python3 "$(project_registry_script_path)" prepare-targets \
    --project-slug "${project_slug}"
}

project_registry_slugs() {
  python3 "$(project_registry_script_path)" project-slugs
}

project_registry_kind() {
  local project_slug="${1:?project slug is required}"
  project_registry_lookup "${project_slug}" kind ""
}

project_registry_clone_owner_token() {
  local project_slug="${1:?project slug is required}"
  local kind

  kind="$(project_registry_kind "${project_slug}")"
  case "${kind}" in
    source) printf 'SOURCE' ;;
    domain) printf 'EDP' ;;
    *)
      echo "unsupported project kind for clone owner token: ${kind}" >&2
      return 1
      ;;
  esac
}

project_registry_project_name_token() {
  local project_slug="${1:?project slug is required}"
  local token

  token="${project_slug#proj_}"
  token="$(sanitize_branch_token "${token}")"
  printf '%s' "${token}" | tr '[:lower:]' '[:upper:]'
}

project_registry_branch_dbt_project_name() {
  local project_slug="${1:?project slug is required}"
  local suffix="${2:?db suffix is required}"
  printf 'DBT_PROJECT_%s_%s' "$(project_registry_project_name_token "${project_slug}")" "${suffix}"
}

project_registry_default_database_env() {
  local project_slug="${1:?project slug is required}"
  project_registry_lookup "${project_slug}" default_database_env ""
}

project_registry_scope_env_prefix() {
  local project_slug="${1:?project slug is required}"
  local kind

  kind="$(project_registry_kind "${project_slug}")"
  case "${kind}" in
    source) printf 'SNOWFLAKE_SDP' ;;
    domain) printf 'SNOWFLAKE_EDP' ;;
    *)
      echo "unsupported project kind for scope env prefix: ${kind}" >&2
      return 1
      ;;
  esac
}

project_registry_scope_database_env() {
  local project_slug="${1:?project slug is required}"
  local scope="${2:?scope is required}"
  local scope_upper

  scope_upper="$(printf '%s' "${scope}" | tr '[:lower:]' '[:upper:]')"
  printf '%s_%s_DATABASE' "$(project_registry_scope_env_prefix "${project_slug}")" "${scope_upper}"
}

project_registry_scope_database_base_env() {
  local project_slug="${1:?project slug is required}"
  local scope="${2:?scope is required}"
  printf '%s_BASE' "$(project_registry_scope_database_env "${project_slug}" "${scope}")"
}

project_registry_project_name_for_target() {
  local project_slug="${1:?project slug is required}"
  local target_name="${2:?target name is required}"
  python3 "$(project_registry_script_path)" project-name \
    --project-slug "${project_slug}" \
    --target-name "${target_name}"
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

compose_build_services() {
  local service
  for service in "$@"; do
    [ -n "${service}" ] || continue
    echo "building compose service: ${service}"
    run_with_retry "${COMPOSE_BUILD_RETRY_ATTEMPTS:-3}" "${COMPOSE_BUILD_RETRY_SLEEP_SECONDS:-5}" \
      docker compose build "${service}"
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

source_taxes_pipeline_basename() {
  printf '%s' "${SOURCE_TAXES_PIPELINE_BASENAME:-local_platform_taxes_ingest}"
}

source_depot_transactions_pipeline_basename() {
  printf '%s' "${SOURCE_DEPOT_TRANSACTIONS_PIPELINE_BASENAME:-local_platform_depot_transactions_ingest}"
}

source_pipeline_basename_for_scope() {
  local scope="${1:?source scope is required}"
  case "${scope}" in
    orders)
      source_orders_pipeline_basename
      ;;
    customers)
      source_customers_pipeline_basename
      ;;
    taxes)
      source_taxes_pipeline_basename
      ;;
    depot_transactions)
      source_depot_transactions_pipeline_basename
      ;;
    *)
      echo "unsupported source scope: ${scope}" >&2
      return 1
      ;;
  esac
}

source_dlt_script_for_scope() {
  local scope="${1:?source scope is required}"
  case "${scope}" in
    orders) printf '/opt/platform/dlt/pipeline_orders.py' ;;
    customers) printf '/opt/platform/dlt/pipeline_customers.py' ;;
    taxes) printf '/opt/platform/dlt/pipeline_taxes.py' ;;
    depot_transactions) printf '/opt/platform/dlt/pipeline_depot_transactions.py' ;;
    *)
      echo "unsupported source scope: ${scope}" >&2
      return 1
      ;;
  esac
}

activate_source_scope_runtime() {
  local scope="${1:?source scope is required (orders|customers|taxes|depot_transactions)}"
  local scope_upper base_pipeline_name dlt_pipeline_name dag_id dag_id_var dlt_name_var scope_database_var

  scope_upper="$(printf '%s' "${scope}" | tr '[:lower:]' '[:upper:]')"

  base_pipeline_name="$(source_pipeline_basename_for_scope "${scope}")"
  export DLT_SCRIPT_PATH="$(source_dlt_script_for_scope "${scope}")"
  export SNOWFLAKE_RAW_SYNC_SCOPE="${scope}"
  export SNOWFLAKE_SDP_DBT_SELECT="${scope}"
  scope_database_var="SNOWFLAKE_SDP_${scope_upper}_DATABASE"

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
  if [ -n "${!scope_database_var:-}" ]; then
    export SNOWFLAKE_SDP_DATABASE="${!scope_database_var}"
  fi
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
  # corrupt the restore file. Empty values are preserved as well: callers such as
  # verify-ingestion-promotion.sh blank credentials on purpose to scope a run,
  # and dropping those would silently restore the value from the env file.
  while IFS='=' read -r -d '' key value; do
    case "${key}" in
      [!A-Za-z_]*|*[!A-Za-z0-9_]*) continue ;;
    esac
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

merge_env_file_with_example() {
  local env_file="${1:?env file is required}"
  local example_file="${2:?example env file is required}"

  [ -f "${example_file}" ] || return 0
  if [ ! -f "${env_file}" ]; then
    cp "${example_file}" "${env_file}"
    return 0
  fi

  python3 - "${env_file}" "${example_file}" <<'PY'
from pathlib import Path
import re
import sys

env_path = Path(sys.argv[1])
example_path = Path(sys.argv[2])
env_lines = env_path.read_text().splitlines()
example_lines = example_path.read_text().splitlines()
key_pattern = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=")
present = set()

for line in env_lines:
    match = key_pattern.match(line)
    if match:
        present.add(match.group(1))

merged = list(env_lines)
appended = False
for line in example_lines:
    match = key_pattern.match(line)
    if not match:
        continue
    key = match.group(1)
    if key in present:
        continue
    merged.append(line)
    present.add(key)
    appended = True

if appended:
    env_path.write_text("\n".join(merged) + "\n")
PY
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

  merge_env_file_with_example .env .env.example

  load_env_preserving_existing .env
  ensure_docker_cli_runtime
  ensure_docker_daemon_endpoint
  ensure_docker_socket_access

  export AIRFLOW_UID="${AIRFLOW_UID:-50000}"

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
  local registry_dir

  registry_dir="$(project_registry_lookup "${project_slug}" dbt_project_dir "")"
  if [ -n "${registry_dir}" ] && [ -f "${ROOT_DIR}/${registry_dir}/dbt_project.yml" ]; then
    printf '%s/%s\n' "${ROOT_DIR}" "${registry_dir}"
    return 0
  fi

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
  local registry_dir

  registry_dir="$(project_registry_lookup "${project_slug}" dbt_project_dir "")"
  if [ -n "${registry_dir}" ] && [ -f "${ROOT_DIR}/${registry_dir}/dbt_project.yml" ]; then
    printf '/opt/platform/%s\n' "${registry_dir}"
    return 0
  fi

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

dbt_loom_manifest_bucket() {
  printf '%s' "${MINIO_MANIFEST_BUCKET:-dbt-manifests}"
}

run_dbt_loom_manifest_helper() {
  local command="${1:?loom manifest command is required}"
  shift

  docker compose run --rm --no-deps dbt-executor \
    python /opt/platform/dbt/scripts/loom_manifest.py "${command}" "$@"
}

publish_source_loom_manifests() {
  local source_project_slug="${1:-proj_source_finnova}"
  local bucket_name
  local source_project_dir
  local publish_args=()
  local object_key

  source_project_dir="$(resolve_container_dbt_project_dir "${source_project_slug}")"
  bucket_name="$(dbt_loom_manifest_bucket)"
  publish_args=(publish --project-dir "${source_project_dir}" --project-slug "${source_project_slug}" --bucket "${bucket_name}")

  while IFS= read -r object_key; do
    if [ -n "${object_key}" ]; then
      publish_args+=(--object-key "${object_key}")
    fi
  done < <(project_registry_manifest_publish_keys "${source_project_slug}")

  run_dbt_loom_manifest_helper "${publish_args[@]}"
}

export_prd_runtime_env() {
  local prd_prefix source_dlt_pipeline source_iceberg_namespace source_minio_prefix
  local source_sdp_database source_sdp_customers_database source_sdp_taxes_database source_sdp_depot_transactions_database
  local source_edp_database source_edp_customers_database source_edp_taxes_database source_edp_depot_transactions_database
  local source_sdp_project_name source_domain_transactions_project_name source_domain_customer_project_name
  local source_system_slug_value

  prd_prefix="${PRD_DEPLOYMENT_PREFIX:-PRD}"
  source_system_slug_value="$(source_system_slug)"
  source_dlt_pipeline="${PRD_SOURCE_DLT_PIPELINE_NAME:-${DLT_PIPELINE_NAME:-local_platform_ingest}}"
  source_iceberg_namespace="${PRD_SOURCE_ICEBERG_NAMESPACE:-${source_system_slug_value}}"
  source_minio_prefix="${PRD_SOURCE_MINIO_PREFIX:-landing/prd}"
  source_sdp_database="${PRD_SOURCE_SDP_DATABASE:-${SNOWFLAKE_SDP_DATABASE_BASE:-${SNOWFLAKE_SDP_DATABASE:-}}}"
  source_sdp_customers_database="${PRD_SOURCE_SDP_CUSTOMERS_DATABASE:-${SNOWFLAKE_SDP_CUSTOMERS_DATABASE_BASE:-${SNOWFLAKE_SDP_CUSTOMERS_DATABASE:-}}}"
  source_sdp_taxes_database="${PRD_SOURCE_SDP_TAXES_DATABASE:-${SNOWFLAKE_SDP_TAXES_DATABASE_BASE:-${SNOWFLAKE_SDP_TAXES_DATABASE:-}}}"
  source_sdp_depot_transactions_database="${PRD_SOURCE_SDP_DEPOT_TRANSACTIONS_DATABASE:-${SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE_BASE:-${SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE:-}}}"
  source_edp_database="${PRD_SOURCE_EDP_DATABASE:-${SNOWFLAKE_EDP_DATABASE_BASE:-${SNOWFLAKE_EDP_DATABASE:-}}}"
  source_edp_customers_database="${PRD_SOURCE_EDP_CUSTOMERS_DATABASE:-${SNOWFLAKE_EDP_CUSTOMERS_DATABASE_BASE:-${SNOWFLAKE_EDP_CUSTOMERS_DATABASE:-}}}"
  source_edp_taxes_database="${PRD_SOURCE_EDP_TAXES_DATABASE:-${SNOWFLAKE_EDP_TAXES_DATABASE_BASE:-${SNOWFLAKE_EDP_TAXES_DATABASE:-}}}"
  source_edp_depot_transactions_database="${PRD_SOURCE_EDP_DEPOT_TRANSACTIONS_DATABASE:-${SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE_BASE:-${SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE:-}}}"
  source_sdp_project_name="$(project_registry_project_name_for_target proj_source_finnova "${prd_prefix}")"
  source_domain_transactions_project_name="$(project_registry_project_name_for_target proj_domain_transactions "${prd_prefix}")"
  source_domain_customer_project_name="$(project_registry_project_name_for_target proj_domain_customer "${prd_prefix}")"

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
  export PRD_SOURCE_SDP_TAXES_DATABASE="${source_sdp_taxes_database}"
  export PRD_SOURCE_SDP_DEPOT_TRANSACTIONS_DATABASE="${source_sdp_depot_transactions_database}"
  export PRD_SOURCE_EDP_DATABASE="${source_edp_database}"
  export PRD_SOURCE_EDP_CUSTOMERS_DATABASE="${source_edp_customers_database}"
  export PRD_SOURCE_EDP_TAXES_DATABASE="${source_edp_taxes_database}"
  export PRD_SOURCE_EDP_DEPOT_TRANSACTIONS_DATABASE="${source_edp_depot_transactions_database}"

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
  export PRD_SNOWFLAKE_SDP_TAXES_DATABASE="${PRD_SNOWFLAKE_SDP_TAXES_DATABASE:-$(prefixed_identifier "${source_sdp_taxes_database}" "${prd_prefix}")}"
  export PRD_SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE="${PRD_SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE:-$(prefixed_identifier "${source_sdp_depot_transactions_database}" "${prd_prefix}")}"
  export PRD_SNOWFLAKE_EDP_DATABASE="${PRD_SNOWFLAKE_EDP_DATABASE:-$(prefixed_identifier "${source_edp_database}" "${prd_prefix}")}"
  export PRD_SNOWFLAKE_EDP_ORDERS_DATABASE="${PRD_SNOWFLAKE_EDP_ORDERS_DATABASE:-${PRD_SNOWFLAKE_EDP_DATABASE}}"
  export PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE="${PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE:-$(prefixed_identifier "${source_edp_customers_database}" "${prd_prefix}")}"
  export PRD_SNOWFLAKE_EDP_TAXES_DATABASE="${PRD_SNOWFLAKE_EDP_TAXES_DATABASE:-$(prefixed_identifier "${source_edp_taxes_database}" "${prd_prefix}")}"
  export PRD_SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE="${PRD_SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE:-$(prefixed_identifier "${source_edp_depot_transactions_database}" "${prd_prefix}")}"
  export PRD_SDP_RUNTIME_IMAGE_PREFIX="${PRD_SDP_RUNTIME_IMAGE_PREFIX:-local-platform-prd-sdp}"
  export PRD_EDP_RUNTIME_IMAGE_PREFIX="${PRD_EDP_RUNTIME_IMAGE_PREFIX:-local-platform-prd-edp}"
  export PRD_SNOWFLAKE_SDP_DBT_PROJECT="${source_sdp_project_name}"
  export PRD_SNOWFLAKE_EDP_DBT_PROJECT="${source_domain_transactions_project_name}"
  export PRD_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT="${source_domain_customer_project_name}"
  export PRD_SNOW_DBT_TARGET_NAME="${PRD_SNOW_DBT_TARGET_NAME:-prd}"

  export SNOWFLAKE_SDP_DATABASE_BASE="${source_sdp_database}"
  export SNOWFLAKE_SDP_ORDERS_DATABASE_BASE="${source_sdp_database}"
  export SNOWFLAKE_SDP_CUSTOMERS_DATABASE_BASE="${source_sdp_customers_database}"
  export SNOWFLAKE_SDP_TAXES_DATABASE_BASE="${source_sdp_taxes_database}"
  export SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE_BASE="${source_sdp_depot_transactions_database}"
  export SNOWFLAKE_EDP_DATABASE_BASE="${source_edp_database}"
  export SNOWFLAKE_EDP_ORDERS_DATABASE_BASE="${source_edp_database}"
  export SNOWFLAKE_EDP_CUSTOMERS_DATABASE_BASE="${source_edp_customers_database}"
  export SNOWFLAKE_EDP_TAXES_DATABASE_BASE="${source_edp_taxes_database}"
  export SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE_BASE="${source_edp_depot_transactions_database}"
  export SNOWFLAKE_SDP_DATABASE="${PRD_SNOWFLAKE_SDP_DATABASE}"
  export SNOWFLAKE_SDP_ORDERS_DATABASE="${PRD_SNOWFLAKE_SDP_ORDERS_DATABASE}"
  export SNOWFLAKE_SDP_CUSTOMERS_DATABASE="${PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE}"
  export SNOWFLAKE_SDP_TAXES_DATABASE="${PRD_SNOWFLAKE_SDP_TAXES_DATABASE}"
  export SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE="${PRD_SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE}"
  export SNOWFLAKE_EDP_DATABASE="${PRD_SNOWFLAKE_EDP_DATABASE}"
  export SNOWFLAKE_EDP_ORDERS_DATABASE="${PRD_SNOWFLAKE_EDP_ORDERS_DATABASE}"
  export SNOWFLAKE_EDP_CUSTOMERS_DATABASE="${PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE}"
  export SNOWFLAKE_EDP_TAXES_DATABASE="${PRD_SNOWFLAKE_EDP_TAXES_DATABASE}"
  export SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE="${PRD_SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE}"
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
  local source_sdp_database source_sdp_customers_database source_sdp_taxes_database source_sdp_depot_transactions_database
  local source_edp_database source_edp_customers_database source_edp_taxes_database source_edp_depot_transactions_database
  local source_sdp_project_name source_domain_transactions_project_name source_domain_customer_project_name
  local source_system_slug_value

  dev_prefix="${DEV_DEPLOYMENT_PREFIX:-DEV}"
  source_system_slug_value="$(source_system_slug)"
  source_dlt_pipeline="${DEV_SOURCE_DLT_PIPELINE_NAME:-${DLT_PIPELINE_NAME:-local_platform_ingest}}"
  source_iceberg_namespace="${DEV_SOURCE_ICEBERG_NAMESPACE:-${source_system_slug_value}}"
  source_minio_prefix="${DEV_SOURCE_MINIO_PREFIX:-landing/dev}"
  source_sdp_database="${DEV_SOURCE_SDP_DATABASE:-${SNOWFLAKE_SDP_DATABASE_BASE:-${SNOWFLAKE_SDP_DATABASE:-}}}"
  source_sdp_customers_database="${DEV_SOURCE_SDP_CUSTOMERS_DATABASE:-${SNOWFLAKE_SDP_CUSTOMERS_DATABASE_BASE:-${SNOWFLAKE_SDP_CUSTOMERS_DATABASE:-}}}"
  source_sdp_taxes_database="${DEV_SOURCE_SDP_TAXES_DATABASE:-${SNOWFLAKE_SDP_TAXES_DATABASE_BASE:-${SNOWFLAKE_SDP_TAXES_DATABASE:-}}}"
  source_sdp_depot_transactions_database="${DEV_SOURCE_SDP_DEPOT_TRANSACTIONS_DATABASE:-${SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE_BASE:-${SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE:-}}}"
  source_edp_database="${DEV_SOURCE_EDP_DATABASE:-${SNOWFLAKE_EDP_DATABASE_BASE:-${SNOWFLAKE_EDP_DATABASE:-}}}"
  source_edp_customers_database="${DEV_SOURCE_EDP_CUSTOMERS_DATABASE:-${SNOWFLAKE_EDP_CUSTOMERS_DATABASE_BASE:-${SNOWFLAKE_EDP_CUSTOMERS_DATABASE:-}}}"
  source_edp_taxes_database="${DEV_SOURCE_EDP_TAXES_DATABASE:-${SNOWFLAKE_EDP_TAXES_DATABASE_BASE:-${SNOWFLAKE_EDP_TAXES_DATABASE:-}}}"
  source_edp_depot_transactions_database="${DEV_SOURCE_EDP_DEPOT_TRANSACTIONS_DATABASE:-${SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE_BASE:-${SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE:-}}}"
  source_sdp_project_name="$(project_registry_project_name_for_target proj_source_finnova "${dev_prefix}")"
  source_domain_transactions_project_name="$(project_registry_project_name_for_target proj_domain_transactions "${dev_prefix}")"
  source_domain_customer_project_name="$(project_registry_project_name_for_target proj_domain_customer "${dev_prefix}")"

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
  export DEV_SOURCE_SDP_TAXES_DATABASE="${source_sdp_taxes_database}"
  export DEV_SOURCE_SDP_DEPOT_TRANSACTIONS_DATABASE="${source_sdp_depot_transactions_database}"
  export DEV_SOURCE_EDP_DATABASE="${source_edp_database}"
  export DEV_SOURCE_EDP_CUSTOMERS_DATABASE="${source_edp_customers_database}"
  export DEV_SOURCE_EDP_TAXES_DATABASE="${source_edp_taxes_database}"
  export DEV_SOURCE_EDP_DEPOT_TRANSACTIONS_DATABASE="${source_edp_depot_transactions_database}"

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
  export DEV_SNOWFLAKE_SDP_TAXES_DATABASE="${DEV_SNOWFLAKE_SDP_TAXES_DATABASE:-${source_sdp_taxes_database}}"
  export DEV_SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE="${DEV_SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE:-${source_sdp_depot_transactions_database}}"
  export DEV_SNOWFLAKE_EDP_DATABASE="${DEV_SNOWFLAKE_EDP_DATABASE:-${source_edp_database}}"
  export DEV_SNOWFLAKE_EDP_ORDERS_DATABASE="${DEV_SNOWFLAKE_EDP_ORDERS_DATABASE:-${DEV_SNOWFLAKE_EDP_DATABASE}}"
  export DEV_SNOWFLAKE_EDP_CUSTOMERS_DATABASE="${DEV_SNOWFLAKE_EDP_CUSTOMERS_DATABASE:-${source_edp_customers_database}}"
  export DEV_SNOWFLAKE_EDP_TAXES_DATABASE="${DEV_SNOWFLAKE_EDP_TAXES_DATABASE:-${source_edp_taxes_database}}"
  export DEV_SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE="${DEV_SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE:-${source_edp_depot_transactions_database}}"
  export DEV_SDP_RUNTIME_IMAGE_PREFIX="${DEV_SDP_RUNTIME_IMAGE_PREFIX:-local-platform-dev-sdp}"
  export DEV_EDP_RUNTIME_IMAGE_PREFIX="${DEV_EDP_RUNTIME_IMAGE_PREFIX:-local-platform-dev-edp}"
  export DEV_SNOWFLAKE_SDP_DBT_PROJECT="${source_sdp_project_name}"
  export DEV_SNOWFLAKE_EDP_DBT_PROJECT="${source_domain_transactions_project_name}"
  export DEV_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT="${source_domain_customer_project_name}"
  export DEV_SNOW_DBT_TARGET_NAME="${DEV_SNOW_DBT_TARGET_NAME:-dev}"

  export SNOWFLAKE_SDP_DATABASE_BASE="${source_sdp_database}"
  export SNOWFLAKE_SDP_ORDERS_DATABASE_BASE="${source_sdp_database}"
  export SNOWFLAKE_SDP_CUSTOMERS_DATABASE_BASE="${source_sdp_customers_database}"
  export SNOWFLAKE_SDP_TAXES_DATABASE_BASE="${source_sdp_taxes_database}"
  export SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE_BASE="${source_sdp_depot_transactions_database}"
  export SNOWFLAKE_EDP_DATABASE_BASE="${source_edp_database}"
  export SNOWFLAKE_EDP_ORDERS_DATABASE_BASE="${source_edp_database}"
  export SNOWFLAKE_EDP_CUSTOMERS_DATABASE_BASE="${source_edp_customers_database}"
  export SNOWFLAKE_EDP_TAXES_DATABASE_BASE="${source_edp_taxes_database}"
  export SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE_BASE="${source_edp_depot_transactions_database}"
  export SNOWFLAKE_SDP_DATABASE="${DEV_SNOWFLAKE_SDP_DATABASE}"
  export SNOWFLAKE_SDP_ORDERS_DATABASE="${DEV_SNOWFLAKE_SDP_ORDERS_DATABASE}"
  export SNOWFLAKE_SDP_CUSTOMERS_DATABASE="${DEV_SNOWFLAKE_SDP_CUSTOMERS_DATABASE}"
  export SNOWFLAKE_SDP_TAXES_DATABASE="${DEV_SNOWFLAKE_SDP_TAXES_DATABASE}"
  export SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE="${DEV_SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE}"
  export SNOWFLAKE_EDP_DATABASE="${DEV_SNOWFLAKE_EDP_DATABASE}"
  export SNOWFLAKE_EDP_ORDERS_DATABASE="${DEV_SNOWFLAKE_EDP_ORDERS_DATABASE}"
  export SNOWFLAKE_EDP_CUSTOMERS_DATABASE="${DEV_SNOWFLAKE_EDP_CUSTOMERS_DATABASE}"
  export SNOWFLAKE_EDP_TAXES_DATABASE="${DEV_SNOWFLAKE_EDP_TAXES_DATABASE}"
  export SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE="${DEV_SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE}"
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
