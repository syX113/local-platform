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

export SNOWFLAKE_EDP_DATABASE="${DEV_SNOWFLAKE_EDP_CUSTOMERS_DATABASE:-${SNOWFLAKE_EDP_CUSTOMERS_DATABASE}}"
export SNOWFLAKE_EDP_DBT_PROJECT="${DEV_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT:-${SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT}}"

ARTIFACT_DIR="${ROOT_DIR}/artifacts/deploy-edp-customers-dev"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

export LOCAL_PLATFORM_SHARED_STACK="true"

source_dbt_image="${DBT_RUNNER_IMAGE:-$(runtime_image_ref dbt-executor)}"

docker image inspect "${source_dbt_image}" >/dev/null 2>&1
docker tag "${source_dbt_image}" "${DEV_EDP_RUNTIME_IMAGE_PREFIX}/dbt-executor:dev"

export RUNTIME_IMAGE_PREFIX="${DEV_EDP_RUNTIME_IMAGE_PREFIX}"
export DBT_RUNNER_IMAGE="${DEV_EDP_RUNTIME_IMAGE_PREFIX}/dbt-executor:dev"
export SNOW_DBT_RUNNER_IMAGE="${DBT_RUNNER_IMAGE}"

bash "${SCRIPT_DIR}/verify-edp-customers-promotion.sh" | tee "${ARTIFACT_DIR}/verify_edp_customers_dev.log"

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
edp_customers_dev_deploy=passed
snowflake.dev_sdp_customers_database=${SNOWFLAKE_SDP_CUSTOMERS_DATABASE}
snowflake.dev_edp_customers_database=${SNOWFLAKE_EDP_DATABASE}
runtime.snow_dbt_image=${SNOW_DBT_RUNNER_IMAGE}
EOF
