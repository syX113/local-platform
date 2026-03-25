from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import shutil
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
DLT_RUNTIME_PYTHON = Path("/home/airflow/dlt-runtime/bin/python")
DBT_RUNTIME_PYTHON = Path("/home/airflow/dbt-runtime/bin/python")
DEFAULT_SOURCE_SQL_FILES = [
    SOURCE_SQL_DIR / "01-create-source-schema.sql",
    SOURCE_SQL_DIR / "02-seed-sample-data.sql",
]
DLT_ENTRYPOINT_ROOT = Path("/opt/platform")


def _is_dlt_script(script_path: str) -> bool:
    return "dlt" in Path(script_path).parts


def _build_dlt_secrets_toml() -> str:
    object_store_bucket = os.environ["OBJECT_STORE_BUCKET"]
    object_store_access_key_id = os.environ["OBJECT_STORE_ACCESS_KEY_ID"]
    object_store_secret_access_key = os.environ["OBJECT_STORE_SECRET_ACCESS_KEY"]
    object_store_endpoint_url = os.environ["OBJECT_STORE_ENDPOINT_URL"]
    object_store_region = os.environ["OBJECT_STORE_REGION"]
    object_store_use_ssl = os.environ.get("OBJECT_STORE_USE_SSL", "false")
    iceberg_catalog_name = os.environ["ICEBERG_CATALOG_NAME"]
    iceberg_catalog_type = os.environ["ICEBERG_CATALOG_TYPE"]

    lines = [
        "[destination.filesystem]",
        f'bucket_url = "{object_store_bucket}"',
        "",
        "[destination.filesystem.credentials]",
        f'aws_access_key_id = "{object_store_access_key_id}"',
        f'aws_secret_access_key = "{object_store_secret_access_key}"',
        f'endpoint_url = "{object_store_endpoint_url}"',
        f'region_name = "{object_store_region}"',
        "",
        "[destination.filesystem.kwargs]",
        f"use_ssl = {object_store_use_ssl}",
        "",
        "[iceberg_catalog]",
        f'iceberg_catalog_name = "{iceberg_catalog_name}"',
        f'iceberg_catalog_type = "{iceberg_catalog_type}"',
        "",
    ]

    if iceberg_catalog_type == "rest":
        lines.extend(
            [
                "[iceberg_catalog.iceberg_catalog_config]",
                f'uri = "{os.environ["OPEN_CATALOG_URI"]}"',
                'type = "rest"',
                f'warehouse = "{os.environ["OPEN_CATALOG_NAME"]}"',
                f'credential = "{os.environ["OPEN_CATALOG_CLIENT_ID"]}:{os.environ["OPEN_CATALOG_CLIENT_SECRET"]}"',
                f'scope = "{os.environ["OPEN_CATALOG_SCOPE"]}"',
                f'header.X-Iceberg-Access-Delegation = "{os.environ["OPEN_CATALOG_ACCESS_DELEGATION"]}"',
                'py-io-impl = "pyiceberg.io.pyarrow.PyArrowFileIO"',
                f'client.access-key-id = "{object_store_access_key_id}"',
                f'client.secret-access-key = "{object_store_secret_access_key}"',
                f'client.region = "{object_store_region}"',
                f's3.endpoint = "{object_store_endpoint_url}"',
                f's3.access-key-id = "{object_store_access_key_id}"',
                f's3.secret-access-key = "{object_store_secret_access_key}"',
                f's3.region = "{object_store_region}"',
                "s3.force-virtual-addressing = false",
                "",
            ]
        )
    else:
        lines.extend(
            [
                "[iceberg_catalog.iceberg_catalog_config]",
                'type = "sql"',
                f'uri = "{os.environ["ICEBERG_SQL_URI"]}"',
                f'warehouse = "{object_store_bucket}"',
                'py-io-impl = "pyiceberg.io.pyarrow.PyArrowFileIO"',
                f'client.access-key-id = "{object_store_access_key_id}"',
                f'client.secret-access-key = "{object_store_secret_access_key}"',
                f'client.region = "{object_store_region}"',
                f's3.endpoint = "{object_store_endpoint_url}"',
                f's3.access-key-id = "{object_store_access_key_id}"',
                f's3.secret-access-key = "{object_store_secret_access_key}"',
                f's3.region = "{object_store_region}"',
                "s3.force-virtual-addressing = false",
                "",
            ]
        )

    return "\n".join(lines)


def _prepare_dlt_runtime_root() -> Path:
    runtime_root = Path(tempfile.mkdtemp(prefix="local-platform-dlt-"))
    dlt_dir = runtime_root / ".dlt"
    dlt_dir.mkdir(parents=True, exist_ok=True)
    (dlt_dir / "secrets.toml").write_text(_build_dlt_secrets_toml(), encoding="utf-8")
    return runtime_root


def _run_subprocess(command: list[str], *, env: dict[str, str], cwd: str | None = None) -> None:
    completed = subprocess.run(command, check=False, env=env, cwd=cwd)
    if completed.returncode != 0:
        raise SystemExit(completed.returncode)


def python_interpreter_for_script(script_path: str) -> str:
    script = Path(script_path)
    if "dlt" in script.parts and DLT_RUNTIME_PYTHON.exists():
        return str(DLT_RUNTIME_PYTHON)
    if "dbt" in script.parts and DBT_RUNTIME_PYTHON.exists():
        return str(DBT_RUNTIME_PYTHON)
    return sys.executable


def python_runtime_bin_dir(script_path: str) -> Path | None:
    script = Path(script_path)
    if "dlt" in script.parts and DLT_RUNTIME_PYTHON.exists():
        return DLT_RUNTIME_PYTHON.parent
    if "dbt" in script.parts and DBT_RUNTIME_PYTHON.exists():
        return DBT_RUNTIME_PYTHON.parent
    return None


def docker_environment(overrides: dict[str, str] | None = None) -> dict[str, str]:
    env = {key: value for key in ENV_KEYS if (value := os.environ.get(key))}
    if overrides:
        env.update(overrides)
    return env


def run_python_script(
    script_path: str,
    *,
    runtime_overrides: dict[str, str] | None = None,
    args: list[str] | None = None,
    cwd: str | None = None,
) -> None:
    command = [python_interpreter_for_script(script_path), script_path, *(args or [])]
    env = os.environ.copy()
    env.update(docker_environment(runtime_overrides))
    runtime_bin_dir = python_runtime_bin_dir(script_path)
    if runtime_bin_dir is not None:
        env["PATH"] = f"{runtime_bin_dir}:{env.get('PATH', '')}"
    if _is_dlt_script(script_path):
        runtime_root = _prepare_dlt_runtime_root()
        dlt_env = env.copy()
        dlt_env["HOME"] = str(runtime_root)
        dlt_env["PYTHONUNBUFFERED"] = dlt_env.get("PYTHONUNBUFFERED", "1")
        try:
            if Path(script_path).name != "init_catalog.py":
                init_catalog_script = str(DLT_ENTRYPOINT_ROOT / "dlt" / "init_catalog.py")
                _run_subprocess(
                    [python_interpreter_for_script(init_catalog_script), init_catalog_script],
                    env=dlt_env,
                    cwd=str(runtime_root),
                )
            _run_subprocess(command, env=dlt_env, cwd=str(runtime_root))
        finally:
            shutil.rmtree(runtime_root, ignore_errors=True)
        return

    subprocess.run(command, check=True, env=env, cwd=cwd)


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
