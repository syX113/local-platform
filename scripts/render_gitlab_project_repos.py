#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
from pathlib import Path
from textwrap import dedent


ROOT_DIR = Path(__file__).resolve().parent.parent
GENERATED_ROOT = ROOT_DIR / "gitlab-projects" / "generated"
TEMPLATE_ROOT = ROOT_DIR / "scripts" / "templates" / "render_gitlab_project_repos"
REGISTRY_PATH = ROOT_DIR / "snowflake" / "project_registry.json"
IGNORE_NAMES = {".DS_Store", "__pycache__", ".dlt", ".loom", "target", "logs", "deployed"}

COMMON_CI_SCRIPTS = [
    "scripts/common.sh",
    "scripts/ensure-snowflake-foundation.sh",
    "scripts/lint-prepared-dbt-project.sh",
    "scripts/prepare-ci-sandbox.sh",
    "scripts/resolve-existing-sandbox.sh",
    "scripts/cleanup-ci-sandbox.sh",
    "scripts/require-approver-match-commit.sh",
    "scripts/deploy-snowflake-dbt-project.sh",
    "scripts/execute-snowflake-dbt-project.sh",
    "scripts/prepare-snowflake-dbt-target.sh",
    "scripts/drop-snowflake-dbt-project.sh",
]

SOURCE_CI_SCRIPTS = COMMON_CI_SCRIPTS + [
    "scripts/load-source-sample-data.sh",
    "scripts/test-airflow-dag.sh",
    "scripts/deploy-airflow-dag.sh",
    "scripts/deploy-sdp-dev.sh",
    "scripts/deploy-sdp-prd.sh",
    "scripts/verify-ingestion-promotion.sh",
    "scripts/verify-sdp-promotion.sh",
]

DOMAIN_CI_SCRIPTS = COMMON_CI_SCRIPTS + [
    "scripts/deploy-edp-dev.sh",
    "scripts/deploy-edp-prd.sh",
    "scripts/verify-edp-promotion.sh",
]


def env(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value or default


def load_registry() -> dict[str, object]:
    payload = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or not isinstance(payload.get("projects"), list):
        raise SystemExit(f"invalid project registry: {REGISTRY_PATH}")
    return payload


def projects() -> list[dict[str, object]]:
    registry = load_registry()
    return [project for project in registry["projects"] if isinstance(project, dict)]


def project_by_slug(slug: str) -> dict[str, object]:
    normalized_slug = slug.strip()
    for project in projects():
        if str(project.get("slug", "")).strip() == normalized_slug:
            return project
    raise SystemExit(f"unknown project slug: {slug}")


def reset_repo(repo_dir: Path) -> None:
    repo_dir.mkdir(parents=True, exist_ok=True)
    for child in repo_dir.iterdir():
        if child.name == ".git":
            continue
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()


def copy_path(src_relative: str, destination_root: Path, dest_relative: str | None = None) -> None:
    source = ROOT_DIR / src_relative
    destination = destination_root / (dest_relative or src_relative)

    if source.is_dir():
        shutil.copytree(
            source,
            destination,
            dirs_exist_ok=True,
            ignore=shutil.ignore_patterns(*IGNORE_NAMES),
        )
        return

    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    if source.suffix == ".sh":
        destination.chmod(destination.stat().st_mode | 0o111)


def write_file(destination: Path, content: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(content, encoding="utf-8")


def template_text(name: str) -> str:
    return (TEMPLATE_ROOT / name).read_text(encoding="utf-8")


def render_template(name: str, **replacements: str) -> str:
    rendered = template_text(name)
    for placeholder, value in replacements.items():
        rendered = rendered.replace(placeholder, value)
    return rendered


def shared_gitignore() -> str:
    return dedent(
        """\
        .DS_Store
        __pycache__/
        *.pyc
        .env
        artifacts/
        logs/
        .loom/
        dbt/.loom/
        dbt/projects/**/.loom/
        dbt/projects/**/loom/
        loom/
        airflow/dags/deployed/
        dbt/profiles/.user.yml
        dbt/target/
        dbt/dbt_packages/
        """
    )


def sqlfluff_lint_prepared_workspace_command(project_slug: str) -> str:
    return f"./ci/scripts/lint-prepared-dbt-project.sh {project_slug}"


def source_ingestion_validation_script(scopes: list[str]) -> str:
    lines: list[str] = []
    for scope in scopes:
        lines.append(f'./ci/scripts/deploy-airflow-dag.sh current {scope} "current-sdp-{scope}-ci"')
        lines.append(f"SOURCE_SCOPE={scope} ./ci/scripts/verify-ingestion-promotion.sh")
    return "\n".join(lines)


def source_model_validation_script(scopes: list[str]) -> str:
    lines = [f"SOURCE_SCOPE={scope} ./ci/scripts/verify-sdp-promotion.sh" for scope in scopes]
    return "\n".join(lines)


def project_readme(project_name: str, body: str) -> str:
    rendered_body = dedent(body).strip()
    return (
        f"# {project_name}\n\n"
        "This repository is rendered from the local platform source repository for fast local testing in GitLab.\n\n"
        "Local CI in this repository assumes the shared `local-platform` stack is already bootstrapped on the Docker host. "
        "The GitLab jobs validate and promote against that running local platform instead of starting a second full copy of the stack inside the runner.\n\n"
        "The shared platform also runs a `gitlab-branch-provisioner` service. GitLab project webhooks notify that service "
        "when a non-default branch is created or deleted and when merge requests are opened, merged, or closed, so branch- "
        "and MR-scoped sandboxes are provisioned and destroyed in step with the GitLab workflow.\n\n"
        f"{rendered_body}\n"
    )


def source_repo_dag_file(*, dag_id: str, scope: str, description: str) -> str:
    return dedent(
        f"""\
        from local_platform_pipeline import build_ingest_dag


        {dag_id} = build_ingest_dag(
            dag_id="{dag_id}",
            description="{description}",
            runtime_overrides={{
                "DLT_SCRIPT_PATH": "/opt/platform/dlt/pipeline_{scope}.py",
                "SNOWFLAKE_RAW_SYNC_SCOPE": "{scope}",
                "SNOWFLAKE_SDP_DBT_SELECT": "{scope}",
            }},
            tags=["source-finnova", "sdp", "{scope}", "postgres", "dlt", "snowflake"],
        )
        """
    )


def copy_registered_project(project_slug: str, repo_dir: Path) -> None:
    project_dir = str(project_by_slug(project_slug).get("dbt_project_dir", "")).strip()
    if not project_dir:
        raise SystemExit(f"missing dbt_project_dir for project: {project_slug}")
    copy_path(project_dir, repo_dir)


def render_source_repo(project_slug: str) -> None:
    spec = project_by_slug(project_slug)
    repo_dir = GENERATED_ROOT / project_slug
    reset_repo(repo_dir)

    copy_path(".dockerignore", repo_dir)
    copy_path(".env.example", repo_dir, "ci/.env.example")

    for relative_path in (
        "airflow",
        "dlt",
        "postgres",
        "minio",
    ):
        copy_path(relative_path, repo_dir)

    for relative_path in SOURCE_CI_SCRIPTS:
        copy_path(relative_path, repo_dir, f"ci/{relative_path}")

    for relative_path in (
        "dbt/.sqlfluff",
        "dbt/Dockerfile",
        "dbt/requirements.txt",
        "dbt/scripts",
        "dbt/profiles",
    ):
        copy_path(relative_path, repo_dir)

    copy_path("snowflake/sql/01_snowflake_foundation.sql.tpl", repo_dir, "ci/snowflake/sql/01_snowflake_foundation.sql.tpl")
    copy_path("snowflake/data_products.json", repo_dir, "ci/snowflake/data_products.json")
    copy_path("snowflake/project_registry.json", repo_dir, "ci/snowflake/project_registry.json")

    copy_registered_project(project_slug, repo_dir)

    scopes = [str(scope).strip() for scope in spec.get("product_scopes", []) if str(scope).strip()]
    for scope in scopes:
        dag_id = f"source_finnova_{scope}_ingest"
        scope_title = scope.replace("_", " ").title()
        write_file(
            repo_dir / f"airflow/dags/{dag_id}.py",
            source_repo_dag_file(
                dag_id=dag_id,
                scope=scope,
                description=f"Finnova source ingestion pipeline for {scope_title} into the SDP {scope} product.",
            ),
        )

    write_file(repo_dir / "compose.yaml", render_template("sdp.compose.yaml.tpl"))
    write_file(repo_dir / "compose.ci.yaml", render_template("sdp.compose.ci.yaml.tpl"))
    write_file(repo_dir / ".gitignore", shared_gitignore())
    write_file(
        repo_dir / ".gitlab-ci.yml",
        render_template(
            "sdp.gitlab-ci.yml.tpl",
            __SQLFLUFF_LINT__=sqlfluff_lint_prepared_workspace_command(project_slug),
            __SOURCE_INGESTION_VALIDATE__=source_ingestion_validation_script(scopes),
            __SOURCE_MODEL_VALIDATE__=source_model_validation_script(scopes),
        ),
    )
    write_file(repo_dir / "README.md", project_readme(project_slug, template_text("sdp.README.md.tpl")))


def render_domain_repo(project_slug: str) -> None:
    spec = project_by_slug(project_slug)
    repo_dir = GENERATED_ROOT / project_slug
    reset_repo(repo_dir)

    copy_path(".dockerignore", repo_dir)
    copy_path(".env.example", repo_dir, "ci/.env.example")

    for relative_path in DOMAIN_CI_SCRIPTS:
        copy_path(relative_path, repo_dir, f"ci/{relative_path}")

    for relative_path in (
        "dbt/.sqlfluff",
        "dbt/Dockerfile",
        "dbt/requirements.txt",
        "dbt/scripts",
        "dbt/profiles",
    ):
        copy_path(relative_path, repo_dir)

    copy_path("snowflake/sql/01_snowflake_foundation.sql.tpl", repo_dir, "ci/snowflake/sql/01_snowflake_foundation.sql.tpl")
    copy_path("snowflake/data_products.json", repo_dir, "ci/snowflake/data_products.json")
    copy_path("snowflake/project_registry.json", repo_dir, "ci/snowflake/project_registry.json")

    copy_registered_project(project_slug, repo_dir)
    # The producer repository is deliberately NOT vendored here. Cross-product
    # dependencies are resolved from the published dbt-loom manifest, which the
    # deploy step turns into a contract stub package, so consumer repositories
    # stay decoupled from producer implementation code.
    upstream_project_slug = str(spec.get("upstream_project_slug", "")).strip()

    project_title = f"Domain {str(spec.get('domain', project_slug)).replace('_', ' ').title()} Promotion"
    scopes = [str(scope).strip() for scope in spec.get("product_scopes", []) if str(scope).strip()]
    upstream_scopes = [str(scope).strip() for scope in project_by_slug(upstream_project_slug).get("product_scopes", [])] if upstream_project_slug else []
    write_file(repo_dir / "compose.yaml", render_template("edp.compose.yaml.tpl"))
    write_file(repo_dir / "compose.ci.yaml", render_template("edp.compose.ci.yaml.tpl"))
    write_file(repo_dir / ".gitignore", shared_gitignore())
    write_file(
        repo_dir / ".gitlab-ci.yml",
        render_template(
            "edp.gitlab-ci.yml.tpl",
            __PROJECT_TITLE__=project_title,
            __PROJECT_SLUG__=project_slug,
            __VERIFY_SCRIPT__=f"./ci/scripts/verify-edp-promotion.sh {project_slug}",
            __DEPLOY_DEV_SCRIPT__=f"./ci/scripts/deploy-edp-dev.sh {project_slug}",
            __DEPLOY_PRD_SCRIPT__=f"./ci/scripts/deploy-edp-prd.sh {project_slug}",
            __ARTIFACT_DIR__=f"artifacts/{project_slug}",
            __DEV_ENVIRONMENT_NAME__=f"DEV/{str(spec.get('domain', project_slug)).replace('_', ' ').upper()}",
            __PRD_ENVIRONMENT_NAME__=f"PRD/{str(spec.get('domain', project_slug)).replace('_', ' ').upper()}",
            __DEV_RESOURCE_GROUP__=f"{project_slug}-dev",
            __PRD_RESOURCE_GROUP__=f"{project_slug}-prd",
        ),
    )
    write_file(
        repo_dir / "README.md",
        render_template(
            "domain.README.md.tpl",
            __PROJECT_TITLE__=project_title,
            __PROJECT_SLUG__=project_slug,
            __DOMAIN_LABEL__=str(spec.get("domain", project_slug)).replace("_", " ").title(),
            __UPSTREAM_PROJECT_SLUG__=upstream_project_slug,
            __SOURCE_SCOPES__=", ".join(upstream_scopes),
            __DOMAIN_SCOPES__=", ".join(scopes),
        ),
    )


def main() -> int:
    source_spec = project_by_slug(env("GITLAB_SDP_PROJECT_PATH", "proj_source_finnova"))
    domain_transactions_spec = project_by_slug(env("GITLAB_EDP_PROJECT_PATH", "proj_domain_transactions"))
    domain_customer_spec = project_by_slug(env("GITLAB_EDP_CUSTOMERS_PROJECT_PATH", "proj_domain_customer"))

    slugs = [str(source_spec["slug"]), str(domain_transactions_spec["slug"]), str(domain_customer_spec["slug"])]
    if len(set(slugs)) != 3:
        raise SystemExit("GitLab source and domain project paths must all be different")

    render_source_repo(str(source_spec["slug"]))
    render_domain_repo(str(domain_transactions_spec["slug"]))
    render_domain_repo(str(domain_customer_spec["slug"]))

    print(f"rendered source project repo: {GENERATED_ROOT / source_spec['slug']}")
    print(f"rendered domain transactions project repo: {GENERATED_ROOT / domain_transactions_spec['slug']}")
    print(f"rendered domain customer project repo: {GENERATED_ROOT / domain_customer_spec['slug']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
