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
            - cp ci/.env.example .env
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
            - ./ci/scripts/prepare-ci-sandbox.sh sdp artifacts/context/sdp.env
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
            - ./ci/scripts/verify-ingestion-promotion.sh
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
            - ./ci/scripts/verify-sdp-promotion.sh
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
            - ./ci/scripts/verify-sdp-cd-clone.sh
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
            - ./ci/scripts/cleanup-ci-sandbox.sh artifacts/context/sdp.env

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
            - ./ci/scripts/cleanup-ci-sandbox.sh --destroy artifacts/context/sdp.env
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
            - cp ci/.env.example .env
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
            - ./ci/scripts/prepare-ci-sandbox.sh edp artifacts/context/edp.env
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
            - ./ci/scripts/verify-edp-promotion.sh
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
            - ./ci/scripts/verify-edp-cd-clone.sh
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
            - ./ci/scripts/cleanup-ci-sandbox.sh artifacts/context/edp.env

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
            - ./ci/scripts/cleanup-ci-sandbox.sh --destroy artifacts/context/edp.env
        """
    )


def sdp_compose_yaml() -> str:
    return dedent(
        """\
        name: ${COMPOSE_PROJECT_NAME:-proj-sdp-local}

        x-common-env: &common-env
          PLATFORM_DOCKER_NETWORK: ${PLATFORM_DOCKER_NETWORK:-local-platform-net}
          AWS_ACCESS_KEY_ID: ${OBJECT_STORE_ACCESS_KEY_ID}
          AWS_SECRET_ACCESS_KEY: ${OBJECT_STORE_SECRET_ACCESS_KEY}
          AWS_DEFAULT_REGION: ${OBJECT_STORE_REGION}
          AWS_REGION: ${OBJECT_STORE_REGION}
          PYICEBERG_MAX_WORKERS: "1"
          MINIO_ROOT_USER: ${MINIO_ROOT_USER}
          MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
          MINIO_BUCKET: ${MINIO_BUCKET}
          MINIO_PREFIX: ${MINIO_PREFIX}
          MINIO_ENDPOINT: ${MINIO_ENDPOINT}
          MINIO_PUBLIC_ENDPOINT: ${MINIO_PUBLIC_ENDPOINT}
          MINIO_USE_SSL: ${MINIO_USE_SSL}
          MINIO_REGION: ${MINIO_REGION}
          OBJECT_STORE_TYPE: ${OBJECT_STORE_TYPE}
          OBJECT_STORE_BUCKET: ${OBJECT_STORE_BUCKET}
          OBJECT_STORE_ACCESS_KEY_ID: ${OBJECT_STORE_ACCESS_KEY_ID}
          OBJECT_STORE_SECRET_ACCESS_KEY: ${OBJECT_STORE_SECRET_ACCESS_KEY}
          OBJECT_STORE_ENDPOINT_URL: ${OBJECT_STORE_ENDPOINT_URL}
          OBJECT_STORE_REGION: ${OBJECT_STORE_REGION}
          OBJECT_STORE_USE_SSL: ${OBJECT_STORE_USE_SSL}
          DLT_PIPELINE_NAME: ${DLT_PIPELINE_NAME}
          DLT_REFRESH_MODE: ${DLT_REFRESH_MODE}
          ICEBERG_NAMESPACE: ${ICEBERG_NAMESPACE}
          ICEBERG_CATALOG_TYPE: ${ICEBERG_CATALOG_TYPE}
          ICEBERG_SQL_URI: ${ICEBERG_SQL_URI}
          SOURCE_POSTGRES_HOST: ${SOURCE_POSTGRES_HOST}
          SOURCE_POSTGRES_PORT: ${SOURCE_POSTGRES_PORT}
          SOURCE_POSTGRES_DB: ${SOURCE_POSTGRES_DB}
          SOURCE_POSTGRES_USER: ${SOURCE_POSTGRES_USER}
          SOURCE_POSTGRES_PASSWORD: ${SOURCE_POSTGRES_PASSWORD}
          SOURCE_POSTGRES_SCHEMA: ${SOURCE_POSTGRES_SCHEMA}
          OPEN_CATALOG_URI: ${OPEN_CATALOG_URI}
          OPEN_CATALOG_NAME: ${OPEN_CATALOG_NAME}
          OPEN_CATALOG_CLIENT_ID: ${OPEN_CATALOG_CLIENT_ID}
          OPEN_CATALOG_CLIENT_SECRET: ${OPEN_CATALOG_CLIENT_SECRET}
          OPEN_CATALOG_SCOPE: ${OPEN_CATALOG_SCOPE}
          OPEN_CATALOG_ACCESS_DELEGATION: ${OPEN_CATALOG_ACCESS_DELEGATION}
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
          SNOWFLAKE_CATALOG_INTEGRATION: ${SNOWFLAKE_CATALOG_INTEGRATION}
          SNOWFLAKE_CLONE_SCHEMA: ${SNOWFLAKE_CLONE_SCHEMA}
          SNOWFLAKE_LOCAL_RAW_SYNC: ${SNOWFLAKE_LOCAL_RAW_SYNC}
          DBT_THREADS: ${DBT_THREADS}

        x-airflow-build: &airflow-build
          context: .
          dockerfile: airflow/Dockerfile
          args:
            AIRFLOW_IMAGE: ${AIRFLOW_IMAGE:-apache/airflow:2.10.5-python3.11}
            AIRFLOW_VERSION: "2.10.5"
            PYTHON_VERSION: "3.11"

        x-airflow-env: &airflow-env
          <<: *common-env
          AIRFLOW__CORE__EXECUTOR: LocalExecutor
          AIRFLOW__CORE__LOAD_EXAMPLES: "False"
          AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION: "True"
          AIRFLOW__WEBSERVER__EXPOSE_CONFIG: "True"
          AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://${AIRFLOW_METADATA_DB_USER}:${AIRFLOW_METADATA_DB_PASSWORD}@airflow-metadata-db:5432/${AIRFLOW_METADATA_DB_NAME}
          AIRFLOW__CORE__FERNET_KEY: ${AIRFLOW_FERNET_KEY}
          AIRFLOW__WEBSERVER__SECRET_KEY: ${AIRFLOW_WEBSERVER_SECRET_KEY}
          AIRFLOW_ADMIN_USERNAME: ${AIRFLOW_ADMIN_USERNAME}
          AIRFLOW_ADMIN_PASSWORD: ${AIRFLOW_ADMIN_PASSWORD}
          AIRFLOW_ADMIN_EMAIL: ${AIRFLOW_ADMIN_EMAIL}
          AIRFLOW_UID: ${AIRFLOW_UID:-50000}
          DOCKER_URL: unix:///var/run/docker.sock
          DLT_RUNNER_IMAGE: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-sdp-local}}/dlt-extractor:dev
          DBT_RUNNER_IMAGE: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-sdp-local}}/dbt-executor:dev

        services:
          airflow-metadata-db:
            image: postgres:16
            environment:
              POSTGRES_USER: ${AIRFLOW_METADATA_DB_USER}
              POSTGRES_PASSWORD: ${AIRFLOW_METADATA_DB_PASSWORD}
              POSTGRES_DB: ${AIRFLOW_METADATA_DB_NAME}
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U ${AIRFLOW_METADATA_DB_USER} -d ${AIRFLOW_METADATA_DB_NAME}"]
              interval: 10s
              timeout: 5s
              retries: 10
            networks:
              - platform
            volumes:
              - airflow-metadata-db-data:/var/lib/postgresql/data
              - ./postgres/catalog-init:/docker-entrypoint-initdb.d:ro

          source-postgres-db:
            image: postgres:16
            environment:
              POSTGRES_USER: ${SOURCE_POSTGRES_USER}
              POSTGRES_PASSWORD: ${SOURCE_POSTGRES_PASSWORD}
              POSTGRES_DB: ${SOURCE_POSTGRES_DB}
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U ${SOURCE_POSTGRES_USER} -d ${SOURCE_POSTGRES_DB}"]
              interval: 10s
              timeout: 5s
              retries: 10
            networks:
              - platform
            volumes:
              - source-postgres-db-data:/var/lib/postgresql/data
              - ./postgres/source-init:/docker-entrypoint-initdb.d:ro

          lakehouse-object-store:
            image: minio/minio:latest
            command: server /data --console-address ":9001"
            environment:
              MINIO_ROOT_USER: ${MINIO_ROOT_USER}
              MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
              MINIO_REGION_NAME: ${MINIO_REGION}
            networks:
              - platform
            volumes:
              - lakehouse-object-store-data:/data

          lakehouse-bucket-init:
            image: minio/mc:latest
            depends_on:
              lakehouse-object-store:
                condition: service_started
            entrypoint: ["/bin/sh", "/scripts/create-bucket.sh"]
            environment:
              MINIO_ROOT_USER: ${MINIO_ROOT_USER}
              MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
              MINIO_BUCKET: ${MINIO_BUCKET}
              MINIO_ENDPOINT: ${MINIO_ENDPOINT}
            networks:
              - platform
            restart: "no"
            volumes:
              - ./minio/init:/scripts:ro

          airflow-init:
            build: *airflow-build
            image: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-sdp-local}}/airflow:dev
            depends_on:
              airflow-metadata-db:
                condition: service_healthy
            environment: *airflow-env
            entrypoint: ["/bin/bash", "/opt/platform/airflow/init-airflow.sh"]
            networks:
              - platform
            restart: "no"
            user: "${AIRFLOW_UID:-50000}:0"
            volumes:
              - airflow-logs:/opt/airflow/logs
              - ./airflow/dags:/opt/airflow/dags
              - ./postgres:/opt/platform/postgres:ro

          airflow-webserver:
            build: *airflow-build
            image: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-sdp-local}}/airflow:dev
            depends_on:
              airflow-metadata-db:
                condition: service_healthy
              source-postgres-db:
                condition: service_healthy
              airflow-init:
                condition: service_completed_successfully
              lakehouse-bucket-init:
                condition: service_completed_successfully
            environment: *airflow-env
            command: ["airflow", "webserver"]
            healthcheck:
              test: ["CMD-SHELL", 'python -c "import urllib.request; urllib.request.urlopen(\\"http://localhost:8080/health\\")"']
              interval: 15s
              timeout: 5s
              retries: 10
            networks:
              - platform
            user: "${AIRFLOW_UID:-50000}:0"
            volumes:
              - airflow-logs:/opt/airflow/logs
              - ./airflow/dags:/opt/airflow/dags
              - ./postgres:/opt/platform/postgres:ro

          airflow-scheduler:
            build: *airflow-build
            image: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-sdp-local}}/airflow:dev
            depends_on:
              airflow-metadata-db:
                condition: service_healthy
              source-postgres-db:
                condition: service_healthy
              airflow-init:
                condition: service_completed_successfully
              lakehouse-bucket-init:
                condition: service_completed_successfully
            environment: *airflow-env
            command: ["airflow", "scheduler"]
            networks:
              - platform
            user: "0:0"
            volumes:
              - airflow-logs:/opt/airflow/logs
              - ./airflow/dags:/opt/airflow/dags
              - ./postgres:/opt/platform/postgres:ro
              - /var/run/docker.sock:/var/run/docker.sock

          dlt-extractor:
            build:
              context: .
              dockerfile: dlt/Dockerfile
            image: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-sdp-local}}/dlt-extractor:dev
            command: ["sleep", "infinity"]
            depends_on:
              airflow-metadata-db:
                condition: service_healthy
              source-postgres-db:
                condition: service_healthy
              lakehouse-bucket-init:
                condition: service_completed_successfully
            environment: *common-env
            networks:
              - platform
            profiles: ["tooling"]
            volumes:
              - ./dlt:/opt/platform/dlt

          dbt-executor:
            build:
              context: .
              dockerfile: dbt/Dockerfile
            image: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-sdp-local}}/dbt-executor:dev
            command: ["sleep", "infinity"]
            environment: *common-env
            networks:
              - platform
            profiles: ["tooling"]
            volumes:
              - ./dbt:/opt/platform/dbt
              - ./ci/snowflake:/opt/platform/ci/snowflake

        networks:
          platform:
            name: ${PLATFORM_DOCKER_NETWORK:-local-platform-net}

        volumes:
          airflow-metadata-db-data:
          source-postgres-db-data:
          lakehouse-object-store-data:
          airflow-logs:
        """
    )


def sdp_compose_ci_yaml() -> str:
    return dedent(
        """\
        services:
          airflow-init:
            volumes: !reset []

          airflow-webserver:
            volumes: !reset []

          airflow-scheduler:
            volumes: !override
              - airflow-logs:/opt/airflow/logs
              - /var/run/docker.sock:/var/run/docker.sock

          dlt-extractor:
            volumes: !reset []

          dbt-executor:
            volumes: !reset []
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
              - ./ci/snowflake:/opt/platform/ci/snowflake
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
        "scripts/prepare-ci-sandbox.sh",
        "scripts/cleanup-ci-sandbox.sh",
        "scripts/load-source-sample-data.sh",
        "scripts/test-airflow-dag.sh",
        "scripts/verify-ingestion-promotion.sh",
        "scripts/verify-sdp-promotion.sh",
        "scripts/verify-sdp-cd-clone.sh",
    ):
        copy_path(relative_path, repo_dir, f"ci/{relative_path}")

    for relative_path in (
        "dbt/.sqlfluff",
        "dbt/Dockerfile",
        "dbt/requirements.txt",
        "dbt/macros",
        "dbt/scripts/apply_sql.py",
        "dbt/scripts/manage_ci_clones.py",
    ):
        copy_path(relative_path, repo_dir)
    copy_path("dbt/profiles/profiles.yml", repo_dir, "dbt/profiles/profiles.yml")

    copy_path("snowflake/sql/01_snowflake_foundation.sql.tpl", repo_dir, "ci/snowflake/sql/01_snowflake_foundation.sql.tpl")
    copy_path("snowflake/data_products.json", repo_dir, "ci/snowflake/data_products.json")

    copy_path("dbt/projects/proj_sdp_orders/dbt_project.yml", repo_dir, "dbt/dbt_project.yml")
    copy_path("dbt/projects/proj_sdp_orders/models", repo_dir, "dbt/models")

    write_file(repo_dir / "compose.yaml", sdp_compose_yaml())
    write_file(repo_dir / "compose.ci.yaml", sdp_compose_ci_yaml())
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
                - `ci/scripts/` contains only CI helper scripts
                - `ci/` contains runner-only config and Snowflake foundation metadata

                Main CI entrypoint:

                - `./ci/scripts/prepare-ci-sandbox.sh sdp artifacts/context/sdp.env`
                - `./ci/scripts/verify-ingestion-promotion.sh`
                - `./ci/scripts/verify-sdp-promotion.sh`
                - `./ci/scripts/verify-sdp-cd-clone.sh`

                CI behaviour:

                - When a new non-default branch appears in GitLab, a GitLab webhook triggers the platform-side branch provisioner to create the branch sandbox automatically.
                - Every non-default branch and merge request pipeline reuses one branch-scoped Snowflake zero-copy environment instead of replacing the shared DEV objects.
                - The clone lifecycle is driven by `ci/snowflake/data_products.json`, so every registered Snowflake data product database is cloned, not just the sample SDP and EDP orders databases.
                - Branch clone databases are named from the original database plus `CI_CLO`, the owning project token, and the branch token, for example `DB_SDP_ORDERS_CI_CLO_SDP_FEATURE_X`.
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

    copy_path(".dockerignore", repo_dir)
    copy_path(".env.example", repo_dir, "ci/.env.example")

    for relative_path in (
        "scripts/common.sh",
        "scripts/ensure-snowflake-foundation.sh",
        "scripts/prepare-ci-sandbox.sh",
        "scripts/cleanup-ci-sandbox.sh",
        "scripts/verify-edp-promotion.sh",
        "scripts/verify-edp-cd-clone.sh",
    ):
        copy_path(relative_path, repo_dir, f"ci/{relative_path}")

    for relative_path in (
        "dbt/.sqlfluff",
        "dbt/Dockerfile",
        "dbt/requirements.txt",
        "dbt/macros",
        "dbt/scripts/apply_sql.py",
        "dbt/scripts/manage_ci_clones.py",
        "dbt/scripts/zero_copy_clone_check.py",
    ):
        copy_path(relative_path, repo_dir)
    copy_path("dbt/profiles/profiles.yml", repo_dir, "dbt/profiles/profiles.yml")

    copy_path("snowflake/sql/01_snowflake_foundation.sql.tpl", repo_dir, "ci/snowflake/sql/01_snowflake_foundation.sql.tpl")
    copy_path("snowflake/data_products.json", repo_dir, "ci/snowflake/data_products.json")

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
                - `ci/scripts/` contains only CI helper scripts
                - `ci/` contains runner-only config and Snowflake foundation metadata

                Upstream dependency:

                - The published SDP `ACCESS` tables must already exist in Snowflake before the EDP promotion runs.

                Main CI entrypoint:

                - `./ci/scripts/prepare-ci-sandbox.sh edp artifacts/context/edp.env`
                - `./ci/scripts/verify-edp-promotion.sh`
                - `./ci/scripts/verify-edp-cd-clone.sh`

                CI behaviour:

                - When a new non-default branch appears in GitLab, a GitLab webhook triggers the platform-side branch provisioner to create the branch sandbox automatically.
                - Every non-default branch and merge request pipeline reuses one branch-scoped Snowflake zero-copy environment instead of replacing the shared DEV objects.
                - The clone lifecycle is driven by `ci/snowflake/data_products.json`, so every registered Snowflake data product database is cloned, not just the sample SDP and EDP orders databases.
                - Branch clone databases are named from the original database plus `CI_CLO`, the owning project token, and the branch token, for example `DB_EDP_ORDERS_CI_CLO_EDP_FEATURE_X`.
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
