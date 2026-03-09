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

force_destroy="false"

if [ "${1:-}" = "--destroy" ]; then
  force_destroy="true"
  shift
fi

dotenv_path="${1:-${ROOT_DIR}/artifacts/context/ci.env}"
log_prefix="${dotenv_path%.env}"

if [ -f "${dotenv_path}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${dotenv_path}"
  set +a
fi

should_destroy="${force_destroy}"
if [ "${should_destroy}" != "true" ]; then
  case "${CI_SANDBOX_CLEANUP_MODE:-destroy}" in
    destroy) should_destroy="true" ;;
    *) should_destroy="false" ;;
  esac
fi

if [ "${should_destroy}" != "true" ]; then
  printf 'preserved ci sandbox %s\n' "${CI_SANDBOX_SLUG:-<unset>}"
  exit 0
fi

if [ -n "${ICEBERG_NAMESPACE:-}" ] && [ -n "${OBJECT_STORE_BUCKET:-}" ] && docker compose config --services 2>/dev/null | grep -qx "dlt-extractor"; then
  docker compose run --rm --no-deps dlt-extractor python - <<'PY'
from __future__ import annotations

import os
from urllib.parse import urlparse

import boto3

from dlt.common.libs.pyiceberg import get_catalog


namespace = os.environ["ICEBERG_NAMESPACE"]
bucket_uri = os.environ["OBJECT_STORE_BUCKET"]
parsed = urlparse(bucket_uri)
bucket = parsed.netloc
prefix = parsed.path.lstrip("/")

catalog = get_catalog()
try:
    tables = list(catalog.list_tables(namespace))
except Exception:
    tables = []

for table_ident in tables:
    if isinstance(table_ident, tuple):
        full_name = ".".join(table_ident)
    else:
        full_name = f"{namespace}.{table_ident}"
    try:
        catalog.drop_table(full_name)
    except Exception:
        pass

client = boto3.client(
    "s3",
    endpoint_url=os.environ["OBJECT_STORE_ENDPOINT_URL"],
    aws_access_key_id=os.environ["OBJECT_STORE_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["OBJECT_STORE_SECRET_ACCESS_KEY"],
    region_name=os.environ["OBJECT_STORE_REGION"],
)

continuation_token = None
while True:
    kwargs = {"Bucket": bucket, "Prefix": prefix}
    if continuation_token:
        kwargs["ContinuationToken"] = continuation_token
    response = client.list_objects_v2(**kwargs)
    objects = [{"Key": item["Key"]} for item in response.get("Contents", [])]
    if objects:
        client.delete_objects(Bucket=bucket, Delete={"Objects": objects})
    if not response.get("IsTruncated"):
        break
    continuation_token = response.get("NextContinuationToken")
PY
fi

if [ -n "${SNOWFLAKE_ACCOUNT:-}" ] && [ -n "${SNOWFLAKE_USER:-}" ] && [ -n "${SNOWFLAKE_PASSWORD:-}" ] \
  && [ -n "${SNOWFLAKE_ROLE:-}" ] && [ -n "${SNOWFLAKE_WAREHOUSE:-}" ] \
  && {
    [ -n "${SNOWFLAKE_CLONE_OWNER_TOKEN:-}" ] && [ -n "${SNOWFLAKE_CLONE_BRANCH_TOKEN:-}" ] \
      || [ -n "${SNOWFLAKE_SDP_DATABASE:-}" ] \
      || [ -n "${SNOWFLAKE_EDP_DATABASE:-}" ];
  }; then
  docker compose run --rm --no-deps \
    -e "SNOWFLAKE_ACCOUNT=${SNOWFLAKE_ACCOUNT}" \
    -e "SNOWFLAKE_USER=${SNOWFLAKE_USER}" \
    -e "SNOWFLAKE_PASSWORD=${SNOWFLAKE_PASSWORD}" \
    -e "SNOWFLAKE_ROLE=${SNOWFLAKE_ROLE}" \
    -e "SNOWFLAKE_WAREHOUSE=${SNOWFLAKE_WAREHOUSE}" \
    -e "SNOWFLAKE_CLONE_OWNER_TOKEN=${SNOWFLAKE_CLONE_OWNER_TOKEN:-}" \
    -e "SNOWFLAKE_CLONE_BRANCH_TOKEN=${SNOWFLAKE_CLONE_BRANCH_TOKEN:-}" \
    -e "SNOWFLAKE_SDP_DATABASE_BASE=${SNOWFLAKE_SDP_DATABASE_BASE:-}" \
    -e "SNOWFLAKE_EDP_DATABASE_BASE=${SNOWFLAKE_EDP_DATABASE_BASE:-}" \
    -e "SNOWFLAKE_SDP_DATABASE=${SNOWFLAKE_SDP_DATABASE:-}" \
    -e "SNOWFLAKE_EDP_DATABASE=${SNOWFLAKE_EDP_DATABASE:-}" \
    dbt-executor \
    python /opt/platform/dbt/scripts/manage_ci_clones.py drop
fi

rm -f \
  "${log_prefix}.snowflake_base_bootstrap.log" \
  "${log_prefix}.snowflake_clone_create.log"

printf 'cleaned ci sandbox %s\n' "${CI_SANDBOX_SLUG:-<unset>}"
