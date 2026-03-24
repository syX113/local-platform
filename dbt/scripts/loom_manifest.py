from __future__ import annotations

import argparse
import gzip
import json
import os
import shutil
import subprocess
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

from snow_dbt_cli import (
    default_database_for_project,
    default_schema_for_project,
    env,
    prepare_project_source,
    snow_env,
)


SOURCE_SCOPE_TO_DATABASE_ENV = {
    "orders": "SNOWFLAKE_SDP_DATABASE",
    "customers": "SNOWFLAKE_SDP_CUSTOMERS_DATABASE",
}


def _opt_env(name: str, default: str = "") -> str:
    return os.environ.get(name, "").strip() or default


def manifest_bucket() -> str:
    return _opt_env("MINIO_MANIFEST_BUCKET", "dbt-manifests")


def object_store_client() -> boto3.client:
    endpoint = _opt_env("OBJECT_STORE_ENDPOINT_URL", _opt_env("MINIO_ENDPOINT"))
    if not endpoint:
        raise SystemExit("missing object store endpoint: OBJECT_STORE_ENDPOINT_URL or MINIO_ENDPOINT")

    use_ssl_raw = _opt_env("OBJECT_STORE_USE_SSL", _opt_env("MINIO_USE_SSL", "false"))
    use_ssl = use_ssl_raw.lower() in {"1", "true", "yes", "on"}
    region = _opt_env("OBJECT_STORE_REGION", _opt_env("MINIO_REGION", "us-east-1"))

    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=env("OBJECT_STORE_ACCESS_KEY_ID"),
        aws_secret_access_key=env("OBJECT_STORE_SECRET_ACCESS_KEY"),
        region_name=region,
        use_ssl=use_ssl,
        config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    )


def ensure_bucket_exists(client: boto3.client, bucket: str) -> None:
    try:
        client.head_bucket(Bucket=bucket)
    except ClientError as exc:
        error_code = str(exc.response.get("Error", {}).get("Code", ""))
        if error_code not in {"404", "NoSuchBucket", "NotFound"}:
            raise
        client.create_bucket(Bucket=bucket)


def run_local_dbt_parse(project_dir: Path, *, database: str, schema: str, target_name: str) -> dict[str, object]:
    prepared_dir = prepare_project_source(
        project_dir,
        database=database,
        schema=schema,
        target_name=target_name,
    )

    try:
        completed = subprocess.run(
            [
                shutil.which("dbt") or "dbt",
                "parse",
                "--profiles-dir",
                str(prepared_dir),
                "--project-dir",
                str(prepared_dir),
                "--target",
                target_name,
            ],
            check=False,
            text=True,
            env=snow_env(),
        )
        if completed.returncode != 0:
            raise SystemExit(completed.returncode)
        manifest_path = prepared_dir / "target" / "manifest.json"
        if not manifest_path.exists():
            raise SystemExit(f"dbt did not create a manifest file at {manifest_path}")
        return json.loads(manifest_path.read_text(encoding="utf-8"))
    finally:
        shutil.rmtree(prepared_dir.parent, ignore_errors=True)


def infer_scope(text: str) -> str | None:
    lowered = text.lower()
    if "customers" in lowered:
        return "customers"
    if "orders" in lowered:
        return "orders"
    return None


def rewrite_manifest_databases(manifest: dict[str, object]) -> dict[str, object]:
    nodes = manifest.get("nodes", {})
    if not isinstance(nodes, dict):
        return manifest

    for node in nodes.values():
        if not isinstance(node, dict):
            continue

        database = node.get("database")
        if not isinstance(database, str) or not database.strip():
            continue

        node_text = " ".join(
            str(value)
            for value in (
                node.get("package_name", ""),
                node.get("name", ""),
                node.get("alias", ""),
                node.get("original_file_path", ""),
                node.get("path", ""),
                " ".join(node.get("fqn", [])) if isinstance(node.get("fqn"), list) else "",
            )
        )
        scope = infer_scope(node_text)
        if not scope:
            continue

        target_env_name = SOURCE_SCOPE_TO_DATABASE_ENV.get(scope)
        if not target_env_name:
            continue

        target_database = os.environ.get(target_env_name, "").strip()
        if not target_database:
            continue

        node["database"] = target_database

    return manifest


def publish_manifest(*, project_dir: Path, bucket: str, object_keys: list[str], target_name: str) -> None:
    database = default_database_for_project(project_dir)
    schema = default_schema_for_project(project_dir)
    manifest = run_local_dbt_parse(
        project_dir,
        database=database,
        schema=schema,
        target_name=target_name,
    )
    payload = gzip.compress(
        json.dumps(manifest, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
        compresslevel=6,
    )

    client = object_store_client()
    ensure_bucket_exists(client, bucket)
    for object_key in object_keys:
        client.put_object(
            Bucket=bucket,
            Key=object_key,
            Body=payload,
            ContentType="application/json",
            ContentEncoding="gzip",
        )
        print(f"published manifest: s3://{bucket}/{object_key}")


def fetch_manifest(*, bucket: str, object_key: str, project_dir: Path, local_path: str) -> None:
    client = object_store_client()
    try:
        response = client.get_object(Bucket=bucket, Key=object_key)
    except Exception as exc:  # pragma: no cover - surfaced as process failure
        raise SystemExit(f"unable to fetch manifest s3://{bucket}/{object_key}: {exc}") from exc

    body = response["Body"].read()
    try:
        manifest = json.loads(gzip.decompress(body).decode("utf-8"))
    except Exception as exc:  # pragma: no cover - surfaced as process failure
        raise SystemExit(f"unable to decode manifest s3://{bucket}/{object_key}: {exc}") from exc

    manifest = rewrite_manifest_databases(manifest)

    local_manifest_path = project_dir / local_path
    local_manifest_path.parent.mkdir(parents=True, exist_ok=True)
    local_manifest_path.write_bytes(
        gzip.compress(
            json.dumps(manifest, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
            compresslevel=6,
        )
    )
    print(f"fetched manifest: s3://{bucket}/{object_key} -> {local_manifest_path}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    publish_parser = subparsers.add_parser("publish")
    publish_parser.add_argument("--project-dir", required=True)
    publish_parser.add_argument("--bucket", default=manifest_bucket())
    publish_parser.add_argument("--object-key", action="append", required=True)
    publish_parser.add_argument("--target-name", default=_opt_env("SNOW_DBT_TARGET_NAME", "dev"))

    fetch_parser = subparsers.add_parser("fetch")
    fetch_parser.add_argument("--project-dir", required=True)
    fetch_parser.add_argument("--bucket", default=manifest_bucket())
    fetch_parser.add_argument("--object-key", required=True)
    fetch_parser.add_argument("--local-path", default="loom/manifest.json.gz")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "publish":
        publish_manifest(
            project_dir=Path(args.project_dir),
            bucket=args.bucket,
            object_keys=args.object_key,
            target_name=args.target_name,
        )
        return 0

    if args.command == "fetch":
        fetch_manifest(
            bucket=args.bucket,
            object_key=args.object_key,
            project_dir=Path(args.project_dir),
            local_path=args.local_path,
        )
        return 0

    raise SystemExit(f"unsupported command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
