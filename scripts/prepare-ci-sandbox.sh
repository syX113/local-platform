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
dotenv_path="${2:-${ROOT_DIR}/artifacts/context/ci.env}"
tmp_dotenv_path="${dotenv_path}.tmp.$$"
log_prefix="${dotenv_path%.env}"
base_bootstrap_log="${log_prefix}.snowflake_base_bootstrap.log"
clone_create_log="${log_prefix}.snowflake_clone_create.log"

mkdir -p "$(dirname "${dotenv_path}")"
trap 'rm -f "${tmp_dotenv_path}"' EXIT

project_kind="$(project_registry_kind "${project_slug}")"
project_scopes="$(project_registry_product_scopes "${project_slug}")"
upstream_project_slug="$(project_registry_lookup "${project_slug}" upstream_project_slug "")"

project_token="$(sanitize_branch_token "${CI_PROJECT_PATH_SLUG:-${project_slug}}")"
project_token="$(trim_identifier "${project_token}" 18)"
branch_name_raw="${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-${CI_COMMIT_BRANCH:-${CI_COMMIT_REF_NAME:-${CI_COMMIT_REF_SLUG:-local}}}}"
branch_token="$(sanitize_branch_token "${branch_name_raw}")"
branch_token="${branch_token:-local}"
clone_owner_token="$(project_registry_clone_owner_token "${project_slug}")"
merge_request_token_raw="${CI_MERGE_REQUEST_IID:-${CI_MERGE_REQUEST_ID:-}}"
merge_request_token=""
if [ -n "${merge_request_token_raw}" ]; then
  merge_request_token="$(sanitize_branch_token "${merge_request_token_raw}")"
fi

if [ "${CI_PIPELINE_SOURCE:-}" = "merge_request_event" ]; then
  sandbox_kind="merge_request"
  merge_request_token="${merge_request_token:-local}"
  branch_seed="mr_${project_token}_${merge_request_token}_${branch_token}"
  clone_branch_token="mr_${merge_request_token}_${branch_token}"
  clone_action="ensure"
  cleanup_mode="preserve"
elif [ "${CI_COMMIT_BRANCH:-}" = "${CI_DEFAULT_BRANCH:-main}" ]; then
  sandbox_kind="merge"
  branch_seed="merge_${project_token}_${CI_PIPELINE_ID:-local}_${CI_COMMIT_SHORT_SHA:-head}"
  clone_branch_token="merge_${CI_PIPELINE_ID:-local}_${CI_COMMIT_SHORT_SHA:-head}"
  clone_action="replace"
  cleanup_mode="destroy"
else
  sandbox_kind="branch"
  branch_seed="branch_${project_token}_${branch_token}"
  clone_branch_token="${branch_token}"
  clone_action="ensure"
  cleanup_mode="preserve"
fi

sandbox_slug="$(sanitize_branch_token "${branch_seed}")"
namespace_hash="$(stable_token "${sandbox_slug}")"
namespace_base="$(trim_identifier "${sandbox_slug}" 29)"
namespace_suffix="$(sanitize_branch_token "${namespace_base}_${namespace_hash}")"
namespace_suffix="$(trim_identifier "${namespace_suffix}" 40)"
namespace_suffix="${namespace_suffix:-local}"
db_suffix="$(printf '%s' "${namespace_suffix}" | tr '[:lower:]' '[:upper:]')"
project_path_slug="${CI_PROJECT_PATH_SLUG:-${project_kind}}"
source_system_slug="${SOURCE_SYSTEM_SLUG:-postgres}"
object_prefix="landing/ci/${project_path_slug}/${sandbox_kind}/${source_system_slug}"
object_store_bucket="s3://${MINIO_BUCKET}/${object_prefix}"
project_name_token="$(project_registry_project_name_token "${project_slug}")"
branch_dbt_project="DBT_PROJECT_${project_name_token}_${db_suffix}"

set_scope_database_envs() {
  local env_project_slug="${1:?project slug is required}"
  local scope="${2:?scope is required}"
  local scope_database_env scope_database_base_env base_database branch_database

  scope_database_env="$(project_registry_scope_database_env "${env_project_slug}" "${scope}")"
  scope_database_base_env="$(project_registry_scope_database_base_env "${env_project_slug}" "${scope}")"
  base_database="${!scope_database_base_env:-${!scope_database_env:-}}"
  if [ -z "${base_database}" ]; then
    echo "missing required Snowflake database environment variable: ${scope_database_base_env} or ${scope_database_env}" >&2
    exit 1
  fi
  branch_database="$(build_clone_database_name "${base_database}" "${clone_owner_token}" "${clone_branch_token}" 120)"

  printf '%s=%s\n' "${scope_database_base_env}" "${base_database}" >> "${tmp_dotenv_path}"
  printf '%s=%s\n' "${scope_database_env}" "${branch_database}" >> "${tmp_dotenv_path}"
}

cat > "${tmp_dotenv_path}" <<EOF
CI_SANDBOX_KIND=${sandbox_kind}
CI_SANDBOX_PROJECT_KIND=${project_kind}
CI_SANDBOX_PROJECT_SLUG=${project_slug}
CI_SANDBOX_SLUG=${sandbox_slug}
CI_SANDBOX_BRANCH_NAME=${branch_name_raw}
CI_SANDBOX_MERGE_REQUEST=${CI_MERGE_REQUEST_IID:-}
CI_SANDBOX_CLONE_ACTION=${clone_action}
CI_SANDBOX_CLEANUP_MODE=${cleanup_mode}
CI_SANDBOX_OBJECT_PREFIX=${object_prefix}
CI_SANDBOX_DBT_PROJECT=${branch_dbt_project}
ICEBERG_CATALOG_NAME=ci_${project_kind}_${sandbox_kind}_${namespace_suffix}
SNOWFLAKE_CLONE_OWNER_TOKEN=${clone_owner_token}
SNOWFLAKE_CLONE_BRANCH_TOKEN=${clone_branch_token}
SNOWFLAKE_CLONE_SCHEMA=CLONE_${db_suffix}
MINIO_PREFIX=${object_prefix}
OBJECT_STORE_BUCKET=${object_store_bucket}
DLT_PIPELINE_NAME=${project_kind}_${sandbox_kind}_${namespace_suffix}
ICEBERG_NAMESPACE=${namespace_suffix}
SNOW_DBT_TARGET_NAME=${sandbox_kind}
EOF

while IFS= read -r scope; do
  [ -n "${scope}" ] || continue
  if [ "${project_kind}" = "domain" ] && [ -n "${upstream_project_slug}" ]; then
    set_scope_database_envs "${upstream_project_slug}" "${scope}"
  fi
  set_scope_database_envs "${project_slug}" "${scope}"
done < <(project_registry_product_scopes "${project_slug}")

default_database_env_name="$(project_registry_default_database_env "${project_slug}")"
default_database_base_env_name="${default_database_env_name}_BASE"
default_database_value="${!default_database_env_name:-}"
default_database_base_value="${!default_database_base_env_name:-${default_database_value}}"

# The scope loop above already mapped every registered scope database onto its
# sandbox clone. Only fill the default database entries when the loop did not
# cover them; re-appending them unconditionally would override the clone name
# with the shared DEV database and silently break branch isolation.
append_env_default() {
  local key="${1:?key is required}"
  local value="${2:-}"

  [ -n "${value}" ] || return 0
  grep -q "^${key}=" "${tmp_dotenv_path}" && return 0
  printf '%s=%s\n' "${key}" "${value}" >> "${tmp_dotenv_path}"
}

append_env_default "${default_database_env_name}" "${default_database_value}"
append_env_default "${default_database_base_env_name}" "${default_database_base_value}"

if [ "${project_kind}" = "source" ]; then
  printf 'SNOWFLAKE_SDP_DBT_PROJECT=%s\n' "${branch_dbt_project}" >> "${tmp_dotenv_path}"
  while IFS= read -r scope; do
    [ -n "${scope}" ] || continue
    scope_upper="$(printf '%s' "${scope}" | tr '[:lower:]' '[:upper:]')"
    printf 'AIRFLOW_SANDBOX_%s_DAG_ID=%s\n' "${scope_upper}" "$( [ "${sandbox_kind}" = "merge_request" ] && printf 'MR_%s_%s_%s' "${project_kind}" "${namespace_suffix}" "${scope}" || printf 'DEV_%s_%s_%s' "${project_kind}" "${namespace_suffix}" "${scope}" )" >> "${tmp_dotenv_path}"
  done < <(project_registry_product_scopes "${project_slug}")
  printf 'AIRFLOW_SANDBOX_DAG_ID=%s\n' "$( [ "${sandbox_kind}" = "merge_request" ] && printf 'MR_%s_%s' "${project_kind}" "${namespace_suffix}" || printf 'DEV_%s_%s' "${project_kind}" "${namespace_suffix}" )" >> "${tmp_dotenv_path}"
else
  printf 'SNOWFLAKE_EDP_DBT_PROJECT=%s\n' "${branch_dbt_project}" >> "${tmp_dotenv_path}"
fi

bash "${SCRIPT_DIR}/ensure-snowflake-foundation.sh" | tee "${base_bootstrap_log}"

set -a
# shellcheck disable=SC1090
source "${tmp_dotenv_path}"
set +a

clone_env_args=()
while IFS='=' read -r key value; do
  case "${key}" in
    SNOWFLAKE_*) clone_env_args+=(-e "${key}=${value}") ;;
  esac
done < <(env)

docker compose run --rm --no-deps \
  "${clone_env_args[@]}" \
  dbt-executor \
  python /opt/platform/dbt/scripts/manage_ci_clones.py "${CI_SANDBOX_CLONE_ACTION}" \
  | tee "${clone_create_log}"

mv "${tmp_dotenv_path}" "${dotenv_path}"
trap - EXIT

printf 'prepared ci sandbox %s for %s\n' "${sandbox_slug}" "${project_kind}"
