#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from textwrap import dedent

from scaffold_support import ROOT_DIR, ensure_new_file, require_slug, upper_identifier


REGISTRY_PATH = ROOT_DIR / "snowflake" / "data_products.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Scaffold a new Snowflake SDP/EDP data product and matching dbt promotion pipeline."
    )
    parser.add_argument("slug", help="Product slug, for example finance_orders")
    parser.add_argument("--sdp-database", help="Snowflake database name for the source data product")
    parser.add_argument("--edp-database", help="Snowflake database name for the enterprise data product")
    return parser.parse_args()


def register_data_product_database(key: str, kind: str, database: str) -> None:
    if REGISTRY_PATH.exists():
        payload = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    else:
        payload = {"data_products": []}

    products = payload.setdefault("data_products", [])
    if not isinstance(products, list):
        raise SystemExit(f"invalid data product registry: {REGISTRY_PATH}")

    filtered_products = [
        product
        for product in products
        if not isinstance(product, dict) or product.get("key") != key
    ]
    filtered_products.append({"key": key, "kind": kind, "database": database})
    filtered_products.sort(key=lambda product: str(product.get("key", "")))
    payload["data_products"] = filtered_products
    REGISTRY_PATH.parent.mkdir(parents=True, exist_ok=True)
    REGISTRY_PATH.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    slug = require_slug(args.slug)
    product_prefix = upper_identifier(slug)
    sdp_database = args.sdp_database or f"DB_SDP_{product_prefix}"
    edp_database = args.edp_database or f"DB_EDP_{product_prefix}"

    product_root = ROOT_DIR / "dbt" / "models" / "products" / slug
    verify_script = ROOT_DIR / "scripts" / f"verify-{slug}-dbt-promotion.sh"
    foundation_sql = ROOT_DIR / "snowflake" / "sql" / "products" / f"{slug}_foundation.sql.tpl"
    artifact_dir = f"artifacts/{slug}-dbt"
    source_name = f"{slug}_sdp_inbound"

    ensure_new_file(
        foundation_sql,
        dedent(
            f"""\
            use role "${{SNOWFLAKE_ROLE}}";

            create warehouse if not exists ${{SNOWFLAKE_WAREHOUSE}}
              warehouse_size = 'XSMALL'
              auto_suspend = 60
              auto_resume = true;

            create database if not exists "{sdp_database}";
            create schema if not exists "{sdp_database}"."INBOUND";
            create schema if not exists "{sdp_database}"."CORE";
            create schema if not exists "{sdp_database}"."ACCESS";

            create database if not exists "{edp_database}";
            create schema if not exists "{edp_database}"."INBOUND";
            create schema if not exists "{edp_database}"."CORE";
            create schema if not exists "{edp_database}"."ACCESS";
            """
        ),
    )
    ensure_new_file(
        product_root / "sources.yml",
        dedent(
            f"""\
            version: 2

            sources:
              - name: {source_name}
                database: {sdp_database}
                schema: INBOUND
                tables:
                  - name: EXT_ORDERS_RAW
                  - name: EXT_ORDER_ITEMS_RAW

            models:
              - name: {slug}_sdp_core_orders
                columns:
                  - name: order_id
                    tests:
                      - not_null
                      - unique
                  - name: order_total
                    tests:
                      - not_null
              - name: {slug}_sdp_core_order_items
                columns:
                  - name: order_id
                    tests:
                      - not_null
                  - name: item_id
                    tests:
                      - not_null
              - name: {slug}_edp_core_dim_customers
                columns:
                  - name: customer_sk
                    tests:
                      - not_null
                      - unique
              - name: {slug}_edp_core_dim_order_status
                columns:
                  - name: status_sk
                    tests:
                      - not_null
                      - unique
              - name: {slug}_edp_core_fct_order_revenue_star
                columns:
                  - name: order_id
                    tests:
                      - not_null
                      - unique
                  - name: customer_sk
                    tests:
                      - not_null
                  - name: status_sk
                    tests:
                      - not_null
            """
        ),
    )

    files = {
        product_root / "sdp" / "core" / f"{slug}_sdp_core_orders.sql": dedent(
            f"""\
            {{% config(materialized='view', database='{sdp_database}', schema='CORE', alias='ORDERS') %}}

            select
              cast(order_id as varchar) as order_id,
              cast(customer_id as varchar) as customer_id,
              upper(trim(cast(status as varchar))) as order_status,
              cast(item_count as number(38, 0)) as item_count,
              cast(order_total as number(38, 2)) as order_total,
              case
                when cast(order_total as number(38, 2)) >= 150 then 'HIGH'
                when cast(order_total as number(38, 2)) >= 75 then 'MEDIUM'
                else 'LOW'
              end as order_value_band,
              to_timestamp_ntz(order_created_at) as order_created_at,
              cast(load_batch as varchar) as load_batch
            from {{ source('{source_name}', 'EXT_ORDERS_RAW') }}
            """
        ),
        product_root / "sdp" / "core" / f"{slug}_sdp_core_order_items.sql": dedent(
            f"""\
            {{% config(materialized='view', database='{sdp_database}', schema='CORE', alias='ORDER_ITEMS') %}}

            select
              cast(order_id as varchar) as order_id,
              cast(item_id as varchar) as item_id,
              cast(sku as varchar) as sku,
              cast(quantity as number(38, 0)) as quantity,
              cast(unit_price as number(38, 2)) as unit_price,
              cast(line_total as number(38, 2)) as line_total,
              to_timestamp_ntz(loaded_at) as loaded_at
            from {{ source('{source_name}', 'EXT_ORDER_ITEMS_RAW') }}
            """
        ),
        product_root / "sdp" / "access" / f"{slug}_sdp_acc_orders.sql": dedent(
            f"""\
            {{% config(materialized='view', database='{sdp_database}', schema='ACCESS', alias='ORDERS') %}}

            select
              order_id,
              customer_id,
              order_status,
              item_count,
              order_total,
              order_value_band,
              order_created_at,
              load_batch,
              current_timestamp() as published_at
            from {{ ref('{slug}_sdp_core_orders') }}
            """
        ),
        product_root / "sdp" / "access" / f"{slug}_sdp_acc_order_items.sql": dedent(
            f"""\
            {{% config(materialized='view', database='{sdp_database}', schema='ACCESS', alias='ORDER_ITEMS') %}}

            select
              order_id,
              item_id,
              sku,
              quantity,
              unit_price,
              line_total,
              row_number() over (partition by order_id order by item_id) as line_number,
              loaded_at,
              current_timestamp() as published_at
            from {{ ref('{slug}_sdp_core_order_items') }}
            """
        ),
        product_root / "edp" / "inbound" / f"{slug}_edp_in_orders.sql": dedent(
            f"""\
            {{% config(materialized='view', database='{edp_database}', schema='INBOUND', alias='ORDERS') %}}

            select
              order_id,
              customer_id,
              order_status,
              item_count,
              order_total,
              order_value_band,
              order_created_at,
              load_batch,
              published_at as sdp_published_at
            from {{ ref('{slug}_sdp_acc_orders') }}
            """
        ),
        product_root / "edp" / "inbound" / f"{slug}_edp_in_order_items.sql": dedent(
            f"""\
            {{% config(materialized='view', database='{edp_database}', schema='INBOUND', alias='ORDER_ITEMS') %}}

            select
              order_id,
              item_id,
              sku,
              quantity,
              unit_price,
              line_total,
              line_number,
              loaded_at,
              published_at as sdp_published_at
            from {{ ref('{slug}_sdp_acc_order_items') }}
            """
        ),
        product_root / "edp" / "core" / f"{slug}_edp_core_dim_customers.sql": dedent(
            f"""\
            {{% config(materialized='table', database='{edp_database}', schema='CORE', alias='DIM_CUSTOMERS') %}}

            select
              md5(customer_id) as customer_sk,
              customer_id,
              min(order_created_at) as first_order_at,
              max(order_created_at) as latest_order_at,
              count(*) as order_count
            from {{ ref('{slug}_edp_in_orders') }}
            group by 1, 2
            """
        ),
        product_root / "edp" / "core" / f"{slug}_edp_core_dim_order_status.sql": dedent(
            f"""\
            {{% config(materialized='table', database='{edp_database}', schema='CORE', alias='DIM_ORDER_STATUS') %}}

            select
              md5(order_status) as status_sk,
              order_status,
              count(*) as order_count
            from {{ ref('{slug}_edp_in_orders') }}
            group by 1, 2
            """
        ),
        product_root / "edp" / "core" / f"{slug}_edp_core_fct_order_revenue_star.sql": dedent(
            f"""\
            {{% config(materialized='table', database='{edp_database}', schema='CORE', alias='FCT_ORDER_REVENUE_STAR') %}}

            with orders as (
                select *
                from {{ ref('{slug}_edp_in_orders') }}
            ),
            items as (
                select
                  order_id,
                  sum(line_total) as item_revenue,
                  count(*) as item_rows
                from {{ ref('{slug}_edp_in_order_items') }}
                group by 1
            ),
            dim_customers as (
                select customer_sk, customer_id
                from {{ ref('{slug}_edp_core_dim_customers') }}
            ),
            dim_order_status as (
                select status_sk, order_status
                from {{ ref('{slug}_edp_core_dim_order_status') }}
            )
            select
              orders.order_id,
              dim_customers.customer_sk,
              dim_order_status.status_sk,
              orders.customer_id,
              orders.order_status,
              orders.item_count,
              orders.order_total,
              coalesce(items.item_revenue, 0) as item_revenue,
              coalesce(items.item_rows, 0) as item_rows,
              orders.order_value_band,
              orders.order_created_at,
              orders.load_batch,
              current_timestamp() as modeled_at
            from orders
            left join items using (order_id)
            left join dim_customers
              on orders.customer_id = dim_customers.customer_id
            left join dim_order_status
              on orders.order_status = dim_order_status.order_status
            """
        ),
        product_root / "edp" / "access" / f"{slug}_edp_acc_mv_order_revenue_created.sql": dedent(
            f"""\
            {{% config(materialized='materialized_view', database='{edp_database}', schema='ACCESS', alias='MV_ORDER_REVENUE_CREATED') %}}

            select
              order_id,
              customer_id,
              customer_sk,
              status_sk,
              order_status,
              order_total,
              item_revenue,
              item_rows,
              order_value_band,
              order_created_at
            from {{ ref('{slug}_edp_core_fct_order_revenue_star') }}
            where order_status = 'CREATED'
            """
        ),
        product_root / "edp" / "access" / f"{slug}_edp_acc_mv_order_revenue_fulfilled.sql": dedent(
            f"""\
            {{% config(materialized='materialized_view', database='{edp_database}', schema='ACCESS', alias='MV_ORDER_REVENUE_FULFILLED') %}}

            select
              order_id,
              customer_id,
              customer_sk,
              status_sk,
              order_status,
              order_total,
              item_revenue,
              item_rows,
              order_value_band,
              order_created_at
            from {{ ref('{slug}_edp_core_fct_order_revenue_star') }}
            where order_status in ('PAID', 'SHIPPED')
            """
        ),
    }

    for path, content in files.items():
        ensure_new_file(path, content)

    ensure_new_file(
        verify_script,
        dedent(
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail

            ROOT_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")/.." && pwd)"
            cd "${{ROOT_DIR}}"

            source "${{ROOT_DIR}}/scripts/common.sh"
            ensure_platform_env

            ARTIFACT_DIR="${{ROOT_DIR}}/{artifact_dir}"
            rm -rf "${{ARTIFACT_DIR}}"
            mkdir -p "${{ARTIFACT_DIR}}"

            required_vars=(
              SNOWFLAKE_ACCOUNT
              SNOWFLAKE_USER
              SNOWFLAKE_PASSWORD
              SNOWFLAKE_ROLE
              SNOWFLAKE_WAREHOUSE
            )

            for key in "${{required_vars[@]}}"; do
              if [ -z "${{!key:-}}" ]; then
                echo "missing required dbt promotion variable: ${{key}}" >&2
                exit 1
              fi
            done

            docker compose up -d airflow-metadata-db source-postgres-db lakehouse-object-store
            docker compose run --rm --no-deps lakehouse-bucket-init | tee "${{ARTIFACT_DIR}}/bucket_init.log"
            ./scripts/load-source-sample-data.sh | tee "${{ARTIFACT_DIR}}/source_seed.log"
            bash ./scripts/ensure-snowflake-foundation.sh | tee "${{ARTIFACT_DIR}}/snowflake_bootstrap.log"

            export SNOWFLAKE_SDP_DATABASE="{sdp_database}"
            export SNOWFLAKE_SDP_IN_SCHEMA="INBOUND"
            export SNOWFLAKE_LOCAL_RAW_SYNC="true"
            export SNOWFLAKE_SDP_DBT_PROJECT="DEV_DBT_PROJECT_SDP_{product_prefix}"
            export SNOWFLAKE_EDP_DBT_PROJECT="DEV_DBT_PROJECT_EDP_{product_prefix}"
            export SNOW_DBT_TARGET_NAME="dev"

            docker compose run --rm --no-deps dlt-extractor python /opt/platform/dlt/snowflake_raw_sync.py | tee "${{ARTIFACT_DIR}}/snowflake_raw_sync.log"
            bash ./scripts/deploy-snowflake-dbt-project.sh \\
              proj_sdp_orders \\
              "${{SNOWFLAKE_SDP_DBT_PROJECT}}" \\
              "${{SNOWFLAKE_SDP_DATABASE}}" \\
              "CORE" \\
              "${{SNOW_DBT_TARGET_NAME}}" | tee "${{ARTIFACT_DIR}}/dbt_deploy_sdp.log"
            bash ./scripts/deploy-snowflake-dbt-project.sh \\
              proj_edp_orders \\
              "${{SNOWFLAKE_EDP_DBT_PROJECT}}" \\
              "{edp_database}" \\
              "CORE" \\
              "${{SNOW_DBT_TARGET_NAME}}" | tee "${{ARTIFACT_DIR}}/dbt_deploy_edp.log"
            bash ./scripts/execute-snowflake-dbt-project.sh \\
              "${{SNOWFLAKE_SDP_DBT_PROJECT}}" parse | tee "${{ARTIFACT_DIR}}/dbt_parse_sdp.log"
            bash ./scripts/execute-snowflake-dbt-project.sh \\
              "${{SNOWFLAKE_SDP_DBT_PROJECT}}" build | tee "${{ARTIFACT_DIR}}/dbt_build_sdp.log"
            bash ./scripts/execute-snowflake-dbt-project.sh \\
              "${{SNOWFLAKE_EDP_DBT_PROJECT}}" parse | tee "${{ARTIFACT_DIR}}/dbt_parse_edp.log"
            bash ./scripts/execute-snowflake-dbt-project.sh \\
              "${{SNOWFLAKE_EDP_DBT_PROJECT}}" build | tee "${{ARTIFACT_DIR}}/dbt_build_edp.log"

            docker compose run --rm --no-deps dbt-executor python - <<'PY' | tee "${{ARTIFACT_DIR}}/snowflake_validation.txt"
            import os

            import snowflake.connector

            def ident(*parts: str) -> str:
                return ".".join(f'"{{part}}"' for part in parts)

            queries = {{
                "sdp_ext_raw_orders": (
                    f"select count(*) from {{ident('{sdp_database}', 'INBOUND', 'EXT_ORDERS_RAW')}}",
                    30,
                ),
                "sdp_ext_raw_order_items": (
                    f"select count(*) from {{ident('{sdp_database}', 'INBOUND', 'EXT_ORDER_ITEMS_RAW')}}",
                    60,
                ),
                "sdp_access_orders": (
                    f"select count(*) from {{ident('{sdp_database}', 'ACCESS', 'ORDERS')}}",
                    30,
                ),
                "edp_dim_customers": (
                    f"select count(*) from {{ident('{edp_database}', 'CORE', 'DIM_CUSTOMERS')}}",
                    12,
                ),
                "edp_dim_order_status": (
                    f"select count(*) from {{ident('{edp_database}', 'CORE', 'DIM_ORDER_STATUS')}}",
                    3,
                ),
                "edp_fact_order_revenue_star": (
                    f"select count(*) from {{ident('{edp_database}', 'CORE', 'FCT_ORDER_REVENUE_STAR')}}",
                    30,
                ),
                "edp_mv_order_revenue_created": (
                    f"select count(*) from {{ident('{edp_database}', 'ACCESS', 'MV_ORDER_REVENUE_CREATED')}}",
                    10,
                ),
                "edp_mv_order_revenue_fulfilled": (
                    f"select count(*) from {{ident('{edp_database}', 'ACCESS', 'MV_ORDER_REVENUE_FULFILLED')}}",
                    20,
                ),
            }}

            connection = snowflake.connector.connect(
                account=os.environ["SNOWFLAKE_ACCOUNT"],
                user=os.environ["SNOWFLAKE_USER"],
                password=os.environ["SNOWFLAKE_PASSWORD"],
                role=os.environ["SNOWFLAKE_ROLE"],
                warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
            )

            try:
                with connection.cursor() as cursor:
                    for name, (sql, expected) in queries.items():
                        cursor.execute(sql)
                        actual = cursor.fetchone()[0]
                        if actual != expected:
                            raise SystemExit(f"expected {{expected}} rows for {{name}}, found {{actual}}")
                        print(f"{{name}}={{actual}}")
            finally:
                connection.close()

            print("dbt_promotion=passed")
            PY

            cat > "${{ARTIFACT_DIR}}/summary.txt" <<EOF
            DBT promotion succeeded.
            snowflake.sdp_database={sdp_database}
            snowflake.edp_database={edp_database}
            snowflake.sdp_ext_raw_orders=30
            snowflake.sdp_ext_raw_order_items=60
            snowflake.sdp_access_orders=30
            snowflake.edp_dim_customers=12
            snowflake.edp_dim_order_status=3
            snowflake.edp_fact_order_revenue_star=30
            snowflake.edp_mv_order_revenue_created=10
            snowflake.edp_mv_order_revenue_fulfilled=20
            EOF
            """
        ),
    )
    verify_script.chmod(0o755)

    register_data_product_database(f"sdp_{slug}", "sdp", sdp_database)
    register_data_product_database(f"edp_{slug}", "edp", edp_database)

    print(f"created data product models: {product_root.relative_to(ROOT_DIR)}")
    print(f"created Snowflake foundation SQL: {foundation_sql.relative_to(ROOT_DIR)}")
    print(f"created verification script: {verify_script.relative_to(ROOT_DIR)}")
    print(f"registered Snowflake clone scope in: {REGISTRY_PATH.relative_to(ROOT_DIR)}")
    print("next step: update scripts/render_gitlab_project_repos.py if this data product should be published to GitLab")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
