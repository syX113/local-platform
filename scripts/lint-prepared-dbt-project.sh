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

project_slug="${1:?usage: lint-prepared-dbt-project.sh <project-slug> [workspace-name]}"
workspace_name="${2:-${project_slug}}"
workspace_container="/tmp/sqlfluff/${workspace_name}"

if [ -f "${ROOT_DIR}/dbt/projects/${project_slug}/dbt_project.yml" ]; then
  project_dir="$(resolve_container_dbt_project_dir "${project_slug}")"
elif [ -f "${ROOT_DIR}/dbt/dbt_project.yml" ]; then
  project_dir="/opt/platform/dbt"
else
  echo "unable to resolve dbt project root for ${project_slug}" >&2
  exit 1
fi

docker compose run --rm --no-deps \
  -e "OBJECT_STORE_ENDPOINT_URL=${OBJECT_STORE_ENDPOINT_URL}" \
  -e "OBJECT_STORE_ACCESS_KEY_ID=${OBJECT_STORE_ACCESS_KEY_ID}" \
  -e "OBJECT_STORE_SECRET_ACCESS_KEY=${OBJECT_STORE_SECRET_ACCESS_KEY}" \
  -e "OBJECT_STORE_REGION=${OBJECT_STORE_REGION}" \
  -e "OBJECT_STORE_USE_SSL=${OBJECT_STORE_USE_SSL}" \
  -e "MINIO_MANIFEST_BUCKET=${MINIO_MANIFEST_BUCKET:-dbt-manifests}" \
  -e "DBT_LOOM_CONFIG=${workspace_container}/project/dbt_loom.config.yml" \
  -e "LINT_PROJECT_SLUG=${project_slug}" \
  -e "SQLFLUFF_WORKSPACE_DIR=${workspace_container}" \
  dbt-executor bash -lc '
    python /opt/platform/dbt/scripts/prepare_sqlfluff_workspace.py \
      --project-dir "'"${project_dir}"'" \
      --project-slug "$LINT_PROJECT_SLUG" \
      --workspace-dir "$SQLFLUFF_WORKSPACE_DIR" &&
    cd "$SQLFLUFF_WORKSPACE_DIR/project" &&
    sqlfluff lint \
      --config .sqlfluff \
      models
  '
