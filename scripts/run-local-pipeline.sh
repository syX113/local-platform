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

source_scopes=()
while IFS= read -r scope; do
  [ -n "${scope}" ] || continue
  source_scopes+=("${scope}")
done < <(project_registry_product_scopes proj_source_finnova)

for scope in "${source_scopes[@]}"; do
  [ -n "${scope}" ] || continue
  activate_source_scope_runtime "${scope}"
  docker compose run --rm --no-deps dlt-extractor python "/opt/platform/dlt/pipeline_${scope}.py"
done

if [ -n "${SNOWFLAKE_ACCOUNT:-}" ] && [ -n "${SNOWFLAKE_USER:-}" ] && [ -n "${SNOWFLAKE_PASSWORD:-}" ]; then
  bash ./scripts/ensure-snowflake-foundation.sh
  for scope in "${source_scopes[@]}"; do
    [ -n "${scope}" ] || continue
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
  bash ./scripts/deploy-edp-dev.sh proj_domain_transactions
  bash ./scripts/deploy-edp-dev.sh proj_domain_customer
else
  echo "Skipping dbt build because Snowflake credentials are not set in .env"
fi
