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

while IFS='=' read -r key value; do
  case "${key}" in
    AIRFLOW_SANDBOX_DAG_ID|AIRFLOW_SANDBOX_*_DAG_ID)
      if [ -n "${value}" ]; then
        remove_deployed_airflow_dag "${value}"
      fi
      ;;
  esac
done < <(env)

if [ -n "${ICEBERG_NAMESPACE:-}" ] && [ -n "${OBJECT_STORE_BUCKET:-}" ] && docker compose --profile tooling config --services 2>/dev/null | grep -qx "dlt-extractor"; then
  docker compose run --rm --no-deps \
    -e "ICEBERG_CATALOG_NAME=${ICEBERG_CATALOG_NAME:-}" \
    -e "ICEBERG_NAMESPACE=${ICEBERG_NAMESPACE}" \
    -e "OBJECT_STORE_BUCKET=${OBJECT_STORE_BUCKET}" \
    -e "OBJECT_STORE_ENDPOINT_URL=${OBJECT_STORE_ENDPOINT_URL}" \
    -e "OBJECT_STORE_ACCESS_KEY_ID=${OBJECT_STORE_ACCESS_KEY_ID}" \
    -e "OBJECT_STORE_SECRET_ACCESS_KEY=${OBJECT_STORE_SECRET_ACCESS_KEY}" \
    -e "OBJECT_STORE_REGION=${OBJECT_STORE_REGION}" \
    dlt-extractor python /opt/platform/dlt/cleanup_namespace.py
fi

if [ -n "${SNOWFLAKE_ACCOUNT:-}" ] && [ -n "${SNOWFLAKE_USER:-}" ] && [ -n "${SNOWFLAKE_PASSWORD:-}" ] \
  && [ -n "${SNOWFLAKE_ROLE:-}" ] && [ -n "${SNOWFLAKE_WAREHOUSE:-}" ]; then
  clone_env_args=()
  while IFS='=' read -r key value; do
    case "${key}" in
      SNOWFLAKE_*) clone_env_args+=(-e "${key}=${value}") ;;
    esac
  done < <(env)

  docker compose run --rm --no-deps \
    "${clone_env_args[@]}" \
    dbt-executor \
    python /opt/platform/dbt/scripts/manage_ci_clones.py drop
fi

if [ -n "${SNOWFLAKE_SDP_DBT_PROJECT:-}" ]; then
  bash "${SCRIPT_DIR}/drop-snowflake-dbt-project.sh" "${SNOWFLAKE_SDP_DBT_PROJECT}" || true
fi

if [ -n "${SNOWFLAKE_EDP_DBT_PROJECT:-}" ]; then
  bash "${SCRIPT_DIR}/drop-snowflake-dbt-project.sh" "${SNOWFLAKE_EDP_DBT_PROJECT}" || true
fi

if [ -n "${SNOWFLAKE_EDP_ORDERS_DBT_PROJECT:-}" ]; then
  bash "${SCRIPT_DIR}/drop-snowflake-dbt-project.sh" "${SNOWFLAKE_EDP_ORDERS_DBT_PROJECT}" || true
fi

if [ -n "${SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT:-}" ]; then
  bash "${SCRIPT_DIR}/drop-snowflake-dbt-project.sh" "${SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT}" || true
fi

rm -f \
  "${log_prefix}.snowflake_base_bootstrap.log" \
  "${log_prefix}.snowflake_clone_create.log"

printf 'cleaned ci sandbox %s\n' "${CI_SANDBOX_SLUG:-<unset>}"
