from __future__ import annotations

import argparse
import os

import snowflake.connector
from project_registry import project_by_slug


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Ensure target Snowflake databases and schemas exist before dbt project deployment.")
    parser.add_argument("project_slug")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    project = project_by_slug(args.project_slug)
    targets = project.get("prepare_targets", [])
    if not isinstance(targets, list):
        raise SystemExit(f"invalid prepare_targets for project: {args.project_slug}")

    connection = connect()
    try:
        with connection.cursor() as cursor:
            for target in targets:
                if not isinstance(target, dict):
                    continue
                database_env = str(target.get("database_env", "")).strip()
                schema_envs = target.get("schema_envs", [])
                if not database_env or not isinstance(schema_envs, list):
                    continue
                database_name = env(database_env)
                schemas = [env(schema_env) for schema_env in schema_envs if str(schema_env).strip()]
                if not schemas:
                    continue
                ensure_databases(cursor, [database_name], schemas)
    finally:
        connection.close()

    print({"project_slug": args.project_slug, "targets": targets})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
