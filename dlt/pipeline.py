from __future__ import annotations

import os
from datetime import UTC, datetime
from typing import Any

import dlt
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL
from pyiceberg.exceptions import NoSuchTableError

from runtime_patch import patch_pyiceberg_catalog_loading


patch_pyiceberg_catalog_loading()

ICEBERG_TABLE_NAMES = ("raw_orders", "raw_order_items")


ORDERS_EXPORT_SQL = """
select
  order_id,
  customer_id,
  status,
  item_count,
  order_total,
  order_created_at,
  :load_batch as load_batch
from raw_orders_export
order by order_created_at, order_id
"""

ORDER_ITEMS_EXPORT_SQL = """
select
  order_id,
  item_id,
  sku,
  quantity,
  unit_price,
  line_total,
  loaded_at
from raw_order_items_export
order by order_id, item_id
"""


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


@dlt.resource(name="raw_orders", write_disposition="replace")
def raw_orders(load_batch: str):
    yield from fetch_rows(ORDERS_EXPORT_SQL, {"load_batch": load_batch})


@dlt.resource(name="raw_order_items", write_disposition="replace")
def raw_order_items():
    yield from fetch_rows(ORDER_ITEMS_EXPORT_SQL)


def reset_sql_catalog_tables(dataset_name: str) -> None:
    from dlt.common.libs.pyiceberg import get_catalog

    catalog = get_catalog()
    for table_name in ICEBERG_TABLE_NAMES:
        try:
            catalog.drop_table(f"{dataset_name}.{table_name}")
        except NoSuchTableError:
            continue


def main() -> None:
    pipeline_name = os.environ.get("DLT_PIPELINE_NAME", "local_platform_ingest")
    dataset_name = os.environ.get("ICEBERG_NAMESPACE", "landing")
    refresh_mode = os.environ.get("DLT_REFRESH_MODE") or None
    load_batch = datetime.now(UTC).strftime("postgres-seed-%Y%m%dT%H%M%SZ")

    pipeline = dlt.pipeline(
        pipeline_name=pipeline_name,
        destination="filesystem",
        dataset_name=dataset_name,
    )

    run_kwargs: dict[str, object] = {"table_format": "iceberg"}
    if refresh_mode:
        if os.environ.get("ICEBERG_CATALOG_TYPE", "sql") == "sql":
            reset_sql_catalog_tables(dataset_name)
        run_kwargs["refresh"] = refresh_mode

    load_info = pipeline.run(
        [
            raw_orders(load_batch=load_batch),
            raw_order_items(),
        ],
        **run_kwargs,
    )

    print(load_info)


if __name__ == "__main__":
    main()
