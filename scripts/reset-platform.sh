#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

if [ -f "${ROOT_DIR}/scripts/cleanup-snowflake-ci-clones.sh" ]; then
  bash "${ROOT_DIR}/scripts/cleanup-snowflake-ci-clones.sh" || true
fi

docker compose down -v --remove-orphans || true

rm -rf artifacts
rm -rf dbt/target
rm -rf dbt/logs
rm -f dbt/profiles/.user.yml
rm -rf dlt/.dlt
rm -rf gitlab-projects/generated
rm -f gitlab-runner/generated/config.toml
rm -f gitlab-runner/generated/bootstrap.env
rm -f gitlab-runner/generated/project.env
rm -f gitlab-runner/generated/projects.env
rm -rf gitlab-branch-provisioner/state
find "${ROOT_DIR}" -type d \( -name __pycache__ -o -name logs -o -name target \) \
  ! -path "${ROOT_DIR}/.git/*" \
  ! -path "${ROOT_DIR}/gitlab-runner/generated/*" \
  ! -path "${ROOT_DIR}/gitlab-projects/generated/*" \
  -prune -exec rm -rf {} +

echo "local platform stack and transient artifacts removed"
echo "next:"
echo "  1. ./scripts/bootstrap.sh"
echo "  2. wait for GitLab and Airflow to become healthy"
echo "  3. ./scripts/bootstrap-gitlab.sh"
