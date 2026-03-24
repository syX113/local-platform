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
docker tag "${source_dlt_image}" "${DEV_SDP_RUNTIME_IMAGE_PREFIX}/dlt-extractor:dev"
docker tag "${source_dbt_image}" "${DEV_SDP_RUNTIME_IMAGE_PREFIX}/dbt-executor:dev"

export RUNTIME_IMAGE_PREFIX="${DEV_SDP_RUNTIME_IMAGE_PREFIX}"
export DLT_RUNNER_IMAGE="${DEV_SDP_RUNTIME_IMAGE_PREFIX}/dlt-extractor:dev"
export DBT_RUNNER_IMAGE="${DEV_SDP_RUNTIME_IMAGE_PREFIX}/dbt-executor:dev"
export SNOW_DBT_RUNNER_IMAGE="${DBT_RUNNER_IMAGE}"

for scope in orders customers; do
  activate_source_scope_runtime "${scope}"
  bash "${SCRIPT_DIR}/deploy-airflow-dag.sh" dev "${scope}" | tee "${ARTIFACT_DIR}/deploy_airflow_dev_${scope}.log"
  SOURCE_SCOPE="${scope}" bash "${SCRIPT_DIR}/verify-ingestion-promotion.sh" \
    "${1:-2026-03-07}" \
    "${AIRFLOW_ACTIVE_DAG_ID}" \
    "/opt/airflow/dags/deployed/${AIRFLOW_ACTIVE_DAG_FILENAME}" \
    | tee "${ARTIFACT_DIR}/verify_ingestion_dev_${scope}.log"
  SOURCE_SCOPE="${scope}" bash "${SCRIPT_DIR}/verify-sdp-promotion.sh" | tee "${ARTIFACT_DIR}/verify_sdp_dev_${scope}.log"
done

publish_source_loom_manifests

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
sdp_dev_deploy=passed
airflow.dev_orders_dag_id=${DEV_ORDERS_AIRFLOW_DAG_ID}
airflow.dev_customers_dag_id=${DEV_CUSTOMERS_AIRFLOW_DAG_ID}
snowflake.dev_sdp_database=${SNOWFLAKE_SDP_DATABASE}
snowflake.dev_edp_database=${SNOWFLAKE_EDP_DATABASE}
runtime.airflow_image=${shared_runtime_prefix}/airflow:dev
runtime.dlt_image=${DLT_RUNNER_IMAGE}
runtime.snow_dbt_image=${SNOW_DBT_RUNNER_IMAGE}
EOF
