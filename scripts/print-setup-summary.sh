#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

if [ -f "${ROOT_DIR}/gitlab-runner/generated/bootstrap.env" ]; then
  load_env_preserving_existing "${ROOT_DIR}/gitlab-runner/generated/bootstrap.env"
fi

if [ -f "${ROOT_DIR}/gitlab-runner/generated/projects.env" ]; then
  load_env_preserving_existing "${ROOT_DIR}/gitlab-runner/generated/projects.env"
fi

gitlab_http_url="http://localhost:${GITLAB_HTTP_PORT}"
sdp_gitlab_project_url="${gitlab_http_url}/root/${GITLAB_SDP_PROJECT_PATH}"
sdp_gitlab_ssh_clone_url="ssh://git@localhost:${GITLAB_SSH_PORT}/root/${GITLAB_SDP_PROJECT_PATH}.git"
edp_gitlab_project_url="${gitlab_http_url}/root/${GITLAB_EDP_PROJECT_PATH}"
edp_gitlab_ssh_clone_url="ssh://git@localhost:${GITLAB_SSH_PORT}/root/${GITLAB_EDP_PROJECT_PATH}.git"
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
printf '  GitLab SDP project: %s\n' "${sdp_gitlab_project_url}"
printf '  GitLab EDP project: %s\n' "${edp_gitlab_project_url}"
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
printf '  SDP git clone over SSH: %s\n' "${sdp_gitlab_ssh_clone_url}"
printf '  EDP git clone over SSH: %s\n' "${edp_gitlab_ssh_clone_url}"
printf '  Source Postgres DSN: %s\n' "${source_postgres_dsn}"
printf '  Airflow metadata DSN: %s\n' "${airflow_metadata_dsn}"
printf '  MinIO internal endpoint: %s\n' "${MINIO_ENDPOINT}"
printf '  Object store URI: %s\n' "${OBJECT_STORE_BUCKET}"
printf '  Iceberg SQL catalog URI: %s\n' "${ICEBERG_SQL_URI}"
printf '  dlt pipeline script: %s/dlt/pipeline.py\n' "${ROOT_DIR}"
printf '  SDP dbt project dir: %s/dbt/projects/proj_sdp_orders\n' "${ROOT_DIR}"
printf '  EDP dbt project dir: %s/dbt/projects/proj_edp_orders\n' "${ROOT_DIR}"
printf '  dbt profiles dir: %s/dbt/profiles\n' "${ROOT_DIR}"
printf '  Snowflake SQL dir: %s/snowflake/sql\n' "${ROOT_DIR}"
printf '  Runner config path: %s/gitlab-runner/generated/config.toml\n' "${ROOT_DIR}"
printf '  Branch sandbox state dir: %s/gitlab-branch-provisioner/state\n' "${ROOT_DIR}"
printf '  Branch webhook endpoint: http://%s:%s/gitlab/webhook\n' "${GITLAB_BRANCH_PROVISIONER_WEBHOOK_HOST:-gitlab-branch-provisioner.local}" "${GITLAB_BRANCH_PROVISIONER_PORT:-8090}"
printf '  SDP rendered platform repo: %s/gitlab-projects/generated/%s\n' "${ROOT_DIR}" "${GITLAB_SDP_PROJECT_PATH}"
printf '  EDP rendered platform repo: %s/gitlab-projects/generated/%s\n' "${ROOT_DIR}" "${GITLAB_EDP_PROJECT_PATH}"
printf '\n'

printf 'Runtime Services\n'
printf '  dlt runtime service: dlt-extractor\n'
printf '  dbt runtime service: dbt-executor\n'
printf '  Airflow DAG id: local_platform_ingest\n'
printf '  GitLab runner service: gitlab-fargate-runner\n'
printf '  GitLab branch provisioner service: gitlab-branch-provisioner\n'
printf '\n'

printf 'Storage And Data Targets\n'
printf '  MinIO bucket: %s\n' "${MINIO_BUCKET}"
printf '  MinIO prefix: %s\n' "${MINIO_PREFIX}"
printf '  Iceberg namespace: %s\n' "${ICEBERG_NAMESPACE}"
printf '  Snowflake SDP database: %s\n' "${SNOWFLAKE_SDP_DATABASE}"
printf '  Snowflake SDP schemas: %s, %s, %s\n' "${SNOWFLAKE_SDP_IN_SCHEMA}" "${SNOWFLAKE_SDP_CORE_SCHEMA}" "${SNOWFLAKE_SDP_ACC_SCHEMA}"
printf '  Snowflake EDP database: %s\n' "${SNOWFLAKE_EDP_DATABASE}"
printf '  Snowflake EDP schemas: %s, %s, %s\n' "${SNOWFLAKE_EDP_IN_SCHEMA}" "${SNOWFLAKE_EDP_CORE_SCHEMA}" "${SNOWFLAKE_EDP_ACC_SCHEMA}"
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

if [ -n "${GITLAB_BOOTSTRAP_PAT:-}" ] || [ -n "${GITLAB_SDP_PROJECT_ID:-}" ] || [ -n "${GITLAB_EDP_PROJECT_ID:-}" ]; then
  printf 'Generated GitLab Bootstrap Details\n'
  printf '  GitLab SDP project id: %s\n' "${GITLAB_SDP_PROJECT_ID:-<unset>}"
  printf '  GitLab EDP project id: %s\n' "${GITLAB_EDP_PROJECT_ID:-<unset>}"
  printf '  GitLab bootstrap PAT: %s\n' "${GITLAB_BOOTSTRAP_PAT:-<unset>}"
  printf '  GitLab SDP runner token: %s\n' "${GITLAB_SDP_RUNNER_TOKEN:-<unset>}"
  printf '  GitLab EDP runner token: %s\n' "${GITLAB_EDP_RUNNER_TOKEN:-<unset>}"
  printf '  GitLab bootstrap env path: %s/gitlab-runner/generated/bootstrap.env\n' "${ROOT_DIR}"
  printf '  GitLab generated project env path: %s/gitlab-runner/generated/projects.env\n' "${ROOT_DIR}"
  printf '\n'
fi

printf 'Useful Commands\n'
printf '  Reset local platform: ./scripts/reset-platform.sh\n'
printf '  Seed source data: ./scripts/load-source-sample-data.sh\n'
printf '  Run local pipeline: ./scripts/run-local-pipeline.sh\n'
printf '  Bootstrap local platform: ./scripts/bootstrap.sh\n'
printf '  Bootstrap GitLab runner/project: ./scripts/bootstrap-gitlab.sh\n'
printf '  Publish rendered platform repos: ./scripts/publish-platform-repos.sh\n'
printf '  Sync GitLab CI variables: ./scripts/sync-gitlab-ci-variables.sh\n'
printf '  Watch branch sandbox provisioning: docker compose logs -f gitlab-branch-provisioner\n'
printf '  Show this summary again: ./scripts/print-setup-summary.sh\n'
printf '\n'

printf 'Notes\n'
printf '  Local MinIO mode supports PostgreSQL -> Airflow/dlt -> Iceberg testing.\n'
printf '  Full Snowflake catalog-linked testing requires real S3 plus real Snowflake/Open Catalog credentials.\n'
printf '\n'
