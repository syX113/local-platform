#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

docker compose up -d source-postgres-db

until docker compose exec -T source-postgres-db \
  pg_isready -U "${SOURCE_POSTGRES_USER}" -d "${SOURCE_POSTGRES_DB}" >/dev/null 2>&1; do
  echo "waiting for source-postgres-db"
  sleep 2
done

for sql_file in \
  "${ROOT_DIR}/postgres/source-init/01-create-source-schema.sql" \
  "${ROOT_DIR}/postgres/source-init/02-seed-sample-data.sql"; do
  docker compose exec -T source-postgres-db \
    psql -v ON_ERROR_STOP=1 -U "${SOURCE_POSTGRES_USER}" -d "${SOURCE_POSTGRES_DB}" < "${sql_file}"
done

docker compose exec -T source-postgres-db \
  psql -U "${SOURCE_POSTGRES_USER}" -d "${SOURCE_POSTGRES_DB}" -c "
    select
      (select count(*) from customers) as customers,
      (select count(*) from orders) as orders,
      (select count(*) from order_items) as order_items;
  "
