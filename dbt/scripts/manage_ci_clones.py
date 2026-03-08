from __future__ import annotations

import argparse
import os
import sys

import snowflake.connector


def ident(name: str) -> str:
    return f'"{name}"'


def env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"missing required environment variable: {name}")
    return value


def connect():
    return snowflake.connector.connect(
        account=env("SNOWFLAKE_ACCOUNT"),
        user=env("SNOWFLAKE_USER"),
        password=env("SNOWFLAKE_PASSWORD"),
        role=env("SNOWFLAKE_ROLE"),
        warehouse=env("SNOWFLAKE_WAREHOUSE"),
        autocommit=False,
    )


def clone_database(cursor, source_name: str, target_name: str) -> None:
    if source_name == target_name:
        return
    cursor.execute(f"create or replace transient database {ident(target_name)} clone {ident(source_name)}")


def database_exists(cursor, target_name: str) -> bool:
    cursor.execute(f"show databases like '{target_name}'")
    return cursor.fetchone() is not None


def ensure_database_clone(cursor, source_name: str, target_name: str) -> bool:
    if source_name == target_name:
        return False
    if database_exists(cursor, target_name):
        return False
    cursor.execute(f"create transient database {ident(target_name)} clone {ident(source_name)}")
    return True


def drop_database(cursor, target_name: str) -> None:
    cursor.execute(f"drop database if exists {ident(target_name)}")


def apply_replace() -> None:
    source_sdp = env("SNOWFLAKE_SDP_DATABASE_BASE")
    target_sdp = env("SNOWFLAKE_SDP_DATABASE")
    source_edp = env("SNOWFLAKE_EDP_DATABASE_BASE")
    target_edp = env("SNOWFLAKE_EDP_DATABASE")

    connection = connect()
    try:
        with connection.cursor() as cursor:
            clone_database(cursor, source_sdp, target_sdp)
            clone_database(cursor, source_edp, target_edp)
        connection.commit()
    finally:
        connection.close()

    print(f"created clones sdp={target_sdp} edp={target_edp}")


def apply_ensure() -> None:
    source_sdp = env("SNOWFLAKE_SDP_DATABASE_BASE")
    target_sdp = env("SNOWFLAKE_SDP_DATABASE")
    source_edp = env("SNOWFLAKE_EDP_DATABASE_BASE")
    target_edp = env("SNOWFLAKE_EDP_DATABASE")

    connection = connect()
    try:
        with connection.cursor() as cursor:
            created_sdp = ensure_database_clone(cursor, source_sdp, target_sdp)
            created_edp = ensure_database_clone(cursor, source_edp, target_edp)
        connection.commit()
    finally:
        connection.close()

    print(
        "ensured clones "
        f"sdp={target_sdp}({'created' if created_sdp else 'reused'}) "
        f"edp={target_edp}({'created' if created_edp else 'reused'})"
    )


def apply_drop() -> None:
    target_sdp = env("SNOWFLAKE_SDP_DATABASE")
    target_edp = env("SNOWFLAKE_EDP_DATABASE")
    source_sdp = os.environ.get("SNOWFLAKE_SDP_DATABASE_BASE", "").strip()
    source_edp = os.environ.get("SNOWFLAKE_EDP_DATABASE_BASE", "").strip()

    connection = connect()
    try:
        with connection.cursor() as cursor:
            if target_edp and target_edp != source_edp:
                drop_database(cursor, target_edp)
            if target_sdp and target_sdp != source_sdp:
                drop_database(cursor, target_sdp)
        connection.commit()
    finally:
        connection.close()

    print(f"dropped clones sdp={target_sdp} edp={target_edp}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Manage branch-scoped Snowflake zero-copy clones.")
    parser.add_argument("action", choices=("ensure", "replace", "drop"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.action == "ensure":
        apply_ensure()
    elif args.action == "replace":
        apply_replace()
    elif args.action == "drop":
        apply_drop()
    else:  # pragma: no cover
        print(f"unsupported action: {args.action}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
