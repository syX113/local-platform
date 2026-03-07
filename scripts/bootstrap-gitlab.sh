#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

mkdir -p gitlab-runner/generated

wait_for_gitlab() {
  until curl -fsS "http://localhost:${GITLAB_HTTP_PORT}/help" >/dev/null; do
    internal_status="$(
      docker compose exec -T gitlab-platform /bin/bash -lc \
        "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1/help || true"
    )"
    if [ "${internal_status}" = "200" ]; then
      return 0
    fi
    echo "waiting for GitLab web endpoint"
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

  curl -fsS \
    --header "PRIVATE-TOKEN: ${token}" \
    "http://localhost:${GITLAB_HTTP_PORT}/api/v4/user" >/dev/null
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

PROJECT_JSON="$(
  curl -fsS --header "PRIVATE-TOKEN: ${BOOTSTRAP_PAT}" \
    --data-urlencode "name=${GITLAB_PROJECT_NAME}" \
    --data-urlencode "path=${GITLAB_PROJECT_PATH}" \
    --request POST "http://localhost:${GITLAB_HTTP_PORT}/api/v4/projects" \
    || true
)"

if [ -n "${PROJECT_JSON}" ] && [ "$(printf '%s' "${PROJECT_JSON}" | json_field id)" != "" ]; then
  PROJECT_ID="$(printf '%s' "${PROJECT_JSON}" | json_field id)"
else
  SEARCH_JSON="$(curl -fsS --header "PRIVATE-TOKEN: ${BOOTSTRAP_PAT}" "http://localhost:${GITLAB_HTTP_PORT}/api/v4/projects?search=${GITLAB_PROJECT_PATH}")"
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

RUNNER_JSON="$(
  TAG_ARGS=()
  OLD_IFS="${IFS}"
  IFS=','
  for tag in ${GITLAB_RUNNER_TAGS}; do
    TAG_ARGS+=("--data-urlencode" "tag_list[]=${tag}")
  done
  IFS="${OLD_IFS}"

  curl -fsS --header "PRIVATE-TOKEN: ${BOOTSTRAP_PAT}" \
    --data-urlencode "runner_type=project_type" \
    --data-urlencode "project_id=${PROJECT_ID}" \
    --data-urlencode "description=${GITLAB_RUNNER_DESCRIPTION}" \
    "${TAG_ARGS[@]}" \
    --request POST "http://localhost:${GITLAB_HTTP_PORT}/api/v4/user/runners"
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

docker compose restart gitlab-fargate-runner
./scripts/sync-gitlab-ci-variables.sh

echo "gitlab bootstrap complete"
echo "project id: ${PROJECT_ID}"
echo "runner config: gitlab-runner/generated/config.toml"
echo "bootstrap pat: gitlab-runner/generated/bootstrap.env"
echo "project env: gitlab-runner/generated/project.env"
./scripts/print-setup-summary.sh
