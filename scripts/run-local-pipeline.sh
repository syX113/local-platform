#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

sdp_container_dbt_project_dir="$(resolve_container_dbt_project_dir proj_sdp_orders)"
edp_container_dbt_project_dir="$(resolve_container_dbt_project_dir proj_edp_orders)"

docker compose up -d airflow-metadata-db source-postgres-db lakehouse-object-store
docker compose run --rm lakehouse-bucket-init
./scripts/load-source-sample-data.sh
docker compose run --rm --no-deps dlt-extractor python /opt/platform/dlt/pipeline.py

if [ -n "${SNOWFLAKE_ACCOUNT:-}" ] && [ -n "${SNOWFLAKE_USER:-}" ] && [ -n "${SNOWFLAKE_PASSWORD:-}" ]; then
  bash ./scripts/ensure-snowflake-foundation.sh
  docker compose run --rm --no-deps dlt-extractor python /opt/platform/dlt/snowflake_raw_sync.py
  docker compose run --rm dbt-executor \
    dbt build --project-dir "${sdp_container_dbt_project_dir}" --profiles-dir /opt/platform/dbt/profiles
  docker compose run --rm dbt-executor \
    dbt build --project-dir "${edp_container_dbt_project_dir}" --profiles-dir /opt/platform/dbt/profiles
else
  echo "Skipping dbt build because Snowflake credentials are not set in .env"
fi
