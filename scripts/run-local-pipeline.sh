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
docker compose run --rm --no-deps dlt-extractor python /opt/platform/dlt/pipeline.py

if [ -n "${SNOWFLAKE_ACCOUNT:-}" ] && [ -n "${SNOWFLAKE_USER:-}" ] && [ -n "${SNOWFLAKE_PASSWORD:-}" ]; then
  bash ./scripts/ensure-snowflake-foundation.sh
  docker compose run --rm --no-deps dlt-extractor python /opt/platform/dlt/snowflake_raw_sync.py
  bash ./scripts/deploy-snowflake-dbt-project.sh \
    proj_sdp_orders \
    "${SNOWFLAKE_SDP_DBT_PROJECT}" \
    "${SNOWFLAKE_SDP_DATABASE}" \
    "${SNOWFLAKE_SDP_CORE_SCHEMA}" \
    dev
  bash ./scripts/execute-snowflake-dbt-project.sh "${SNOWFLAKE_SDP_DBT_PROJECT}" build
  echo "EDP deploy/build is intentionally skipped here; use the EDP CI/CD pipeline or ./scripts/deploy-edp-dev.sh"
else
  echo "Skipping dbt build because Snowflake credentials are not set in .env"
fi
