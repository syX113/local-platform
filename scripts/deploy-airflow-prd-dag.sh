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

ARTIFACT_DIR="${ROOT_DIR}/artifacts/deploy-sdp-prd"
mkdir -p "${ARTIFACT_DIR}"

python_literal() {
  local value="${1:?value is required}"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf "'%s'" "${value}"
}

module_prefix="${PRD_AIRFLOW_MODULE_PREFIX}"
dag_filename="${PRD_AIRFLOW_DAG_FILENAME}"
wrapper_path="/opt/airflow/dags/deployed/${dag_filename}"
support_module="${module_prefix}_platform_support"
impl_module="${module_prefix}_pipeline_impl"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

support_file="${tmp_dir}/${support_module}.py"
impl_file="${tmp_dir}/${impl_module}.py"
wrapper_file="${tmp_dir}/${dag_filename}"

cp "${ROOT_DIR}/airflow/dags/platform_support.py" "${support_file}"
{
  IFS= read -r first_line || true
  if [[ "${first_line}" == "from __future__ import annotations" ]]; then
    printf '%s\n\n' "${first_line}"
  else
    printf '%s\n' "${first_line}"
  fi
  cat <<'EOF'
from pathlib import Path
import sys

_THIS_DIR = Path(__file__).resolve().parent
if str(_THIS_DIR) not in sys.path:
    sys.path.insert(0, str(_THIS_DIR))

EOF
  cat
} < <(
  sed -e "s/from platform_support import /from ${support_module} import /" \
      -e "/^dag = build_ingest_dag()$/d" \
    "${ROOT_DIR}/airflow/dags/local_platform_pipeline.py"
) > "${impl_file}"

cat > "${wrapper_file}" <<EOF
from pathlib import Path
import sys

from airflow import DAG

_THIS_DIR = Path(__file__).resolve().parent
if str(_THIS_DIR) not in sys.path:
    sys.path.insert(0, str(_THIS_DIR))

from ${impl_module} import DEFAULT_TAGS, build_ingest_dag

dag = build_ingest_dag(
    dag_id=$(python_literal "${PRD_AIRFLOW_DAG_ID}"),
    description=$(python_literal "Production deployment for ${PRD_AIRFLOW_DAG_ID}."),
    runtime_overrides={
        "DLT_PIPELINE_NAME": $(python_literal "${DLT_PIPELINE_NAME}"),
        "ICEBERG_NAMESPACE": $(python_literal "${ICEBERG_NAMESPACE}"),
        "MINIO_PREFIX": $(python_literal "${MINIO_PREFIX}"),
        "OBJECT_STORE_BUCKET": $(python_literal "${OBJECT_STORE_BUCKET}"),
        "SNOWFLAKE_SDP_DATABASE": $(python_literal "${SNOWFLAKE_SDP_DATABASE}"),
        "SNOWFLAKE_EDP_DATABASE": $(python_literal "${SNOWFLAKE_EDP_DATABASE}"),
        "DLT_RUNNER_IMAGE": $(python_literal "${DLT_RUNNER_IMAGE}"),
        "DBT_RUNNER_IMAGE": $(python_literal "${DBT_RUNNER_IMAGE}"),
    },
    tags=DEFAULT_TAGS + ["prd", "deployment"],
)
EOF

scheduler_container_id="$(docker compose ps -q airflow-scheduler)"
if [ -z "${scheduler_container_id}" ]; then
  echo "unable to resolve airflow-scheduler container id" >&2
  exit 1
fi

docker compose exec -T airflow-scheduler mkdir -p /opt/airflow/dags/deployed
docker cp "${support_file}" "${scheduler_container_id}:/opt/airflow/dags/deployed/$(basename "${support_file}")"
docker cp "${impl_file}" "${scheduler_container_id}:/opt/airflow/dags/deployed/$(basename "${impl_file}")"
docker cp "${wrapper_file}" "${scheduler_container_id}:${wrapper_path}"

docker compose exec -T airflow-scheduler airflow dags list-import-errors | tee "${ARTIFACT_DIR}/prd_airflow_imports.log"
docker compose exec -T airflow-scheduler airflow dags list --subdir "${wrapper_path}" \
  | tee "${ARTIFACT_DIR}/prd_airflow_dags.log"

grep -q "${PRD_AIRFLOW_DAG_ID}" "${ARTIFACT_DIR}/prd_airflow_dags.log" || {
  echo "deployed PRD Airflow DAG ${PRD_AIRFLOW_DAG_ID} was not detected" >&2
  exit 1
}

cat > "${ARTIFACT_DIR}/prd_airflow_summary.txt" <<EOF
airflow.prd_dag_id=${PRD_AIRFLOW_DAG_ID}
airflow.prd_dag_subdir=${wrapper_path}
runtime.dlt_image=${DLT_RUNNER_IMAGE}
runtime.dbt_image=${DBT_RUNNER_IMAGE}
EOF
