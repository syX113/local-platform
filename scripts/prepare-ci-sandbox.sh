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
tmp_dotenv_path="${dotenv_path}.tmp.$$"
log_prefix="${dotenv_path%.env}"
base_bootstrap_log="${log_prefix}.snowflake_base_bootstrap.log"
clone_create_log="${log_prefix}.snowflake_clone_create.log"

mkdir -p "$(dirname "${dotenv_path}")"
trap 'rm -f "${tmp_dotenv_path}"' EXIT

project_token="$(sanitize_branch_token "${CI_PROJECT_PATH_SLUG:-${project_kind}}")"
project_token="$(trim_identifier "${project_token}" 18)"
branch_name_raw="${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-${CI_COMMIT_BRANCH:-${CI_COMMIT_REF_NAME:-${CI_COMMIT_REF_SLUG:-local}}}}"
branch_token="$(sanitize_branch_token "${branch_name_raw}")"
branch_token="${branch_token:-local}"
clone_owner_token="$(printf '%s' "${project_kind}" | tr '[:lower:]' '[:upper:]')"
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
source_dbt_project="DBT_PROJECT_SOURCE_FINNOVA_${db_suffix}"
edp_orders_dbt_project="DBT_PROJECT_EDP_ORDERS_${db_suffix}"
edp_customers_dbt_project="DBT_PROJECT_EDP_CUSTOMERS_${db_suffix}"
source_orders_pipeline_name="${project_kind}_${sandbox_kind}_${namespace_suffix}_orders"
source_customers_pipeline_name="${project_kind}_${sandbox_kind}_${namespace_suffix}_customers"

base_sdp_database="${SNOWFLAKE_SDP_ORDERS_DATABASE:-${SNOWFLAKE_SDP_DATABASE}}"
base_sdp_customers_database="${SNOWFLAKE_SDP_CUSTOMERS_DATABASE}"
base_edp_orders_database="${SNOWFLAKE_EDP_ORDERS_DATABASE:-${SNOWFLAKE_EDP_DATABASE}}"
base_edp_customers_database="${SNOWFLAKE_EDP_CUSTOMERS_DATABASE}"
branch_sdp_database="$(build_clone_database_name "${base_sdp_database}" "${clone_owner_token}" "${clone_branch_token}" 120)"
branch_sdp_customers_database="$(build_clone_database_name "${base_sdp_customers_database}" "${clone_owner_token}" "${clone_branch_token}" 120)"
branch_edp_orders_database="$(build_clone_database_name "${base_edp_orders_database}" "${clone_owner_token}" "${clone_branch_token}" 120)"
branch_edp_customers_database="$(build_clone_database_name "${base_edp_customers_database}" "${clone_owner_token}" "${clone_branch_token}" 120)"

if printf '%s' "${project_path_slug}" | grep -qi 'customers'; then
  base_edp_database="${base_edp_customers_database}"
  branch_edp_database="${branch_edp_customers_database}"
  edp_dbt_project="${edp_customers_dbt_project}"
else
  base_edp_database="${base_edp_orders_database}"
  branch_edp_database="${branch_edp_orders_database}"
  edp_dbt_project="${edp_orders_dbt_project}"
fi

cat > "${tmp_dotenv_path}" <<EOF
CI_SANDBOX_KIND=${sandbox_kind}
CI_SANDBOX_PROJECT_KIND=${project_kind}
CI_SANDBOX_SLUG=${sandbox_slug}
CI_SANDBOX_BRANCH_NAME=${branch_name_raw}
CI_SANDBOX_MERGE_REQUEST=${CI_MERGE_REQUEST_IID:-}
CI_SANDBOX_CLONE_ACTION=${clone_action}
CI_SANDBOX_CLEANUP_MODE=${cleanup_mode}
CI_SANDBOX_OBJECT_PREFIX=${object_prefix}
ICEBERG_CATALOG_NAME=ci_${project_kind}_${sandbox_kind}_${namespace_suffix}
SNOWFLAKE_CLONE_OWNER_TOKEN=${clone_owner_token}
SNOWFLAKE_CLONE_BRANCH_TOKEN=${clone_branch_token}
SNOWFLAKE_SDP_DATABASE_BASE=${base_sdp_database}
SNOWFLAKE_SDP_ORDERS_DATABASE_BASE=${base_sdp_database}
SNOWFLAKE_SDP_CUSTOMERS_DATABASE_BASE=${base_sdp_customers_database}
SNOWFLAKE_EDP_DATABASE_BASE=${base_edp_database}
SNOWFLAKE_EDP_ORDERS_DATABASE_BASE=${base_edp_orders_database}
SNOWFLAKE_EDP_CUSTOMERS_DATABASE_BASE=${base_edp_customers_database}
SNOWFLAKE_SDP_DATABASE=${branch_sdp_database}
SNOWFLAKE_SDP_ORDERS_DATABASE=${branch_sdp_database}
SNOWFLAKE_SDP_CUSTOMERS_DATABASE=${branch_sdp_customers_database}
SNOWFLAKE_EDP_DATABASE=${branch_edp_database}
SNOWFLAKE_EDP_ORDERS_DATABASE=${branch_edp_orders_database}
SNOWFLAKE_EDP_CUSTOMERS_DATABASE=${branch_edp_customers_database}
SNOWFLAKE_CLONE_SCHEMA=CLONE_${db_suffix}
SNOWFLAKE_SDP_DBT_PROJECT=${source_dbt_project}
SNOWFLAKE_EDP_DBT_PROJECT=${edp_dbt_project}
SNOWFLAKE_EDP_ORDERS_DBT_PROJECT=${edp_orders_dbt_project}
SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT=${edp_customers_dbt_project}
MINIO_PREFIX=${object_prefix}
OBJECT_STORE_BUCKET=${object_store_bucket}
DLT_PIPELINE_NAME=${project_kind}_${sandbox_kind}_${namespace_suffix}
SOURCE_ORDERS_DLT_PIPELINE_NAME=${source_orders_pipeline_name}
SOURCE_CUSTOMERS_DLT_PIPELINE_NAME=${source_customers_pipeline_name}
ICEBERG_NAMESPACE=${namespace_suffix}
SNOW_DBT_TARGET_NAME=${sandbox_kind}
AIRFLOW_SANDBOX_DAG_ID=$( [ "${sandbox_kind}" = "merge_request" ] && printf 'MR_%s_%s' "${project_kind}" "${namespace_suffix}" || printf 'DEV_%s_%s' "${project_kind}" "${namespace_suffix}" )
AIRFLOW_SANDBOX_ORDERS_DAG_ID=$( [ "${sandbox_kind}" = "merge_request" ] && printf 'MR_%s_%s_orders' "${project_kind}" "${namespace_suffix}" || printf 'DEV_%s_%s_orders' "${project_kind}" "${namespace_suffix}" )
AIRFLOW_SANDBOX_CUSTOMERS_DAG_ID=$( [ "${sandbox_kind}" = "merge_request" ] && printf 'MR_%s_%s_customers' "${project_kind}" "${namespace_suffix}" || printf 'DEV_%s_%s_customers' "${project_kind}" "${namespace_suffix}" )
EOF

bash "${SCRIPT_DIR}/ensure-snowflake-foundation.sh" | tee "${base_bootstrap_log}"

set -a
# shellcheck disable=SC1090
source "${tmp_dotenv_path}"
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
  -e "SNOWFLAKE_SDP_ORDERS_DATABASE_BASE=${SNOWFLAKE_SDP_ORDERS_DATABASE_BASE}" \
  -e "SNOWFLAKE_SDP_CUSTOMERS_DATABASE_BASE=${SNOWFLAKE_SDP_CUSTOMERS_DATABASE_BASE}" \
  -e "SNOWFLAKE_EDP_DATABASE_BASE=${SNOWFLAKE_EDP_DATABASE_BASE}" \
  -e "SNOWFLAKE_EDP_ORDERS_DATABASE_BASE=${SNOWFLAKE_EDP_ORDERS_DATABASE_BASE}" \
  -e "SNOWFLAKE_EDP_CUSTOMERS_DATABASE_BASE=${SNOWFLAKE_EDP_CUSTOMERS_DATABASE_BASE}" \
  -e "SNOWFLAKE_SDP_DATABASE=${SNOWFLAKE_SDP_DATABASE}" \
  -e "SNOWFLAKE_SDP_ORDERS_DATABASE=${SNOWFLAKE_SDP_ORDERS_DATABASE}" \
  -e "SNOWFLAKE_SDP_CUSTOMERS_DATABASE=${SNOWFLAKE_SDP_CUSTOMERS_DATABASE}" \
  -e "SNOWFLAKE_EDP_DATABASE=${SNOWFLAKE_EDP_DATABASE}" \
  -e "SNOWFLAKE_EDP_ORDERS_DATABASE=${SNOWFLAKE_EDP_ORDERS_DATABASE}" \
  -e "SNOWFLAKE_EDP_CUSTOMERS_DATABASE=${SNOWFLAKE_EDP_CUSTOMERS_DATABASE}" \
  dbt-executor \
  python /opt/platform/dbt/scripts/manage_ci_clones.py "${CI_SANDBOX_CLONE_ACTION}" \
  | tee "${clone_create_log}"

mv "${tmp_dotenv_path}" "${dotenv_path}"
trap - EXIT

printf 'prepared ci sandbox %s for %s\n' "${sandbox_slug}" "${project_kind}"
