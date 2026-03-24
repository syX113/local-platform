from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import snowflake.connector

from project_registry import project_by_name, project_by_slug


ENV_VAR_PATTERN = re.compile(
    r"env_var\(\s*'([^']+)'\s*(?:,\s*'([^']*)'\s*)?\)"
)
EXCLUDED_PATH_NAMES = {".git", "__pycache__", "target", "logs", "dbt_packages"}


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, "").strip()
    if value:
        return value
    if default is not None:
        return default
    raise SystemExit(f"missing required environment variable: {name}")


def opt_env(name: str) -> str:
    return os.environ.get(name, "").strip()


def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)


def ensure_snow_cli_available() -> str:
    cli_path = shutil.which("snow")
    if not cli_path:
        raise SystemExit("snow CLI is not available in PATH")
    return cli_path


def snow_connection_args() -> list[str]:
    return [
        "-x",
        "--account",
        env("SNOWFLAKE_ACCOUNT"),
        "--user",
        env("SNOWFLAKE_USER"),
        "--role",
        env("SNOWFLAKE_ROLE"),
        "--warehouse",
        env("SNOWFLAKE_WAREHOUSE"),
        "--database",
        env("SNOWFLAKE_CONTROL_DATABASE"),
        "--schema",
        env("SNOWFLAKE_CONTROL_SCHEMA"),
    ]


def snow_env() -> dict[str, str]:
    runtime_env = os.environ.copy()
    runtime_env["SNOWFLAKE_PASSWORD"] = env("SNOWFLAKE_PASSWORD")
    return runtime_env


def run_snow(*args: str, capture_output: bool = False, allow_failure: bool = False) -> subprocess.CompletedProcess[str]:
    cli_path = ensure_snow_cli_available()
    completed = subprocess.run(
        [cli_path, *args],
        check=False,
        capture_output=capture_output,
        text=True,
        env=snow_env(),
    )
    if completed.returncode != 0 and not allow_failure:
        if completed.stdout:
            print(completed.stdout, file=sys.stdout, end="")
        if completed.stderr:
            print(completed.stderr, file=sys.stderr, end="")
        raise SystemExit(completed.returncode)
    return completed


def control_database() -> str:
    return env("SNOWFLAKE_CONTROL_DATABASE")


def control_schema() -> str:
    return env("SNOWFLAKE_CONTROL_SCHEMA")


def fully_qualified_project_name(name: str) -> str:
    if "." in name:
        return name
    return ident(control_database(), control_schema(), name)


def project_spec(project_dir: Path, project_slug: str | None = None) -> dict[str, object]:
    if project_slug:
        try:
            return project_by_slug(project_slug)
        except SystemExit:
            pass

    try:
        return project_by_slug(project_dir.name)
    except SystemExit:
        pass

    try:
        return project_by_name(project_dir.name)
    except SystemExit:
        return {}


def project_registry_env_value(spec: dict[str, object], field: str, *, required: bool = True, default: str = "") -> str:
    env_name = str(spec.get(field, "")).strip()
    if not env_name:
        if required:
            raise SystemExit(f"missing project registry field: {field}")
        return default
    return env(env_name, default if not required else None)


def render_env_vars(raw_text: str) -> str:
    def replace(match: re.Match[str]) -> str:
        variable_name = match.group(1)
        default_value = match.group(2)
        rendered = env(variable_name, default_value)
        escaped = rendered.replace("\\", "\\\\").replace("'", "\\'")
        return f"'{escaped}'"

    return ENV_VAR_PATTERN.sub(replace, raw_text)


def render_env_vars_in_tree(root_dir: Path) -> None:
    for config_path in list(root_dir.rglob("*.yml")) + list(root_dir.rglob("*.yaml")):
        if config_path.name == "profiles.yml":
            continue
        config_path.write_text(render_env_vars(config_path.read_text(encoding="utf-8")), encoding="utf-8")


def project_profile_name(project_dir: Path) -> str:
    match = re.search(r"^\s*profile:\s*([A-Za-z0-9_]+)\s*$", project_dir.joinpath("dbt_project.yml").read_text(encoding="utf-8"), re.MULTILINE)
    if not match:
        raise SystemExit(f"unable to resolve profile name from {project_dir / 'dbt_project.yml'}")
    return match.group(1)


def build_profiles_yml(project_dir: Path, *, database: str, schema: str, target_name: str) -> str:
    return (
        f"{project_profile_name(project_dir)}:\n"
        f"  target: {target_name}\n"
        "  outputs:\n"
        f"    {target_name}:\n"
        "      type: snowflake\n"
        f"      account: \"{env('SNOWFLAKE_ACCOUNT')}\"\n"
        f"      user: \"{env('SNOWFLAKE_USER')}\"\n"
        f"      password: \"{env('SNOWFLAKE_PASSWORD')}\"\n"
        f"      role: \"{env('SNOWFLAKE_ROLE')}\"\n"
        f"      warehouse: \"{env('SNOWFLAKE_WAREHOUSE')}\"\n"
        f"      database: \"{database}\"\n"
        f"      schema: \"{schema}\"\n"
        f"      threads: {int(opt_env('DBT_THREADS') or '4')}\n"
    )


def prepare_project_source(
    project_dir: Path,
    *,
    project_slug: str | None = None,
    database: str,
    schema: str,
    target_name: str,
    quiet: bool = False,
    copy_downstream_dependencies: bool = True,
    work_dir: Path | None = None,
) -> Path:
    if not project_dir.joinpath("dbt_project.yml").exists():
        raise SystemExit(f"{project_dir} is not a dbt project directory")

    spec = project_spec(project_dir, project_slug)
    project_identity = str(spec.get("slug", project_slug or project_dir.name)).strip()
    project_kind = str(spec.get("kind", "")).strip()

    if work_dir is None:
        work_root = Path(tempfile.mkdtemp(prefix="snow-dbt-project-"))
        prepared_dir = work_root / "project"
    else:
        work_root = Path(work_dir)
        prepared_dir = work_root / "project"
        shutil.rmtree(prepared_dir, ignore_errors=True)

    shutil.copytree(
        project_dir,
        prepared_dir,
        ignore=shutil.ignore_patterns(*EXCLUDED_PATH_NAMES),
    )

    render_env_vars_in_tree(prepared_dir)

    prepared_dir.joinpath("profiles.yml").write_text(
        build_profiles_yml(project_dir, database=database, schema=schema, target_name=target_name),
        encoding="utf-8",
    )

    if copy_downstream_dependencies and project_kind == "edp":
        upstream_project_slug = str(spec.get("upstream_project_slug", "")).strip()
        if not upstream_project_slug:
            raise SystemExit(f"missing upstream_project_slug for project: {project_identity}")

        local_source_project_dir = project_dir.parent / upstream_project_slug
        if not local_source_project_dir.exists():
            raise SystemExit(
                f"missing local dependency project directory: {local_source_project_dir}"
            )

        local_dependency_dir = prepared_dir / upstream_project_slug
        shutil.copytree(
            local_source_project_dir,
            local_dependency_dir,
            ignore=shutil.ignore_patterns(*EXCLUDED_PATH_NAMES),
        )
        render_env_vars_in_tree(local_dependency_dir)

        prepared_dir.joinpath("packages.yml").write_text(
            "packages:\n"
            f"  - local: {upstream_project_slug}\n",
            encoding="utf-8",
        )

        completed = subprocess.run(
            [
                shutil.which("dbt") or "dbt",
                "deps",
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
            capture_output=quiet,
        )
        if completed.returncode != 0:
            if completed.stdout:
                print(completed.stdout, file=sys.stdout, end="")
            if completed.stderr:
                print(completed.stderr, file=sys.stderr, end="")
            raise SystemExit(completed.returncode)

    return prepared_dir


def deploy_project(*, project_dir: Path, project_name: str, database: str, schema: str, target_name: str, project_slug: str | None = None) -> None:
    prepared_dir = prepare_project_source(
        project_dir,
        project_slug=project_slug,
        database=database,
        schema=schema,
        target_name=target_name,
    )
    try:
        run_snow(
            "dbt",
            "deploy",
            *snow_connection_args(),
            fully_qualified_project_name(project_name),
            "--source",
            str(prepared_dir),
            "--profiles-dir",
            str(prepared_dir),
            "--default-target",
            target_name,
            "--force",
        )
    finally:
        shutil.rmtree(prepared_dir.parent, ignore_errors=True)


def execute_project(*, project_name: str, dbt_command: str, command_args: list[str]) -> None:
    run_snow(
        "dbt",
        "execute",
        *snow_connection_args(),
        fully_qualified_project_name(project_name),
        dbt_command,
        *command_args,
    )


def run_local_dbt(
    *,
    project_dir: Path,
    project_slug: str | None = None,
    database: str,
    schema: str,
    target_name: str,
    dbt_args: list[str],
) -> None:
    prepared_dir = prepare_project_source(
        project_dir,
        project_slug=project_slug,
        database=database,
        schema=schema,
        target_name=target_name,
    )
    try:
        completed = subprocess.run(
            [
                shutil.which("dbt") or "dbt",
                *dbt_args,
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
    finally:
        shutil.rmtree(prepared_dir.parent, ignore_errors=True)


def prepare_target(
    *,
    project_dir: Path,
    project_slug: str | None = None,
    database: str,
    schema: str,
    target_name: str,
    schemas: list[str],
) -> None:
    run_local_dbt(
        project_dir=project_dir,
        project_slug=project_slug,
        database=database,
        schema=schema,
        target_name=target_name,
        dbt_args=[
            "run-operation",
            "ensure_target_database_and_schemas",
            "--args",
            json.dumps({"database_name": database, "schemas": schemas}),
        ],
    )


def drop_project(project_name: str) -> None:
    if not project_name.strip():
        return
    completed = run_snow(
        "dbt",
        "drop",
        *snow_connection_args(),
        fully_qualified_project_name(project_name),
        capture_output=True,
        allow_failure=True,
    )
    if completed.returncode == 0:
        return

    combined_output = "\n".join(part for part in (completed.stdout, completed.stderr) if part)
    if "does not exist" in combined_output.lower():
        return

    if completed.stdout:
        print(completed.stdout, file=sys.stdout, end="")
    if completed.stderr:
        print(completed.stderr, file=sys.stderr, end="")
    raise SystemExit(completed.returncode)


def purge_all_projects() -> None:
    project_names: list[str] = []
    try:
        connection = snowflake.connector.connect(
            account=env("SNOWFLAKE_ACCOUNT"),
            user=env("SNOWFLAKE_USER"),
            password=env("SNOWFLAKE_PASSWORD"),
            role=env("SNOWFLAKE_ROLE"),
            warehouse=env("SNOWFLAKE_WAREHOUSE"),
            autocommit=True,
        )
        try:
            with connection.cursor() as cursor:
                cursor.execute(f"show dbt projects in schema {ident(control_database(), control_schema())}")
                column_names = [description[0].lower() for description in cursor.description or []]
                try:
                    name_index = column_names.index("name")
                except ValueError:
                    name_index = 1
                for row in cursor.fetchall():
                    name = str(row[name_index]).strip()
                    if name:
                        project_names.append(name)
        finally:
            connection.close()
    except snowflake.connector.errors.ProgrammingError as error:
        if "does not exist or not authorized" in str(error).lower():
            return
        raise

    for project_name in project_names:
        drop_project(project_name)


def default_database_for_project(project_dir: Path, project_slug: str | None = None) -> str:
    spec = project_spec(project_dir, project_slug)
    return project_registry_env_value(spec, "default_database_env")


def default_schema_for_project(project_dir: Path, project_slug: str | None = None) -> str:
    spec = project_spec(project_dir, project_slug)
    return project_registry_env_value(spec, "default_schema_env")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    deploy_parser = subparsers.add_parser("deploy")
    deploy_parser.add_argument("--project-dir", required=True)
    deploy_parser.add_argument("--project-name", required=True)
    deploy_parser.add_argument("--project-slug")
    deploy_parser.add_argument("--database")
    deploy_parser.add_argument("--schema")
    deploy_parser.add_argument("--target-name", default="dev")

    prepare_parser = subparsers.add_parser("prepare-target")
    prepare_parser.add_argument("--project-dir", required=True)
    prepare_parser.add_argument("--project-slug")
    prepare_parser.add_argument("--database", required=True)
    prepare_parser.add_argument("--schema", required=True)
    prepare_parser.add_argument("--target-name", default="dev")
    prepare_parser.add_argument("--schemas", nargs="+", required=True)

    execute_parser = subparsers.add_parser("execute")
    execute_parser.add_argument("--project-name", required=True)
    execute_parser.add_argument("dbt_command")
    execute_parser.add_argument("command_args", nargs=argparse.REMAINDER)

    drop_parser = subparsers.add_parser("drop")
    drop_parser.add_argument("--project-name", required=True)

    subparsers.add_parser("purge")
    return parser


def main() -> int:
    args = build_parser().parse_args()

    if args.command == "deploy":
        project_dir = Path(args.project_dir)
        deploy_project(
            project_dir=project_dir,
            project_name=args.project_name,
            database=args.database or default_database_for_project(project_dir),
            schema=args.schema or default_schema_for_project(project_dir),
            target_name=args.target_name,
            project_slug=args.project_slug,
        )
        return 0

    if args.command == "prepare-target":
        prepare_target(
            project_dir=Path(args.project_dir),
            project_slug=args.project_slug,
            database=args.database,
            schema=args.schema,
            target_name=args.target_name,
            schemas=args.schemas,
        )
        return 0

    if args.command == "execute":
        execute_project(
            project_name=args.project_name,
            dbt_command=args.dbt_command,
            command_args=args.command_args,
        )
        return 0

    if args.command == "drop":
        drop_project(args.project_name)
        return 0

    if args.command == "purge":
        purge_all_projects()
        return 0

    raise SystemExit(f"unsupported command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
