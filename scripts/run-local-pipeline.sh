#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

docker compose up -d airflow-metadata-db source-postgres-db lakehouse-object-store
docker compose run --rm lakehouse-bucket-init
./scripts/load-source-sample-data.sh
docker compose run --rm dlt-extractor python /opt/platform/dlt/pipeline.py

if [ -n "${SNOWFLAKE_ACCOUNT:-}" ] && [ -n "${SNOWFLAKE_USER:-}" ] && [ -n "${SNOWFLAKE_PASSWORD:-}" ]; then
  ./scripts/bootstrap-snowflake.sh
  docker compose run --rm dlt-extractor python /opt/platform/dlt/snowflake_raw_sync.py
  docker compose run --rm dbt-executor dbt build --project-dir /opt/platform/dbt --profiles-dir /opt/platform/dbt/profiles
else
  echo "Skipping dbt build because Snowflake credentials are not set in .env"
fi
