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

ARTIFACT_DIR="${ROOT_DIR}/artifacts/deploy-sdp-dev"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

export LOCAL_PLATFORM_SHARED_STACK="true"

shared_runtime_prefix="${LOCAL_PLATFORM_PROJECT_NAME:-local-platform}"
source_airflow_image="${RUNTIME_IMAGE_PREFIX:-${shared_runtime_prefix}}/airflow:dev"
source_dlt_image="${DLT_RUNNER_IMAGE:-$(runtime_image_ref dlt-extractor)}"
source_dbt_image="${DBT_RUNNER_IMAGE:-$(runtime_image_ref dbt-executor)}"

docker image inspect "${source_airflow_image}" >/dev/null 2>&1
docker image inspect "${source_dlt_image}" >/dev/null 2>&1
docker image inspect "${source_dbt_image}" >/dev/null 2>&1

docker tag "${source_airflow_image}" "${shared_runtime_prefix}/airflow:dev"
docker tag "${source_dlt_image}" "${shared_runtime_prefix}/dlt-extractor:dev"
docker tag "${source_dbt_image}" "${shared_runtime_prefix}/dbt-executor:dev"

export RUNTIME_IMAGE_PREFIX="${shared_runtime_prefix}"
export DLT_RUNNER_IMAGE="${shared_runtime_prefix}/dlt-extractor:dev"
export DBT_RUNNER_IMAGE="${shared_runtime_prefix}/dbt-executor:dev"

# Recreate the shared Airflow services from the base compose file so CI overrides
# never strip the host port binding from the operator-facing web UI.
COMPOSE_FILE=compose.yaml docker compose up -d --no-build --no-deps airflow-webserver airflow-scheduler >/dev/null

bash "${SCRIPT_DIR}/verify-ingestion-promotion.sh" "${1:-2026-03-07}" \
  | tee "${ARTIFACT_DIR}/verify_ingestion_dev.log"

bash "${SCRIPT_DIR}/verify-sdp-promotion.sh" | tee "${ARTIFACT_DIR}/verify_sdp_dev.log"

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
sdp_dev_deploy=passed
airflow.dev_dag_id=local_platform_ingest
snowflake.dev_sdp_database=${SNOWFLAKE_SDP_DATABASE}
snowflake.dev_edp_database=${SNOWFLAKE_EDP_DATABASE}
runtime.airflow_image=${shared_runtime_prefix}/airflow:dev
runtime.dlt_image=${DLT_RUNNER_IMAGE}
runtime.dbt_image=${DBT_RUNNER_IMAGE}
EOF
