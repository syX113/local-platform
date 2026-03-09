from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import snowflake.connector


REGISTRY_PATH_CANDIDATES = (
    Path("/opt/platform/snowflake/data_products.json"),
    Path("/opt/platform/ci/snowflake/data_products.json"),
)
MAX_DATABASE_NAME_LENGTH = 120


@dataclass(frozen=True)
class ClonePair:
    key: str
    source_database: str
    target_database: str


def ident(name: str) -> str:
    return f'"{name}"'


def env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"missing required environment variable: {name}")
    return value


def opt_env(name: str) -> str:
    return os.environ.get(name, "").strip()


def connect():
    return snowflake.connector.connect(
        account=env("SNOWFLAKE_ACCOUNT"),
        user=env("SNOWFLAKE_USER"),
        password=env("SNOWFLAKE_PASSWORD"),
        role=env("SNOWFLAKE_ROLE"),
        warehouse=env("SNOWFLAKE_WAREHOUSE"),
        autocommit=False,
    )


def trim_identifier(value: str, max_len: int) -> str:
    return value[:max_len]


def stable_token(raw: str) -> str:
    completed = subprocess.run(
        ["cksum"],
        input=f"{raw}\n",
        text=True,
        capture_output=True,
        check=True,
    )
    return completed.stdout.split()[0]


def build_clone_database_name(base_name: str, owner_token: str, branch_token_raw: str, max_len: int) -> str:
    branch_upper = branch_token_raw.upper()
    prefix = f"{base_name}_CI_CLO_{owner_token}_"

    if len(prefix) >= max_len:
        return trim_identifier(prefix, max_len)

    remaining = max_len - len(prefix)
    if len(branch_upper) <= remaining:
        return f"{prefix}{branch_upper}"

    hash_value = stable_token(f"{base_name}_{owner_token}_{branch_token_raw}")
    suffix_len = 1 + len(hash_value)
    trimmed_len = remaining - suffix_len
    if trimmed_len < 1:
        return f"{prefix}{trim_identifier(hash_value, remaining)}"

    branch_trimmed = trim_identifier(branch_upper, trimmed_len)
    return f"{prefix}{branch_trimmed}_{hash_value}"


def load_product_registry() -> list[dict[str, str]]:
    configured_path = opt_env("SNOWFLAKE_DATA_PRODUCTS_PATH")
    registry_path = Path(configured_path) if configured_path else None
    if registry_path is None:
        registry_path = next((path for path in REGISTRY_PATH_CANDIDATES if path.exists()), REGISTRY_PATH_CANDIDATES[0])
    if not registry_path.exists():
        return []

    payload = json.loads(registry_path.read_text(encoding="utf-8"))
    products = payload.get("data_products", [])
    if not isinstance(products, list):
        raise SystemExit(f"invalid data product registry: {registry_path}")
    return [product for product in products if isinstance(product, dict)]


def resolve_source_database(product: dict[str, str]) -> str:
    source_env_var = str(product.get("source_env_var", "")).strip()
    if source_env_var:
        source_value = opt_env(source_env_var)
        if source_value:
            return source_value
    return str(product.get("database", "")).strip()


def resolve_runtime_target(product: dict[str, str], owner_token: str, branch_token: str) -> str:
    runtime_env_var = str(product.get("runtime_env_var", "")).strip()
    runtime_value = opt_env(runtime_env_var) if runtime_env_var else ""
    if runtime_value:
        return runtime_value
    source_database = resolve_source_database(product)
    return build_clone_database_name(source_database, owner_token, branch_token, MAX_DATABASE_NAME_LENGTH)


def clone_pairs_from_registry() -> list[ClonePair]:
    owner_token = opt_env("SNOWFLAKE_CLONE_OWNER_TOKEN")
    branch_token = opt_env("SNOWFLAKE_CLONE_BRANCH_TOKEN")
    if not owner_token or not branch_token:
        return []

    pairs: list[ClonePair] = []
    seen_targets: set[str] = set()
    for product in load_product_registry():
        key = str(product.get("key") or product.get("database") or "product").strip()
        source_database = resolve_source_database(product)
        if not source_database:
            continue
        target_database = resolve_runtime_target(product, owner_token, branch_token)
        if not target_database or target_database in seen_targets:
            continue
        seen_targets.add(target_database)
        pairs.append(ClonePair(key=key, source_database=source_database, target_database=target_database))
    return pairs


def clone_pairs_from_legacy_env() -> list[ClonePair]:
    pairs: list[ClonePair] = []

    source_sdp = opt_env("SNOWFLAKE_SDP_DATABASE_BASE") or opt_env("SNOWFLAKE_SDP_DATABASE")
    target_sdp = opt_env("SNOWFLAKE_SDP_DATABASE")
    if source_sdp and target_sdp:
        pairs.append(ClonePair(key="sdp", source_database=source_sdp, target_database=target_sdp))

    source_edp = opt_env("SNOWFLAKE_EDP_DATABASE_BASE") or opt_env("SNOWFLAKE_EDP_DATABASE")
    target_edp = opt_env("SNOWFLAKE_EDP_DATABASE")
    if source_edp and target_edp:
        pairs.append(ClonePair(key="edp", source_database=source_edp, target_database=target_edp))

    return pairs


def clone_pairs() -> list[ClonePair]:
    pairs = clone_pairs_from_registry()
    if pairs:
        return pairs

    pairs = clone_pairs_from_legacy_env()
    if pairs:
        return pairs

    raise SystemExit(
        "no clone targets resolved; set SNOWFLAKE_CLONE_OWNER_TOKEN/SNOWFLAKE_CLONE_BRANCH_TOKEN "
        "or the legacy SNOWFLAKE_SDP_DATABASE/SNOWFLAKE_EDP_DATABASE variables"
    )


def base_databases_from_registry() -> list[str]:
    names: list[str] = []
    seen: set[str] = set()
    for product in load_product_registry():
        source_database = resolve_source_database(product) or str(product.get("database", "")).strip()
        if not source_database or source_database in seen:
            continue
        seen.add(source_database)
        names.append(source_database)
    return names


def base_databases_from_legacy_env() -> list[str]:
    names: list[str] = []
    for value in (
        opt_env("SNOWFLAKE_SDP_DATABASE_BASE") or opt_env("SNOWFLAKE_SDP_DATABASE"),
        opt_env("SNOWFLAKE_EDP_DATABASE_BASE") or opt_env("SNOWFLAKE_EDP_DATABASE"),
    ):
        if value and value not in names:
            names.append(value)
    return names


def clone_base_databases() -> list[str]:
    names = base_databases_from_registry()
    if names:
        return names
    names = base_databases_from_legacy_env()
    if names:
        return names
    raise SystemExit(
        "no base data product databases resolved; configure snowflake/data_products.json "
        "or the legacy SNOWFLAKE_SDP_DATABASE/SNOWFLAKE_EDP_DATABASE variables"
    )


def clone_database(cursor, source_name: str, target_name: str) -> None:
    if source_name == target_name:
        return
    cursor.execute(f"create or replace transient database {ident(target_name)} clone {ident(source_name)}")


def database_exists(cursor, target_name: str) -> bool:
    cursor.execute(f"show databases like '{target_name}'")
    return cursor.fetchone() is not None


def is_already_exists_error(error: snowflake.connector.errors.ProgrammingError) -> bool:
    errno = getattr(error, "errno", None)
    sqlstate = getattr(error, "sqlstate", "")
    message = str(error).lower()
    return errno == 2002 or sqlstate == "42710" or "already exists" in message


def ensure_database_clone(cursor, source_name: str, target_name: str) -> bool:
    if source_name == target_name:
        return False
    if database_exists(cursor, target_name):
        return False
    try:
        cursor.execute(f"create transient database {ident(target_name)} clone {ident(source_name)}")
    except snowflake.connector.errors.ProgrammingError as error:
        if is_already_exists_error(error):
            return False
        raise
    return True


def drop_database(cursor, target_name: str) -> None:
    cursor.execute(f"drop database if exists {ident(target_name)}")


def list_ci_clone_databases(cursor) -> list[str]:
    prefixes = tuple(f"{name.upper()}_CI_CLO_" for name in clone_base_databases())
    cursor.execute("show databases")
    columns = [description[0].lower() for description in cursor.description or []]
    name_index = columns.index("name") if "name" in columns else 1

    matches: set[str] = set()
    for row in cursor.fetchall():
        database_name = str(row[name_index]).strip()
        database_upper = database_name.upper()
        if any(database_upper.startswith(prefix) for prefix in prefixes):
            matches.add(database_name)

    return sorted(matches)


def apply_replace() -> None:
    pairs = clone_pairs()
    connection = connect()
    try:
        with connection.cursor() as cursor:
            for pair in pairs:
                clone_database(cursor, pair.source_database, pair.target_database)
        connection.commit()
    finally:
        connection.close()

    print("created clones " + " ".join(f"{pair.key}={pair.target_database}" for pair in pairs))


def apply_ensure() -> None:
    pairs = clone_pairs()
    created_pairs: list[tuple[ClonePair, bool]] = []

    connection = connect()
    try:
        with connection.cursor() as cursor:
            for pair in pairs:
                created_pairs.append(
                    (pair, ensure_database_clone(cursor, pair.source_database, pair.target_database))
                )
        connection.commit()
    finally:
        connection.close()

    print(
        "ensured clones "
        + " ".join(
            f"{pair.key}={pair.target_database}({'created' if created else 'reused'})"
            for pair, created in created_pairs
        )
    )


def apply_drop() -> None:
    pairs = clone_pairs()
    connection = connect()
    try:
        with connection.cursor() as cursor:
            for pair in pairs:
                if pair.target_database != pair.source_database:
                    drop_database(cursor, pair.target_database)
        connection.commit()
    finally:
        connection.close()

    print("dropped clones " + " ".join(f"{pair.key}={pair.target_database}" for pair in pairs))


def apply_purge_ci() -> None:
    connection = connect()
    try:
        with connection.cursor() as cursor:
            matches = list_ci_clone_databases(cursor)
            for database_name in matches:
                drop_database(cursor, database_name)
        connection.commit()
    finally:
        connection.close()

    if matches:
        print("purged ci clones " + " ".join(matches))
    else:
        print("purged ci clones none")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Manage branch-scoped Snowflake zero-copy clones.")
    parser.add_argument("action", choices=("ensure", "replace", "drop", "purge-ci"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.action == "ensure":
        apply_ensure()
    elif args.action == "replace":
        apply_replace()
    elif args.action == "drop":
        apply_drop()
    elif args.action == "purge-ci":
        apply_purge_ci()
    else:  # pragma: no cover
        print(f"unsupported action: {args.action}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
