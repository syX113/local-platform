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

project_slug="${1:?project slug is required}"
dbt_target_name="${SNOW_DBT_TARGET_NAME:-dev}"
skip_foundation="false"
skip_dbt="false"

shift || true
while [ $# -gt 0 ]; do
  case "${1}" in
    --skip-foundation)
      skip_foundation="true"
      ;;
    --skip-dbt)
      skip_dbt="true"
      ;;
    -*)
      echo "unsupported argument: ${1}" >&2
      exit 1
      ;;
    *)
      echo "unsupported positional argument: ${1}" >&2
      exit 1
      ;;
  esac
  shift
done

project_kind="$(project_registry_kind "${project_slug}")"
if [ "${project_kind}" != "domain" ]; then
  echo "unsupported EDP project kind for promotion: ${project_kind}" >&2
  exit 1
fi

project_domain="$(project_registry_lookup "${project_slug}" domain "")"
upstream_project_slug="$(project_registry_lookup "${project_slug}" upstream_project_slug "")"
if [ -z "${upstream_project_slug}" ]; then
  echo "missing upstream project for domain project: ${project_slug}" >&2
  exit 1
fi

project_scopes=()
while IFS= read -r scope; do
  [ -n "${scope}" ] || continue
  project_scopes+=("${scope}")
done < <(project_registry_product_scopes "${project_slug}")

if [ "${#project_scopes[@]}" -eq 0 ]; then
  echo "domain project has no registered scopes: ${project_slug}" >&2
  exit 1
fi

ARTIFACT_DIR="${ROOT_DIR}/artifacts/${project_slug}"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"
export PROJECT_SCOPE="${project_domain}"
export SNOWFLAKE_EDP_DBT_PROJECT="${SNOWFLAKE_EDP_DBT_PROJECT:-$(project_registry_project_name_for_target "${project_slug}" "${dbt_target_name}")}"

database_env_name="$(project_registry_default_database_env "${project_slug}")"
export SNOWFLAKE_EDP_DATABASE="${!database_env_name:-${SNOWFLAKE_EDP_DATABASE}}"

required_vars=(
  SNOWFLAKE_ACCOUNT
  SNOWFLAKE_USER
  SNOWFLAKE_PASSWORD
  SNOWFLAKE_ROLE
  SNOWFLAKE_WAREHOUSE
  SNOWFLAKE_CONTROL_DATABASE
  SNOWFLAKE_CONTROL_SCHEMA
  SNOWFLAKE_DBT_STAGE
  SNOWFLAKE_EDP_DATABASE
  SNOWFLAKE_EDP_IN_SCHEMA
  SNOWFLAKE_EDP_CORE_SCHEMA
  SNOWFLAKE_EDP_ACC_SCHEMA
  SNOWFLAKE_SDP_ORDERS_DATABASE
  SNOWFLAKE_SDP_CUSTOMERS_DATABASE
  SNOWFLAKE_SDP_TAXES_DATABASE
  SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE
  SNOWFLAKE_SDP_IN_SCHEMA
  SNOWFLAKE_SDP_ACC_SCHEMA
  SNOWFLAKE_EDP_DBT_PROJECT
)

for scope in "${project_scopes[@]}"; do
  required_vars+=("$(project_registry_scope_database_env "${upstream_project_slug}" "${scope}")")
  required_vars+=("$(project_registry_scope_database_env "${project_slug}" "${scope}")")
done

for key in "${required_vars[@]}"; do
  if [ -z "${!key:-}" ]; then
    echo "missing required EDP promotion variable: ${key}" >&2
    exit 1
  fi
done

if [ "${SNOWFLAKE_LOCAL_RAW_SYNC:-false}" != "true" ] && {
  [ -z "${OPEN_CATALOG_URI:-}" ] || [ -z "${OPEN_CATALOG_NAME:-}" ] || [ -z "${OPEN_CATALOG_CLIENT_ID:-}" ] || [ -z "${OPEN_CATALOG_CLIENT_SECRET:-}" ];
}; then
  echo "EDP promotion requires either SNOWFLAKE_LOCAL_RAW_SYNC=true or complete OPEN_CATALOG_* configuration" >&2
  exit 1
fi

if [ "${skip_foundation}" != "true" ]; then
  bash "${SCRIPT_DIR}/ensure-snowflake-foundation.sh" | tee "${ARTIFACT_DIR}/snowflake_bootstrap.log"
fi

docker compose run --rm --no-deps -e "PROJECT_SLUG=${project_slug}" dbt-executor python - <<'PY' | tee "${ARTIFACT_DIR}/sdp_contract_check.txt"
import os
import sys

import snowflake.connector


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


project_slug = os.environ["PROJECT_SLUG"]
project_domain = os.environ.get("PROJECT_SCOPE", "").strip().lower()

source_checks = {
    "proj_domain_customer": {
        "customers": (
            "SNOWFLAKE_SDP_CUSTOMERS_DATABASE",
            {
                "T_CUSTOMERS_ENTITY_GRAIN": 12,
                "T_CUSTOMERS_REGION_GRAIN": 3,
                "T_CUSTOMERS_SEGMENT_GRAIN": 3,
            },
        ),
        "taxes": (
            "SNOWFLAKE_SDP_TAXES_DATABASE",
            {
                "T_TAXES_GRAIN": 8,
            },
        ),
    },
    "proj_domain_transactions": {
        "orders": (
            "SNOWFLAKE_SDP_ORDERS_DATABASE",
            {
                "T_ORDERS_ORDER_GRAIN": 30,
                "T_ORDERS_CUSTOMER_GRAIN": 12,
                "T_ORDER_LINES_ORDER_GRAIN": 60,
            },
        ),
        "depot_transactions": (
            "SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE",
            {
                "T_DEPOT_TRANSACTIONS_GRAIN": 18,
            },
        ),
    },
}

if project_slug not in source_checks:
    raise SystemExit(f"unsupported EDP project slug: {project_slug}")

connection = snowflake.connector.connect(
    account=os.environ["SNOWFLAKE_ACCOUNT"],
    user=os.environ["SNOWFLAKE_USER"],
    password=os.environ["SNOWFLAKE_PASSWORD"],
    role=os.environ["SNOWFLAKE_ROLE"],
    warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
)

try:
    with connection.cursor() as cursor:
        for scope, (database_env, tables) in source_checks[project_slug].items():
            source_database = os.environ[database_env]
            for table_name, expected in tables.items():
                try:
                    cursor.execute(
                        f"select count(*) from {ident(source_database, os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], table_name)}"
                    )
                except Exception as exc:  # pragma: no cover - surfaced as process failure
                    raise SystemExit(
                        f"required upstream SDP table is missing for {scope}:{table_name}. Promote the SDP project first. Original error: {exc}"
                    ) from exc
                actual = cursor.fetchone()[0]
                if actual != expected:
                    raise SystemExit(
                        f"expected {expected} rows for upstream {scope}:{table_name}, found {actual}"
                    )
                print(f"upstream_{scope}_{table_name.lower()}={actual}")
finally:
    connection.close()

print("sdp_contract=passed")
PY

if [ "${skip_dbt}" != "true" ]; then
  bash "${SCRIPT_DIR}/deploy-snowflake-dbt-project.sh" \
    "${project_slug}" \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    "${SNOWFLAKE_EDP_DATABASE}" \
    "${SNOWFLAKE_EDP_CORE_SCHEMA}" \
    "${dbt_target_name}" | tee "${ARTIFACT_DIR}/dbt_deploy.log"

  bash "${SCRIPT_DIR}/execute-snowflake-dbt-project.sh" \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    parse | tee "${ARTIFACT_DIR}/dbt_parse.log"

  # The upstream source project is vendored as a local dbt package so that
  # ref('<source project>', ...) resolves. Excluding it keeps the domain build
  # inside its own data-product boundary instead of rebuilding and overwriting
  # the source product tables owned by another repository.
  bash "${SCRIPT_DIR}/execute-snowflake-dbt-project.sh" \
    "${SNOWFLAKE_EDP_DBT_PROJECT}" \
    build --exclude "package:${upstream_project_slug}" | tee "${ARTIFACT_DIR}/dbt_build.log"
fi

docker compose run --rm --no-deps -e "PROJECT_SLUG=${project_slug}" dbt-executor python - <<'PY' | tee "${ARTIFACT_DIR}/snowflake_validation.txt"
import os

import snowflake.connector


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


project_slug = os.environ["PROJECT_SLUG"]

queries_by_project = {
    "proj_domain_customer": {
        "edp_in_customers_entity_grain": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_CUSTOMERS_ENTITY_GRAIN')}",
            12,
        ),
        "edp_in_customers_region_grain": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_CUSTOMERS_REGION_GRAIN')}",
            3,
        ),
        "edp_in_customers_segment_grain": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_CUSTOMERS_SEGMENT_GRAIN')}",
            3,
        ),
        "edp_core_dim_regions": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'DIM_REGIONS')}",
            3,
        ),
        "edp_core_dim_segments": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'DIM_SEGMENTS')}",
            3,
        ),
        "edp_core_customers_3nf": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'T_CUSTOMERS_3NF')}",
            12,
        ),
        "edp_fact_customer_value_star": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'FCT_CUSTOMER_VALUE_STAR')}",
            12,
        ),
        "edp_access_customers_only": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_CUSTOMERS_ONLY')}",
            12,
        ),
        "edp_access_customers_complete": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_CUSTOMERS_COMPLETE')}",
            12,
        ),
        "edp_access_customers_high_value": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_CUSTOMERS_HIGH_VALUE')}",
            4,
        ),
        "edp_in_taxes_grain": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_TAXES_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_TAXES_GRAIN')}",
            8,
        ),
        "edp_core_taxes_3nf": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_TAXES_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'T_TAXES_3NF')}",
            8,
        ),
        "edp_access_taxes_only": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_TAXES_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_TAXES_ONLY')}",
            8,
        ),
    },
    "proj_domain_transactions": {
        "edp_in_orders_order_grain": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_ORDERS_ORDER_GRAIN')}",
            30,
        ),
        "edp_in_orders_customer_grain": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_ORDERS_CUSTOMER_GRAIN')}",
            12,
        ),
        "edp_in_order_lines_order_grain": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_ORDER_LINES_ORDER_GRAIN')}",
            60,
        ),
        "edp_core_dim_customers": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'DIM_CUSTOMERS')}",
            12,
        ),
        "edp_core_dim_order_status": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'DIM_ORDER_STATUS')}",
            3,
        ),
        "edp_core_orders_3nf": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'T_ORDERS_3NF')}",
            30,
        ),
        "edp_fact_order_revenue_star": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'FCT_ORDER_REVENUE_STAR')}",
            30,
        ),
        "edp_access_orders_only": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_ORDERS_ONLY')}",
            30,
        ),
        "edp_access_orders_complete": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_ORDERS_COMPLETE')}",
            30,
        ),
        "edp_access_orders_fulfilled": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_ORDERS_FULFILLED')}",
            20,
        ),
        "edp_in_depot_transactions_grain": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE'], os.environ['SNOWFLAKE_EDP_IN_SCHEMA'], 'V_IN_DEPOT_TRANSACTIONS_GRAIN')}",
            18,
        ),
        "edp_core_depot_transactions_3nf": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE'], os.environ['SNOWFLAKE_EDP_CORE_SCHEMA'], 'T_DEPOT_TRANSACTIONS_3NF')}",
            18,
        ),
        "edp_access_depot_transactions_only": (
            f"select count(*) from {ident(os.environ['SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE'], os.environ['SNOWFLAKE_EDP_ACC_SCHEMA'], 'T_DEPOT_TRANSACTIONS_ONLY')}",
            18,
        ),
    },
}

if project_slug not in queries_by_project:
    raise SystemExit(f"unsupported EDP project slug: {project_slug}")

connection = snowflake.connector.connect(
    account=os.environ["SNOWFLAKE_ACCOUNT"],
    user=os.environ["SNOWFLAKE_USER"],
    password=os.environ["SNOWFLAKE_PASSWORD"],
    role=os.environ["SNOWFLAKE_ROLE"],
    warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
)

try:
    with connection.cursor() as cursor:
        for name, (sql, expected) in queries_by_project[project_slug].items():
            cursor.execute(sql)
            actual = cursor.fetchone()[0]
            if actual != expected:
                raise SystemExit(f"expected {expected} rows for {name}, found {actual}")
            print(f"{name}={actual}")
finally:
    connection.close()

print("edp_promotion=passed")
PY

domain_label="$(printf '%s' "${project_domain}" | tr '_' ' ' )"
cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
EDP ${domain_label} promotion succeeded.
snowflake.edp_dbt_project=${SNOWFLAKE_EDP_DBT_PROJECT}
snowflake.dbt_target=${dbt_target_name}
EOF
