from __future__ import annotations

import os
from collections.abc import Iterable
from datetime import datetime
from decimal import Decimal
from typing import Any

import snowflake.connector
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL


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


def env_flag(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


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


def ident(*parts: str) -> str:
    return ".".join(parts)


def connect_snowflake():
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        role=os.environ["SNOWFLAKE_ROLE"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        autocommit=False,
    )


def normalize_value(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, Decimal):
        return value
    return value


def rows_to_tuples(rows: Iterable[dict[str, Any]], columns: list[str]) -> list[tuple[Any, ...]]:
    return [
        tuple(normalize_value(row[column]) for column in columns)
        for row in rows
    ]


def ensure_foundation(cursor) -> None:
    warehouse = os.environ["SNOWFLAKE_WAREHOUSE"]
    target_database = os.environ["SNOWFLAKE_TARGET_DATABASE"]
    target_schema = os.environ["SNOWFLAKE_TARGET_SCHEMA"]
    raw_database = os.environ["SNOWFLAKE_RAW_DATABASE"]
    raw_schema = os.environ.get("ICEBERG_NAMESPACE", "landing")

    cursor.execute(f"use role {os.environ['SNOWFLAKE_ROLE']}")
    cursor.execute(
        f"""
        create warehouse if not exists {warehouse}
          warehouse_size = 'XSMALL'
          auto_suspend = 60
          auto_resume = true
        """
    )
    cursor.execute(f"use warehouse {warehouse}")
    cursor.execute(f"create database if not exists {target_database}")
    cursor.execute(f"create schema if not exists {ident(target_database, target_schema)}")
    cursor.execute(f"create database if not exists {raw_database}")
    cursor.execute(f"create schema if not exists {ident(raw_database, raw_schema)}")
    cursor.execute(
        f"""
        create or replace transient table {ident(raw_database, raw_schema, 'RAW_ORDERS')} (
          ORDER_ID varchar,
          CUSTOMER_ID varchar,
          STATUS varchar,
          ITEM_COUNT number(38, 0),
          ORDER_TOTAL number(38, 2),
          ORDER_CREATED_AT varchar,
          LOAD_BATCH varchar
        )
        """
    )
    cursor.execute(
        f"""
        create or replace transient table {ident(raw_database, raw_schema, 'RAW_ORDER_ITEMS')} (
          ORDER_ID varchar,
          ITEM_ID varchar,
          SKU varchar,
          QUANTITY number(38, 0),
          UNIT_PRICE number(38, 2),
          LINE_TOTAL number(38, 2),
          LOADED_AT varchar
        )
        """
    )


def load_raw_tables() -> None:
    raw_schema = os.environ.get("ICEBERG_NAMESPACE", "landing")
    raw_database = os.environ["SNOWFLAKE_RAW_DATABASE"]
    load_batch = datetime.utcnow().strftime("postgres-seed-%Y%m%dT%H%M%SZ")

    orders = fetch_rows(ORDERS_EXPORT_SQL, {"load_batch": load_batch})
    order_items = fetch_rows(ORDER_ITEMS_EXPORT_SQL)

    order_columns = [
        "order_id",
        "customer_id",
        "status",
        "item_count",
        "order_total",
        "order_created_at",
        "load_batch",
    ]
    item_columns = [
        "order_id",
        "item_id",
        "sku",
        "quantity",
        "unit_price",
        "line_total",
        "loaded_at",
    ]

    connection = connect_snowflake()
    try:
        with connection.cursor() as cursor:
            ensure_foundation(cursor)
            cursor.executemany(
                f"""
                insert into {ident(raw_database, raw_schema, 'RAW_ORDERS')}
                (ORDER_ID, CUSTOMER_ID, STATUS, ITEM_COUNT, ORDER_TOTAL, ORDER_CREATED_AT, LOAD_BATCH)
                values (%s, %s, %s, %s, %s, %s, %s)
                """,
                rows_to_tuples(orders, order_columns),
            )
            cursor.executemany(
                f"""
                insert into {ident(raw_database, raw_schema, 'RAW_ORDER_ITEMS')}
                (ORDER_ID, ITEM_ID, SKU, QUANTITY, UNIT_PRICE, LINE_TOTAL, LOADED_AT)
                values (%s, %s, %s, %s, %s, %s, %s)
                """,
                rows_to_tuples(order_items, item_columns),
            )
            connection.commit()

        print(
            {
                "snowflake_raw_database": raw_database,
                "snowflake_raw_schema": raw_schema,
                "raw_orders": len(orders),
                "raw_order_items": len(order_items),
            }
        )
    finally:
        connection.close()


def main() -> int:
    if not env_flag("SNOWFLAKE_LOCAL_RAW_SYNC", default=True):
        print("Skipping Snowflake raw sync because SNOWFLAKE_LOCAL_RAW_SYNC is disabled.")
        return 0

    required = ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_PASSWORD"]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        print(f"Skipping Snowflake raw sync because required variables are missing: {', '.join(missing)}")
        return 0

    load_raw_tables()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
