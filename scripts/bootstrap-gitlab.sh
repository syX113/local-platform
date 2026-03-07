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

configure_local_git_remote() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  local remote_url branch
  remote_url="http://oauth2:${BOOTSTRAP_PAT}@localhost:${GITLAB_HTTP_PORT}/root/${GITLAB_PROJECT_PATH}.git"
  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "${branch}" = "HEAD" ]; then
    branch="main"
  fi

  if git remote get-url local-gitlab >/dev/null 2>&1; then
    git remote set-url local-gitlab "${remote_url}"
  else
    git remote add local-gitlab "${remote_url}"
  fi

  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "pushing current committed branch to local GitLab remote"
    git push --set-upstream local-gitlab "HEAD:refs/heads/${branch}"
  fi
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

echo "creating or resolving GitLab project"
PROJECT_JSON="$(
  gitlab_api_request POST /projects \
    --data-urlencode "name=${GITLAB_PROJECT_NAME}" \
    --data-urlencode "path=${GITLAB_PROJECT_PATH}" \
    || true
)"

if [ -n "${PROJECT_JSON}" ] && [ "$(printf '%s' "${PROJECT_JSON}" | json_field id)" != "" ]; then
  PROJECT_ID="$(printf '%s' "${PROJECT_JSON}" | json_field id)"
else
  SEARCH_JSON="$(gitlab_api_request GET "/projects?search=${GITLAB_PROJECT_PATH}")"
  PROJECT_ID="$(
    GITLAB_PROJECT_PATH="${GITLAB_PROJECT_PATH}" python3 -c '
import json
import os
import sys

path = os.environ["GITLAB_PROJECT_PATH"]
for project in json.load(sys.stdin):
    if project.get("path") == path:
        print(project["id"])
        break
' <<<"${SEARCH_JSON}"
  )"
fi

if [ -z "${PROJECT_ID}" ]; then
  echo "failed to resolve GitLab project id" >&2
  exit 1
fi

echo "creating project runner token"
RUNNER_JSON="$(
  TAG_ARGS=()
  OLD_IFS="${IFS}"
  IFS=','
  for tag in ${GITLAB_RUNNER_TAGS}; do
    TAG_ARGS+=("--data-urlencode" "tag_list[]=${tag}")
  done
  IFS="${OLD_IFS}"

  gitlab_api_request POST /user/runners \
    --data-urlencode "runner_type=project_type" \
    --data-urlencode "project_id=${PROJECT_ID}" \
    --data-urlencode "description=${GITLAB_RUNNER_DESCRIPTION}" \
    "${TAG_ARGS[@]}"
)"

RUNNER_TOKEN="$(printf '%s' "${RUNNER_JSON}" | json_field token)"

if [ -z "${RUNNER_TOKEN}" ]; then
  echo "failed to create runner token" >&2
  exit 1
fi

cat > gitlab-runner/generated/project.env <<EOF
GITLAB_PROJECT_ID=${PROJECT_ID}
GITLAB_RUNNER_TOKEN=${RUNNER_TOKEN}
EOF

sed \
  -e "s|__RUNNER_DESCRIPTION__|${GITLAB_RUNNER_DESCRIPTION}|g" \
  -e "s|__GITLAB_URL__|http://gitlab/|g" \
  -e "s|__RUNNER_TOKEN__|${RUNNER_TOKEN}|g" \
  -e "s|__CLONE_URL__|http://gitlab|g" \
  -e "s|__JOB_IMAGE__|${GITLAB_RUNNER_JOB_IMAGE}|g" \
  -e "s|__RUNNER_NETWORK__|${PLATFORM_DOCKER_NETWORK}|g" \
  gitlab-runner/config.template.toml > gitlab-runner/generated/config.toml

configure_local_git_remote

docker compose restart gitlab-fargate-runner
echo "syncing GitLab CI variables"
./scripts/sync-gitlab-ci-variables.sh

echo "gitlab bootstrap complete"
echo "project id: ${PROJECT_ID}"
echo "runner config: gitlab-runner/generated/config.toml"
echo "bootstrap pat: gitlab-runner/generated/bootstrap.env"
echo "project env: gitlab-runner/generated/project.env"
./scripts/print-setup-summary.sh
