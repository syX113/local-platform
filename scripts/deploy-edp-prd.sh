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

ARTIFACT_DIR="${ROOT_DIR}/artifacts/deploy-edp-prd"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

source_dbt_image="${DBT_RUNNER_IMAGE:-$(runtime_image_ref dbt-executor)}"

export_prd_runtime_env

database_env_name="$(project_registry_lookup "${project_slug}" default_database_env)"
export SNOWFLAKE_EDP_DATABASE="${!database_env_name:-${SNOWFLAKE_EDP_DATABASE}}"
export SNOWFLAKE_EDP_DBT_PROJECT="$(project_registry_project_name_for_target "${project_slug}" prd)"

export RUNTIME_IMAGE_PREFIX="${PRD_EDP_RUNTIME_IMAGE_PREFIX}"
export DBT_RUNNER_IMAGE="${PRD_EDP_RUNTIME_IMAGE_PREFIX}/dbt-executor:dev"
export SNOW_DBT_RUNNER_IMAGE="${DBT_RUNNER_IMAGE}"

docker image inspect "${source_dbt_image}" >/dev/null 2>&1
docker tag "${source_dbt_image}" "${DBT_RUNNER_IMAGE}"

bash "${SCRIPT_DIR}/verify-edp-promotion.sh" "${project_slug}" | tee "${ARTIFACT_DIR}/verify_edp_prd.log"

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
edp_prd_deploy=passed
snowflake.prd_sdp_database=${SNOWFLAKE_SDP_DATABASE}
snowflake.prd_edp_database=${SNOWFLAKE_EDP_DATABASE}
runtime.snow_dbt_image=${SNOW_DBT_RUNNER_IMAGE}
EOF
