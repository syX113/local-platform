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
export_prd_runtime_env

ARTIFACT_DIR="${ROOT_DIR}/artifacts/edp-prd-cd"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

source_sdp_database="${SNOWFLAKE_SDP_DATABASE}"
source_edp_database="${SNOWFLAKE_EDP_DATABASE}"
clone_owner_token="EDP_PRD"
clone_branch_token="prd_${CI_PIPELINE_ID:-local}_${CI_COMMIT_SHORT_SHA:-head}"

export SNOWFLAKE_SDP_DATABASE_BASE="${source_sdp_database}"
export SNOWFLAKE_EDP_DATABASE_BASE="${source_edp_database}"
export SNOWFLAKE_CLONE_OWNER_TOKEN="${clone_owner_token}"
export SNOWFLAKE_CLONE_BRANCH_TOKEN="${clone_branch_token}"
export SNOWFLAKE_SDP_DATABASE="$(build_clone_database_name "${source_sdp_database}" "${clone_owner_token}" "${clone_branch_token}" 120)"
export SNOWFLAKE_EDP_DATABASE="$(build_clone_database_name "${source_edp_database}" "${clone_owner_token}" "${clone_branch_token}" 120)"

cleanup() {
  "${SCRIPT_DIR}/cleanup-ci-sandbox.sh" || true
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
  python /opt/platform/dbt/scripts/manage_ci_clones.py replace | tee "${ARTIFACT_DIR}/prd_clone_create.log"

bash "${SCRIPT_DIR}/verify-edp-promotion.sh" | tee "${ARTIFACT_DIR}/edp.log"

printf 'edp_prd_clone=passed\n' | tee "${ARTIFACT_DIR}/summary.txt"
