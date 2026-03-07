#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

mkdir -p gitlab-runner/generated

docker compose build airflow-webserver dlt-extractor dbt-executor
docker compose up -d airflow-metadata-db source-postgres-db lakehouse-object-store gitlab-platform
docker compose up -d lakehouse-bucket-init airflow-init
./scripts/load-source-sample-data.sh
docker compose up -d airflow-webserver airflow-scheduler

echo "stack is starting"
echo "next:"
echo "  1. wait for GitLab on http://localhost:${GITLAB_HTTP_PORT:-8080}"
echo "  2. run ./scripts/bootstrap-gitlab.sh to create the SDP and EDP GitLab projects and start the GitLab runner"
./scripts/print-setup-summary.sh
