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

CUSTOMERS_EXPORT_SQL = """
select
  customer_id,
  customer_name,
  region,
  segment,
  order_count,
  total_order_value,
  first_order_at,
  latest_order_at,
  customer_created_at,
  :load_batch as load_batch
from raw_customers_export
order by customer_id
"""

TAXES_EXPORT_SQL = """
select
  tax_code,
  tax_name,
  jurisdiction,
  rate,
  effective_at,
  loaded_at,
  :load_batch as load_batch
from raw_taxes_export
order by tax_code
"""

DEPOT_TRANSACTIONS_EXPORT_SQL = """
select
  transaction_id,
  customer_id,
  depot_code,
  transaction_type,
  amount,
  transaction_at,
  source_system,
  loaded_at,
  :load_batch as load_batch
from raw_depot_transactions_export
order by transaction_at, transaction_id
"""


def active_scope() -> str:
    return os.environ.get("RAW_SYNC_SCOPE", "all").strip().lower() or "all"


def sync_orders(scope: str) -> bool:
    return scope in {"all", "orders"}


def sync_customers(scope: str) -> bool:
    return scope in {"all", "customers"}


def sync_taxes(scope: str) -> bool:
    return scope in {"all", "taxes"}


def sync_depot_transactions(scope: str) -> bool:
    return scope in {"all", "depot_transactions"}


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
    return ".".join(f'"{part}"' for part in parts)


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


def ensure_foundation(cursor, scope: str) -> None:
    warehouse = os.environ["SNOWFLAKE_WAREHOUSE"]
    sdp_orders_database = os.environ["SNOWFLAKE_SDP_ORDERS_DATABASE"]
    sdp_customers_database = os.environ["SNOWFLAKE_SDP_CUSTOMERS_DATABASE"]
    sdp_taxes_database = os.environ["SNOWFLAKE_SDP_TAXES_DATABASE"]
    sdp_depot_transactions_database = os.environ["SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE"]
    sdp_in_schema = os.environ.get("SNOWFLAKE_SDP_IN_SCHEMA", "INBOUND")

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
    if sync_orders(scope):
        cursor.execute(f"create database if not exists {sdp_orders_database}")
        cursor.execute(f"create schema if not exists {ident(sdp_orders_database, sdp_in_schema)}")
        cursor.execute(
            f"""
            create or replace transient table {ident(sdp_orders_database, sdp_in_schema, 'EXT_ORDERS_RAW')} (
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
            create or replace transient table {ident(sdp_orders_database, sdp_in_schema, 'EXT_ORDER_ITEMS_RAW')} (
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

    if sync_customers(scope):
        cursor.execute(f"create database if not exists {sdp_customers_database}")
        cursor.execute(f"create schema if not exists {ident(sdp_customers_database, sdp_in_schema)}")
        cursor.execute(
            f"""
            create or replace transient table {ident(sdp_customers_database, sdp_in_schema, 'EXT_CUSTOMERS_RAW')} (
              CUSTOMER_ID varchar,
              CUSTOMER_NAME varchar,
              REGION varchar,
              SEGMENT varchar,
              ORDER_COUNT number(38, 0),
              TOTAL_ORDER_VALUE number(38, 2),
              FIRST_ORDER_AT varchar,
              LATEST_ORDER_AT varchar,
              CUSTOMER_CREATED_AT varchar,
              LOAD_BATCH varchar
            )
            """
        )

    if sync_taxes(scope):
        cursor.execute(f"create database if not exists {sdp_taxes_database}")
        cursor.execute(f"create schema if not exists {ident(sdp_taxes_database, sdp_in_schema)}")
        cursor.execute(
            f"""
            create or replace transient table {ident(sdp_taxes_database, sdp_in_schema, 'EXT_TAXES_RAW')} (
              TAX_CODE varchar,
              TAX_NAME varchar,
              JURISDICTION varchar,
              RATE number(38, 4),
              EFFECTIVE_AT varchar,
              LOADED_AT varchar,
              LOAD_BATCH varchar
            )
            """
        )

    if sync_depot_transactions(scope):
        cursor.execute(f"create database if not exists {sdp_depot_transactions_database}")
        cursor.execute(f"create schema if not exists {ident(sdp_depot_transactions_database, sdp_in_schema)}")
        cursor.execute(
            f"""
            create or replace transient table {ident(sdp_depot_transactions_database, sdp_in_schema, 'EXT_DEPOT_TRANSACTIONS_RAW')} (
              TRANSACTION_ID varchar,
              CUSTOMER_ID varchar,
              DEPOT_CODE varchar,
              TRANSACTION_TYPE varchar,
              AMOUNT number(38, 2),
              TRANSACTION_AT varchar,
              SOURCE_SYSTEM varchar,
              LOADED_AT varchar,
              LOAD_BATCH varchar
            )
            """
        )


def load_raw_tables() -> None:
    scope = active_scope()
    sdp_orders_database = os.environ["SNOWFLAKE_SDP_ORDERS_DATABASE"]
    sdp_customers_database = os.environ["SNOWFLAKE_SDP_CUSTOMERS_DATABASE"]
    sdp_taxes_database = os.environ["SNOWFLAKE_SDP_TAXES_DATABASE"]
    sdp_depot_transactions_database = os.environ["SNOWFLAKE_SDP_DEPOT_TRANSACTIONS_DATABASE"]
    sdp_in_schema = os.environ.get("SNOWFLAKE_SDP_IN_SCHEMA", "INBOUND")
    load_batch = datetime.utcnow().strftime("postgres-seed-%Y%m%dT%H%M%SZ")

    orders = fetch_rows(ORDERS_EXPORT_SQL, {"load_batch": load_batch}) if sync_orders(scope) else []
    order_items = fetch_rows(ORDER_ITEMS_EXPORT_SQL) if sync_orders(scope) else []
    customers = fetch_rows(CUSTOMERS_EXPORT_SQL, {"load_batch": load_batch}) if sync_customers(scope) else []
    taxes = fetch_rows(TAXES_EXPORT_SQL, {"load_batch": load_batch}) if sync_taxes(scope) else []
    depot_transactions = fetch_rows(DEPOT_TRANSACTIONS_EXPORT_SQL, {"load_batch": load_batch}) if sync_depot_transactions(scope) else []

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
    customer_columns = [
        "customer_id",
        "customer_name",
        "region",
        "segment",
        "order_count",
        "total_order_value",
        "first_order_at",
        "latest_order_at",
        "customer_created_at",
        "load_batch",
    ]
    tax_columns = [
        "tax_code",
        "tax_name",
        "jurisdiction",
        "rate",
        "effective_at",
        "loaded_at",
        "load_batch",
    ]
    depot_transaction_columns = [
        "transaction_id",
        "customer_id",
        "depot_code",
        "transaction_type",
        "amount",
        "transaction_at",
        "source_system",
        "loaded_at",
        "load_batch",
    ]

    connection = connect_snowflake()
    try:
        with connection.cursor() as cursor:
            ensure_foundation(cursor, scope)
            if sync_orders(scope):
                cursor.executemany(
                    f"""
                    insert into {ident(sdp_orders_database, sdp_in_schema, 'EXT_ORDERS_RAW')}
                    (ORDER_ID, CUSTOMER_ID, STATUS, ITEM_COUNT, ORDER_TOTAL, ORDER_CREATED_AT, LOAD_BATCH)
                    values (%s, %s, %s, %s, %s, %s, %s)
                    """,
                    rows_to_tuples(orders, order_columns),
                )
                cursor.executemany(
                    f"""
                    insert into {ident(sdp_orders_database, sdp_in_schema, 'EXT_ORDER_ITEMS_RAW')}
                    (ORDER_ID, ITEM_ID, SKU, QUANTITY, UNIT_PRICE, LINE_TOTAL, LOADED_AT)
                    values (%s, %s, %s, %s, %s, %s, %s)
                    """,
                    rows_to_tuples(order_items, item_columns),
                )
            if sync_customers(scope):
                cursor.executemany(
                    f"""
                    insert into {ident(sdp_customers_database, sdp_in_schema, 'EXT_CUSTOMERS_RAW')}
                    (CUSTOMER_ID, CUSTOMER_NAME, REGION, SEGMENT, ORDER_COUNT, TOTAL_ORDER_VALUE, FIRST_ORDER_AT, LATEST_ORDER_AT, CUSTOMER_CREATED_AT, LOAD_BATCH)
                    values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    rows_to_tuples(customers, customer_columns),
                )
            if sync_taxes(scope):
                cursor.executemany(
                    f"""
                    insert into {ident(sdp_taxes_database, sdp_in_schema, 'EXT_TAXES_RAW')}
                    (TAX_CODE, TAX_NAME, JURISDICTION, RATE, EFFECTIVE_AT, LOADED_AT, LOAD_BATCH)
                    values (%s, %s, %s, %s, %s, %s, %s)
                    """,
                    rows_to_tuples(taxes, tax_columns),
                )
            if sync_depot_transactions(scope):
                cursor.executemany(
                    f"""
                    insert into {ident(sdp_depot_transactions_database, sdp_in_schema, 'EXT_DEPOT_TRANSACTIONS_RAW')}
                    (TRANSACTION_ID, CUSTOMER_ID, DEPOT_CODE, TRANSACTION_TYPE, AMOUNT, TRANSACTION_AT, SOURCE_SYSTEM, LOADED_AT, LOAD_BATCH)
                    values (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    rows_to_tuples(depot_transactions, depot_transaction_columns),
                )
            connection.commit()

        print(
            {
                "scope": scope,
                "snowflake_sdp_orders_database": sdp_orders_database,
                "snowflake_sdp_customers_database": sdp_customers_database,
                "snowflake_sdp_taxes_database": sdp_taxes_database,
                "snowflake_sdp_depot_transactions_database": sdp_depot_transactions_database,
                "snowflake_sdp_in_schema": sdp_in_schema,
                "raw_orders": len(orders),
                "raw_order_items": len(order_items),
                "raw_customers": len(customers),
                "raw_taxes": len(taxes),
                "raw_depot_transactions": len(depot_transactions),
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
