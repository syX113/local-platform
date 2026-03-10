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
export_dev_runtime_env

ARTIFACT_DIR="${ROOT_DIR}/artifacts/deploy-edp-dev"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

export LOCAL_PLATFORM_SHARED_STACK="true"

source_dbt_image="${DBT_RUNNER_IMAGE:-$(runtime_image_ref dbt-executor)}"

docker image inspect "${source_dbt_image}" >/dev/null 2>&1
docker tag "${source_dbt_image}" "${DEV_EDP_RUNTIME_IMAGE_PREFIX}/dbt-executor:dev"

export RUNTIME_IMAGE_PREFIX="${DEV_EDP_RUNTIME_IMAGE_PREFIX}"
export DBT_RUNNER_IMAGE="${DEV_EDP_RUNTIME_IMAGE_PREFIX}/dbt-executor:dev"
export SNOW_DBT_RUNNER_IMAGE="${DBT_RUNNER_IMAGE}"

bash "${SCRIPT_DIR}/verify-edp-promotion.sh" | tee "${ARTIFACT_DIR}/verify_edp_dev.log"

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
edp_dev_deploy=passed
snowflake.dev_sdp_database=${SNOWFLAKE_SDP_DATABASE}
snowflake.dev_edp_database=${SNOWFLAKE_EDP_DATABASE}
runtime.snow_dbt_image=${SNOW_DBT_RUNNER_IMAGE}
EOF
