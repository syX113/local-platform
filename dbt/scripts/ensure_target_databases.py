from __future__ import annotations

import argparse
import os

import snowflake.connector


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, "").strip()
    if value:
        return value
    if default is not None:
        return default
    raise SystemExit(f"missing required environment variable: {name}")


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


def connect():
    return snowflake.connector.connect(
        account=env("SNOWFLAKE_ACCOUNT"),
        user=env("SNOWFLAKE_USER"),
        password=env("SNOWFLAKE_PASSWORD"),
        role=env("SNOWFLAKE_ROLE"),
        warehouse=env("SNOWFLAKE_WAREHOUSE"),
        autocommit=True,
    )


def ensure_databases(cursor, databases: list[str], schemas: list[str]) -> None:
    cursor.execute(f"use role \"{env('SNOWFLAKE_ROLE')}\"")
    cursor.execute(f"use warehouse \"{env('SNOWFLAKE_WAREHOUSE')}\"")
    for database in databases:
        cursor.execute(f"create database if not exists {ident(database)}")
        for schema in schemas:
            cursor.execute(f"create schema if not exists {ident(database, schema)}")


def source_targets() -> tuple[list[str], list[str]]:
    return (
        [
            env("SNOWFLAKE_SDP_DATABASE"),
            env("SNOWFLAKE_SDP_CUSTOMERS_DATABASE"),
        ],
        [
            env("SNOWFLAKE_SDP_IN_SCHEMA", "INBOUND"),
            env("SNOWFLAKE_SDP_CORE_SCHEMA", "CORE"),
            env("SNOWFLAKE_SDP_ACC_SCHEMA", "ACCESS"),
        ],
    )


def edp_targets() -> tuple[list[str], list[str]]:
    return (
        [env("SNOWFLAKE_EDP_DATABASE")],
        [
            env("SNOWFLAKE_EDP_IN_SCHEMA", "INBOUND"),
            env("SNOWFLAKE_EDP_CORE_SCHEMA", "CORE"),
            env("SNOWFLAKE_EDP_ACC_SCHEMA", "ACCESS"),
        ],
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Ensure target Snowflake databases and schemas exist before dbt project deployment.")
    parser.add_argument("target_kind", choices=("source", "edp"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.target_kind == "source":
        databases, schemas = source_targets()
    else:
        databases, schemas = edp_targets()

    connection = connect()
    try:
        with connection.cursor() as cursor:
            ensure_databases(cursor, databases, schemas)
    finally:
        connection.close()

    print({"target_kind": args.target_kind, "databases": databases, "schemas": schemas})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
