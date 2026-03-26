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

branch_name_raw="${CI_COMMIT_BRANCH:-${CI_COMMIT_REF_NAME:-${CI_COMMIT_REF_SLUG:-local}}}"
if [ -z "${branch_name_raw}" ]; then
  echo "branch sandbox resolution requires CI_COMMIT_BRANCH or CI_COMMIT_REF_NAME" >&2
  exit 1
fi

project_kind="$(project_registry_kind "${project_slug}")"
project_scopes="$(project_registry_product_scopes "${project_slug}")"
upstream_project_slug="$(project_registry_lookup "${project_slug}" upstream_project_slug "")"

project_path_slug="${CI_PROJECT_PATH_SLUG:-${project_slug}}"
project_token="$(sanitize_branch_token "${project_path_slug}")"
project_token="$(trim_identifier "${project_token}" 18)"
branch_token="$(sanitize_branch_token "${branch_name_raw}")"
branch_token="${branch_token:-local}"
clone_owner_token="$(project_registry_clone_owner_token "${project_slug}")"

sandbox_kind="branch"
branch_seed="branch_${project_token}_${branch_token}"
clone_branch_token="${branch_token}"
clone_action="ensure"
cleanup_mode="preserve"

sandbox_slug="$(sanitize_branch_token "${branch_seed}")"
namespace_hash="$(stable_token "${sandbox_slug}")"
namespace_base="$(trim_identifier "${sandbox_slug}" 29)"
namespace_suffix="$(sanitize_branch_token "${namespace_base}_${namespace_hash}")"
namespace_suffix="$(trim_identifier "${namespace_suffix}" 40)"
namespace_suffix="${namespace_suffix:-local}"
db_suffix="$(printf '%s' "${namespace_suffix}" | tr '[:lower:]' '[:upper:]')"
source_system_slug="${SOURCE_SYSTEM_SLUG:-postgres}"
object_prefix="landing/ci/${project_path_slug}/${sandbox_kind}/${source_system_slug}"
object_store_bucket="s3://${MINIO_BUCKET}/${object_prefix}"
project_name_token="$(project_registry_project_name_token "${project_slug}")"
branch_dbt_project="DBT_PROJECT_${project_name_token}_${db_suffix}"

required_databases=()
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
  required_databases+=("${branch_database}")

  printf '%s=%s\n' "${scope_database_base_env}" "${base_database}" >> "${dotenv_path}"
  printf '%s=%s\n' "${scope_database_env}" "${branch_database}" >> "${dotenv_path}"
}

mkdir -p "$(dirname "${dotenv_path}")"

cat > "${dotenv_path}" <<EOF
CI_SANDBOX_KIND=${sandbox_kind}
CI_SANDBOX_PROJECT_KIND=${project_kind}
CI_SANDBOX_PROJECT_SLUG=${project_slug}
CI_SANDBOX_SLUG=${sandbox_slug}
CI_SANDBOX_BRANCH_NAME=${branch_name_raw}
CI_SANDBOX_MERGE_REQUEST=
CI_SANDBOX_CLONE_ACTION=${clone_action}
CI_SANDBOX_CLEANUP_MODE=${cleanup_mode}
CI_SANDBOX_OBJECT_PREFIX=${object_prefix}
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
if [ -n "${default_database_base_value}" ]; then
  printf '%s=%s\n' "${default_database_base_env_name}" "${default_database_base_value}" >> "${dotenv_path}"
fi
if [ -n "${default_database_value}" ]; then
  printf '%s=%s\n' "${default_database_env_name}" "${default_database_value}" >> "${dotenv_path}"
fi

if [ "${project_kind}" = "source" ]; then
  printf 'SNOWFLAKE_SDP_DBT_PROJECT=%s\n' "${branch_dbt_project}" >> "${dotenv_path}"
  printf 'AIRFLOW_SANDBOX_DAG_ID=DEV_%s_%s\n' "${project_kind}" "${namespace_suffix}" >> "${dotenv_path}"
  while IFS= read -r scope; do
    [ -n "${scope}" ] || continue
    scope_upper="$(printf '%s' "${scope}" | tr '[:lower:]' '[:upper:]')"
    printf 'AIRFLOW_SANDBOX_%s_DAG_ID=DEV_%s_%s_%s\n' "${scope_upper}" "${project_kind}" "${namespace_suffix}" "${scope}" >> "${dotenv_path}"
  done < <(project_registry_product_scopes "${project_slug}")
else
  printf 'SNOWFLAKE_EDP_DBT_PROJECT=%s\n' "${branch_dbt_project}" >> "${dotenv_path}"
fi

clone_databases_exist() {
  local -a databases=("$@")

  if [ "${#databases[@]}" -eq 0 ]; then
    return 0
  fi

  docker compose run --rm --no-deps \
    -e "SNOWFLAKE_ACCOUNT=${SNOWFLAKE_ACCOUNT}" \
    -e "SNOWFLAKE_USER=${SNOWFLAKE_USER}" \
    -e "SNOWFLAKE_PASSWORD=${SNOWFLAKE_PASSWORD}" \
    -e "SNOWFLAKE_ROLE=${SNOWFLAKE_ROLE}" \
    -e "SNOWFLAKE_WAREHOUSE=${SNOWFLAKE_WAREHOUSE}" \
    dbt-executor python - "${databases[@]}" <<'PY' >/dev/null
from __future__ import annotations

import os
import sys

import snowflake.connector


def main() -> int:
    connection = snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        role=os.environ["SNOWFLAKE_ROLE"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
    )
    try:
        with connection.cursor() as cursor:
            for database_name in sys.argv[1:]:
                cursor.execute(f"show databases like '{database_name}'")
                if cursor.fetchone() is None:
                    return 1
    finally:
        connection.close()
    return 0


raise SystemExit(main())
PY
}

wait_seconds="${CI_BRANCH_SANDBOX_WAIT_SECONDS:-20}"
wait_interval="${CI_BRANCH_SANDBOX_WAIT_INTERVAL_SECONDS:-4}"
elapsed=0

while ! clone_databases_exist "${required_databases[@]}"; do
  if [ "${elapsed}" -ge "${wait_seconds}" ]; then
    printf 'branch sandbox missing for %s:%s after %ss; provisioning deterministic fallback\\n' "${project_kind}" "${branch_name_raw}" "${wait_seconds}" >&2
    bash "${SCRIPT_DIR}/prepare-ci-sandbox.sh" "${project_kind}" "${dotenv_path}"
    break
  fi

  sleep "${wait_interval}"
  elapsed=$((elapsed + wait_interval))
done

printf 'resolved deterministic branch sandbox context for %s:%s\n' "${project_kind}" "${branch_name_raw}"
