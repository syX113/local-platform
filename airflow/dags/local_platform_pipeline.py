from __future__ import annotations

from datetime import datetime

from airflow import DAG
from airflow.operators.empty import EmptyOperator
from airflow.operators.python import PythonOperator, ShortCircuitOperator

from platform_support import (
    docker_environment,
    run_python_script,
    seed_source_postgres as seed_source_postgres_callable,
    snowflake_configured,
)


DEFAULT_DAG_ID = "local_platform_ingest"
DEFAULT_DESCRIPTION = (
    "Seeds PostgreSQL sample data, writes Iceberg tables to object storage, mirrors "
    "the source inbound layer into Snowflake for local mode, and executes the source "
    "dbt project directly from the Airflow runtime."
)
DEFAULT_TAGS = ["local-platform", "postgres", "dlt", "dbt", "snowflake"]


def python_script_task(
    *,
    task_id: str,
    script_path: str,
    runtime_environment: dict[str, str],
    args: list[str] | None = None,
) -> PythonOperator:
    return PythonOperator(
        task_id=task_id,
        python_callable=run_python_script,
        op_kwargs={
            "script_path": script_path,
            "runtime_overrides": runtime_environment,
            **({"args": args} if args else {}),
        },
    )


def build_ingest_dag(
    *,
    dag_id: str = DEFAULT_DAG_ID,
    description: str = DEFAULT_DESCRIPTION,
    runtime_overrides: dict[str, str] | None = None,
    tags: list[str] | None = None,
) -> DAG:
    runtime_environment = docker_environment(runtime_overrides or {})
    dlt_script_path = runtime_environment.get("DLT_SCRIPT_PATH", "/opt/platform/dlt/pipeline_orders.py")
    raw_sync_scope = runtime_environment.get("SNOWFLAKE_RAW_SYNC_SCOPE", "").strip().lower()
    sdp_dbt_select = runtime_environment.get("SNOWFLAKE_SDP_DBT_SELECT", "").strip()
    dbt_project_name = runtime_environment.get("SNOWFLAKE_SDP_DBT_PROJECT", "DBT_PROJECT_SOURCE_FINNOVA")

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

        run_dlt = python_script_task(
            task_id="run_dlt_pipeline",
            script_path=dlt_script_path,
            runtime_environment=runtime_environment,
        )

        check_snowflake = ShortCircuitOperator(
            task_id="check_snowflake_configuration",
            python_callable=snowflake_configured,
        )

        sync_snowflake_raw = python_script_task(
            task_id="sync_snowflake_raw_tables",
            script_path="/opt/platform/dlt/snowflake_raw_sync.py",
            runtime_environment={
                **runtime_environment,
                **({"RAW_SYNC_SCOPE": raw_sync_scope} if raw_sync_scope else {}),
            },
        )

        deploy_snowflake_sdp_dbt_project = python_script_task(
            task_id="deploy_snowflake_sdp_dbt_project",
            script_path="/opt/platform/dbt/scripts/snow_dbt_cli.py",
            runtime_environment=runtime_environment,
            args=[
                "deploy",
                "--project-dir",
                "/opt/platform/dbt/projects/proj_source_finnova",
                "--project-name",
                dbt_project_name,
                "--database",
                runtime_environment.get("SNOWFLAKE_SDP_DATABASE", "DB_SDP_ORDERS"),
                "--schema",
                runtime_environment.get("SNOWFLAKE_SDP_CORE_SCHEMA", "CORE"),
                "--target-name",
                runtime_environment.get("SNOW_DBT_TARGET_NAME", "dev"),
            ],
        )

        run_dbt = python_script_task(
            task_id="run_snowflake_sdp_dbt_build",
            script_path="/opt/platform/dbt/scripts/snow_dbt_cli.py",
            runtime_environment=runtime_environment,
            args=[
                "execute",
                "--project-name",
                dbt_project_name,
                "build",
                *(
                    ["--select", sdp_dbt_select]
                    if sdp_dbt_select
                    else []
                ),
            ],
        )

        finish = EmptyOperator(task_id="finish")

        start >> seed_source_postgres_task >> run_dlt >> check_snowflake >> sync_snowflake_raw >> deploy_snowflake_sdp_dbt_project >> run_dbt >> finish

    return dag
