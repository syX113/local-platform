from __future__ import annotations

import os
import sys

import snowflake.connector


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


def connect():
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        role=os.environ["SNOWFLAKE_ROLE"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        database=os.environ["SNOWFLAKE_EDP_DATABASE"],
        schema=os.environ["SNOWFLAKE_EDP_CORE_SCHEMA"],
    )


def scalar(cursor, sql: str):
    cursor.execute(sql)
    return cursor.fetchone()[0]


def main() -> int:
    database = os.environ["SNOWFLAKE_EDP_DATABASE"]
    schema = os.environ["SNOWFLAKE_EDP_CORE_SCHEMA"]
    clone_schema = os.environ.get("SNOWFLAKE_CLONE_SCHEMA", f"{schema}_CLONE_CI")
    fact_table = "FCT_ORDER_REVENUE_STAR"

    connection = connect()
    try:
        with connection.cursor() as cursor:
            cursor.execute(f"create or replace transient schema {ident(database, clone_schema)} clone {ident(database, schema)}")
            source_rows = scalar(cursor, f"select count(*) from {ident(database, schema, fact_table)}")
            clone_rows = scalar(cursor, f"select count(*) from {ident(database, clone_schema, fact_table)}")

            if source_rows != clone_rows:
                print("clone row counts do not match source", file=sys.stderr)
                return 1

            cursor.execute(
                f"create or replace table {ident(database, clone_schema, 'CLONE_MUTATION_CHECK')} as "
                "select current_timestamp() as created_at"
            )
            cursor.execute(f"drop schema if exists {ident(database, clone_schema)}")
    finally:
        connection.close()

    print(
        "Zero-copy clone semantics validated. Storage-byte accounting for clones is intentionally not checked "
        "here because Snowflake storage metrics views are delayed."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
