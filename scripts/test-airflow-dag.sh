#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

execution_date="${1:-2026-03-07}"
dag_id="${2:-local_platform_ingest}"
dag_subdir="${3:-/opt/airflow/dags/local_platform_pipeline.py}"

docker compose up -d airflow-metadata-db source-postgres-db lakehouse-object-store
docker compose run --rm lakehouse-bucket-init
docker compose up -d airflow-init
docker compose up -d airflow-scheduler

docker compose exec -T airflow-scheduler airflow dags list-import-errors
docker compose exec -T airflow-scheduler \
  airflow dags test \
  --subdir "${dag_subdir}" \
  "${dag_id}" \
  "${execution_date}"
