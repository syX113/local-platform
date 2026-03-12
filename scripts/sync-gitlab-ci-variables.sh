#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

if [ ! -f "${ROOT_DIR}/gitlab-runner/generated/bootstrap.env" ] || [ ! -f "${ROOT_DIR}/gitlab-runner/generated/projects.env" ]; then
  echo "GitLab bootstrap artifacts are missing; run ./scripts/bootstrap-gitlab.sh first" >&2
  exit 1
fi

load_env_preserving_existing "${ROOT_DIR}/gitlab-runner/generated/bootstrap.env"
load_env_preserving_existing "${ROOT_DIR}/gitlab-runner/generated/projects.env"

if [ -z "${GITLAB_BOOTSTRAP_PAT:-}" ] || { [ -z "${GITLAB_SDP_PROJECT_ID:-}" ] && [ -z "${GITLAB_EDP_PROJECT_ID:-}" ] && [ -z "${GITLAB_EDP_CUSTOMERS_PROJECT_ID:-}" ]; }; then
  echo "GitLab bootstrap token or project ids are missing" >&2
  exit 1
fi

CURL_RETRY_ARGS=(
  --silent
  --show-error
  --location
  --connect-timeout 5
  --max-time 30
  --retry 20
  --retry-delay 5
  --retry-all-errors
)

ci_variable_keys=(
  LOCAL_PLATFORM_PROJECT_NAME
  COMPOSE_PROJECT_NAME
  PLATFORM_DOCKER_NETWORK
  AIRFLOW_PORT
  AIRFLOW_UID
  AIRFLOW_ADMIN_USERNAME
  AIRFLOW_ADMIN_PASSWORD
  AIRFLOW_ADMIN_EMAIL
  AIRFLOW_FERNET_KEY
  AIRFLOW_WEBSERVER_SECRET_KEY
  AIRFLOW_METADATA_DB_USER
  AIRFLOW_METADATA_DB_PASSWORD
  AIRFLOW_METADATA_DB_NAME
  AIRFLOW_METADATA_DB_PORT
  SOURCE_POSTGRES_HOST
  SOURCE_POSTGRES_PORT
  SOURCE_POSTGRES_EXPOSE_PORT
  SOURCE_POSTGRES_DB
  SOURCE_POSTGRES_USER
  SOURCE_POSTGRES_PASSWORD
  SOURCE_POSTGRES_SCHEMA
  DLT_PIPELINE_NAME
  DLT_REFRESH_MODE
  ICEBERG_CATALOG_NAME
  ICEBERG_NAMESPACE
  ICEBERG_CATALOG_TYPE
  ICEBERG_SQL_URI
  MINIO_API_PORT
  MINIO_CONSOLE_PORT
  MINIO_ROOT_USER
  MINIO_ROOT_PASSWORD
  MINIO_REGION
  MINIO_BUCKET
  MINIO_PREFIX
  MINIO_ENDPOINT
  MINIO_PUBLIC_ENDPOINT
  MINIO_USE_SSL
  OBJECT_STORE_TYPE
  OBJECT_STORE_BUCKET
  OBJECT_STORE_ACCESS_KEY_ID
  OBJECT_STORE_SECRET_ACCESS_KEY
  OBJECT_STORE_ENDPOINT_URL
  OBJECT_STORE_REGION
  OBJECT_STORE_USE_SSL
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
  SNOWFLAKE_SDP_ORDERS_DATABASE
  SNOWFLAKE_SDP_CUSTOMERS_DATABASE
  SNOWFLAKE_SDP_IN_SCHEMA
  SNOWFLAKE_SDP_CORE_SCHEMA
  SNOWFLAKE_SDP_ACC_SCHEMA
  SNOWFLAKE_EDP_DATABASE
  SNOWFLAKE_EDP_ORDERS_DATABASE
  SNOWFLAKE_EDP_CUSTOMERS_DATABASE
  SNOWFLAKE_EDP_IN_SCHEMA
  SNOWFLAKE_EDP_CORE_SCHEMA
  SNOWFLAKE_EDP_ACC_SCHEMA
  SNOWFLAKE_CATALOG_INTEGRATION
  SNOWFLAKE_CLONE_SCHEMA
  SNOWFLAKE_LOCAL_RAW_SYNC
  DBT_THREADS
)

sync_project_variables() {
  local project_id="${1:?project id is required}"
  local gitlab_api_url="http://localhost:${GITLAB_HTTP_PORT}/api/v4/projects/${project_id}/variables"

  for key in "${ci_variable_keys[@]}"; do
    if [ -z "${!key+x}" ]; then
      continue
    fi

    value="${!key}"

    status_code="$(
      curl "${CURL_RETRY_ARGS[@]}" -o /dev/null -w "%{http_code}" \
        --header "PRIVATE-TOKEN: ${GITLAB_BOOTSTRAP_PAT}" \
        "${gitlab_api_url}/${key}"
    )"

    if [ "${status_code}" = "200" ]; then
      curl --fail "${CURL_RETRY_ARGS[@]}" \
        --request PUT \
        --header "PRIVATE-TOKEN: ${GITLAB_BOOTSTRAP_PAT}" \
        --data-urlencode "value=${value}" \
        --data-urlencode "masked=false" \
        --data-urlencode "protected=false" \
        --data-urlencode "raw=true" \
        "${gitlab_api_url}/${key}" >/dev/null
    else
      curl --fail "${CURL_RETRY_ARGS[@]}" \
        --request POST \
        --header "PRIVATE-TOKEN: ${GITLAB_BOOTSTRAP_PAT}" \
        --data-urlencode "key=${key}" \
        --data-urlencode "value=${value}" \
        --data-urlencode "masked=false" \
        --data-urlencode "protected=false" \
        --data-urlencode "raw=true" \
        "${gitlab_api_url}" >/dev/null
    fi
  done
}

if [ -n "${GITLAB_SDP_PROJECT_ID:-}" ]; then
  sync_project_variables "${GITLAB_SDP_PROJECT_ID}"
  echo "Synced ${#ci_variable_keys[@]} GitLab CI/CD variables to SDP project ${GITLAB_SDP_PROJECT_ID}"
fi

if [ -n "${GITLAB_EDP_PROJECT_ID:-}" ]; then
  sync_project_variables "${GITLAB_EDP_PROJECT_ID}"
  echo "Synced ${#ci_variable_keys[@]} GitLab CI/CD variables to EDP project ${GITLAB_EDP_PROJECT_ID}"
fi

if [ -n "${GITLAB_EDP_CUSTOMERS_PROJECT_ID:-}" ]; then
  sync_project_variables "${GITLAB_EDP_CUSTOMERS_PROJECT_ID}"
  echo "Synced ${#ci_variable_keys[@]} GitLab CI/CD variables to EDP customers project ${GITLAB_EDP_CUSTOMERS_PROJECT_ID}"
fi
