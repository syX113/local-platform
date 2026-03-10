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

ARTIFACT_DIR="${ROOT_DIR}/artifacts/sdp-cd"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

source_sdp_database="${SNOWFLAKE_SDP_DATABASE}"
source_edp_database="${SNOWFLAKE_EDP_DATABASE}"
clone_owner_token="SDP_CD"
clone_branch_token="merge_${CI_PIPELINE_ID:-local}_${CI_COMMIT_SHORT_SHA:-head}"
cd_slug="$(printf '%s' "${CI_SANDBOX_SLUG:-local}" | tr '[:upper:]' '[:lower:]')_cd_${CI_PIPELINE_ID:-local}"
cd_slug="$(printf '%s' "${cd_slug}" | tr -cs 'a-z0-9' '_')"
cd_slug="${cd_slug#_}"
cd_slug="${cd_slug%_}"
cd_hash="$(stable_token "${cd_slug}")"
cd_namespace="$(printf '%s' "${cd_slug}" | cut -c1-29)_${cd_hash}"
cd_namespace="$(printf '%s' "${cd_namespace}" | tr -cs 'a-z0-9' '_')"
cd_namespace="${cd_namespace#_}"
cd_namespace="${cd_namespace%_}"
cd_namespace="${cd_namespace:0:40}"
cd_namespace="${cd_namespace:-local}"

orig_minio_prefix="${MINIO_PREFIX:-}"
orig_object_store_bucket="${OBJECT_STORE_BUCKET:-}"
orig_dlt_pipeline_name="${DLT_PIPELINE_NAME:-}"
orig_iceberg_namespace="${ICEBERG_NAMESPACE:-}"

export SNOWFLAKE_SDP_DATABASE_BASE="${source_sdp_database}"
export SNOWFLAKE_EDP_DATABASE_BASE="${source_edp_database}"
export SNOWFLAKE_CLONE_OWNER_TOKEN="${clone_owner_token}"
export SNOWFLAKE_CLONE_BRANCH_TOKEN="${clone_branch_token}"
export SNOWFLAKE_SDP_DATABASE="$(build_clone_database_name "${source_sdp_database}" "${clone_owner_token}" "${clone_branch_token}" 120)"
export SNOWFLAKE_EDP_DATABASE="$(build_clone_database_name "${source_edp_database}" "${clone_owner_token}" "${clone_branch_token}" 120)"
export SNOWFLAKE_SDP_DBT_PROJECT="DBT_PROJECT_SDP_ORDERS_$(printf '%s' "${cd_namespace}" | tr '[:lower:]' '[:upper:]')"
export SNOWFLAKE_EDP_DBT_PROJECT="DBT_PROJECT_EDP_ORDERS_$(printf '%s' "${cd_namespace}" | tr '[:lower:]' '[:upper:]')"
export MINIO_PREFIX="platform/ci/${CI_PROJECT_PATH_SLUG:-proj_sdp_orders}/${cd_slug}"
export OBJECT_STORE_BUCKET="s3://${MINIO_BUCKET}/${MINIO_PREFIX}"
export DLT_PIPELINE_NAME="sdp_cd_${cd_namespace}"
export ICEBERG_NAMESPACE="landing_${cd_namespace}"
export SNOW_DBT_TARGET_NAME="merge"
export CI_SANDBOX_KIND="merge"
export CI_SANDBOX_SLUG="${cd_slug}"
export CI_SANDBOX_CLEANUP_MODE="destroy"

candidate_dag_id="DEV_${DLT_PIPELINE_NAME}"
export AIRFLOW_SANDBOX_DAG_ID="${candidate_dag_id}"
bash "${SCRIPT_DIR}/deploy-airflow-dag.sh" current "${candidate_dag_id}" "current-sdp-cd" | tee "${ARTIFACT_DIR}/airflow_candidate.log"

cleanup() {
  "${SCRIPT_DIR}/cleanup-ci-sandbox.sh" || true
  export MINIO_PREFIX="${orig_minio_prefix}"
  export OBJECT_STORE_BUCKET="${orig_object_store_bucket}"
  export DLT_PIPELINE_NAME="${orig_dlt_pipeline_name}"
  export ICEBERG_NAMESPACE="${orig_iceberg_namespace}"
}

trap cleanup EXIT

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
  python /opt/platform/dbt/scripts/manage_ci_clones.py replace | tee "${ARTIFACT_DIR}/cd_clone_create.log"

"${SCRIPT_DIR}/verify-ingestion-promotion.sh" \
  "2026-03-07" \
  "${candidate_dag_id}" \
  "/opt/airflow/dags/deployed/$(sanitize_branch_token "${candidate_dag_id}").py" \
  | tee "${ARTIFACT_DIR}/ingestion.log"
"${SCRIPT_DIR}/verify-sdp-promotion.sh" | tee "${ARTIFACT_DIR}/sdp.log"

printf 'sdp_cd_clone=passed\n' | tee "${ARTIFACT_DIR}/summary.txt"
