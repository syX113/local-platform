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

target_env="${1:?target environment is required (dev|prd|current)}"
scope="${2:?source scope is required (orders|customers)}"
case "${target_env}" in
  dev)
    export_dev_runtime_env
    activate_source_scope_runtime "${scope}"
    airflow_dag_id="${AIRFLOW_ACTIVE_DAG_ID}"
    airflow_module_prefix="${AIRFLOW_ACTIVE_MODULE_PREFIX}"
    airflow_dag_filename="${AIRFLOW_ACTIVE_DAG_FILENAME}"
    target_label="dev-${scope}"
    ;;
  prd)
    export_prd_runtime_env
    activate_source_scope_runtime "${scope}"
    airflow_dag_id="${AIRFLOW_ACTIVE_DAG_ID}"
    airflow_module_prefix="${AIRFLOW_ACTIVE_MODULE_PREFIX}"
    airflow_dag_filename="${AIRFLOW_ACTIVE_DAG_FILENAME}"
    target_label="prd-${scope}"
    ;;
  current)
    activate_source_scope_runtime "${scope}"
    airflow_dag_id="${AIRFLOW_ACTIVE_DAG_ID}"
    airflow_module_prefix="${AIRFLOW_ACTIVE_MODULE_PREFIX}"
    airflow_dag_filename="${AIRFLOW_ACTIVE_DAG_FILENAME}"
    target_label="${3:-current-${scope}}"
    ;;
  *)
    echo "unsupported target environment: ${target_env}" >&2
    exit 1
    ;;
esac

ARTIFACT_DIR="${ROOT_DIR}/artifacts/deploy-sdp-${target_label}"
mkdir -p "${ARTIFACT_DIR}"

target_label_upper="$(printf '%s' "${target_label}" | tr '[:lower:]' '[:upper:]')"

python_literal() {
  local value="${1:?value is required}"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf "'%s'" "${value}"
}

module_prefix="${airflow_module_prefix}"
dag_filename="${airflow_dag_filename}"
wrapper_path="/opt/airflow/dags/deployed/${dag_filename}"
support_module="${module_prefix}_platform_support"
impl_module="${module_prefix}_pipeline_impl"
host_deployed_dir="${ROOT_DIR}/airflow/dags/deployed"

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
    "${ROOT_DIR}/airflow/dags/local_platform_pipeline.py"
) > "${impl_file}"

cat > "${wrapper_file}" <<EOF
from pathlib import Path
import sys
from airflow import DAG  # noqa: F401

_THIS_DIR = Path(__file__).resolve().parent
if str(_THIS_DIR) not in sys.path:
    sys.path.insert(0, str(_THIS_DIR))

from ${impl_module} import DEFAULT_TAGS, build_ingest_dag

dag = build_ingest_dag(
    dag_id=$(python_literal "${airflow_dag_id}"),
    description=$(python_literal "$(printf '%s deployment for %s.' "${target_label_upper}" "${airflow_dag_id}")"),
    runtime_overrides={
        "DLT_PIPELINE_NAME": $(python_literal "${DLT_PIPELINE_NAME}"),
        "ICEBERG_CATALOG_NAME": $(python_literal "${ICEBERG_CATALOG_NAME}"),
        "ICEBERG_NAMESPACE": $(python_literal "${ICEBERG_NAMESPACE}"),
        "MINIO_PREFIX": $(python_literal "${MINIO_PREFIX}"),
        "OBJECT_STORE_BUCKET": $(python_literal "${OBJECT_STORE_BUCKET}"),
        "SNOWFLAKE_CONTROL_DATABASE": $(python_literal "${SNOWFLAKE_CONTROL_DATABASE}"),
        "SNOWFLAKE_CONTROL_SCHEMA": $(python_literal "${SNOWFLAKE_CONTROL_SCHEMA}"),
        "SNOWFLAKE_DBT_STAGE": $(python_literal "${SNOWFLAKE_DBT_STAGE}"),
        "DLT_SCRIPT_PATH": $(python_literal "${DLT_SCRIPT_PATH:-/opt/platform/dlt/pipeline_${scope}.py}"),
        "SNOWFLAKE_RAW_SYNC_SCOPE": $(python_literal "${SNOWFLAKE_RAW_SYNC_SCOPE:-}"),
        "SNOWFLAKE_SDP_DBT_SELECT": $(python_literal "${SNOWFLAKE_SDP_DBT_SELECT:-}"),
        "SNOWFLAKE_SDP_DATABASE": $(python_literal "${SNOWFLAKE_SDP_DATABASE}"),
        "SNOWFLAKE_SDP_CUSTOMERS_DATABASE": $(python_literal "${SNOWFLAKE_SDP_CUSTOMERS_DATABASE:-}"),
        "SNOWFLAKE_EDP_DATABASE": $(python_literal "${SNOWFLAKE_EDP_DATABASE}"),
        "SNOWFLAKE_EDP_CUSTOMERS_DATABASE": $(python_literal "${SNOWFLAKE_EDP_CUSTOMERS_DATABASE:-}"),
        "SNOWFLAKE_SDP_DBT_PROJECT": $(python_literal "${SNOWFLAKE_SDP_DBT_PROJECT}"),
        "SNOWFLAKE_EDP_DBT_PROJECT": $(python_literal "${SNOWFLAKE_EDP_DBT_PROJECT}"),
        "SNOWFLAKE_LOCAL_RAW_SYNC": $(python_literal "${SNOWFLAKE_LOCAL_RAW_SYNC:-false}"),
        "SNOW_DBT_TARGET_NAME": $(python_literal "${SNOW_DBT_TARGET_NAME:-dev}"),
    },
    tags=DEFAULT_TAGS + [$(python_literal "${target_label}"), $(python_literal "${scope}"), "deployment"],
)
EOF

mkdir -p "${host_deployed_dir}"
cp "${support_file}" "${host_deployed_dir}/$(basename "${support_file}")"
cp "${impl_file}" "${host_deployed_dir}/$(basename "${impl_file}")"
cp "${wrapper_file}" "${host_deployed_dir}/${dag_filename}"

ensure_shared_airflow_services

if [ -n "$(docker compose ps -q airflow-scheduler || true)" ]; then
  echo "airflow-scheduler container is running; deployed DAG files are available via the bind-mounted ${host_deployed_dir}" >&2
else
  echo "airflow-scheduler container is not running; deployed DAG files were written to ${host_deployed_dir}" >&2
fi

docker compose exec -T airflow-scheduler airflow dags list-import-errors | tee "${ARTIFACT_DIR}/${target_label}_airflow_imports.log"
docker compose exec -T airflow-scheduler airflow dags list --subdir "${wrapper_path}" \
  | tee "${ARTIFACT_DIR}/${target_label}_airflow_dags.log"

grep -q "${airflow_dag_id}" "${ARTIFACT_DIR}/${target_label}_airflow_dags.log" || {
  echo "deployed ${target_label_upper} Airflow DAG ${airflow_dag_id} was not detected" >&2
  exit 1
}

cat > "${ARTIFACT_DIR}/${target_label}_airflow_summary.txt" <<EOF
airflow.${target_label}_dag_id=${airflow_dag_id}
airflow.${target_label}_dag_subdir=${wrapper_path}
airflow.${target_label}_scope=${scope}
snowflake.sdp_dbt_project=${SNOWFLAKE_SDP_DBT_PROJECT}
snowflake.edp_dbt_project=${SNOWFLAKE_EDP_DBT_PROJECT}
snowflake.dbt_target=${SNOW_DBT_TARGET_NAME:-dev}
EOF
