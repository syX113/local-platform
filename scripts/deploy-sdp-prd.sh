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

ARTIFACT_DIR="${ROOT_DIR}/artifacts/deploy-sdp-prd"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"
export LOCAL_PLATFORM_SHARED_STACK="true"

source_dlt_image="${DLT_RUNNER_IMAGE:-$(runtime_image_ref dlt-extractor)}"
source_dbt_image="${DBT_RUNNER_IMAGE:-$(runtime_image_ref dbt-executor)}"

export_prd_runtime_env

export RUNTIME_IMAGE_PREFIX="${PRD_SDP_RUNTIME_IMAGE_PREFIX}"
export DLT_RUNNER_IMAGE="${PRD_SDP_RUNTIME_IMAGE_PREFIX}/dlt-extractor:dev"
export DBT_RUNNER_IMAGE="${PRD_SDP_RUNTIME_IMAGE_PREFIX}/dbt-executor:dev"
export SNOW_DBT_RUNNER_IMAGE="${DBT_RUNNER_IMAGE}"

docker image inspect "${source_dlt_image}" >/dev/null 2>&1
docker image inspect "${source_dbt_image}" >/dev/null 2>&1
docker tag "${source_dlt_image}" "${DLT_RUNNER_IMAGE}"
docker tag "${source_dbt_image}" "${DBT_RUNNER_IMAGE}"

source_scopes=()
while IFS= read -r scope; do
  [ -n "${scope}" ] || continue
  source_scopes+=("${scope}")
done < <(project_registry_product_scopes proj_source_finnova)

for scope in "${source_scopes[@]}"; do
  [ -n "${scope}" ] || continue
  echo "deploying SDP source scope: ${scope}"
  activate_source_scope_runtime "${scope}"
  bash "${SCRIPT_DIR}/deploy-airflow-dag.sh" prd "${scope}" | tee "${ARTIFACT_DIR}/deploy_airflow_prd_${scope}.log"
  airflow_prd_subdir="/opt/airflow/dags/deployed/${AIRFLOW_ACTIVE_DAG_FILENAME}"
  SOURCE_SCOPE="${scope}" bash "${SCRIPT_DIR}/verify-ingestion-promotion.sh" \
    "${1:-2026-03-07}" \
    "${AIRFLOW_ACTIVE_DAG_ID}" \
    "${airflow_prd_subdir}" | tee "${ARTIFACT_DIR}/verify_ingestion_prd_${scope}.log"
  SOURCE_SCOPE="${scope}" bash "${SCRIPT_DIR}/verify-sdp-promotion.sh" | tee "${ARTIFACT_DIR}/verify_sdp_prd_${scope}.log"
done

publish_source_loom_manifests

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
sdp_prd_deploy=passed
airflow.prd_orders_dag_id=${PRD_ORDERS_AIRFLOW_DAG_ID}
airflow.prd_customers_dag_id=${PRD_CUSTOMERS_AIRFLOW_DAG_ID}
snowflake.prd_sdp_database=${SNOWFLAKE_SDP_DATABASE}
snowflake.prd_edp_database=${SNOWFLAKE_EDP_DATABASE}
iceberg.prd_namespace=${ICEBERG_NAMESPACE}
object_store.prd_bucket=${OBJECT_STORE_BUCKET}
runtime.dlt_image=${DLT_RUNNER_IMAGE}
runtime.snow_dbt_image=${SNOW_DBT_RUNNER_IMAGE}
EOF
