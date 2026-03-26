#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

action="${1:?action is required (provision|destroy)}"
project_kind="${2:?project kind is required (sdp|edp)}"
project_path_slug="${3:?project path slug is required}"
branch_name="${4:?branch name is required}"
default_branch="${5:-main}"
merge_request_iid="${6:?merge request iid is required}"

state_dir="${GITLAB_BRANCH_PROVISIONER_STATE_DIR:-${ROOT_DIR}/gitlab-branch-provisioner/state}"

gitlab_slug() {
  local raw="${1:?raw value is required}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "${raw}" | tr -cs 'a-z0-9' '-')"
  raw="${raw#-}"
  raw="${raw%-}"
  printf '%s' "${raw:0:63}"
}

file_token() {
  local raw="${1:?raw value is required}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "${raw}" | tr -cs 'a-z0-9' '_')"
  raw="${raw#_}"
  raw="${raw%_}"
  printf '%s' "${raw:0:120}"
}

branch_slug="$(gitlab_slug "${branch_name}")"
branch_slug="${branch_slug:-local}"
state_token="$(file_token "mr_${project_kind}_${project_path_slug}_${merge_request_iid}_${branch_name}")"
state_token="${state_token:-local}"
dotenv_path="${state_dir}/merge_requests/${state_token}.env"

mkdir -p "$(dirname "${dotenv_path}")"

export CI_PROJECT_PATH_SLUG="${project_path_slug}"
export CI_COMMIT_BRANCH="${branch_name}"
export CI_COMMIT_REF_SLUG="${branch_slug}"
export CI_DEFAULT_BRANCH="${default_branch}"
export CI_PIPELINE_ID="mr-bootstrap-${merge_request_iid}"
export CI_PIPELINE_SOURCE="merge_request_event"
export CI_MERGE_REQUEST_IID="${merge_request_iid}"
export CI_MERGE_REQUEST_SOURCE_BRANCH_NAME="${branch_name}"

case "${action}" in
  provision)
    bash ./scripts/prepare-ci-sandbox.sh "${project_kind}" "${dotenv_path}"
    printf 'merge request sandbox ready for %s:!%s (%s) at %s\n' "${project_kind}" "${merge_request_iid}" "${branch_name}" "${dotenv_path}"
    ;;
  destroy)
    if [ ! -f "${dotenv_path}" ]; then
      printf 'merge request sandbox already absent for %s:!%s (%s)\n' "${project_kind}" "${merge_request_iid}" "${branch_name}"
      exit 0
    fi
    bash ./scripts/cleanup-ci-sandbox.sh --destroy "${dotenv_path}"
    rm -f "${dotenv_path}"
    rmdir "$(dirname "${dotenv_path}")" 2>/dev/null || true
    printf 'merge request sandbox removed for %s:!%s (%s)\n' "${project_kind}" "${merge_request_iid}" "${branch_name}"
    ;;
  *)
    echo "unsupported action: ${action}" >&2
    exit 1
    ;;
esac
