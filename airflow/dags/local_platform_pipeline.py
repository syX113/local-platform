from __future__ import annotations

import os
from datetime import datetime

from airflow import DAG
from airflow.operators.empty import EmptyOperator
from airflow.operators.python import PythonOperator, ShortCircuitOperator
from airflow.providers.docker.operators.docker import DockerOperator

from platform_support import docker_environment, seed_source_postgres as seed_source_postgres_callable, snowflake_configured


DEFAULT_DAG_ID = "local_platform_ingest"
DEFAULT_DESCRIPTION = (
    "Seeds PostgreSQL sample data, writes Iceberg tables to object storage, mirrors "
    "the SDP inbound layer into Snowflake for local mode, and runs the SDP dbt "
    "project in an external container."
)
DEFAULT_TAGS = ["local-platform", "postgres", "dlt", "dbt", "snowflake"]


def resolve_sdp_dbt_project_dir() -> str:
    nested_project_dir = "/opt/platform/dbt/projects/proj_sdp_orders"
    if os.path.exists(f"{nested_project_dir}/dbt_project.yml"):
        return nested_project_dir
    return "/opt/platform/dbt"


def build_ingest_dag(
    *,
    dag_id: str = DEFAULT_DAG_ID,
    description: str = DEFAULT_DESCRIPTION,
    runtime_overrides: dict[str, str] | None = None,
    tags: list[str] | None = None,
) -> DAG:
    runtime_environment = docker_environment(runtime_overrides or {})

    with DAG(
        dag_id=dag_id,
        description=description,
        schedule=None,
        start_date=datetime(2024, 1, 1),
        catchup=False,
        tags=tags or DEFAULT_TAGS,
    ) as dag:
        start = EmptyOperator(task_id="start")

        seed_source_postgres_task = PythonOperator(
            task_id="seed_source_postgres",
            python_callable=seed_source_postgres_callable,
        )

        run_dlt = DockerOperator(
            task_id="run_dlt_pipeline",
            image=runtime_environment.get("DLT_RUNNER_IMAGE", "local-platform/dlt-extractor:dev"),
            docker_url=os.environ.get("DOCKER_URL", "unix:///var/run/docker.sock"),
            command="python /opt/platform/dlt/pipeline.py",
            network_mode=os.environ.get("PLATFORM_DOCKER_NETWORK", "local-platform-net"),
            mount_tmp_dir=False,
            auto_remove="force",
            tty=True,
            environment=runtime_environment,
        )

        check_snowflake = ShortCircuitOperator(
            task_id="check_snowflake_configuration",
            python_callable=snowflake_configured,
        )

        sync_snowflake_raw = DockerOperator(
            task_id="sync_snowflake_raw_tables",
            image=runtime_environment.get("DLT_RUNNER_IMAGE", "local-platform/dlt-extractor:dev"),
            docker_url=os.environ.get("DOCKER_URL", "unix:///var/run/docker.sock"),
            command="python /opt/platform/dlt/snowflake_raw_sync.py",
            network_mode=os.environ.get("PLATFORM_DOCKER_NETWORK", "local-platform-net"),
            mount_tmp_dir=False,
            auto_remove="force",
            tty=True,
            environment=runtime_environment,
        )

        run_dbt = DockerOperator(
            task_id="run_external_sdp_dbt_build",
            image=runtime_environment.get("DBT_RUNNER_IMAGE", "local-platform/dbt-executor:dev"),
            docker_url=os.environ.get("DOCKER_URL", "unix:///var/run/docker.sock"),
            command=(
                f"dbt build --project-dir {resolve_sdp_dbt_project_dir()} "
                "--profiles-dir /opt/platform/dbt/profiles"
            ),
            network_mode=os.environ.get("PLATFORM_DOCKER_NETWORK", "local-platform-net"),
            mount_tmp_dir=False,
            auto_remove="force",
            tty=True,
            environment=runtime_environment,
        )

        finish = EmptyOperator(task_id="finish")

        start >> seed_source_postgres_task >> run_dlt >> check_snowflake >> sync_snowflake_raw >> run_dbt >> finish

    return dag


dag = build_ingest_dag()
