#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

mkdir -p gitlab-runner/generated

CURL_RETRY_ARGS=(
  --silent
  --show-error
  --location
  --connect-timeout 5
  --max-time 30
  --retry 20
  --retry-delay 5
  --retry-all-errors
)

wait_for_gitlab() {
  local stable=0

  while [ "${stable}" -lt 2 ]; do
    help_status="$(
      curl "${CURL_RETRY_ARGS[@]}" -o /dev/null -w '%{http_code}' "http://localhost:${GITLAB_HTTP_PORT}/help" || true
    )"
    sign_in_status="$(
      curl "${CURL_RETRY_ARGS[@]}" -o /dev/null -w '%{http_code}' "http://localhost:${GITLAB_HTTP_PORT}/users/sign_in" || true
    )"
    api_status="$(
      curl "${CURL_RETRY_ARGS[@]}" -o /dev/null -w '%{http_code}' "http://localhost:${GITLAB_HTTP_PORT}/api/v4/version" || true
    )"

    if [ "${help_status}" = "200" ] && [ "${sign_in_status}" = "200" ] && { [ "${api_status}" = "200" ] || [ "${api_status}" = "401" ]; }; then
      stable=$((stable + 1))
      echo "GitLab endpoints are healthy (${stable}/2)"
      sleep 5
      continue
    fi

    stable=0
    echo "waiting for GitLab UI/API readiness (help=${help_status} sign_in=${sign_in_status} api=${api_status})"
    sleep 10
  done
}

json_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

bootstrap_pat_works() {
  local token="${1:-}"

  if [ -z "${token}" ]; then
    return 1
  fi

  curl --fail "${CURL_RETRY_ARGS[@]}" \
    --header "PRIVATE-TOKEN: ${token}" \
    "http://localhost:${GITLAB_HTTP_PORT}/api/v4/user" >/dev/null
}

gitlab_api_request() {
  local method="${1:?method is required}"
  local path="${2:?path is required}"
  shift 2

  curl --fail "${CURL_RETRY_ARGS[@]}" \
    --request "${method}" \
    --header "PRIVATE-TOKEN: ${BOOTSTRAP_PAT}" \
    "$@" \
    "http://localhost:${GITLAB_HTTP_PORT}/api/v4${path}"
}

delete_matching_runners() {
  local runner_description="${1:?runner description is required}"
  local runners_json runner_ids runner_id

  runners_json="$(gitlab_api_request GET "/runners/all?per_page=100")"
  runner_ids="$(
    RUNNER_DESCRIPTION="${runner_description}" python3 -c '
import json
import os
import sys

description = os.environ["RUNNER_DESCRIPTION"]
for runner in json.load(sys.stdin):
    if runner.get("description") == description:
        print(runner["id"])
' <<<"${runners_json}"
  )"

  while IFS= read -r runner_id; do
    [ -n "${runner_id}" ] || continue
    gitlab_api_request DELETE "/runners/${runner_id}" >/dev/null
  done <<<"${runner_ids}"
}

create_or_resolve_project() {
  local project_name="${1:?project name is required}"
  local project_path="${2:?project path is required}"
  local project_json search_json project_id create_status create_response

  create_response="$(
    curl \
      --silent \
      --show-error \
      --location \
      --connect-timeout 5 \
      --max-time 30 \
      --request POST \
      --header "PRIVATE-TOKEN: ${BOOTSTRAP_PAT}" \
      --data-urlencode "name=${project_name}" \
      --data-urlencode "path=${project_path}" \
      --write-out $'\nHTTP_STATUS=%{http_code}' \
      "http://localhost:${GITLAB_HTTP_PORT}/api/v4/projects"
  )"

  create_status="$(printf '%s\n' "${create_response}" | awk -F= '/^HTTP_STATUS=/{print $2}' | tail -n 1)"
  project_json="$(printf '%s\n' "${create_response}" | sed '/^HTTP_STATUS=/d')"

  if [ "${create_status}" = "200" ] || [ "${create_status}" = "201" ]; then
    printf '%s\n' "$(printf '%s' "${project_json}" | json_field id)"
    return 0
  fi

  search_json="$(gitlab_api_request GET "/projects?search=${project_path}")"
  project_id="$(
    GITLAB_PROJECT_PATH="${project_path}" python3 -c '
import json
import os
import sys

path = os.environ["GITLAB_PROJECT_PATH"]
for project in json.load(sys.stdin):
    if project.get("path") == path:
        print(project["id"])
        break
' <<<"${search_json}"
  )"

  printf '%s\n' "${project_id}"
}

create_project_runner_token() {
  local project_id="${1:?project id is required}"
  local runner_description="${2:?runner description is required}"
  local runner_json runner_token runner_tags

  delete_matching_runners "${runner_description}"

  runner_json="$(
    runner_tags="${GITLAB_RUNNER_TAGS}"

    gitlab_api_request POST /user/runners \
      --data-urlencode "runner_type=project_type" \
      --data-urlencode "project_id=${project_id}" \
      --data-urlencode "description=${runner_description}" \
      --data-urlencode "tag_list=${runner_tags}"
  )"

  runner_token="$(printf '%s' "${runner_json}" | json_field token)"
  printf '%s\n' "${runner_token}"
}

ensure_git_repo() {
  local repo_dir="${1:?repo dir is required}"

  if [ ! -d "${repo_dir}/.git" ]; then
    git -C "${repo_dir}" init -b main >/dev/null
  fi

  git -C "${repo_dir}" config user.name "Codex Local"
  git -C "${repo_dir}" config user.email "codex-local@example.com"
}

sync_gitlab_repo() {
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

  git -C "${repo_dir}" add -A
  if [ -n "$(git -C "${repo_dir}" status --short)" ]; then
    git -C "${repo_dir}" commit -m "${commit_message}" >/dev/null
  fi

  git -C "${repo_dir}" push --set-upstream "${remote_name}" main
}

render_runner_config() {
  local sdp_runner_description="${1:?runner description is required}"
  local sdp_runner_token="${2:?runner token is required}"
  local edp_runner_description="${3:?runner description is required}"
  local edp_runner_token="${4:?runner token is required}"

  {
    printf 'concurrent = 1\n'
    printf 'check_interval = 2\n\n'
    sed \
      -e "s|__RUNNER_DESCRIPTION__|${sdp_runner_description}|g" \
      -e "s|__GITLAB_URL__|http://gitlab/|g" \
      -e "s|__RUNNER_TOKEN__|${sdp_runner_token}|g" \
      -e "s|__CLONE_URL__|http://gitlab|g" \
      -e "s|__JOB_IMAGE__|${GITLAB_RUNNER_JOB_IMAGE}|g" \
      -e "s|__RUNNER_NETWORK__|${PLATFORM_DOCKER_NETWORK}|g" \
      gitlab-runner/config.template.toml
    printf '\n'
    sed \
      -e "s|__RUNNER_DESCRIPTION__|${edp_runner_description}|g" \
      -e "s|__GITLAB_URL__|http://gitlab/|g" \
      -e "s|__RUNNER_TOKEN__|${edp_runner_token}|g" \
      -e "s|__CLONE_URL__|http://gitlab|g" \
      -e "s|__JOB_IMAGE__|${GITLAB_RUNNER_JOB_IMAGE}|g" \
      -e "s|__RUNNER_NETWORK__|${PLATFORM_DOCKER_NETWORK}|g" \
      gitlab-runner/config.template.toml
  } > gitlab-runner/generated/config.toml
}

wait_for_gitlab

BOOTSTRAP_PAT=""

if [ -f gitlab-runner/generated/bootstrap.env ]; then
  # shellcheck disable=SC1091
  source gitlab-runner/generated/bootstrap.env
  if bootstrap_pat_works "${GITLAB_BOOTSTRAP_PAT:-}"; then
    BOOTSTRAP_PAT="${GITLAB_BOOTSTRAP_PAT}"
  fi
fi

if [ -z "${BOOTSTRAP_PAT}" ]; then
  echo "creating bootstrap PAT"
  BOOTSTRAP_PAT="$(
    docker compose exec -T gitlab-platform gitlab-rails runner "
      user = User.find_by_username('root')
      user.personal_access_tokens.where(name: 'local-platform-bootstrap').each(&:revoke!)
      token = user.personal_access_tokens.create!(scopes: ['api', 'create_runner', 'admin_mode'], name: 'local-platform-bootstrap', expires_at: 365.days.from_now)
      puts token.token
    " | tail -n 1
  )"
fi

echo "GITLAB_BOOTSTRAP_PAT=${BOOTSTRAP_PAT}" > gitlab-runner/generated/bootstrap.env

python3 "${ROOT_DIR}/scripts/render_gitlab_project_repos.py"

SDP_PROJECT_NAME="${GITLAB_SDP_PROJECT_NAME}"
SDP_PROJECT_PATH="${GITLAB_SDP_PROJECT_PATH}"
EDP_PROJECT_NAME="${GITLAB_EDP_PROJECT_NAME}"
EDP_PROJECT_PATH="${GITLAB_EDP_PROJECT_PATH}"
RUNNER_PREFIX="${GITLAB_RUNNER_DESCRIPTION_PREFIX:-local-fargate-runner}"

SDP_PROJECT_DIR="${ROOT_DIR}/gitlab-projects/generated/${SDP_PROJECT_PATH}"
EDP_PROJECT_DIR="${ROOT_DIR}/gitlab-projects/generated/${EDP_PROJECT_PATH}"
SDP_RUNNER_DESCRIPTION="${RUNNER_PREFIX}-sdp"
EDP_RUNNER_DESCRIPTION="${RUNNER_PREFIX}-edp"

echo "creating or resolving SDP GitLab project"
SDP_PROJECT_ID="$(create_or_resolve_project "${SDP_PROJECT_NAME}" "${SDP_PROJECT_PATH}")"
[ -n "${SDP_PROJECT_ID}" ] || { echo "failed to resolve SDP GitLab project id" >&2; exit 1; }

echo "creating or resolving EDP GitLab project"
EDP_PROJECT_ID="$(create_or_resolve_project "${EDP_PROJECT_NAME}" "${EDP_PROJECT_PATH}")"
[ -n "${EDP_PROJECT_ID}" ] || { echo "failed to resolve EDP GitLab project id" >&2; exit 1; }

echo "creating SDP project runner token"
SDP_RUNNER_TOKEN="$(create_project_runner_token "${SDP_PROJECT_ID}" "${SDP_RUNNER_DESCRIPTION}")"
[ -n "${SDP_RUNNER_TOKEN}" ] || { echo "failed to create SDP runner token" >&2; exit 1; }

echo "creating EDP project runner token"
EDP_RUNNER_TOKEN="$(create_project_runner_token "${EDP_PROJECT_ID}" "${EDP_RUNNER_DESCRIPTION}")"
[ -n "${EDP_RUNNER_TOKEN}" ] || { echo "failed to create EDP runner token" >&2; exit 1; }

cat > gitlab-runner/generated/projects.env <<EOF
GITLAB_SDP_PROJECT_ID=${SDP_PROJECT_ID}
GITLAB_SDP_PROJECT_PATH=${SDP_PROJECT_PATH}
GITLAB_SDP_RUNNER_TOKEN=${SDP_RUNNER_TOKEN}
GITLAB_EDP_PROJECT_ID=${EDP_PROJECT_ID}
GITLAB_EDP_PROJECT_PATH=${EDP_PROJECT_PATH}
GITLAB_EDP_RUNNER_TOKEN=${EDP_RUNNER_TOKEN}
EOF

render_runner_config \
  "${SDP_RUNNER_DESCRIPTION}" "${SDP_RUNNER_TOKEN}" \
  "${EDP_RUNNER_DESCRIPTION}" "${EDP_RUNNER_TOKEN}"

platform_sha="$(git rev-parse --short HEAD 2>/dev/null || echo manual)"

echo "pushing generated SDP repository"
sync_gitlab_repo \
  "${SDP_PROJECT_DIR}" \
  local-gitlab-sdp \
  "http://oauth2:${BOOTSTRAP_PAT}@localhost:${GITLAB_HTTP_PORT}/root/${SDP_PROJECT_PATH}.git" \
  "Sync SDP project from local platform ${platform_sha}"

echo "pushing generated EDP repository"
sync_gitlab_repo \
  "${EDP_PROJECT_DIR}" \
  local-gitlab-edp \
  "http://oauth2:${BOOTSTRAP_PAT}@localhost:${GITLAB_HTTP_PORT}/root/${EDP_PROJECT_PATH}.git" \
  "Sync EDP project from local platform ${platform_sha}"

docker compose up -d gitlab-fargate-runner
echo "syncing GitLab CI variables"
./scripts/sync-gitlab-ci-variables.sh

echo "gitlab bootstrap complete"
echo "SDP project id: ${SDP_PROJECT_ID}"
echo "EDP project id: ${EDP_PROJECT_ID}"
echo "runner config: gitlab-runner/generated/config.toml"
echo "bootstrap pat: gitlab-runner/generated/bootstrap.env"
echo "project metadata: gitlab-runner/generated/projects.env"
./scripts/print-setup-summary.sh
