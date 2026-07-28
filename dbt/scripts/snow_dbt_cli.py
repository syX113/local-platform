from __future__ import annotations

import argparse
import gzip
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


def snow_env(extra_env: dict[str, str] | None = None) -> dict[str, str]:
    runtime_env = os.environ.copy()
    runtime_env["SNOWFLAKE_PASSWORD"] = env("SNOWFLAKE_PASSWORD")
    if extra_env:
        for key, value in extra_env.items():
            if value:
                runtime_env[key] = value
    return runtime_env


def run_snow(
    *args: str,
    capture_output: bool = False,
    allow_failure: bool = False,
    extra_env: dict[str, str] | None = None,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    cli_path = ensure_snow_cli_available()
    completed = subprocess.run(
        [cli_path, *args],
        check=False,
        capture_output=capture_output,
        text=True,
        env=snow_env(extra_env),
        cwd=str(cwd) if cwd is not None else None,
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
    for config_path in list(root_dir.rglob("*.yml")) + list(root_dir.rglob("*.yaml")) + list(root_dir.rglob("*.sql")):
        if config_path.name == "profiles.yml":
            continue
        config_path.write_text(render_env_vars(config_path.read_text(encoding="utf-8")), encoding="utf-8")


def dbt_loom_config_path(project_dir: Path) -> Path | None:
    config_path = project_dir / "dbt_loom.config.yml"
    if config_path.exists():
        return config_path
    return None


def dbt_loom_manifest_bucket() -> str:
    return opt_env("MINIO_MANIFEST_BUCKET") or "dbt-manifests"


def fetch_loom_manifest_for_prepared_project(
    prepared_dir: Path,
    *,
    manifest_object_key: str,
    loom_config_path: Path,
    quiet: bool = False,
) -> None:
    if not manifest_object_key:
        return
    if not loom_config_path.exists():
        raise SystemExit(f"missing dbt_loom.config.yml in prepared project: {prepared_dir}")

    manifest_helper = Path(__file__).resolve().with_name("loom_manifest.py")
    completed = subprocess.run(
        [
            sys.executable,
            str(manifest_helper),
            "fetch",
            "--project-dir",
            str(prepared_dir),
            "--bucket",
            dbt_loom_manifest_bucket(),
            "--object-key",
            manifest_object_key,
            "--local-path",
            "loom/manifest.json.gz",
        ],
        check=False,
        text=True,
        env=snow_env({"DBT_LOOM_CONFIG": str(loom_config_path)}),
        capture_output=quiet,
    )
    if completed.returncode != 0:
        if completed.stdout:
            print(completed.stdout, file=sys.stdout, end="")
        if completed.stderr:
            print(completed.stderr, file=sys.stderr, end="")
        raise SystemExit(completed.returncode)


def rewrite_loom_config_for_prepared_project(prepared_dir: Path, loom_config_path: Path) -> None:
    if not loom_config_path.exists():
        return

    manifest_path = prepared_dir / "loom" / "manifest.json.gz"
    if not manifest_path.exists():
        return

    config_text = loom_config_path.read_text(encoding="utf-8")
    rendered_manifest_path = json.dumps(str(manifest_path))
    updated_config_text = config_text.replace(
        "path: loom/manifest.json.gz",
        f"path: {rendered_manifest_path}",
    )
    if updated_config_text != config_text:
        loom_config_path.write_text(updated_config_text, encoding="utf-8")


def project_profile_name(project_dir: Path) -> str:
    match = re.search(r"^\s*profile:\s*([A-Za-z0-9_]+)\s*$", project_dir.joinpath("dbt_project.yml").read_text(encoding="utf-8"), re.MULTILINE)
    if not match:
        raise SystemExit(f"unable to resolve profile name from {project_dir / 'dbt_project.yml'}")
    return match.group(1)


def build_upstream_contract_package(
    prepared_dir: Path,
    *,
    upstream_project_slug: str,
    manifest_path: Path,
) -> int:
    """Materialise the upstream data-product contract as a stub dbt package.

    Snowflake executes dbt with its own managed runtime, which does not load the
    ``dbt-loom`` plugin, so ``ref('<source project>', ...)`` cannot be resolved
    from a loom manifest at run time. Instead the published loom manifest -- the
    contract between the data products -- is translated here into a minimal local
    package that contains one placeholder model per ``public`` upstream node,
    carrying only the physical relation coordinates.

    This keeps the repositories decoupled: no upstream business logic is vendored
    into the consuming repository, and only nodes the producer explicitly marked
    as ``public`` (the ACCESS layer) can be referenced.
    """
    if not manifest_path.exists():
        raise SystemExit(
            f"missing upstream contract manifest for {upstream_project_slug}: {manifest_path}. "
            "Publish the source project manifest before deploying a domain project."
        )

    try:
        manifest = json.loads(gzip.decompress(manifest_path.read_bytes()).decode("utf-8"))
    except Exception as exc:  # pragma: no cover - surfaced as process failure
        raise SystemExit(f"unable to read upstream contract manifest {manifest_path}: {exc}") from exc

    nodes = manifest.get("nodes", {})
    if not isinstance(nodes, dict):
        raise SystemExit(f"invalid upstream contract manifest: {manifest_path}")

    package_dir = prepared_dir / upstream_project_slug
    shutil.rmtree(package_dir, ignore_errors=True)
    models_dir = package_dir / "models"
    models_dir.mkdir(parents=True)

    package_dir.joinpath("dbt_project.yml").write_text(
        f"name: {upstream_project_slug}\n"
        "version: 1.0.0\n"
        "config-version: 2\n"
        'model-paths: ["models"]\n',
        encoding="utf-8",
    )

    exported = 0
    for node in nodes.values():
        if not isinstance(node, dict):
            continue
        if node.get("resource_type") != "model":
            continue
        if str(node.get("package_name", "")).strip() != upstream_project_slug:
            continue
        if str(node.get("access", "")).strip() != "public":
            continue

        name = str(node.get("name", "")).strip()
        database = str(node.get("database", "")).strip()
        schema = str(node.get("schema", "")).strip()
        alias = str(node.get("alias", "")).strip() or name
        if not name or not database or not schema:
            continue

        # The body is never executed: domain builds exclude this package. If it
        # ever were executed it would fail loudly on the self reference instead
        # of overwriting the producer-owned relation.
        models_dir.joinpath(f"{name}.sql").write_text(
            "{{ config(\n"
            f"    database={database!r},\n"
            f"    schema={schema!r},\n"
            f"    alias={alias!r},\n"
            "    materialized='view'\n"
            ") }}\n\n"
            f"-- Contract stub for {upstream_project_slug}.{name}.\n"
            f"-- Generated from the published dbt-loom manifest; the model is owned\n"
            f"-- and materialised by the {upstream_project_slug} repository.\n"
            "select * from {{ this }}\n",
            encoding="utf-8",
        )
        exported += 1

    if not exported:
        raise SystemExit(
            f"upstream contract manifest {manifest_path} exposes no public models for {upstream_project_slug}"
        )

    print(f"generated upstream contract package: {upstream_project_slug} ({exported} public models)")
    return exported


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
    enable_loom: bool = True,
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

    if not enable_loom:
        shutil.rmtree(prepared_dir / "loom", ignore_errors=True)
        loom_config_copy = prepared_dir / "dbt_loom.config.yml"
        if loom_config_copy.exists():
            loom_config_copy.unlink()

    prepared_dir.joinpath("profiles.yml").write_text(
        build_profiles_yml(project_dir, database=database, schema=schema, target_name=target_name),
        encoding="utf-8",
    )

    loom_config_path = dbt_loom_config_path(prepared_dir) if enable_loom else None
    manifest_object_key = str(spec.get("manifest_object_key", "")).strip()

    if enable_loom and manifest_object_key:
        if loom_config_path is None:
            raise SystemExit(f"missing dbt_loom.config.yml for project: {project_identity}")
        fetch_loom_manifest_for_prepared_project(
            prepared_dir,
            manifest_object_key=manifest_object_key,
            loom_config_path=loom_config_path,
            quiet=quiet,
        )
        rewrite_loom_config_for_prepared_project(prepared_dir, loom_config_path)

    if copy_downstream_dependencies and project_kind in {"edp", "domain"}:
        upstream_project_slug = str(spec.get("upstream_project_slug", "")).strip()
        if not upstream_project_slug:
            raise SystemExit(f"missing upstream_project_slug for project: {project_identity}")

        build_upstream_contract_package(
            prepared_dir,
            upstream_project_slug=upstream_project_slug,
            manifest_path=prepared_dir / "loom" / "manifest.json.gz",
        )

        prepared_dir.joinpath("packages.yml").write_text(
            "packages:\n"
            f"  - local: {upstream_project_slug}\n",
            encoding="utf-8",
        )

        # The loom manifest is fetched above, before this point, so dbt-loom can
        # load it cleanly during `dbt deps` and does not need to be disabled here.
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


def strip_non_deployable_artifacts(prepared_dir: Path) -> None:
    """Remove everything that must not end up in the Snowflake dbt project object.

    The loom config and manifest are build-time inputs only: Snowflake cannot load
    the dbt-loom plugin, and the rewritten config points at a local temporary path
    that does not exist server side. Shipping it would advertise a dependency the
    Snowflake runtime silently ignores.
    """
    for relative_path in ("dbt_loom.config.yml", "dbt_loom.config.yml.disabled", "loom", ".loom", "logs", ".user.yml"):
        target = prepared_dir / relative_path
        if target.is_dir():
            shutil.rmtree(target, ignore_errors=True)
        elif target.exists():
            target.unlink()


def validate_upstream_contract(
    project_dir: Path,
    *,
    project_slug: str | None = None,
    database: str,
    schema: str,
    target_name: str,
    quiet: bool = False,
) -> None:
    """Resolve the cross-project graph through dbt-loom before deploying.

    This is where the dbt-loom plugin actually runs: dbt-core parses the consumer
    project with the producer manifest injected, which proves every
    ``ref('<producer>', ...)`` still resolves to a node the producer publishes as
    ``public``. Snowflake executes dbt with its own runtime and cannot load the
    plugin, so this parse is what keeps the data-product contract honest before
    anything is deployed.
    """
    prepared_dir = prepare_project_source(
        project_dir,
        project_slug=project_slug,
        database=database,
        schema=schema,
        target_name=target_name,
        quiet=quiet,
        copy_downstream_dependencies=False,
        enable_loom=True,
    )
    try:
        loom_config_path = prepared_dir / "dbt_loom.config.yml"
        if not loom_config_path.exists():
            raise SystemExit(f"missing dbt_loom.config.yml for contract validation: {prepared_dir}")

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
            env=snow_env({"DBT_LOOM_CONFIG": str(loom_config_path)}),
            capture_output=quiet,
        )
        if completed.returncode != 0:
            if completed.stdout:
                print(completed.stdout, file=sys.stdout, end="")
            if completed.stderr:
                print(completed.stderr, file=sys.stderr, end="")
            raise SystemExit(
                "dbt-loom contract validation failed: the consumer references upstream nodes that the "
                "producer does not publish. Redeploy the producer or fix the cross-project refs."
            )
        print("dbt-loom contract validated: cross-project refs resolve against the published manifest")
    finally:
        shutil.rmtree(prepared_dir.parent, ignore_errors=True)


def deploy_project(*, project_dir: Path, project_name: str, database: str, schema: str, target_name: str, project_slug: str | None = None) -> None:
    spec = project_spec(project_dir, project_slug)
    prepare_targets = spec.get("prepare_targets", [])
    if isinstance(prepare_targets, list):
        for target in prepare_targets:
            if not isinstance(target, dict):
                continue
            database_env = str(target.get("database_env", "")).strip()
            schema_envs = target.get("schema_envs", [])
            if not database_env or not isinstance(schema_envs, list):
                continue
            target_database = env(database_env)
            target_schemas = [env(schema_env) for schema_env in schema_envs if str(schema_env).strip()]
            if not target_schemas:
                continue
            prepare_target(
                project_dir=project_dir,
                project_slug=project_slug,
                database=target_database,
                schema=target_schemas[0],
                target_name=target_name,
                schemas=target_schemas,
            )

    if str(spec.get("kind", "")).strip() in {"edp", "domain"}:
        validate_upstream_contract(
            project_dir,
            project_slug=project_slug,
            database=database,
            schema=schema,
            target_name=target_name,
            quiet=True,
        )

    prepared_dir = prepare_project_source(
        project_dir,
        project_slug=project_slug,
        database=database,
        schema=schema,
        target_name=target_name,
    )
    try:
        strip_non_deployable_artifacts(prepared_dir)
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
            cwd=prepared_dir,
        )
    finally:
        shutil.rmtree(prepared_dir.parent, ignore_errors=True)


SELECTOR_DBT_COMMANDS = {"build", "run", "test", "compile", "list", "ls", "snapshot", "seed"}


def upstream_exclude_args(project_name: str, dbt_command: str, command_args: list[str]) -> list[str]:
    """Keep a domain execution inside its own data-product boundary.

    The upstream contract package only carries placeholder models, so it must
    never be built. Applying the exclusion here rather than at every call site
    means no caller can forget it.
    """
    if dbt_command not in SELECTOR_DBT_COMMANDS:
        return []
    if any(arg in {"--exclude", "--selector"} for arg in command_args):
        return []

    try:
        spec = project_by_name(project_name)
    except SystemExit:
        return []
    if str(spec.get("kind", "")).strip() not in {"edp", "domain"}:
        return []
    upstream_project_slug = str(spec.get("upstream_project_slug", "")).strip()
    if not upstream_project_slug:
        return []
    return ["--exclude", f"package:{upstream_project_slug}"]


def execute_project(*, project_name: str, dbt_command: str, command_args: list[str]) -> None:
    run_snow(
        "dbt",
        "execute",
        *snow_connection_args(),
        fully_qualified_project_name(project_name),
        dbt_command,
        *command_args,
        *upstream_exclude_args(project_name, dbt_command, command_args),
    )


def prepare_target(
    *,
    project_dir: Path,
    project_slug: str | None = None,
    database: str,
    schema: str,
    target_name: str,
    schemas: list[str],
) -> None:
    """Create the target database and schemas if they do not exist yet.

    This runs as plain DDL over a single Snowflake connection instead of a local
    ``dbt run-operation``. Spawning dbt required copying the whole project tree,
    resolving packages and starting a dbt process for every single target, which
    dominated deployment time while producing exactly the same DDL.
    """
    del project_dir, project_slug, schema, target_name

    ordered_schemas = list(dict.fromkeys(name for name in schemas if name.strip()))
    if not database.strip() or not ordered_schemas:
        return

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
            cursor.execute(f"use role {ident(env('SNOWFLAKE_ROLE'))}")
            cursor.execute(f"use warehouse {ident(env('SNOWFLAKE_WAREHOUSE'))}")
            cursor.execute(f"create database if not exists {ident(database)}")
            for schema_name in ordered_schemas:
                cursor.execute(f"create schema if not exists {ident(database, schema_name)}")
    finally:
        connection.close()

    print({"prepared_database": database, "prepared_schemas": ordered_schemas})


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
