from __future__ import annotations

import argparse
import json
from pathlib import Path


def registry_candidates() -> list[Path]:
    here = Path(__file__).resolve()
    candidates: list[Path] = []
    for parent in here.parents:
        candidates.extend(
            [
                parent / "snowflake" / "project_registry.json",
                parent / "ci" / "snowflake" / "project_registry.json",
            ]
        )
    return candidates


def load_registry() -> dict[str, object]:
    for candidate in registry_candidates():
        if candidate.exists():
            payload = json.loads(candidate.read_text(encoding="utf-8"))
            if isinstance(payload, dict) and isinstance(payload.get("projects"), list):
                return payload
            raise SystemExit(f"invalid project registry: {candidate}")
    raise SystemExit("unable to locate project registry JSON")


def projects() -> list[dict[str, object]]:
    registry = load_registry()
    return [project for project in registry["projects"] if isinstance(project, dict)]


def project_by_slug(slug: str) -> dict[str, object]:
    normalized_slug = slug.strip()
    for project in projects():
        if str(project.get("slug", "")).strip() == normalized_slug:
            return project
    raise SystemExit(f"unknown project slug: {slug}")


def project_by_name(project_name: str) -> dict[str, object]:
    normalized_name = project_name.strip()
    for project in projects():
        snowflake_names = project.get("snowflake_project_names", [])
        if not isinstance(snowflake_names, list):
            continue
        for candidate in snowflake_names:
            if str(candidate).strip() == normalized_name:
                return project
        prefixes = project.get("snowflake_project_name_prefixes", [])
        if not isinstance(prefixes, list):
            continue
        for prefix in prefixes:
            if normalized_name.startswith(str(prefix).strip()):
                return project
    raise SystemExit(f"unknown Snowflake dbt project name: {project_name}")


def lookup(slug: str, field: str, default: str = "") -> int:
    project = project_by_slug(slug)
    value = project.get(field, default)
    if isinstance(value, (dict, list)):
        print(json.dumps(value, ensure_ascii=False))
    elif value is None:
        print(default)
    else:
        print(str(value))
    return 0


def project_dir(slug: str) -> int:
    return lookup(slug, "dbt_project_dir")


def manifest_key(slug: str) -> int:
    return lookup(slug, "manifest_object_key")


def manifest_publish_keys(slug: str) -> int:
    project = project_by_slug(slug)
    keys = project.get("manifest_publish_keys", [])
    if not isinstance(keys, list):
        raise SystemExit(f"invalid manifest_publish_keys for project: {slug}")
    for key in keys:
        text = str(key).strip()
        if text:
            print(text)
    return 0


def prepare_targets(slug: str) -> int:
    project = project_by_slug(slug)
    targets = project.get("prepare_targets", [])
    if not isinstance(targets, list):
        raise SystemExit(f"invalid prepare_targets for project: {slug}")
    for target in targets:
        if not isinstance(target, dict):
            continue
        database_env = str(target.get("database_env", "")).strip()
        schema_envs = target.get("schema_envs", [])
        if not database_env or not isinstance(schema_envs, list):
            continue
        schema_envs_text = ",".join(str(item).strip() for item in schema_envs if str(item).strip())
        if schema_envs_text:
            print(f"{database_env}|{schema_envs_text}")
    return 0


def project_slug_for_name(project_name: str) -> int:
    print(project_by_name(project_name).get("slug", ""))
    return 0


def project_name_for_target(slug: str, target_name: str) -> int:
    project = project_by_slug(slug)
    snowflake_names = project.get("snowflake_project_names", [])
    if not isinstance(snowflake_names, list) or not snowflake_names:
        raise SystemExit(f"invalid snowflake_project_names for project: {slug}")

    target = target_name.strip().lower()
    if len(snowflake_names) == 1:
        print(str(snowflake_names[0]).strip())
        return 0

    if target == "prd" and len(snowflake_names) > 1:
        print(str(snowflake_names[1]).strip())
        return 0

    print(str(snowflake_names[0]).strip())
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    lookup_parser = subparsers.add_parser("lookup")
    lookup_parser.add_argument("--project-slug", required=True)
    lookup_parser.add_argument("--field", required=True)
    lookup_parser.add_argument("--default", default="")

    project_dir_parser = subparsers.add_parser("project-dir")
    project_dir_parser.add_argument("--project-slug", required=True)

    manifest_key_parser = subparsers.add_parser("manifest-key")
    manifest_key_parser.add_argument("--project-slug", required=True)

    publish_keys_parser = subparsers.add_parser("manifest-publish-keys")
    publish_keys_parser.add_argument("--project-slug", required=True)

    prepare_targets_parser = subparsers.add_parser("prepare-targets")
    prepare_targets_parser.add_argument("--project-slug", required=True)

    name_parser = subparsers.add_parser("project-slug-for-name")
    name_parser.add_argument("--project-name", required=True)

    project_name_parser = subparsers.add_parser("project-name")
    project_name_parser.add_argument("--project-slug", required=True)
    project_name_parser.add_argument("--target-name", required=True)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "lookup":
        return lookup(args.project_slug, args.field, args.default)
    if args.command == "project-dir":
        return project_dir(args.project_slug)
    if args.command == "manifest-key":
        return manifest_key(args.project_slug)
    if args.command == "manifest-publish-keys":
        return manifest_publish_keys(args.project_slug)
    if args.command == "prepare-targets":
        return prepare_targets(args.project_slug)
    if args.command == "project-slug-for-name":
        return project_slug_for_name(args.project_name)
    if args.command == "project-name":
        return project_name_for_target(args.project_slug, args.target_name)
    raise SystemExit(f"unsupported command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
