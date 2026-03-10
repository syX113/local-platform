#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

SKIP_VARIABLE_SYNC="false"
INIT_SDP_HISTORY="false"
INIT_EDP_HISTORY="false"

while [ $# -gt 0 ]; do
  case "${1}" in
    --skip-variable-sync)
      SKIP_VARIABLE_SYNC="true"
      ;;
    --init-history)
      INIT_SDP_HISTORY="true"
      INIT_EDP_HISTORY="true"
      ;;
    --init-sdp-history)
      INIT_SDP_HISTORY="true"
      ;;
    --init-edp-history)
      INIT_EDP_HISTORY="true"
      ;;
    *)
      echo "unsupported argument: ${1}" >&2
      exit 1
      ;;
  esac
  shift
done

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

gitlab_api_request() {
  local method="${1:?method is required}"
  local path="${2:?path is required}"
  shift 2

  curl --silent --show-error --location \
    --request "${method}" \
    --header "PRIVATE-TOKEN: ${GITLAB_BOOTSTRAP_PAT}" \
    "$@" \
    "http://localhost:${GITLAB_HTTP_PORT}/api/v4${path}"
}

unprotect_main_branch() {
  local project_id="${1:?project id is required}"
  curl --silent --show-error --location \
    --request DELETE \
    --header "PRIVATE-TOKEN: ${GITLAB_BOOTSTRAP_PAT}" \
    "http://localhost:${GITLAB_HTTP_PORT}/api/v4/projects/${project_id}/protected_branches/main" >/dev/null || true
}

protect_main_branch() {
  local project_id="${1:?project id is required}"
  gitlab_api_request POST "/projects/${project_id}/protected_branches" \
    --data-urlencode "name=main" \
    --data-urlencode "push_access_level=40" \
    --data-urlencode "merge_access_level=40" \
    --data-urlencode "allow_force_push=false" >/dev/null || true
}

ensure_git_repo() {
  local repo_dir="${1:?repo dir is required}"
  local publish_name publish_email

  mkdir -p "${repo_dir}"

  if [ ! -d "${repo_dir}/.git" ]; then
    git -C "${repo_dir}" init -b main >/dev/null
  fi

  publish_name="${GITLAB_PUBLISH_GIT_NAME:-root}"
  publish_email="${GITLAB_PUBLISH_GIT_EMAIL:-${GITLAB_ROOT_EMAIL:-root@example.com}}"

  git -C "${repo_dir}" config user.name "${publish_name}"
  git -C "${repo_dir}" config user.email "${publish_email}"
}

prime_rendered_repo() {
  local repo_dir="${1:?repo dir is required}"
  local remote_name="${2:?remote name is required}"
  local remote_url="${3:?remote url is required}"

  ensure_git_repo "${repo_dir}"

  if git -C "${repo_dir}" remote get-url "${remote_name}" >/dev/null 2>&1; then
    git -C "${repo_dir}" remote set-url "${remote_name}" "${remote_url}"
  else
    git -C "${repo_dir}" remote add "${remote_name}" "${remote_url}"
  fi

  if remote_repo_is_empty "${remote_url}"; then
    git -C "${repo_dir}" checkout -B main >/dev/null 2>&1 || true
    return 0
  fi

  git -C "${repo_dir}" fetch "${remote_name}" main >/dev/null 2>&1 || true
  if git -C "${repo_dir}" rev-parse --verify "${remote_name}/main" >/dev/null 2>&1; then
    git -C "${repo_dir}" checkout -B main "${remote_name}/main" >/dev/null
  else
    git -C "${repo_dir}" checkout -B main >/dev/null
  fi
}

remote_repo_is_empty() {
  local remote_url="${1:?remote url is required}"
  local heads

  heads="$(git ls-remote --heads "${remote_url}" 2>/dev/null || true)"
  [ -z "${heads}" ]
}

sync_rendered_repo() {
  local repo_dir="${1:?repo dir is required}"
  local remote_name="${2:?remote name is required}"
  local remote_url="${3:?remote url is required}"
  local commit_message="${4:?commit message is required}"
  local init_history="${5:-false}"
  local project_id="${6:-}"

  ensure_git_repo "${repo_dir}"

  if git -C "${repo_dir}" remote get-url "${remote_name}" >/dev/null 2>&1; then
    git -C "${repo_dir}" remote set-url "${remote_name}" "${remote_url}"
  else
    git -C "${repo_dir}" remote add "${remote_name}" "${remote_url}"
  fi

  if [ "${init_history}" != "true" ] && remote_repo_is_empty "${remote_url}"; then
    init_history="true"
  fi

  if [ "${init_history}" = "true" ]; then
    if [ -n "${project_id}" ]; then
      unprotect_main_branch "${project_id}"
    fi
    git -C "${repo_dir}" checkout --orphan __init_artifacts__ >/dev/null 2>&1
    git -C "${repo_dir}" add -A
    git -C "${repo_dir}" commit --allow-empty -m "init-artifacts" >/dev/null
    git -C "${repo_dir}" branch -M __init_artifacts__ main >/dev/null
    if ! git -C "${repo_dir}" push -o ci.skip --force --set-upstream "${remote_name}" main; then
      if [ -n "${project_id}" ]; then
        protect_main_branch "${project_id}"
      fi
      return 1
    fi
    if [ -n "${project_id}" ]; then
      protect_main_branch "${project_id}"
    fi
    return 0
  fi

  git -C "${repo_dir}" checkout -B main >/dev/null
  git -C "${repo_dir}" add -A
  if [ -n "$(git -C "${repo_dir}" status --short)" ]; then
    git -C "${repo_dir}" commit -m "${commit_message}" >/dev/null
  fi

  git -C "${repo_dir}" push --set-upstream "${remote_name}" main
}

platform_sha="$(git rev-parse --short HEAD 2>/dev/null || echo manual)"
sdp_repo_dir="${ROOT_DIR}/gitlab-projects/generated/${GITLAB_SDP_PROJECT_PATH}"
edp_repo_dir="${ROOT_DIR}/gitlab-projects/generated/${GITLAB_EDP_PROJECT_PATH}"

prime_rendered_repo \
  "${sdp_repo_dir}" \
  local-gitlab-sdp \
  "http://oauth2:${GITLAB_BOOTSTRAP_PAT}@localhost:${GITLAB_HTTP_PORT}/root/${GITLAB_SDP_PROJECT_PATH}.git"

prime_rendered_repo \
  "${edp_repo_dir}" \
  local-gitlab-edp \
  "http://oauth2:${GITLAB_BOOTSTRAP_PAT}@localhost:${GITLAB_HTTP_PORT}/root/${GITLAB_EDP_PROJECT_PATH}.git"

python3 "${ROOT_DIR}/scripts/render_gitlab_project_repos.py"

echo "publishing rendered SDP platform repo"
sync_rendered_repo \
  "${sdp_repo_dir}" \
  local-gitlab-sdp \
  "http://oauth2:${GITLAB_BOOTSTRAP_PAT}@localhost:${GITLAB_HTTP_PORT}/root/${GITLAB_SDP_PROJECT_PATH}.git" \
  "Sync SDP project from local platform ${platform_sha}" \
  "${INIT_SDP_HISTORY}" \
  "${GITLAB_SDP_PROJECT_ID}"

echo "publishing rendered EDP platform repo"
sync_rendered_repo \
  "${edp_repo_dir}" \
  local-gitlab-edp \
  "http://oauth2:${GITLAB_BOOTSTRAP_PAT}@localhost:${GITLAB_HTTP_PORT}/root/${GITLAB_EDP_PROJECT_PATH}.git" \
  "Sync EDP project from local platform ${platform_sha}" \
  "${INIT_EDP_HISTORY}" \
  "${GITLAB_EDP_PROJECT_ID}"

if [ "${SKIP_VARIABLE_SYNC}" != "true" ]; then
  echo "syncing GitLab CI variables"
  "${ROOT_DIR}/scripts/sync-gitlab-ci-variables.sh"
fi

echo "rendered platform repositories published"
echo "source repository remotes were not modified"
