from __future__ import annotations

import os
from datetime import UTC, datetime
from typing import Any

import dlt
from pyiceberg.exceptions import NoSuchTableError
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL

from runtime_patch import patch_pyiceberg_catalog_loading


patch_pyiceberg_catalog_loading()


def source_database_url() -> str:
    explicit_url = os.environ.get("SOURCE_POSTGRES_SQLALCHEMY_URL")
    if explicit_url:
        return explicit_url

    return URL.create(
        drivername="postgresql+psycopg2",
        username=os.environ["SOURCE_POSTGRES_USER"],
        password=os.environ["SOURCE_POSTGRES_PASSWORD"],
        host=os.environ.get("SOURCE_POSTGRES_HOST", "source-postgres-db"),
        port=int(os.environ.get("SOURCE_POSTGRES_PORT", "5432")),
        database=os.environ["SOURCE_POSTGRES_DB"],
    ).render_as_string(hide_password=False)


def fetch_rows(query: str, parameters: dict[str, object] | None = None) -> list[dict[str, Any]]:
    engine = create_engine(source_database_url())
    try:
        with engine.connect() as connection:
            result = connection.execute(text(query), parameters or {})
            return [dict(row) for row in result.mappings()]
    finally:
        engine.dispose()


def reset_sql_catalog_tables(dataset_name: str, table_names: tuple[str, ...]) -> None:
    from dlt.common.libs.pyiceberg import get_catalog

    catalog = get_catalog()
    for table_name in table_names:
        try:
            catalog.drop_table(f"{dataset_name}.{table_name}")
        except NoSuchTableError:
            continue


def current_load_batch(prefix: str = "postgres-seed") -> str:
    return datetime.now(UTC).strftime(f"{prefix}-%Y%m%dT%H%M%SZ")


def run_filesystem_pipeline(
    *,
    default_pipeline_name: str,
    default_dataset_name: str,
    table_names: tuple[str, ...],
    resources: list[Any],
) -> None:
    pipeline_name = os.environ.get("DLT_PIPELINE_NAME", default_pipeline_name)
    dataset_name = os.environ.get("ICEBERG_NAMESPACE", default_dataset_name)
    refresh_mode = os.environ.get("DLT_REFRESH_MODE") or None

    pipeline = dlt.pipeline(
        pipeline_name=pipeline_name,
        destination="filesystem",
        dataset_name=dataset_name,
    )

    run_kwargs: dict[str, object] = {"table_format": "iceberg"}
    if refresh_mode:
        if os.environ.get("ICEBERG_CATALOG_TYPE", "sql") == "sql":
            reset_sql_catalog_tables(dataset_name, table_names)
        run_kwargs["refresh"] = refresh_mode

    load_info = pipeline.run(resources, **run_kwargs)
    print(load_info)
