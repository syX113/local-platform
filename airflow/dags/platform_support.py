from __future__ import annotations

import os
from pathlib import Path

import psycopg2


ENV_KEYS = [
    "PLATFORM_DOCKER_NETWORK",
    "MINIO_ROOT_USER",
    "MINIO_ROOT_PASSWORD",
    "MINIO_BUCKET",
    "MINIO_PREFIX",
    "MINIO_ENDPOINT",
    "MINIO_PUBLIC_ENDPOINT",
    "MINIO_USE_SSL",
    "MINIO_REGION",
    "OBJECT_STORE_TYPE",
    "OBJECT_STORE_BUCKET",
    "OBJECT_STORE_ACCESS_KEY_ID",
    "OBJECT_STORE_SECRET_ACCESS_KEY",
    "OBJECT_STORE_ENDPOINT_URL",
    "OBJECT_STORE_REGION",
    "OBJECT_STORE_USE_SSL",
    "DLT_PIPELINE_NAME",
    "DLT_REFRESH_MODE",
    "ICEBERG_CATALOG_NAME",
    "ICEBERG_NAMESPACE",
    "ICEBERG_CATALOG_TYPE",
    "ICEBERG_SQL_URI",
    "SOURCE_POSTGRES_HOST",
    "SOURCE_POSTGRES_PORT",
    "SOURCE_POSTGRES_DB",
    "SOURCE_POSTGRES_USER",
    "SOURCE_POSTGRES_PASSWORD",
    "SOURCE_POSTGRES_SCHEMA",
    "OPEN_CATALOG_URI",
    "OPEN_CATALOG_NAME",
    "OPEN_CATALOG_CLIENT_ID",
    "OPEN_CATALOG_CLIENT_SECRET",
    "OPEN_CATALOG_SCOPE",
    "OPEN_CATALOG_ACCESS_DELEGATION",
    "SNOWFLAKE_ACCOUNT",
    "SNOWFLAKE_USER",
    "SNOWFLAKE_PASSWORD",
    "SNOWFLAKE_ROLE",
    "SNOWFLAKE_WAREHOUSE",
    "SNOWFLAKE_CONTROL_DATABASE",
    "SNOWFLAKE_CONTROL_SCHEMA",
    "SNOWFLAKE_DBT_STAGE",
    "SNOWFLAKE_SDP_DATABASE",
    "SNOWFLAKE_SDP_CUSTOMERS_DATABASE",
    "SNOWFLAKE_SDP_IN_SCHEMA",
    "SNOWFLAKE_SDP_CORE_SCHEMA",
    "SNOWFLAKE_SDP_ACC_SCHEMA",
    "SNOWFLAKE_SDP_DBT_PROJECT",
    "SNOWFLAKE_EDP_DATABASE",
    "SNOWFLAKE_EDP_CUSTOMERS_DATABASE",
    "SNOWFLAKE_EDP_IN_SCHEMA",
    "SNOWFLAKE_EDP_CORE_SCHEMA",
    "SNOWFLAKE_EDP_ACC_SCHEMA",
    "SNOWFLAKE_EDP_DBT_PROJECT",
    "SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT",
    "SNOW_DBT_TARGET_NAME",
    "SNOWFLAKE_CATALOG_INTEGRATION",
    "SNOWFLAKE_CLONE_SCHEMA",
    "SNOWFLAKE_LOCAL_RAW_SYNC",
    "DBT_THREADS",
    "DLT_RUNNER_IMAGE",
    "DBT_RUNNER_IMAGE",
    "SNOW_DBT_RUNNER_IMAGE",
]

SOURCE_SQL_DIR = Path("/opt/platform/postgres/source-init")
DEFAULT_SOURCE_SQL_FILES = [
    SOURCE_SQL_DIR / "01-create-source-schema.sql",
    SOURCE_SQL_DIR / "02-seed-sample-data.sql",
]


def docker_environment(overrides: dict[str, str] | None = None) -> dict[str, str]:
    env = {key: value for key in ENV_KEYS if (value := os.environ.get(key))}
    if overrides:
        env.update(overrides)
    return env


def snowflake_configured() -> bool:
    required = [
        "SNOWFLAKE_ACCOUNT",
        "SNOWFLAKE_USER",
        "SNOWFLAKE_PASSWORD",
        "SNOWFLAKE_SDP_DATABASE",
        "SNOWFLAKE_SDP_CUSTOMERS_DATABASE",
    ]
    return all(os.environ.get(key) for key in required)


def seed_source_postgres(sql_files: list[Path] | None = None) -> None:
    sql_paths = sql_files or DEFAULT_SOURCE_SQL_FILES

    with psycopg2.connect(
        host=os.environ.get("SOURCE_POSTGRES_HOST", "source-postgres-db"),
        port=os.environ.get("SOURCE_POSTGRES_PORT", "5432"),
        dbname=os.environ["SOURCE_POSTGRES_DB"],
        user=os.environ["SOURCE_POSTGRES_USER"],
        password=os.environ["SOURCE_POSTGRES_PASSWORD"],
    ) as connection:
        with connection.cursor() as cursor:
            for sql_file in sql_paths:
                cursor.execute(sql_file.read_text(encoding="utf-8"))

        with connection.cursor() as cursor:
            cursor.execute(
                """
                select
                  (select count(*) from customers) as customer_count,
                  (select count(*) from orders) as order_count,
                  (select count(*) from order_items) as order_item_count
                """
            )
            counts = cursor.fetchone()

    print(
        {
            "customers": counts[0],
            "orders": counts[1],
            "order_items": counts[2],
        }
    )
