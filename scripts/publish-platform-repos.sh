#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

SKIP_VARIABLE_SYNC="false"
if [ "${1:-}" = "--skip-variable-sync" ]; then
  SKIP_VARIABLE_SYNC="true"
fi

if [ ! -f "${ROOT_DIR}/gitlab-runner/generated/bootstrap.env" ] || [ ! -f "${ROOT_DIR}/gitlab-runner/generated/projects.env" ]; then
  echo "missing GitLab bootstrap metadata. Run ./scripts/bootstrap-gitlab.sh first." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${ROOT_DIR}/gitlab-runner/generated/bootstrap.env"
# shellcheck disable=SC1091
source "${ROOT_DIR}/gitlab-runner/generated/projects.env"

if [ -z "${GITLAB_BOOTSTRAP_PAT:-}" ] || [ -z "${GITLAB_SDP_PROJECT_PATH:-}" ] || [ -z "${GITLAB_EDP_PROJECT_PATH:-}" ]; then
  echo "bootstrap metadata is incomplete. Re-run ./scripts/bootstrap-gitlab.sh." >&2
  exit 1
fi

ensure_git_repo() {
  local repo_dir="${1:?repo dir is required}"

  if [ ! -d "${repo_dir}/.git" ]; then
    git -C "${repo_dir}" init -b main >/dev/null
  fi

  git -C "${repo_dir}" config user.name "Codex Local"
  git -C "${repo_dir}" config user.email "codex-local@example.com"
}

sync_rendered_repo() {
  local repo_dir="${1:?repo dir is required}"
  local remote_name="${2:?remote name is required}"
  local remote_url="${3:?remote url is required}"
  local commit_message="${4:?commit message is required}"

  ensure_git_repo "${repo_dir}"

  if git -C "${repo_dir}" remote get-url "${remote_name}" >/dev/null 2>&1; then
    git -C "${repo_dir}" remote set-url "${remote_name}" "${remote_url}"
  else
    git -C "${repo_dir}" remote add "${remote_name}" "${remote_url}"
  fi

  git -C "${repo_dir}" checkout -B main >/dev/null
  git -C "${repo_dir}" add -A
  if [ -n "$(git -C "${repo_dir}" status --short)" ]; then
    git -C "${repo_dir}" commit -m "${commit_message}" >/dev/null
  fi

  git -C "${repo_dir}" push --set-upstream "${remote_name}" main
}

python3 "${ROOT_DIR}/scripts/render_gitlab_project_repos.py"

platform_sha="$(git rev-parse --short HEAD 2>/dev/null || echo manual)"
sdp_repo_dir="${ROOT_DIR}/gitlab-projects/generated/${GITLAB_SDP_PROJECT_PATH}"
edp_repo_dir="${ROOT_DIR}/gitlab-projects/generated/${GITLAB_EDP_PROJECT_PATH}"

echo "publishing rendered SDP platform repo"
sync_rendered_repo \
  "${sdp_repo_dir}" \
  local-gitlab-sdp \
  "http://oauth2:${GITLAB_BOOTSTRAP_PAT}@localhost:${GITLAB_HTTP_PORT}/root/${GITLAB_SDP_PROJECT_PATH}.git" \
  "Sync SDP project from local platform ${platform_sha}"

echo "publishing rendered EDP platform repo"
sync_rendered_repo \
  "${edp_repo_dir}" \
  local-gitlab-edp \
  "http://oauth2:${GITLAB_BOOTSTRAP_PAT}@localhost:${GITLAB_HTTP_PORT}/root/${GITLAB_EDP_PROJECT_PATH}.git" \
  "Sync EDP project from local platform ${platform_sha}"

if [ "${SKIP_VARIABLE_SYNC}" != "true" ]; then
  echo "syncing GitLab CI variables"
  "${ROOT_DIR}/scripts/sync-gitlab-ci-variables.sh"
fi

echo "rendered platform repositories published"
echo "source repository remotes were not modified"
