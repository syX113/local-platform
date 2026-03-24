from __future__ import annotations

import argparse
import os
from pathlib import Path

from loom_manifest import fetch_manifest, manifest_bucket
from project_registry import project_by_slug
from snow_dbt_cli import default_database_for_project, default_schema_for_project, prepare_project_source


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", required=True)
    parser.add_argument("--project-slug", required=True)
    parser.add_argument("--workspace-dir", required=True)
    parser.add_argument("--target-name", default=os.environ.get("SNOW_DBT_TARGET_NAME", "dev"))
    return parser


def main() -> int:
    args = build_parser().parse_args()
    project_dir = Path(args.project_dir)
    project_slug = args.project_slug.strip()
    workspace_dir = Path(args.workspace_dir)

    prepared_dir = prepare_project_source(
        project_dir,
        project_slug=project_slug,
        database=default_database_for_project(project_dir, project_slug),
        schema=default_schema_for_project(project_dir, project_slug),
        target_name=args.target_name,
        quiet=True,
        copy_downstream_dependencies=False,
        work_dir=workspace_dir,
    )

    manifest_object_key = str(project_by_slug(project_slug).get("manifest_object_key", "")).strip()
    if manifest_object_key:
        fetch_manifest(
            bucket=manifest_bucket(),
            object_key=manifest_object_key,
            project_dir=prepared_dir,
            local_path="loom/manifest.json.gz",
        )

    print(f"prepared sqlfluff workspace: {prepared_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
