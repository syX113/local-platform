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

execution_date="${1:-2026-03-07}"
source_scope="${SOURCE_SCOPE:-orders}"

resolve_sandbox_dag_id() {
  local scope="${1:?source scope is required}"

  case "${scope}" in
    orders)
      printf '%s' "${AIRFLOW_SANDBOX_ORDERS_DAG_ID:-${AIRFLOW_SANDBOX_DAG_ID:-${DEV_ORDERS_AIRFLOW_DAG_ID:-DEV_local_platform_orders_ingest}}}"
      ;;
    customers)
      printf '%s' "${AIRFLOW_SANDBOX_CUSTOMERS_DAG_ID:-${AIRFLOW_SANDBOX_DAG_ID:-${DEV_CUSTOMERS_AIRFLOW_DAG_ID:-DEV_local_platform_customers_ingest}}}"
      ;;
    *)
      echo "unsupported source scope for DAG resolution: ${scope}" >&2
      exit 1
      ;;
  esac
}

if [ -n "${2:-}" ]; then
  dag_id="${2}"
elif [ -n "${AIRFLOW_SANDBOX_ORDERS_DAG_ID:-}" ] || [ -n "${AIRFLOW_SANDBOX_CUSTOMERS_DAG_ID:-}" ] || [ -n "${AIRFLOW_SANDBOX_DAG_ID:-}" ]; then
  dag_id="$(resolve_sandbox_dag_id "${source_scope}")"
else
  case "${source_scope}" in
    orders)
      dag_id="${DEV_ORDERS_AIRFLOW_DAG_ID:-DEV_local_platform_orders_ingest}"
      ;;
    customers)
      dag_id="${DEV_CUSTOMERS_AIRFLOW_DAG_ID:-DEV_local_platform_customers_ingest}"
      ;;
    *)
      echo "unsupported source scope for DAG test: ${source_scope}" >&2
      exit 1
      ;;
  esac
fi

if [ -n "${3:-}" ]; then
  dag_subdir="${3}"
elif [ -n "${AIRFLOW_SANDBOX_ORDERS_DAG_ID:-}" ] || [ -n "${AIRFLOW_SANDBOX_CUSTOMERS_DAG_ID:-}" ] || [ -n "${AIRFLOW_SANDBOX_DAG_ID:-}" ]; then
  dag_subdir="/opt/airflow/dags/deployed/$(sanitize_branch_token "$(resolve_sandbox_dag_id "${source_scope}")").py"
else
  case "${source_scope}" in
    orders)
      dag_subdir="/opt/airflow/dags/deployed/dev_local_platform_orders_ingest.py"
      ;;
    customers)
      dag_subdir="/opt/airflow/dags/deployed/dev_local_platform_customers_ingest.py"
      ;;
    *)
      echo "unsupported source scope for DAG subdir: ${source_scope}" >&2
      exit 1
      ;;
  esac
fi
env_keys=(
  PLATFORM_DOCKER_NETWORK
  MINIO_ROOT_USER
  MINIO_ROOT_PASSWORD
  MINIO_BUCKET
  MINIO_PREFIX
  MINIO_ENDPOINT
  MINIO_PUBLIC_ENDPOINT
  MINIO_USE_SSL
  MINIO_REGION
  OBJECT_STORE_TYPE
  OBJECT_STORE_BUCKET
  OBJECT_STORE_ACCESS_KEY_ID
  OBJECT_STORE_SECRET_ACCESS_KEY
  OBJECT_STORE_ENDPOINT_URL
  OBJECT_STORE_REGION
  OBJECT_STORE_USE_SSL
  DLT_PIPELINE_NAME
  DLT_REFRESH_MODE
  ICEBERG_CATALOG_NAME
  ICEBERG_NAMESPACE
  ICEBERG_CATALOG_TYPE
  ICEBERG_SQL_URI
  SOURCE_POSTGRES_HOST
  SOURCE_POSTGRES_PORT
  SOURCE_POSTGRES_DB
  SOURCE_POSTGRES_USER
  SOURCE_POSTGRES_PASSWORD
  SOURCE_POSTGRES_SCHEMA
  OPEN_CATALOG_URI
  OPEN_CATALOG_NAME
  OPEN_CATALOG_CLIENT_ID
  OPEN_CATALOG_CLIENT_SECRET
  OPEN_CATALOG_SCOPE
  OPEN_CATALOG_ACCESS_DELEGATION
  SNOWFLAKE_ACCOUNT
  SNOWFLAKE_USER
  SNOWFLAKE_PASSWORD
  SNOWFLAKE_ROLE
  SNOWFLAKE_WAREHOUSE
  SNOWFLAKE_CONTROL_DATABASE
  SNOWFLAKE_CONTROL_SCHEMA
  SNOWFLAKE_DBT_STAGE
  SNOWFLAKE_SDP_DATABASE
  SNOWFLAKE_SDP_IN_SCHEMA
  SNOWFLAKE_SDP_CORE_SCHEMA
  SNOWFLAKE_SDP_ACC_SCHEMA
  SNOWFLAKE_SDP_DBT_PROJECT
  SNOWFLAKE_EDP_DATABASE
  SNOWFLAKE_EDP_IN_SCHEMA
  SNOWFLAKE_EDP_CORE_SCHEMA
  SNOWFLAKE_EDP_ACC_SCHEMA
  SNOWFLAKE_EDP_DBT_PROJECT
  SNOWFLAKE_CATALOG_INTEGRATION
  SNOWFLAKE_CLONE_SCHEMA
  SNOWFLAKE_LOCAL_RAW_SYNC
  SNOW_DBT_TARGET_NAME
  DBT_THREADS
  DLT_RUNNER_IMAGE
  DBT_RUNNER_IMAGE
  SNOW_DBT_RUNNER_IMAGE
)

if [ "${LOCAL_PLATFORM_SHARED_STACK:-false}" != "true" ]; then
  docker compose up -d airflow-metadata-db source-postgres-db lakehouse-object-store
  docker compose run --rm lakehouse-bucket-init
  docker compose up -d airflow-init
  docker compose up -d airflow-scheduler
else
  ensure_shared_airflow_services
fi

exec_env_args=()
for key in "${env_keys[@]}"; do
  if [ -n "${!key:-}" ]; then
    exec_env_args+=(-e "${key}=${!key}")
  fi
done

if [ "${LOCAL_PLATFORM_SHARED_STACK:-false}" = "true" ]; then
  airflow_cli=(docker compose exec -T "${exec_env_args[@]}" airflow-scheduler)
else
  airflow_cli=(docker compose run --rm --no-deps "${exec_env_args[@]}" airflow-scheduler)
fi

"${airflow_cli[@]}" airflow dags list-import-errors

"${airflow_cli[@]}" \
  python - "${dag_subdir}" "${dag_id}" "${execution_date}" <<'PY'
import importlib.util
import sys
from pathlib import Path

import pendulum
from airflow.models.dag import DAG
import airflow.providers.fab.auth_manager.models  # noqa: F401

dag_subdir = Path(sys.argv[1])
dag_id = sys.argv[2]
execution_date = pendulum.parse(sys.argv[3])

module_dir = str(dag_subdir.parent)
if module_dir not in sys.path:
    sys.path.insert(0, module_dir)

spec = importlib.util.spec_from_file_location("local_platform_dynamic_dag", dag_subdir)
if spec is None or spec.loader is None:
    raise SystemExit(f"unable to load DAG module from {dag_subdir}")

module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

dag = getattr(module, "dag", None)
if not isinstance(dag, DAG):
    matching_dags = [
        value for value in module.__dict__.values()
        if isinstance(value, DAG) and value.dag_id == dag_id
    ]
    dag = matching_dags[0] if matching_dags else None

if not isinstance(dag, DAG):
    raise SystemExit(f"dag {dag_id} not found in {dag_subdir}")

if dag.dag_id != dag_id:
    raise SystemExit(f"loaded dag id {dag.dag_id} does not match expected {dag_id}")

dag.test(execution_date=execution_date)
PY
