#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
from pathlib import Path
from textwrap import dedent


ROOT_DIR = Path(__file__).resolve().parent.parent
GENERATED_ROOT = ROOT_DIR / "gitlab-projects" / "generated"
IGNORE_NAMES = {".DS_Store", "__pycache__", ".dlt", "target", "logs"}


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


def write_file(destination: Path, content: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(content, encoding="utf-8")


def shared_gitignore() -> str:
    return dedent(
        """\
        .DS_Store
        __pycache__/
        *.pyc
        .env
        artifacts/
        logs/
        dbt/profiles/.user.yml
        dbt/target/
        dbt/dbt_packages/
        """
    )


def sdp_ci_yaml() -> str:
    return dedent(
        """\
        workflow:
          name: SDP Promotion
          rules:
            - if: '$CI_PIPELINE_SOURCE == "push"'
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - if: '$CI_PIPELINE_SOURCE == "web"'
            - if: '$CI_PIPELINE_SOURCE == "api"'
            - when: never

        default:
          image: docker:29.1.3-cli
          tags:
            - local
            - fargate
          before_script:
            - apk add --no-cache bash curl
            - docker version
            - docker compose version
            - cp .env.example .env
            - mkdir -p artifacts
            - export LOCAL_PLATFORM_PROJECT_NAME="${LOCAL_PLATFORM_PROJECT_NAME:-local-platform}"
            - export LOCAL_PLATFORM_SHARED_STACK="true"
            - export COMPOSE_FILE="compose.yaml:compose.ci.yaml"
            - export COMPOSE_PROJECT_NAME="${LOCAL_PLATFORM_PROJECT_NAME}"
            - export PLATFORM_DOCKER_NETWORK="${PLATFORM_DOCKER_NETWORK:-${LOCAL_PLATFORM_PROJECT_NAME}-net}"
          after_script:
            - docker compose ps || true

        stages:
          - build
          - prepare
          - validate
          - promote_ingestion
          - promote_sdp
          - cd_verify
          - cleanup

        build_sdp_runtimes:
          stage: build
          script:
            - export RUNTIME_IMAGE_PREFIX="${CI_PROJECT_PATH_SLUG}-${CI_PIPELINE_ID}"
            - mkdir -p artifacts/context
            - docker compose build airflow-webserver dlt-extractor dbt-executor
            - printf 'RUNTIME_IMAGE_PREFIX=%s\\n' "${RUNTIME_IMAGE_PREFIX}" > artifacts/context/runtime.env
            - printf 'DLT_RUNNER_IMAGE=%s/dlt-extractor:dev\\n' "${RUNTIME_IMAGE_PREFIX}" >> artifacts/context/runtime.env
            - printf 'DBT_RUNNER_IMAGE=%s/dbt-executor:dev\\n' "${RUNTIME_IMAGE_PREFIX}" >> artifacts/context/runtime.env
          artifacts:
            when: always
            reports:
              dotenv: artifacts/context/runtime.env
            paths:
              - artifacts/context/

        prepare_sdp_sandbox:
          stage: prepare
          script:
            - ./scripts/prepare-ci-sandbox.sh sdp artifacts/context/sdp.env
          artifacts:
            when: always
            reports:
              dotenv: artifacts/context/sdp.env
            paths:
              - artifacts/context/

        validate_sdp_assets:
          stage: validate
          needs:
            - job: build_sdp_runtimes
              artifacts: true
            - job: prepare_sdp_sandbox
              artifacts: true
          script:
            - set -a; . artifacts/context/runtime.env; . artifacts/context/sdp.env; set +a
            - docker compose config -q
            - docker compose run --rm --no-deps --entrypoint python airflow-webserver -m compileall /opt/airflow/dags
            - docker compose run --rm --no-deps --entrypoint python dlt-extractor -m compileall /opt/platform/dlt
            - docker compose run --rm --no-deps --entrypoint python dbt-executor -m compileall /opt/platform/dbt
            - docker compose run --rm --no-deps dbt-executor dbt parse --project-dir /opt/platform/dbt --profiles-dir /opt/platform/dbt/profiles
            - docker compose run --rm --no-deps dbt-executor sqlfluff lint --config /opt/platform/dbt/.sqlfluff /opt/platform/dbt/models

        promote_sdp_ingestion:
          stage: promote_ingestion
          needs:
            - job: build_sdp_runtimes
              artifacts: true
            - job: prepare_sdp_sandbox
              artifacts: true
          script:
            - set -a; . artifacts/context/runtime.env; . artifacts/context/sdp.env; set +a
            - ./scripts/verify-ingestion-promotion.sh
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/ingestion/

        promote_sdp_models:
          stage: promote_sdp
          needs:
            - job: build_sdp_runtimes
              artifacts: true
            - job: prepare_sdp_sandbox
              artifacts: true
            - job: promote_sdp_ingestion
              artifacts: true
          script:
            - set -a; . artifacts/context/runtime.env; . artifacts/context/sdp.env; set +a
            - ./scripts/verify-sdp-promotion.sh
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/sdp/

        verify_sdp_cd_clone:
          stage: cd_verify
          needs:
            - job: build_sdp_runtimes
              artifacts: true
            - job: prepare_sdp_sandbox
              artifacts: true
            - job: promote_sdp_models
              artifacts: true
          rules:
            - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
            - when: never
          script:
            - set -a; . artifacts/context/runtime.env; . artifacts/context/sdp.env; set +a
            - ./scripts/verify-sdp-cd-clone.sh
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/sdp-cd/

        cleanup_sdp_sandbox:
          stage: cleanup
          when: always
          needs:
            - job: prepare_sdp_sandbox
              artifacts: true
          rules:
            - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
            - when: never
          script:
            - ./scripts/cleanup-ci-sandbox.sh artifacts/context/sdp.env

        destroy_sdp_branch_sandbox:
          stage: cleanup
          needs:
            - job: prepare_sdp_sandbox
              artifacts: true
          rules:
            - if: '$CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH'
              when: manual
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
              when: manual
            - when: never
          allow_failure: true
          script:
            - ./scripts/cleanup-ci-sandbox.sh --destroy artifacts/context/sdp.env
        """
    )


def edp_ci_yaml() -> str:
    return dedent(
        """\
        workflow:
          name: EDP Promotion
          rules:
            - if: '$CI_PIPELINE_SOURCE == "push"'
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - if: '$CI_PIPELINE_SOURCE == "web"'
            - if: '$CI_PIPELINE_SOURCE == "api"'
            - when: never

        default:
          image: docker:29.1.3-cli
          tags:
            - local
            - fargate
          before_script:
            - apk add --no-cache bash curl
            - docker version
            - docker compose version
            - cp .env.example .env
            - mkdir -p artifacts
            - export LOCAL_PLATFORM_PROJECT_NAME="${LOCAL_PLATFORM_PROJECT_NAME:-local-platform}"
            - export LOCAL_PLATFORM_SHARED_STACK="true"
            - export COMPOSE_FILE="compose.yaml:compose.ci.yaml"
            - export COMPOSE_PROJECT_NAME="${LOCAL_PLATFORM_PROJECT_NAME}"
            - export PLATFORM_DOCKER_NETWORK="${PLATFORM_DOCKER_NETWORK:-${LOCAL_PLATFORM_PROJECT_NAME}-net}"
          after_script:
            - docker compose ps || true

        stages:
          - build
          - prepare
          - validate
          - promote
          - cd_verify
          - cleanup

        build_edp_runtime:
          stage: build
          script:
            - export RUNTIME_IMAGE_PREFIX="${CI_PROJECT_PATH_SLUG}-${CI_PIPELINE_ID}"
            - mkdir -p artifacts/context
            - docker compose build dbt-executor
            - printf 'RUNTIME_IMAGE_PREFIX=%s\\n' "${RUNTIME_IMAGE_PREFIX}" > artifacts/context/runtime.env
            - printf 'DBT_RUNNER_IMAGE=%s/dbt-executor:dev\\n' "${RUNTIME_IMAGE_PREFIX}" >> artifacts/context/runtime.env
          artifacts:
            when: always
            reports:
              dotenv: artifacts/context/runtime.env
            paths:
              - artifacts/context/

        prepare_edp_sandbox:
          stage: prepare
          script:
            - ./scripts/prepare-ci-sandbox.sh edp artifacts/context/edp.env
          artifacts:
            when: always
            reports:
              dotenv: artifacts/context/edp.env
            paths:
              - artifacts/context/

        validate_edp_assets:
          stage: validate
          needs:
            - job: build_edp_runtime
              artifacts: true
            - job: prepare_edp_sandbox
              artifacts: true
          script:
            - set -a; . artifacts/context/runtime.env; . artifacts/context/edp.env; set +a
            - docker compose config -q
            - docker compose run --rm --no-deps --entrypoint python dbt-executor -m compileall /opt/platform/dbt
            - docker compose run --rm --no-deps dbt-executor dbt parse --project-dir /opt/platform/dbt --profiles-dir /opt/platform/dbt/profiles
            - docker compose run --rm --no-deps dbt-executor sqlfluff lint --config /opt/platform/dbt/.sqlfluff /opt/platform/dbt/models

        promote_edp:
          stage: promote
          needs:
            - job: build_edp_runtime
              artifacts: true
            - job: prepare_edp_sandbox
              artifacts: true
          script:
            - set -a; . artifacts/context/runtime.env; . artifacts/context/edp.env; set +a
            - ./scripts/verify-edp-promotion.sh
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/edp/

        verify_edp_cd_clone:
          stage: cd_verify
          needs:
            - job: build_edp_runtime
              artifacts: true
            - job: prepare_edp_sandbox
              artifacts: true
            - job: promote_edp
              artifacts: true
          rules:
            - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
            - when: never
          script:
            - set -a; . artifacts/context/runtime.env; . artifacts/context/edp.env; set +a
            - ./scripts/verify-edp-cd-clone.sh
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/edp-cd/

        cleanup_edp_sandbox:
          stage: cleanup
          when: always
          needs:
            - job: prepare_edp_sandbox
              artifacts: true
          rules:
            - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
            - when: never
          script:
            - ./scripts/cleanup-ci-sandbox.sh artifacts/context/edp.env

        destroy_edp_branch_sandbox:
          stage: cleanup
          needs:
            - job: prepare_edp_sandbox
              artifacts: true
          rules:
            - if: '$CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH'
              when: manual
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
              when: manual
            - when: never
          allow_failure: true
          script:
            - ./scripts/cleanup-ci-sandbox.sh --destroy artifacts/context/edp.env
        """
    )


def edp_compose_yaml() -> str:
    return dedent(
        """\
        name: ${COMPOSE_PROJECT_NAME:-proj-edp-local}

        services:
          dbt-executor:
            build:
              context: .
              dockerfile: dbt/Dockerfile
            image: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-edp-local}}/dbt-executor:dev
            environment:
              SNOWFLAKE_ACCOUNT: ${SNOWFLAKE_ACCOUNT}
              SNOWFLAKE_USER: ${SNOWFLAKE_USER}
              SNOWFLAKE_PASSWORD: ${SNOWFLAKE_PASSWORD}
              SNOWFLAKE_ROLE: ${SNOWFLAKE_ROLE}
              SNOWFLAKE_WAREHOUSE: ${SNOWFLAKE_WAREHOUSE}
              SNOWFLAKE_SDP_DATABASE: ${SNOWFLAKE_SDP_DATABASE}
              SNOWFLAKE_SDP_IN_SCHEMA: ${SNOWFLAKE_SDP_IN_SCHEMA}
              SNOWFLAKE_SDP_CORE_SCHEMA: ${SNOWFLAKE_SDP_CORE_SCHEMA}
              SNOWFLAKE_SDP_ACC_SCHEMA: ${SNOWFLAKE_SDP_ACC_SCHEMA}
              SNOWFLAKE_EDP_DATABASE: ${SNOWFLAKE_EDP_DATABASE}
              SNOWFLAKE_EDP_IN_SCHEMA: ${SNOWFLAKE_EDP_IN_SCHEMA}
              SNOWFLAKE_EDP_CORE_SCHEMA: ${SNOWFLAKE_EDP_CORE_SCHEMA}
              SNOWFLAKE_EDP_ACC_SCHEMA: ${SNOWFLAKE_EDP_ACC_SCHEMA}
              SNOWFLAKE_CLONE_SCHEMA: ${SNOWFLAKE_CLONE_SCHEMA}
              DBT_THREADS: ${DBT_THREADS}
            volumes:
              - ./dbt:/opt/platform/dbt
              - ./snowflake:/opt/platform/snowflake
        """
    )


def edp_compose_ci_yaml() -> str:
    return dedent(
        """\
        services:
          dbt-executor:
            volumes: !reset []
        """
    )


def project_readme(project_name: str, body: str) -> str:
    rendered_body = dedent(body).strip()
    return (
        f"# {project_name}\n\n"
        "This repository is rendered from the local platform source repository for fast local testing in GitLab.\n\n"
        "Local CI in this repository assumes the shared `local-platform` stack is already bootstrapped on the Docker host. "
        "The GitLab jobs validate and promote against that running local platform instead of starting a second full copy of the stack inside the runner.\n\n"
        "The shared platform also runs a `gitlab-branch-provisioner` service. GitLab project webhooks notify that service "
        "when a non-default branch is created or deleted, so the branch sandbox is provisioned before the branch pipeline "
        "needs to use it and destroyed again when the branch is removed.\n\n"
        f"{rendered_body}\n"
    )


def render_sdp_repo(project_path: str) -> None:
    repo_dir = GENERATED_ROOT / project_path
    reset_repo(repo_dir)

    for relative_path in (
        ".dockerignore",
        ".env.example",
        "compose.yaml",
        "compose.ci.yaml",
        "airflow",
        "dlt",
        "postgres",
        "minio",
    ):
        copy_path(relative_path, repo_dir)

    for relative_path in (
        "scripts/common.sh",
        "scripts/ensure-snowflake-foundation.sh",
        "scripts/prepare-ci-sandbox.sh",
        "scripts/cleanup-ci-sandbox.sh",
        "scripts/load-source-sample-data.sh",
        "scripts/test-airflow-dag.sh",
        "scripts/verify-ingestion-promotion.sh",
        "scripts/verify-sdp-promotion.sh",
        "scripts/verify-sdp-cd-clone.sh",
    ):
        copy_path(relative_path, repo_dir)

    for relative_path in (
        "dbt/.sqlfluff",
        "dbt/Dockerfile",
        "dbt/requirements.txt",
        "dbt/macros",
        "dbt/profiles",
        "dbt/scripts/apply_sql.py",
        "dbt/scripts/manage_ci_clones.py",
    ):
        copy_path(relative_path, repo_dir)

    for relative_path in (
        "snowflake/sql/01_snowflake_foundation.sql.tpl",
        "snowflake/sql/02_open_catalog_integration.sql.tpl",
        "snowflake/sql/03_catalog_linked_database.sql.tpl",
    ):
        copy_path(relative_path, repo_dir)

    copy_path("dbt/projects/proj_sdp_orders/dbt_project.yml", repo_dir, "dbt/dbt_project.yml")
    copy_path("dbt/projects/proj_sdp_orders/models", repo_dir, "dbt/models")

    write_file(repo_dir / ".gitignore", shared_gitignore())
    write_file(repo_dir / ".gitlab-ci.yml", sdp_ci_yaml())
    write_file(
        repo_dir / "README.md",
        project_readme(
            project_path,
            dedent(
                """\
                This is the Source Data Product repository.

                Managed artifacts:

                - Airflow DAG for PostgreSQL -> MinIO/Iceberg ingestion
                - dlt ingestion runtime code
                - SDP dbt project for Snowflake `INBOUND`, `CORE`, and `ACCESS`

                Main CI entrypoint:

                - `./scripts/prepare-ci-sandbox.sh sdp artifacts/context/sdp.env`
                - `./scripts/verify-ingestion-promotion.sh`
                - `./scripts/verify-sdp-promotion.sh`
                - `./scripts/verify-sdp-cd-clone.sh`

                CI behaviour:

                - When a new non-default branch appears in GitLab, a GitLab webhook triggers the platform-side branch provisioner to create the branch sandbox automatically.
                - Every non-default branch and merge request pipeline reuses one branch-scoped Snowflake zero-copy environment instead of replacing the shared DEV objects.
                - Every non-default branch and merge request pipeline writes ingestion output to a stable branch-scoped MinIO/S3 prefix and Iceberg namespace.
                - Validation runs `dbt parse` and `sqlfluff lint` before promotion, and promotion runs `dbt run` plus `dbt test`.
                - Default-branch pipelines create a fresh merge clone, run an additional CD verification stage on a second fresh clone, and then clean both up automatically.
                - Branch environments are preserved after the pipeline, can be destroyed explicitly with the manual `destroy_sdp_branch_sandbox` job, and are also destroyed automatically when the GitLab branch is deleted.
                """
            ),
        ),
    )


def render_edp_repo(project_path: str) -> None:
    repo_dir = GENERATED_ROOT / project_path
    reset_repo(repo_dir)

    for relative_path in (
        ".dockerignore",
        ".env.example",
    ):
        copy_path(relative_path, repo_dir)

    for relative_path in (
        "scripts/common.sh",
        "scripts/ensure-snowflake-foundation.sh",
        "scripts/prepare-ci-sandbox.sh",
        "scripts/cleanup-ci-sandbox.sh",
        "scripts/verify-edp-promotion.sh",
        "scripts/verify-edp-cd-clone.sh",
    ):
        copy_path(relative_path, repo_dir)

    for relative_path in (
        "dbt/.sqlfluff",
        "dbt/Dockerfile",
        "dbt/requirements.txt",
        "dbt/macros",
        "dbt/profiles",
        "dbt/scripts/apply_sql.py",
        "dbt/scripts/manage_ci_clones.py",
        "dbt/scripts/zero_copy_clone_check.py",
    ):
        copy_path(relative_path, repo_dir)

    for relative_path in (
        "snowflake/sql/01_snowflake_foundation.sql.tpl",
        "snowflake/sql/02_open_catalog_integration.sql.tpl",
        "snowflake/sql/03_catalog_linked_database.sql.tpl",
    ):
        copy_path(relative_path, repo_dir)

    copy_path("dbt/projects/proj_edp_orders/dbt_project.yml", repo_dir, "dbt/dbt_project.yml")
    copy_path("dbt/projects/proj_edp_orders/models", repo_dir, "dbt/models")

    write_file(repo_dir / "compose.yaml", edp_compose_yaml())
    write_file(repo_dir / "compose.ci.yaml", edp_compose_ci_yaml())
    write_file(repo_dir / ".gitignore", shared_gitignore())
    write_file(repo_dir / ".gitlab-ci.yml", edp_ci_yaml())
    write_file(
        repo_dir / "README.md",
        project_readme(
            project_path,
            dedent(
                """\
                This is the Enterprise Data Product repository.

                Managed artifacts:

                - EDP dbt project for Snowflake `INBOUND`, `CORE`, and `ACCESS`

                Upstream dependency:

                - The published SDP `ACCESS` tables must already exist in Snowflake before the EDP promotion runs.

                Main CI entrypoint:

                - `./scripts/prepare-ci-sandbox.sh edp artifacts/context/edp.env`
                - `./scripts/verify-edp-promotion.sh`
                - `./scripts/verify-edp-cd-clone.sh`

                CI behaviour:

                - When a new non-default branch appears in GitLab, a GitLab webhook triggers the platform-side branch provisioner to create the branch sandbox automatically.
                - Every non-default branch and merge request pipeline reuses one branch-scoped Snowflake zero-copy environment instead of replacing the shared DEV objects.
                - Validation runs `dbt parse` and `sqlfluff lint`, and promotion runs `dbt run` plus `dbt test`.
                - Default-branch pipelines create a fresh merge clone, run an additional CD verification stage on a second fresh clone, and then clean both up automatically.
                - Branch environments are preserved after the pipeline, can be destroyed explicitly with the manual `destroy_edp_branch_sandbox` job, and are also destroyed automatically when the GitLab branch is deleted.
                """
            ),
        ),
    )


def main() -> int:
    sdp_project_path = env("GITLAB_SDP_PROJECT_PATH", "proj_sdp_orders")
    edp_project_path = env("GITLAB_EDP_PROJECT_PATH", "proj_edp_orders")

    if sdp_project_path == edp_project_path:
        raise SystemExit("GITLAB_SDP_PROJECT_PATH and GITLAB_EDP_PROJECT_PATH must be different")

    render_sdp_repo(sdp_project_path)
    render_edp_repo(edp_project_path)

    print(f"rendered SDP project repo: {GENERATED_ROOT / sdp_project_path}")
    print(f"rendered EDP project repo: {GENERATED_ROOT / edp_project_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
