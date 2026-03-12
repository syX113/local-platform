from __future__ import annotations

from datetime import datetime
import os

from airflow import DAG
from airflow.operators.empty import EmptyOperator
from airflow.operators.python import PythonOperator, ShortCircuitOperator
from airflow.providers.docker.operators.docker import DockerOperator

from platform_support import docker_environment, seed_source_postgres as seed_source_postgres_callable, snowflake_configured


DEFAULT_DAG_ID = "local_platform_ingest"
DEFAULT_DESCRIPTION = (
    "Seeds PostgreSQL sample data, writes Iceberg tables to object storage, mirrors "
    "the source inbound layer into Snowflake for local mode, and triggers the source "
    "dbt project inside Snowflake."
)
DEFAULT_TAGS = ["local-platform", "postgres", "dlt", "dbt", "snowflake"]


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

        deploy_snowflake_sdp_dbt_project = DockerOperator(
            task_id="deploy_snowflake_sdp_dbt_project",
            image=runtime_environment.get(
                "SNOW_DBT_RUNNER_IMAGE",
                runtime_environment.get("DBT_RUNNER_IMAGE", "local-platform/dbt-executor:dev"),
            ),
            docker_url=os.environ.get("DOCKER_URL", "unix:///var/run/docker.sock"),
            command=[
                "bash",
                "-lc",
                (
                    "python /opt/platform/dbt/scripts/ensure_target_databases.py source && "
                    "python /opt/platform/dbt/scripts/snow_dbt_cli.py "
                    f"deploy --project-dir /opt/platform/dbt/projects/proj_source_finnova "
                    f"--project-name {runtime_environment.get('SNOWFLAKE_SDP_DBT_PROJECT', 'DBT_PROJECT_SOURCE_FINNOVA')} "
                    f"--database {runtime_environment.get('SNOWFLAKE_SDP_DATABASE', 'DB_SDP_ORDERS')} "
                    f"--schema {runtime_environment.get('SNOWFLAKE_SDP_CORE_SCHEMA', 'CORE')} "
                    f"--target-name {runtime_environment.get('SNOW_DBT_TARGET_NAME', 'dev')}"
                ),
            ],
            network_mode=os.environ.get("PLATFORM_DOCKER_NETWORK", "local-platform-net"),
            mount_tmp_dir=False,
            auto_remove="force",
            tty=True,
            environment=runtime_environment,
        )

        run_dbt = DockerOperator(
            task_id="run_snowflake_sdp_dbt_build",
            image=runtime_environment.get(
                "SNOW_DBT_RUNNER_IMAGE",
                runtime_environment.get("DBT_RUNNER_IMAGE", "local-platform/dbt-executor:dev"),
            ),
            docker_url=os.environ.get("DOCKER_URL", "unix:///var/run/docker.sock"),
            command=(
                "python /opt/platform/dbt/scripts/snow_dbt_cli.py "
                f"execute --project-name {runtime_environment.get('SNOWFLAKE_SDP_DBT_PROJECT', 'DBT_PROJECT_SOURCE_FINNOVA')} build"
            ),
            network_mode=os.environ.get("PLATFORM_DOCKER_NETWORK", "local-platform-net"),
            mount_tmp_dir=False,
            auto_remove="force",
            tty=True,
            environment=runtime_environment,
        )

        finish = EmptyOperator(task_id="finish")

        start >> seed_source_postgres_task >> run_dlt >> check_snowflake >> sync_snowflake_raw >> deploy_snowflake_sdp_dbt_project >> run_dbt >> finish

    return dag
