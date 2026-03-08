#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

ARTIFACT_DIR="${ROOT_DIR}/artifacts/sdp-cd"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

stable_token() {
  local raw="${1:?raw token is required}"
  cksum <<<"${raw}" | awk '{print $1}'
}

source_sdp_database="${SNOWFLAKE_SDP_DATABASE}"
source_edp_database="${SNOWFLAKE_EDP_DATABASE}"
suffix="$(printf '%s' "${CI_PIPELINE_ID:-local}" | tr -cs '[:alnum:]' '_' | tr '[:lower:]' '[:upper:]')"
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
export SNOWFLAKE_SDP_DATABASE="${source_sdp_database}_CD_${suffix}"
export SNOWFLAKE_EDP_DATABASE="${source_edp_database}_CD_${suffix}"
export MINIO_PREFIX="platform/ci/${CI_PROJECT_PATH_SLUG:-proj_sdp_orders}/${cd_slug}"
export OBJECT_STORE_BUCKET="s3://${MINIO_BUCKET}/${MINIO_PREFIX}"
export DLT_PIPELINE_NAME="sdp_cd_${cd_namespace}"
export ICEBERG_NAMESPACE="landing_${cd_namespace}"

cleanup() {
  ./scripts/cleanup-ci-sandbox.sh || true
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
  -e "SNOWFLAKE_SDP_DATABASE_BASE=${SNOWFLAKE_SDP_DATABASE_BASE}" \
  -e "SNOWFLAKE_EDP_DATABASE_BASE=${SNOWFLAKE_EDP_DATABASE_BASE}" \
  -e "SNOWFLAKE_SDP_DATABASE=${SNOWFLAKE_SDP_DATABASE}" \
  -e "SNOWFLAKE_EDP_DATABASE=${SNOWFLAKE_EDP_DATABASE}" \
  dbt-executor \
  python /opt/platform/dbt/scripts/manage_ci_clones.py replace | tee "${ARTIFACT_DIR}/cd_clone_create.log"

./scripts/verify-ingestion-promotion.sh | tee "${ARTIFACT_DIR}/ingestion.log"
./scripts/verify-sdp-promotion.sh | tee "${ARTIFACT_DIR}/sdp.log"

printf 'sdp_cd_clone=passed\n' | tee "${ARTIFACT_DIR}/summary.txt"
