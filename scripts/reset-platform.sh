#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

docker compose down -v --remove-orphans || true

rm -rf artifacts
rm -rf dbt/target
rm -rf dbt/logs
rm -f gitlab-runner/generated/config.toml
rm -f gitlab-runner/generated/bootstrap.env
rm -f gitlab-runner/generated/project.env

echo "local platform stack and transient artifacts removed"
echo "next:"
echo "  1. ./scripts/bootstrap.sh"
echo "  2. wait for GitLab and Airflow to become healthy"
echo "  3. ./scripts/bootstrap-gitlab.sh"
