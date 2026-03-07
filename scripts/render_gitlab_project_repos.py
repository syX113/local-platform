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
          - validate
          - promote_ingestion
          - promote_sdp
          - mock_cd

        build_sdp_runtimes:
          stage: build
          script:
            - docker image inspect "${LOCAL_PLATFORM_PROJECT_NAME:-local-platform}/airflow:dev"
            - docker image inspect "${LOCAL_PLATFORM_PROJECT_NAME:-local-platform}/dlt-extractor:dev"
            - docker image inspect "${LOCAL_PLATFORM_PROJECT_NAME:-local-platform}/dbt-executor:dev"

        validate_sdp_assets:
          stage: validate
          script:
            - docker compose config -q
            - docker compose run --rm --no-deps --entrypoint python airflow-webserver -m compileall /opt/airflow/dags
            - docker compose run --rm --no-deps --entrypoint python dlt-extractor -m compileall /opt/platform/dlt
            - docker compose run --rm --no-deps --entrypoint python dbt-executor -m compileall /opt/platform/dbt
            - docker compose run --rm --no-deps dbt-executor dbt parse --project-dir /opt/platform/dbt --profiles-dir /opt/platform/dbt/profiles

        promote_sdp_ingestion:
          stage: promote_ingestion
          script:
            - ./scripts/verify-ingestion-promotion.sh
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/ingestion/

        promote_sdp_models:
          stage: promote_sdp
          needs:
            - promote_sdp_ingestion
          script:
            - ./scripts/verify-sdp-promotion.sh
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/sdp/

        mock_cd_sdp:
          stage: mock_cd
          needs:
            - promote_sdp_models
          script:
            - mkdir -p artifacts/sdp
            - printf 'mock_cd=sdp\\nstatus=skipped_real_deploy\\nreason=no_second_environment\\n' > artifacts/sdp/mock_cd.txt
            - cat artifacts/sdp/mock_cd.txt
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/sdp/mock_cd.txt
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
          - validate
          - promote
          - mock_cd

        build_edp_runtime:
          stage: build
          script:
            - docker image inspect "${LOCAL_PLATFORM_PROJECT_NAME:-local-platform}/dbt-executor:dev"

        validate_edp_assets:
          stage: validate
          script:
            - docker compose config -q
            - docker compose run --rm --no-deps --entrypoint python dbt-executor -m compileall /opt/platform/dbt
            - docker compose run --rm --no-deps dbt-executor dbt parse --project-dir /opt/platform/dbt --profiles-dir /opt/platform/dbt/profiles

        promote_edp:
          stage: promote
          script:
            - ./scripts/verify-edp-promotion.sh
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/edp/

        mock_cd_edp:
          stage: mock_cd
          needs:
            - promote_edp
          script:
            - mkdir -p artifacts/edp
            - printf 'mock_cd=edp\\nstatus=skipped_real_deploy\\nreason=no_second_environment\\n' > artifacts/edp/mock_cd.txt
            - cat artifacts/edp/mock_cd.txt
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/edp/mock_cd.txt
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
            image: ${COMPOSE_PROJECT_NAME:-proj-edp-local}/dbt-executor:dev
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
        "snowflake",
    ):
        copy_path(relative_path, repo_dir)

    for relative_path in (
        "scripts/common.sh",
        "scripts/bootstrap-snowflake.sh",
        "scripts/load-source-sample-data.sh",
        "scripts/test-airflow-dag.sh",
        "scripts/verify-ingestion-promotion.sh",
        "scripts/verify-sdp-promotion.sh",
    ):
        copy_path(relative_path, repo_dir)

    for relative_path in (
        "dbt/Dockerfile",
        "dbt/requirements.txt",
        "dbt/macros",
        "dbt/profiles",
        "dbt/scripts",
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

                - `./scripts/verify-ingestion-promotion.sh`
                - `./scripts/verify-sdp-promotion.sh`
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
        "snowflake",
    ):
        copy_path(relative_path, repo_dir)

    for relative_path in (
        "scripts/common.sh",
        "scripts/bootstrap-snowflake.sh",
        "scripts/verify-edp-promotion.sh",
    ):
        copy_path(relative_path, repo_dir)

    for relative_path in (
        "dbt/Dockerfile",
        "dbt/requirements.txt",
        "dbt/macros",
        "dbt/profiles",
        "dbt/scripts",
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

                - `./scripts/verify-edp-promotion.sh`
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
