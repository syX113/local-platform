from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path

import psycopg2
from airflow import DAG
from airflow.operators.empty import EmptyOperator
from airflow.operators.python import PythonOperator, ShortCircuitOperator
from airflow.providers.docker.operators.docker import DockerOperator


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
    "SNOWFLAKE_SDP_DATABASE",
    "SNOWFLAKE_SDP_IN_SCHEMA",
    "SNOWFLAKE_SDP_CORE_SCHEMA",
    "SNOWFLAKE_SDP_ACC_SCHEMA",
    "SNOWFLAKE_EDP_DATABASE",
    "SNOWFLAKE_EDP_IN_SCHEMA",
    "SNOWFLAKE_EDP_CORE_SCHEMA",
    "SNOWFLAKE_EDP_ACC_SCHEMA",
    "SNOWFLAKE_CATALOG_INTEGRATION",
    "SNOWFLAKE_CLONE_SCHEMA",
    "SNOWFLAKE_LOCAL_RAW_SYNC",
    "DBT_THREADS",
]

SOURCE_SQL_DIR = Path("/opt/platform/postgres/source-init")


def _env() -> dict[str, str]:
    return {key: value for key in ENV_KEYS if (value := os.environ.get(key))}


def _should_run_dbt() -> bool:
    required = [
        "SNOWFLAKE_ACCOUNT",
        "SNOWFLAKE_USER",
        "SNOWFLAKE_PASSWORD",
        "SNOWFLAKE_SDP_DATABASE",
        "SNOWFLAKE_EDP_DATABASE",
    ]
    return all(os.environ.get(key) for key in required)


def _seed_source_postgres() -> None:
    sql_files = [
        SOURCE_SQL_DIR / "01-create-source-schema.sql",
        SOURCE_SQL_DIR / "02-seed-sample-data.sql",
    ]

    with psycopg2.connect(
        host=os.environ.get("SOURCE_POSTGRES_HOST", "source-postgres-db"),
        port=os.environ.get("SOURCE_POSTGRES_PORT", "5432"),
        dbname=os.environ["SOURCE_POSTGRES_DB"],
        user=os.environ["SOURCE_POSTGRES_USER"],
        password=os.environ["SOURCE_POSTGRES_PASSWORD"],
    ) as connection:
        with connection.cursor() as cursor:
            for sql_file in sql_files:
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


with DAG(
    dag_id="local_platform_ingest",
    description="Seeds PostgreSQL sample data, writes Iceberg tables to object storage, mirrors source data product landing tables into Snowflake for local mode, and runs dbt in an external container to build the SDP and EDP layers.",
    schedule=None,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["local-platform", "postgres", "dlt", "dbt", "snowflake"],
) as dag:
    start = EmptyOperator(task_id="start")

    seed_source_postgres = PythonOperator(
        task_id="seed_source_postgres",
        python_callable=_seed_source_postgres,
    )

    run_dlt = DockerOperator(
        task_id="run_dlt_pipeline",
        image=os.environ.get("DLT_RUNNER_IMAGE", "local-platform/dlt-extractor:dev"),
        docker_url=os.environ.get("DOCKER_URL", "unix:///var/run/docker.sock"),
        command="python /opt/platform/dlt/pipeline.py",
        network_mode=os.environ.get("PLATFORM_DOCKER_NETWORK", "local-platform-net"),
        mount_tmp_dir=False,
        auto_remove="force",
        tty=True,
        environment=_env(),
    )

    check_snowflake = ShortCircuitOperator(
        task_id="check_snowflake_configuration",
        python_callable=_should_run_dbt,
    )

    sync_snowflake_raw = DockerOperator(
        task_id="sync_snowflake_raw_tables",
        image=os.environ.get("DLT_RUNNER_IMAGE", "local-platform/dlt-extractor:dev"),
        docker_url=os.environ.get("DOCKER_URL", "unix:///var/run/docker.sock"),
        command="python /opt/platform/dlt/snowflake_raw_sync.py",
        network_mode=os.environ.get("PLATFORM_DOCKER_NETWORK", "local-platform-net"),
        mount_tmp_dir=False,
        auto_remove="force",
        tty=True,
        environment=_env(),
    )

    run_dbt = DockerOperator(
        task_id="run_external_dbt_build",
        image=os.environ.get("DBT_RUNNER_IMAGE", "local-platform/dbt-executor:dev"),
        docker_url=os.environ.get("DOCKER_URL", "unix:///var/run/docker.sock"),
        command=(
            "dbt build --project-dir /opt/platform/dbt "
            "--profiles-dir /opt/platform/dbt/profiles"
        ),
        network_mode=os.environ.get("PLATFORM_DOCKER_NETWORK", "local-platform-net"),
        mount_tmp_dir=False,
        auto_remove="force",
        tty=True,
        environment=_env(),
    )

    finish = EmptyOperator(task_id="finish")

    start >> seed_source_postgres >> run_dlt >> check_snowflake >> sync_snowflake_raw >> run_dbt >> finish
