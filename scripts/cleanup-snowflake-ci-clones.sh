#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

dbt_executor_image="$(runtime_image_ref dbt-executor)"

required_vars=(
  SNOWFLAKE_ACCOUNT
  SNOWFLAKE_USER
  SNOWFLAKE_PASSWORD
  SNOWFLAKE_ROLE
  SNOWFLAKE_WAREHOUSE
)

for key in "${required_vars[@]}"; do
  if [ -z "${!key:-}" ]; then
    echo "skipping Snowflake CI clone cleanup because ${key} is not set"
    exit 0
  fi
  done

if ! docker image inspect "${dbt_executor_image}" >/dev/null 2>&1; then
  echo "skipping Snowflake CI clone cleanup because ${dbt_executor_image} is not available yet"
  exit 0
fi

docker compose run --rm --no-deps \
  -e "SNOWFLAKE_ACCOUNT=${SNOWFLAKE_ACCOUNT}" \
  -e "SNOWFLAKE_USER=${SNOWFLAKE_USER}" \
  -e "SNOWFLAKE_PASSWORD=${SNOWFLAKE_PASSWORD}" \
  -e "SNOWFLAKE_ROLE=${SNOWFLAKE_ROLE}" \
  -e "SNOWFLAKE_WAREHOUSE=${SNOWFLAKE_WAREHOUSE}" \
  dbt-executor \
  python /opt/platform/dbt/scripts/manage_ci_clones.py purge-ci
