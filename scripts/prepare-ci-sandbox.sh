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

project_kind="${1:?project kind is required (sdp|edp)}"
dotenv_path="${2:-${ROOT_DIR}/artifacts/context/ci.env}"

mkdir -p "$(dirname "${dotenv_path}")"

project_token="$(sanitize_branch_token "${CI_PROJECT_PATH_SLUG:-${project_kind}}")"
project_token="$(trim_identifier "${project_token}" 18)"
branch_name_raw="${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-${CI_COMMIT_BRANCH:-${CI_COMMIT_REF_NAME:-${CI_COMMIT_REF_SLUG:-local}}}}"
branch_token="$(sanitize_branch_token "${branch_name_raw}")"
branch_token="${branch_token:-local}"
clone_owner_token="$(printf '%s' "${project_kind}" | tr '[:lower:]' '[:upper:]')"

if [ "${CI_COMMIT_BRANCH:-}" = "${CI_DEFAULT_BRANCH:-main}" ]; then
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
object_prefix="platform/ci/${project_path_slug}/${sandbox_slug}"
object_store_bucket="s3://${MINIO_BUCKET}/${object_prefix}"

base_sdp_database="${SNOWFLAKE_SDP_DATABASE}"
base_edp_database="${SNOWFLAKE_EDP_DATABASE}"
branch_sdp_database="$(build_clone_database_name "${base_sdp_database}" "${clone_owner_token}" "${clone_branch_token}" 120)"
branch_edp_database="$(build_clone_database_name "${base_edp_database}" "${clone_owner_token}" "${clone_branch_token}" 120)"

cat > "${dotenv_path}" <<EOF
CI_SANDBOX_KIND=${sandbox_kind}
CI_SANDBOX_PROJECT_KIND=${project_kind}
CI_SANDBOX_SLUG=${sandbox_slug}
CI_SANDBOX_CLONE_ACTION=${clone_action}
CI_SANDBOX_CLEANUP_MODE=${cleanup_mode}
CI_SANDBOX_OBJECT_PREFIX=${object_prefix}
SNOWFLAKE_CLONE_OWNER_TOKEN=${clone_owner_token}
SNOWFLAKE_CLONE_BRANCH_TOKEN=${clone_branch_token}
SNOWFLAKE_SDP_DATABASE_BASE=${base_sdp_database}
SNOWFLAKE_EDP_DATABASE_BASE=${base_edp_database}
SNOWFLAKE_SDP_DATABASE=${branch_sdp_database}
SNOWFLAKE_EDP_DATABASE=${branch_edp_database}
SNOWFLAKE_CLONE_SCHEMA=CLONE_${db_suffix}
MINIO_PREFIX=${object_prefix}
OBJECT_STORE_BUCKET=${object_store_bucket}
DLT_PIPELINE_NAME=${project_kind}_${namespace_suffix}
ICEBERG_NAMESPACE=landing_${namespace_suffix}
EOF

bash "${SCRIPT_DIR}/ensure-snowflake-foundation.sh" | tee "$(dirname "${dotenv_path}")/snowflake_base_bootstrap.log"

set -a
# shellcheck disable=SC1090
source "${dotenv_path}"
set +a

docker compose run --rm --no-deps \
  -e "SNOWFLAKE_ACCOUNT=${SNOWFLAKE_ACCOUNT}" \
  -e "SNOWFLAKE_USER=${SNOWFLAKE_USER}" \
  -e "SNOWFLAKE_PASSWORD=${SNOWFLAKE_PASSWORD}" \
  -e "SNOWFLAKE_ROLE=${SNOWFLAKE_ROLE}" \
  -e "SNOWFLAKE_WAREHOUSE=${SNOWFLAKE_WAREHOUSE}" \
  -e "SNOWFLAKE_CLONE_OWNER_TOKEN=${SNOWFLAKE_CLONE_OWNER_TOKEN}" \
  -e "SNOWFLAKE_CLONE_BRANCH_TOKEN=${SNOWFLAKE_CLONE_BRANCH_TOKEN}" \
  -e "SNOWFLAKE_SDP_DATABASE_BASE=${SNOWFLAKE_SDP_DATABASE_BASE}" \
  -e "SNOWFLAKE_EDP_DATABASE_BASE=${SNOWFLAKE_EDP_DATABASE_BASE}" \
  -e "SNOWFLAKE_SDP_DATABASE=${SNOWFLAKE_SDP_DATABASE}" \
  -e "SNOWFLAKE_EDP_DATABASE=${SNOWFLAKE_EDP_DATABASE}" \
  dbt-executor \
  python /opt/platform/dbt/scripts/manage_ci_clones.py "${CI_SANDBOX_CLONE_ACTION}" \
  | tee "$(dirname "${dotenv_path}")/snowflake_clone_create.log"

printf 'prepared ci sandbox %s for %s\n' "${sandbox_slug}" "${project_kind}"
