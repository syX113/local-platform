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

ensure_sdp_object_prefix() {
  docker compose run --rm --no-deps \
    -e "OBJECT_STORE_BUCKET=${OBJECT_STORE_BUCKET}" \
    -e "OBJECT_STORE_ENDPOINT_URL=${OBJECT_STORE_ENDPOINT_URL}" \
    -e "OBJECT_STORE_ACCESS_KEY_ID=${OBJECT_STORE_ACCESS_KEY_ID}" \
    -e "OBJECT_STORE_SECRET_ACCESS_KEY=${OBJECT_STORE_SECRET_ACCESS_KEY}" \
    -e "OBJECT_STORE_REGION=${OBJECT_STORE_REGION}" \
    dlt-extractor python - <<'PY'
from __future__ import annotations

import os
from urllib.parse import urlparse

import boto3


bucket_uri = os.environ["OBJECT_STORE_BUCKET"]
parsed = urlparse(bucket_uri)
bucket = parsed.netloc
prefix = parsed.path.lstrip("/").rstrip("/")
key = f"{prefix}/.branch-sandbox"

client = boto3.client(
    "s3",
    endpoint_url=os.environ["OBJECT_STORE_ENDPOINT_URL"],
    aws_access_key_id=os.environ["OBJECT_STORE_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["OBJECT_STORE_SECRET_ACCESS_KEY"],
    region_name=os.environ["OBJECT_STORE_REGION"],
)
client.put_object(Bucket=bucket, Key=key, Body=b"branch sandbox ready\n")
print(f"ensured branch object prefix s3://{bucket}/{key}")
PY
}

branch_slug="$(gitlab_slug "${branch_name}")"
branch_slug="${branch_slug:-local}"
state_token="$(file_token "${project_kind}_${project_path_slug}_${branch_name}")"
state_token="${state_token:-local}"
dotenv_path="${state_dir}/${project_kind}/${state_token}.env"

mkdir -p "$(dirname "${dotenv_path}")"

export CI_PROJECT_PATH_SLUG="${project_path_slug}"
export CI_COMMIT_BRANCH="${branch_name}"
export CI_COMMIT_REF_SLUG="${branch_slug}"
export CI_DEFAULT_BRANCH="${default_branch}"
export CI_PIPELINE_ID="branch-bootstrap"
unset CI_MERGE_REQUEST_SOURCE_BRANCH_NAME

case "${action}" in
  provision)
    bash ./scripts/prepare-ci-sandbox.sh "${project_kind}" "${dotenv_path}"
    if [ "${project_kind}" = "sdp" ]; then
      set -a
      # shellcheck disable=SC1090
      source "${dotenv_path}"
      set +a
      ensure_sdp_object_prefix
    fi
    printf 'branch sandbox ready for %s:%s at %s\n' "${project_kind}" "${branch_name}" "${dotenv_path}"
    ;;
  destroy)
    if [ ! -f "${dotenv_path}" ]; then
      printf 'branch sandbox already absent for %s:%s\n' "${project_kind}" "${branch_name}"
      exit 0
    fi
    bash ./scripts/cleanup-ci-sandbox.sh --destroy "${dotenv_path}"
    rm -f "${dotenv_path}"
    rmdir "$(dirname "${dotenv_path}")" 2>/dev/null || true
    printf 'branch sandbox removed for %s:%s\n' "${project_kind}" "${branch_name}"
    ;;
  *)
    echo "unsupported action: ${action}" >&2
    exit 1
    ;;
esac
