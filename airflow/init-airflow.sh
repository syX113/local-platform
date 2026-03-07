#!/usr/bin/env bash
set -euo pipefail

airflow db migrate

if ! airflow users list | tail -n +3 | awk '{print $2}' | grep -qx "${AIRFLOW_ADMIN_USERNAME}"; then
  airflow users create \
    --username "${AIRFLOW_ADMIN_USERNAME}" \
    --firstname Local \
    --lastname Admin \
    --role Admin \
    --email "${AIRFLOW_ADMIN_EMAIL}" \
    --password "${AIRFLOW_ADMIN_PASSWORD}"
fi

