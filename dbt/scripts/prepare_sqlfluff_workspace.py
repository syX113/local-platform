from __future__ import annotations

import argparse
import os
import re
from pathlib import Path

from snow_dbt_cli import default_database_for_project, default_schema_for_project, prepare_project_source


SQLFLUFF_CONFIG_CANDIDATES = (
    Path("/opt/platform/dbt/.sqlfluff"),
    Path(__file__).resolve().parent.parent / ".sqlfluff",
)


def write_workspace_sqlfluff_config(prepared_dir: Path) -> None:
    """Copy the shared sqlfluff config and point its dbt templater at the workspace.

    The checked-in config refers to the repository layout. sqlfluff runs against the
    prepared workspace, which carries its own generated profiles.yml, so both paths
    have to be rewritten or the dbt templater resolves nothing.
    """
    for candidate in SQLFLUFF_CONFIG_CANDIDATES:
        if not candidate.exists():
            continue
        config_text = candidate.read_text(encoding="utf-8")
        config_text = re.sub(
            r"^project_dir\s*=.*$", f"project_dir = {prepared_dir}", config_text, flags=re.MULTILINE
        )
        config_text = re.sub(
            r"^profiles_dir\s*=.*$", f"profiles_dir = {prepared_dir}", config_text, flags=re.MULTILINE
        )
        prepared_dir.joinpath(".sqlfluff").write_text(config_text, encoding="utf-8")
        return

    raise SystemExit("unable to locate a .sqlfluff config to prepare the lint workspace")


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

    write_workspace_sqlfluff_config(prepared_dir)

    print(f"prepared sqlfluff workspace: {prepared_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
