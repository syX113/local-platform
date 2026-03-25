#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
from pathlib import Path
from textwrap import dedent


ROOT_DIR = Path(__file__).resolve().parent.parent
GENERATED_ROOT = ROOT_DIR / "gitlab-projects" / "generated"
TEMPLATE_ROOT = ROOT_DIR / "scripts" / "templates" / "render_gitlab_project_repos"
IGNORE_NAMES = {".DS_Store", "__pycache__", ".dlt", ".loom", "target", "logs", "deployed"}


def env(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value or default


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
    template_path = TEMPLATE_ROOT / name
    return template_path.read_text(encoding="utf-8")


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
    return dedent(
        """\
            - mkdir -p artifacts/sqlfluff/{workspace_name}
            - docker compose run --rm --no-deps dbt-executor python /opt/platform/dbt/scripts/prepare_sqlfluff_workspace.py --project-dir /opt/platform/dbt --project-slug {project_slug} --workspace-dir /opt/platform/artifacts/sqlfluff/{workspace_name}
            - docker compose run --rm --no-deps dbt-executor sqlfluff lint --config /opt/platform/artifacts/sqlfluff/{workspace_name}/.sqlfluff /opt/platform/artifacts/sqlfluff/{workspace_name}/models
            - rm -rf artifacts/sqlfluff/{workspace_name}
        """
    ).format(project_slug=project_slug, workspace_name=project_slug)


def sdp_ci_yaml(*, sqlfluff_lint_script: str) -> str:
    return render_template("sdp.gitlab-ci.yml.tpl", __SQLFLUFF_LINT__=sqlfluff_lint_script)


def edp_ci_yaml(
    *,
    project_title: str,
    project_slug: str,
    sqlfluff_lint_script: str,
    verify_script: str,
    deploy_dev_script: str,
    deploy_prd_script: str,
    artifact_dir: str,
    dev_environment_name: str,
    prd_environment_name: str,
    dev_resource_group: str,
    prd_resource_group: str,
) -> str:
    return render_template(
        "edp.gitlab-ci.yml.tpl",
        __PROJECT_TITLE__=project_title,
        __PROJECT_SLUG__=project_slug,
        __VERIFY_SCRIPT__=verify_script,
        __DEPLOY_DEV_SCRIPT__=deploy_dev_script,
        __DEPLOY_PRD_SCRIPT__=deploy_prd_script,
        __ARTIFACT_DIR__=artifact_dir,
        __DEV_ENVIRONMENT_NAME__=dev_environment_name,
        __PRD_ENVIRONMENT_NAME__=prd_environment_name,
        __DEV_RESOURCE_GROUP__=dev_resource_group,
        __PRD_RESOURCE_GROUP__=prd_resource_group,
    )


def sdp_compose_yaml() -> str:
    return template_text("sdp.compose.yaml.tpl")


def sdp_compose_ci_yaml() -> str:
    return template_text("sdp.compose.ci.yaml.tpl")


def edp_compose_yaml() -> str:
    return template_text("edp.compose.yaml.tpl")


def edp_compose_ci_yaml() -> str:
    return template_text("edp.compose.ci.yaml.tpl")


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


def render_sdp_repo(project_path: str) -> None:
    repo_dir = GENERATED_ROOT / project_path
    reset_repo(repo_dir)

    for relative_path in (
        ".dockerignore",
        "airflow",
        "dlt",
        "postgres",
        "minio",
    ):
        copy_path(relative_path, repo_dir)
    copy_path(".env.example", repo_dir, "ci/.env.example")

    for relative_path in (
        "scripts/common.sh",
        "scripts/ensure-snowflake-foundation.sh",
        "scripts/lint-prepared-dbt-project.sh",
        "scripts/prepare-ci-sandbox.sh",
        "scripts/resolve-existing-sandbox.sh",
        "scripts/cleanup-ci-sandbox.sh",
        "scripts/require-approver-match-commit.sh",
        "scripts/load-source-sample-data.sh",
        "scripts/test-airflow-dag.sh",
        "scripts/deploy-airflow-dag.sh",
        "scripts/deploy-snowflake-dbt-project.sh",
        "scripts/execute-snowflake-dbt-project.sh",
        "scripts/prepare-snowflake-dbt-target.sh",
        "scripts/drop-snowflake-dbt-project.sh",
        "scripts/deploy-sdp-dev.sh",
        "scripts/deploy-sdp-prd.sh",
        "scripts/verify-ingestion-promotion.sh",
        "scripts/verify-sdp-promotion.sh",
    ):
        copy_path(relative_path, repo_dir, f"ci/{relative_path}")

    for relative_path in (
        "dbt/.sqlfluff",
        "dbt/Dockerfile",
        "dbt/requirements.txt",
        "dbt/scripts/project_registry.py",
        "dbt/scripts/apply_sql.py",
        "dbt/scripts/ensure_target_databases.py",
        "dbt/scripts/prepare_sqlfluff_workspace.py",
        "dbt/scripts/loom_manifest.py",
        "dbt/scripts/manage_ci_clones.py",
        "dbt/scripts/snow_dbt_cli.py",
    ):
        copy_path(relative_path, repo_dir)
    copy_path("dbt/profiles/profiles.yml", repo_dir, "dbt/profiles/profiles.yml")

    copy_path("snowflake/sql/01_snowflake_foundation.sql.tpl", repo_dir, "ci/snowflake/sql/01_snowflake_foundation.sql.tpl")
    copy_path("snowflake/data_products.json", repo_dir, "ci/snowflake/data_products.json")
    copy_path("snowflake/project_registry.json", repo_dir, "ci/snowflake/project_registry.json")

    copy_path("dbt/projects/proj_source_finnova/macros", repo_dir, "dbt/macros")
    copy_path("dbt/projects/proj_source_finnova/dbt_project.yml", repo_dir, "dbt/dbt_project.yml")
    copy_path("dbt/projects/proj_source_finnova/models", repo_dir, "dbt/models")
    write_file(
        repo_dir / "airflow/dags/source_finnova_orders_ingest.py",
        source_repo_dag_file(
            dag_id="source_finnova_orders_ingest",
            scope="orders",
            description="Finnova source ingestion pipeline for orders into the SDP orders product.",
        ),
    )
    write_file(
        repo_dir / "airflow/dags/source_finnova_customers_ingest.py",
        source_repo_dag_file(
            dag_id="source_finnova_customers_ingest",
            scope="customers",
            description="Finnova source ingestion pipeline for customers into the SDP customers product.",
        ),
    )

    write_file(repo_dir / "compose.yaml", sdp_compose_yaml())
    write_file(repo_dir / "compose.ci.yaml", sdp_compose_ci_yaml())
    write_file(repo_dir / ".gitignore", shared_gitignore())
    write_file(
        repo_dir / ".gitlab-ci.yml",
        sdp_ci_yaml(sqlfluff_lint_script=sqlfluff_lint_prepared_workspace_command("proj_source_finnova")),
    )
    write_file(
        repo_dir / "README.md",
        project_readme(project_path, template_text("sdp.README.md.tpl")),
    )


def render_edp_repo(project_path: str) -> None:
    repo_dir = GENERATED_ROOT / project_path
    reset_repo(repo_dir)

    copy_path(".dockerignore", repo_dir)
    copy_path(".env.example", repo_dir, "ci/.env.example")

    for relative_path in (
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
        "scripts/deploy-edp-dev.sh",
        "scripts/deploy-edp-prd.sh",
        "scripts/verify-edp-promotion.sh",
    ):
        copy_path(relative_path, repo_dir, f"ci/{relative_path}")

    for relative_path in (
        "dbt/.sqlfluff",
        "dbt/Dockerfile",
        "dbt/requirements.txt",
        "dbt/scripts/project_registry.py",
        "dbt/scripts/apply_sql.py",
        "dbt/scripts/ensure_target_databases.py",
        "dbt/scripts/prepare_sqlfluff_workspace.py",
        "dbt/scripts/loom_manifest.py",
        "dbt/scripts/manage_ci_clones.py",
        "dbt/scripts/snow_dbt_cli.py",
        "dbt/scripts/zero_copy_clone_check.py",
    ):
        copy_path(relative_path, repo_dir)
    copy_path("dbt/profiles/profiles.yml", repo_dir, "dbt/profiles/profiles.yml")
    copy_path("dbt/projects/proj_edp_orders/dbt_loom.config.yml", repo_dir, "dbt/dbt_loom.config.yml")

    copy_path("snowflake/sql/01_snowflake_foundation.sql.tpl", repo_dir, "ci/snowflake/sql/01_snowflake_foundation.sql.tpl")
    copy_path("snowflake/data_products.json", repo_dir, "ci/snowflake/data_products.json")
    copy_path("snowflake/project_registry.json", repo_dir, "ci/snowflake/project_registry.json")

    copy_path("dbt/projects/proj_edp_orders/macros", repo_dir, "dbt/macros")
    copy_path("dbt/projects/proj_edp_orders/dbt_project.yml", repo_dir, "dbt/dbt_project.yml")
    copy_path("dbt/projects/proj_edp_orders/models", repo_dir, "dbt/models")

    write_file(repo_dir / "compose.yaml", edp_compose_yaml())
    write_file(repo_dir / "compose.ci.yaml", edp_compose_ci_yaml())
    write_file(repo_dir / ".gitignore", shared_gitignore())
    write_file(
        repo_dir / ".gitlab-ci.yml",
        edp_ci_yaml(
            project_title="EDP Promotion",
            project_slug="proj_edp_orders",
            sqlfluff_lint_script=sqlfluff_lint_prepared_workspace_command("proj_edp_orders"),
            verify_script="./ci/scripts/verify-edp-promotion.sh proj_edp_orders",
            deploy_dev_script="./ci/scripts/deploy-edp-dev.sh proj_edp_orders",
            deploy_prd_script="./ci/scripts/deploy-edp-prd.sh proj_edp_orders",
            artifact_dir="artifacts/proj_edp_orders",
            dev_environment_name="DEV/EDP",
            prd_environment_name="PRD/EDP",
            dev_resource_group="edp-dev",
            prd_resource_group="edp-prd",
        ),
    )
    write_file(
        repo_dir / "README.md",
        project_readme(project_path, template_text("edp_orders.README.md.tpl")),
    )


def render_edp_customers_repo(project_path: str) -> None:
    repo_dir = GENERATED_ROOT / project_path
    reset_repo(repo_dir)

    copy_path(".dockerignore", repo_dir)
    copy_path(".env.example", repo_dir, "ci/.env.example")

    for relative_path in (
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
        "scripts/deploy-edp-dev.sh",
        "scripts/deploy-edp-prd.sh",
        "scripts/verify-edp-promotion.sh",
    ):
        copy_path(relative_path, repo_dir, f"ci/{relative_path}")

    for relative_path in (
        "dbt/.sqlfluff",
        "dbt/Dockerfile",
        "dbt/requirements.txt",
        "dbt/scripts/project_registry.py",
        "dbt/scripts/apply_sql.py",
        "dbt/scripts/ensure_target_databases.py",
        "dbt/scripts/prepare_sqlfluff_workspace.py",
        "dbt/scripts/loom_manifest.py",
        "dbt/scripts/manage_ci_clones.py",
        "dbt/scripts/snow_dbt_cli.py",
        "dbt/scripts/zero_copy_clone_check.py",
    ):
        copy_path(relative_path, repo_dir)
    copy_path("dbt/profiles/profiles.yml", repo_dir, "dbt/profiles/profiles.yml")
    copy_path("dbt/projects/proj_edp_customers/dbt_loom.config.yml", repo_dir, "dbt/dbt_loom.config.yml")

    copy_path("snowflake/sql/01_snowflake_foundation.sql.tpl", repo_dir, "ci/snowflake/sql/01_snowflake_foundation.sql.tpl")
    copy_path("snowflake/data_products.json", repo_dir, "ci/snowflake/data_products.json")
    copy_path("snowflake/project_registry.json", repo_dir, "ci/snowflake/project_registry.json")

    copy_path("dbt/projects/proj_edp_customers/macros", repo_dir, "dbt/macros")
    copy_path("dbt/projects/proj_edp_customers/dbt_project.yml", repo_dir, "dbt/dbt_project.yml")
    copy_path("dbt/projects/proj_edp_customers/models", repo_dir, "dbt/models")

    write_file(repo_dir / "compose.yaml", edp_compose_yaml())
    write_file(repo_dir / "compose.ci.yaml", edp_compose_ci_yaml())
    write_file(repo_dir / ".gitignore", shared_gitignore())
    write_file(
        repo_dir / ".gitlab-ci.yml",
        edp_ci_yaml(
            project_title="EDP Customers Promotion",
            project_slug="proj_edp_customers",
            sqlfluff_lint_script=sqlfluff_lint_prepared_workspace_command("proj_edp_customers"),
            verify_script="./ci/scripts/verify-edp-promotion.sh proj_edp_customers",
            deploy_dev_script="./ci/scripts/deploy-edp-dev.sh proj_edp_customers",
            deploy_prd_script="./ci/scripts/deploy-edp-prd.sh proj_edp_customers",
            artifact_dir="artifacts/proj_edp_customers",
            dev_environment_name="DEV/EDP_CUSTOMERS",
            prd_environment_name="PRD/EDP_CUSTOMERS",
            dev_resource_group="edp-customers-dev",
            prd_resource_group="edp-customers-prd",
        ),
    )
    write_file(
        repo_dir / "README.md",
        project_readme(project_path, template_text("edp_customers.README.md.tpl")),
    )


def main() -> int:
    sdp_project_path = env("GITLAB_SDP_PROJECT_PATH", "proj_source_finnova")
    edp_project_path = env("GITLAB_EDP_PROJECT_PATH", "proj_edp_orders")
    edp_customers_project_path = env("GITLAB_EDP_CUSTOMERS_PROJECT_PATH", "proj_edp_customers")

    if len({sdp_project_path, edp_project_path, edp_customers_project_path}) != 3:
        raise SystemExit("GitLab source and EDP project paths must all be different")

    render_sdp_repo(sdp_project_path)
    render_edp_repo(edp_project_path)
    render_edp_customers_repo(edp_customers_project_path)

    print(f"rendered source project repo: {GENERATED_ROOT / sdp_project_path}")
    print(f"rendered EDP orders project repo: {GENERATED_ROOT / edp_project_path}")
    print(f"rendered EDP customers project repo: {GENERATED_ROOT / edp_customers_project_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
