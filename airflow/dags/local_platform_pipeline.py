from __future__ import annotations

import os
from datetime import datetime

from airflow import DAG
from airflow.operators.empty import EmptyOperator
from airflow.operators.python import PythonOperator, ShortCircuitOperator
from airflow.providers.docker.operators.docker import DockerOperator

from platform_support import docker_environment, seed_source_postgres, snowflake_configured


with DAG(
    dag_id="local_platform_ingest",
    description="Seeds PostgreSQL sample data, writes Iceberg tables to object storage, mirrors the SDP inbound layer into Snowflake for local mode, and runs dbt in an external container to build the SDP and EDP data products.",
    schedule=None,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["local-platform", "postgres", "dlt", "dbt", "snowflake"],
) as dag:
    start = EmptyOperator(task_id="start")

    seed_source_postgres = PythonOperator(
        task_id="seed_source_postgres",
        python_callable=seed_source_postgres,
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
        environment=docker_environment(),
    )

    check_snowflake = ShortCircuitOperator(
        task_id="check_snowflake_configuration",
        python_callable=snowflake_configured,
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
        environment=docker_environment(),
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
        environment=docker_environment(),
    )

    finish = EmptyOperator(task_id="finish")

    start >> seed_source_postgres >> run_dlt >> check_snowflake >> sync_snowflake_raw >> run_dbt >> finish
