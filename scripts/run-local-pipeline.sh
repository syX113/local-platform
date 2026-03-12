#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env
export_dev_runtime_env

docker compose up -d --no-build airflow-metadata-db source-postgres-db lakehouse-object-store
docker compose run --rm --no-deps lakehouse-bucket-init
./scripts/load-source-sample-data.sh

for scope in orders customers; do
  activate_source_scope_runtime "${scope}"
  docker compose run --rm --no-deps dlt-extractor python "/opt/platform/dlt/pipeline_${scope}.py"
done

if [ -n "${SNOWFLAKE_ACCOUNT:-}" ] && [ -n "${SNOWFLAKE_USER:-}" ] && [ -n "${SNOWFLAKE_PASSWORD:-}" ]; then
  bash ./scripts/ensure-snowflake-foundation.sh
  for scope in orders customers; do
    docker compose run --rm --no-deps dlt-extractor bash -lc "RAW_SYNC_SCOPE=${scope} python /opt/platform/dlt/snowflake_raw_sync.py"
  done
  bash ./scripts/deploy-snowflake-dbt-project.sh \
    proj_source_finnova \
    "${SNOWFLAKE_SDP_DBT_PROJECT}" \
    "${SNOWFLAKE_SDP_DATABASE}" \
    "${SNOWFLAKE_SDP_CORE_SCHEMA}" \
    dev
  bash ./scripts/prepare-snowflake-dbt-target.sh \
    proj_source_finnova \
    "${SNOWFLAKE_SDP_DBT_PROJECT}"
  bash ./scripts/execute-snowflake-dbt-project.sh "${SNOWFLAKE_SDP_DBT_PROJECT}" build
  bash ./scripts/deploy-edp-dev.sh
  bash ./scripts/deploy-edp-customers-dev.sh
else
  echo "Skipping dbt build because Snowflake credentials are not set in .env"
fi
