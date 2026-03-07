#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

if [ -f "${ROOT_DIR}/gitlab-runner/generated/bootstrap.env" ]; then
  load_env_preserving_existing "${ROOT_DIR}/gitlab-runner/generated/bootstrap.env"
fi

if [ -f "${ROOT_DIR}/gitlab-runner/generated/project.env" ]; then
  load_env_preserving_existing "${ROOT_DIR}/gitlab-runner/generated/project.env"
fi

gitlab_http_url="http://localhost:${GITLAB_HTTP_PORT}"
gitlab_project_url="${gitlab_http_url}/root/${GITLAB_PROJECT_PATH}"
gitlab_ssh_clone_url="ssh://git@localhost:${GITLAB_SSH_PORT}/root/${GITLAB_PROJECT_PATH}.git"
airflow_url="http://localhost:${AIRFLOW_PORT}"
minio_console_url="http://localhost:${MINIO_CONSOLE_PORT}"
minio_api_url="http://localhost:${MINIO_API_PORT}"
source_postgres_dsn="postgresql://${SOURCE_POSTGRES_USER}:${SOURCE_POSTGRES_PASSWORD}@localhost:${SOURCE_POSTGRES_EXPOSE_PORT}/${SOURCE_POSTGRES_DB}"
airflow_metadata_dsn="postgresql://${AIRFLOW_METADATA_DB_USER}:${AIRFLOW_METADATA_DB_PASSWORD}@localhost:${AIRFLOW_METADATA_DB_PORT}/${AIRFLOW_METADATA_DB_NAME}"

snowflake_status="configured"
if [ -z "${SNOWFLAKE_ACCOUNT:-}" ] || [ -z "${SNOWFLAKE_USER:-}" ] || [ -z "${SNOWFLAKE_PASSWORD:-}" ]; then
  snowflake_status="missing credentials"
fi
snowflake_server_url="<unset>"
if [ -n "${SNOWFLAKE_ACCOUNT:-}" ]; then
  snowflake_server_url="https://${SNOWFLAKE_ACCOUNT}.snowflakecomputing.com"
fi

open_catalog_status="configured"
if [ -z "${OPEN_CATALOG_URI:-}" ] || [ -z "${OPEN_CATALOG_NAME:-}" ] || [ -z "${OPEN_CATALOG_CLIENT_ID:-}" ] || [ -z "${OPEN_CATALOG_CLIENT_SECRET:-}" ]; then
  open_catalog_status="missing configuration"
fi

printf '\n== Local Platform Access Summary ==\n\n'

printf 'Repository\n'
printf '  Root: %s\n' "${ROOT_DIR}"
printf '  Env file: %s/.env\n' "${ROOT_DIR}"
printf '\n'

printf 'Web URLs\n'
printf '  GitLab UI: %s\n' "${gitlab_http_url}"
printf '  GitLab project: %s\n' "${gitlab_project_url}"
printf '  Airflow UI: %s\n' "${airflow_url}"
printf '  MinIO Console: %s\n' "${minio_console_url}"
printf '  MinIO API: %s\n' "${minio_api_url}"
printf '\n'

printf 'Core Credentials\n'
printf '  GitLab root email: %s\n' "${GITLAB_ROOT_EMAIL}"
printf '  GitLab root password: %s\n' "${GITLAB_ROOT_PASSWORD}"
printf '  Airflow admin username: %s\n' "${AIRFLOW_ADMIN_USERNAME}"
printf '  Airflow admin password: %s\n' "${AIRFLOW_ADMIN_PASSWORD}"
printf '  MinIO access key: %s\n' "${MINIO_ROOT_USER}"
printf '  MinIO secret key: %s\n' "${MINIO_ROOT_PASSWORD}"
printf '  Source Postgres user: %s\n' "${SOURCE_POSTGRES_USER}"
printf '  Source Postgres password: %s\n' "${SOURCE_POSTGRES_PASSWORD}"
printf '  Airflow metadata Postgres user: %s\n' "${AIRFLOW_METADATA_DB_USER}"
printf '  Airflow metadata Postgres password: %s\n' "${AIRFLOW_METADATA_DB_PASSWORD}"
printf '\n'

printf 'Connection URLs And Paths\n'
printf '  Git clone over SSH: %s\n' "${gitlab_ssh_clone_url}"
printf '  Source Postgres DSN: %s\n' "${source_postgres_dsn}"
printf '  Airflow metadata DSN: %s\n' "${airflow_metadata_dsn}"
printf '  MinIO internal endpoint: %s\n' "${MINIO_ENDPOINT}"
printf '  Object store URI: %s\n' "${OBJECT_STORE_BUCKET}"
printf '  Iceberg SQL catalog URI: %s\n' "${ICEBERG_SQL_URI}"
printf '  dlt pipeline script: %s/dlt/pipeline.py\n' "${ROOT_DIR}"
printf '  dbt project dir: %s/dbt\n' "${ROOT_DIR}"
printf '  dbt profiles dir: %s/dbt/profiles\n' "${ROOT_DIR}"
printf '  Snowflake SQL dir: %s/snowflake/sql\n' "${ROOT_DIR}"
printf '  Runner config path: %s/gitlab-runner/generated/config.toml\n' "${ROOT_DIR}"
printf '\n'

printf 'Runtime Services\n'
printf '  dlt runtime service: dlt-extractor\n'
printf '  dbt runtime service: dbt-executor\n'
printf '  Airflow DAG id: local_platform_ingest\n'
printf '  GitLab runner service: gitlab-fargate-runner\n'
printf '\n'

printf 'Storage And Data Targets\n'
printf '  MinIO bucket: %s\n' "${MINIO_BUCKET}"
printf '  MinIO prefix: %s\n' "${MINIO_PREFIX}"
printf '  Iceberg namespace: %s\n' "${ICEBERG_NAMESPACE}"
printf '  Snowflake raw database: %s\n' "${SNOWFLAKE_RAW_DATABASE}"
printf '  Snowflake target database/schema: %s.%s\n' "${SNOWFLAKE_TARGET_DATABASE}" "${SNOWFLAKE_TARGET_SCHEMA}"
printf '  Snowflake warehouse: %s\n' "${SNOWFLAKE_WAREHOUSE}"
printf '  Local Snowflake raw sync: %s\n' "${SNOWFLAKE_LOCAL_RAW_SYNC:-false}"
printf '\n'

printf 'Snowflake And Open Catalog Status\n'
printf '  Snowflake status: %s\n' "${snowflake_status}"
printf '  Snowflake account: %s\n' "${SNOWFLAKE_ACCOUNT:-<unset>}"
printf '  Snowflake server URL: %s\n' "${snowflake_server_url}"
printf '  Snowflake user: %s\n' "${SNOWFLAKE_USER:-<unset>}"
printf '  Snowflake role: %s\n' "${SNOWFLAKE_ROLE}"
printf '  Open Catalog status: %s\n' "${open_catalog_status}"
printf '  Open Catalog URI: %s\n' "${OPEN_CATALOG_URI:-<unset>}"
printf '  Open Catalog name: %s\n' "${OPEN_CATALOG_NAME:-<unset>}"
printf '\n'

if [ -n "${GITLAB_BOOTSTRAP_PAT:-}" ] || [ -n "${GITLAB_PROJECT_ID:-}" ] || [ -n "${GITLAB_RUNNER_TOKEN:-}" ]; then
  printf 'Generated GitLab Bootstrap Details\n'
  printf '  GitLab project id: %s\n' "${GITLAB_PROJECT_ID:-<unset>}"
  printf '  GitLab bootstrap PAT: %s\n' "${GITLAB_BOOTSTRAP_PAT:-<unset>}"
  printf '  GitLab runner token: %s\n' "${GITLAB_RUNNER_TOKEN:-<unset>}"
  printf '  GitLab bootstrap env path: %s/gitlab-runner/generated/bootstrap.env\n' "${ROOT_DIR}"
  printf '  GitLab generated project env path: %s/gitlab-runner/generated/project.env\n' "${ROOT_DIR}"
  printf '\n'
fi

printf 'Useful Commands\n'
printf '  Seed source data: ./scripts/load-source-sample-data.sh\n'
printf '  Run local pipeline: ./scripts/run-local-pipeline.sh\n'
printf '  Bootstrap GitLab runner/project: ./scripts/bootstrap-gitlab.sh\n'
printf '  Sync GitLab CI variables: ./scripts/sync-gitlab-ci-variables.sh\n'
printf '  Show this summary again: ./scripts/print-setup-summary.sh\n'
printf '\n'

printf 'Notes\n'
printf '  Local MinIO mode supports PostgreSQL -> Airflow/dlt -> Iceberg testing.\n'
printf '  Full Snowflake catalog-linked testing requires real S3 plus real Snowflake/Open Catalog credentials.\n'
printf '\n'
