#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

execution_date="${1:-2026-03-07}"
dag_id="${2:-local_platform_ingest}"
dag_subdir="${3:-/opt/airflow/dags/local_platform_pipeline.py}"
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
  SNOWFLAKE_SDP_DATABASE
  SNOWFLAKE_SDP_IN_SCHEMA
  SNOWFLAKE_SDP_CORE_SCHEMA
  SNOWFLAKE_SDP_ACC_SCHEMA
  SNOWFLAKE_EDP_DATABASE
  SNOWFLAKE_EDP_IN_SCHEMA
  SNOWFLAKE_EDP_CORE_SCHEMA
  SNOWFLAKE_EDP_ACC_SCHEMA
  SNOWFLAKE_CATALOG_INTEGRATION
  SNOWFLAKE_CLONE_SCHEMA
  SNOWFLAKE_LOCAL_RAW_SYNC
  DBT_THREADS
  DLT_RUNNER_IMAGE
  DBT_RUNNER_IMAGE
)

if [ "${LOCAL_PLATFORM_SHARED_STACK:-false}" != "true" ]; then
  docker compose up -d airflow-metadata-db source-postgres-db lakehouse-object-store
  docker compose run --rm lakehouse-bucket-init
  docker compose up -d airflow-init
  docker compose up -d airflow-scheduler
fi

exec_env_args=()
for key in "${env_keys[@]}"; do
  if [ -n "${!key:-}" ]; then
    exec_env_args+=(-e "${key}=${!key}")
  fi
done

docker compose exec -T "${exec_env_args[@]}" airflow-scheduler airflow dags list-import-errors
docker compose exec -T "${exec_env_args[@]}" airflow-scheduler \
  airflow dags test \
  --subdir "${dag_subdir}" \
  "${dag_id}" \
  "${execution_date}"
