#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

mkdir -p gitlab-runner/generated

docker build -t "${GITLAB_RUNNER_JOB_IMAGE:-local-platform/gitlab-ci-tools:dev}" gitlab-ci
compose_build_services airflow-webserver dlt-extractor dbt-executor
docker compose up -d airflow-metadata-db source-postgres-db lakehouse-object-store gitlab-platform
docker compose up -d lakehouse-bucket-init airflow-init
docker compose up -d airflow-webserver airflow-scheduler

source_scopes=()
while IFS= read -r scope; do
  [ -n "${scope}" ] || continue
  source_scopes+=("${scope}")
done < <(project_registry_product_scopes proj_source_finnova)

for scope in "${source_scopes[@]}"; do
  [ -n "${scope}" ] || continue
  ./scripts/deploy-airflow-dag.sh dev "${scope}"
done

for scope in "${source_scopes[@]}"; do
  [ -n "${scope}" ] || continue
  ./scripts/deploy-airflow-dag.sh prd "${scope}"
done

echo "bootstrapping Snowflake foundation and data products"
./scripts/bootstrap-snowflake-products.sh

echo "full bootstrap complete"
echo "next:"
echo "  1. wait for GitLab on http://localhost:${GITLAB_HTTP_PORT:-8080}"
echo "  2. run ./scripts/bootstrap-gitlab.sh to create the source and EDP GitLab projects and start the GitLab runner"
./scripts/print-setup-summary.sh
