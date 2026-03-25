#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
from pathlib import Path
from textwrap import dedent


ROOT_DIR = Path(__file__).resolve().parent.parent
GENERATED_ROOT = ROOT_DIR / "gitlab-projects" / "generated"
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
    return dedent(
        """\
        workflow:
          name: Source Promotion
          rules:
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH && $CI_OPEN_MERGE_REQUESTS'
              when: never
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH'
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_COMMIT_TITLE =~ /^Merge branch /'
            - when: never

        default:
          image: ${GITLAB_RUNNER_JOB_IMAGE:-local-platform/gitlab-ci-tools:dev}
          tags:
            - local
            - fargate
          before_script:
            - |
              docker() {
                if [ "${1:-}" = "compose" ] && [ "${2:-}" = "run" ]; then
                  shift 2
                  command docker compose run "$@" 2> >(awk 'index($0, "No services to build") == 0 && index($0, "Found orphan containers") == 0 { print > "/dev/stderr" }')
                else
                  command docker "$@"
                fi
              }
            - docker version
            - docker compose version
            - cp ci/.env.example .env
            - mkdir -p artifacts
            - export LOCAL_PLATFORM_PROJECT_NAME="${LOCAL_PLATFORM_PROJECT_NAME:-local-platform}"
            - export LOCAL_PLATFORM_SHARED_STACK="true"
            - export COMPOSE_FILE="compose.yaml:compose.ci.yaml"
            - export COMPOSE_PROJECT_NAME="${LOCAL_PLATFORM_PROJECT_NAME}"
            - export PLATFORM_DOCKER_NETWORK="${PLATFORM_DOCKER_NETWORK:-${LOCAL_PLATFORM_PROJECT_NAME}-net}"

        stages:
          - build
          - prepare
          - ci_validate
          - deploy_dev
          - approve_prd
          - deploy_prd
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
            - printf 'SNOW_DBT_RUNNER_IMAGE=%s/dbt-executor:dev\\n' "${RUNTIME_IMAGE_PREFIX}" >> artifacts/context/runtime.env
          artifacts:
            when: always
            reports:
              dotenv: artifacts/context/runtime.env
            paths:
              - artifacts/context/

        prepare_sdp_mr_context:
          stage: prepare
          script:
            - ./ci/scripts/prepare-ci-sandbox.sh sdp artifacts/context/sdp.env
          rules:
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - when: never
          artifacts:
            when: always
            paths:
              - artifacts/context/

        ci_validate_sdp_assets:
          stage: ci_validate
          needs:
            - job: build_sdp_runtimes
              artifacts: true
            - job: prepare_sdp_mr_context
              artifacts: true
              optional: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH'
            - when: never
          script:
            - |
              if [ "${CI_PIPELINE_SOURCE}" != "merge_request_event" ]; then
                bash ./ci/scripts/resolve-existing-sandbox.sh sdp artifacts/context/sdp.env
              fi
            - set -a; . artifacts/context/runtime.env; . artifacts/context/sdp.env; set +a
            - docker compose config -q
            - docker compose run --rm --no-deps --entrypoint python airflow-webserver -m compileall /opt/airflow/dags
            - docker compose run --rm --no-deps --entrypoint python dlt-extractor -m compileall /opt/platform/dlt
            - docker compose run --rm --no-deps --entrypoint python dbt-executor -m compileall /opt/platform/dbt
            - ./ci/scripts/lint-prepared-dbt-project.sh proj_source_finnova

        ci_validate_sdp_ingestion:
          stage: ci_validate
          needs:
            - job: build_sdp_runtimes
              artifacts: true
            - job: prepare_sdp_mr_context
              artifacts: true
              optional: true
            - job: ci_validate_sdp_assets
              artifacts: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH'
            - when: never
          script:
            - |
              if [ "${CI_PIPELINE_SOURCE}" != "merge_request_event" ]; then
                bash ./ci/scripts/resolve-existing-sandbox.sh sdp artifacts/context/sdp.env
              fi
            - set -a; . artifacts/context/runtime.env; . artifacts/context/sdp.env; set +a
            - ./ci/scripts/deploy-airflow-dag.sh current orders "current-sdp-orders-ci"
            - SOURCE_SCOPE=orders ./ci/scripts/verify-ingestion-promotion.sh
            - ./ci/scripts/deploy-airflow-dag.sh current customers "current-sdp-customers-ci"
            - SOURCE_SCOPE=customers ./ci/scripts/verify-ingestion-promotion.sh
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/ingestion/

        ci_validate_sdp_models:
          stage: ci_validate
          needs:
            - job: build_sdp_runtimes
              artifacts: true
            - job: prepare_sdp_mr_context
              artifacts: true
              optional: true
            - job: ci_validate_sdp_ingestion
              artifacts: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH'
            - when: never
          script:
            - |
              if [ "${CI_PIPELINE_SOURCE}" != "merge_request_event" ]; then
                bash ./ci/scripts/resolve-existing-sandbox.sh sdp artifacts/context/sdp.env
              fi
            - set -a; . artifacts/context/runtime.env; . artifacts/context/sdp.env; set +a
            - SOURCE_SCOPE=orders ./ci/scripts/verify-sdp-promotion.sh
            - SOURCE_SCOPE=customers ./ci/scripts/verify-sdp-promotion.sh
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/sdp/

        deploy_sdp_dev:
          stage: deploy_dev
          needs:
            - job: build_sdp_runtimes
              artifacts: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_COMMIT_TITLE =~ /^Merge branch /'
            - when: never
          environment:
            name: DEV/SDP
          resource_group: sdp-dev
          script:
            - set -a; . artifacts/context/runtime.env; set +a
            - ./ci/scripts/deploy-sdp-dev.sh
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/deploy-sdp-dev/

        approve_prd_deploy_by_committer:
          stage: approve_prd
          needs:
            - job: deploy_sdp_dev
              artifacts: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_COMMIT_TITLE =~ /^Merge branch /'
              when: manual
            - when: never
          allow_failure: false
          manual_confirmation: Only the committer should approve PRD deployment.
          script:
            - ./ci/scripts/require-approver-match-commit.sh

        deploy_sdp_prd:
          stage: deploy_prd
          needs:
            - job: build_sdp_runtimes
              artifacts: true
            - job: approve_prd_deploy_by_committer
              artifacts: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_COMMIT_TITLE =~ /^Merge branch /'
            - when: never
          environment:
            name: PRD/SDP
          resource_group: sdp-prd
          script:
            - set -a; . artifacts/context/runtime.env; set +a
            - ./ci/scripts/deploy-sdp-prd.sh
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/deploy-sdp-prd/

        cleanup_sdp_mr_sandbox:
          stage: cleanup
          when: always
          needs:
            - job: prepare_sdp_mr_context
              artifacts: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - when: never
          script:
            - ./ci/scripts/cleanup-ci-sandbox.sh artifacts/context/sdp.env

        """
    ).replace("__SQLFLUFF_LINT__", sqlfluff_lint_script)


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
    return (
        dedent(
            """\
        workflow:
          name: __PROJECT_TITLE__
          rules:
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH && $CI_OPEN_MERGE_REQUESTS'
              when: never
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH'
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_COMMIT_TITLE =~ /^Merge branch /'
            - when: never

        default:
          image: ${GITLAB_RUNNER_JOB_IMAGE:-local-platform/gitlab-ci-tools:dev}
          tags:
            - local
            - fargate
          before_script:
            - |
              docker() {
                if [ "${1:-}" = "compose" ] && [ "${2:-}" = "run" ]; then
                  shift 2
                  command docker compose run "$@" 2> >(awk 'index($0, "No services to build") == 0 && index($0, "Found orphan containers") == 0 { print > "/dev/stderr" }')
                else
                  command docker "$@"
                fi
              }
            - docker version
            - docker compose version
            - cp ci/.env.example .env
            - mkdir -p artifacts
            - export LOCAL_PLATFORM_PROJECT_NAME="${LOCAL_PLATFORM_PROJECT_NAME:-local-platform}"
            - export LOCAL_PLATFORM_SHARED_STACK="true"
            - export COMPOSE_FILE="compose.yaml:compose.ci.yaml"
            - export COMPOSE_PROJECT_NAME="${LOCAL_PLATFORM_PROJECT_NAME}"
            - export PLATFORM_DOCKER_NETWORK="${PLATFORM_DOCKER_NETWORK:-${LOCAL_PLATFORM_PROJECT_NAME}-net}"

        stages:
          - build
          - prepare
          - ci_validate
          - deploy_dev
          - approve_prd
          - deploy_prd
          - cleanup

        build_edp_runtime:
          stage: build
          script:
            - export RUNTIME_IMAGE_PREFIX="${CI_PROJECT_PATH_SLUG}-${CI_PIPELINE_ID}"
            - mkdir -p artifacts/context
            - docker compose build dbt-executor
            - printf 'RUNTIME_IMAGE_PREFIX=%s\\n' "${RUNTIME_IMAGE_PREFIX}" > artifacts/context/runtime.env
            - printf 'DBT_RUNNER_IMAGE=%s/dbt-executor:dev\\n' "${RUNTIME_IMAGE_PREFIX}" >> artifacts/context/runtime.env
            - printf 'SNOW_DBT_RUNNER_IMAGE=%s/dbt-executor:dev\\n' "${RUNTIME_IMAGE_PREFIX}" >> artifacts/context/runtime.env
          artifacts:
            when: always
            reports:
              dotenv: artifacts/context/runtime.env
            paths:
              - artifacts/context/

        prepare_edp_mr_context:
          stage: prepare
          script:
            - ./ci/scripts/prepare-ci-sandbox.sh edp artifacts/context/edp.env
          rules:
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - when: never
          artifacts:
            when: always
            paths:
              - artifacts/context/

        ci_validate_edp_assets:
          stage: ci_validate
          needs:
            - job: build_edp_runtime
              artifacts: true
            - job: prepare_edp_mr_context
              artifacts: true
              optional: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH'
            - when: never
          script:
            - |
              if [ "${CI_PIPELINE_SOURCE}" != "merge_request_event" ]; then
                bash ./ci/scripts/resolve-existing-sandbox.sh edp artifacts/context/edp.env
              fi
            - set -a; . artifacts/context/runtime.env; . artifacts/context/edp.env; set +a
            - docker compose config -q
            - docker compose run --rm --no-deps --entrypoint python dbt-executor -m compileall /opt/platform/dbt
            - ./ci/scripts/lint-prepared-dbt-project.sh __PROJECT_SLUG__

        ci_validate_edp_models:
          stage: ci_validate
          needs:
            - job: build_edp_runtime
              artifacts: true
            - job: prepare_edp_mr_context
              artifacts: true
              optional: true
            - job: ci_validate_edp_assets
              artifacts: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH'
            - when: never
          script:
            - |
              if [ "${CI_PIPELINE_SOURCE}" != "merge_request_event" ]; then
                bash ./ci/scripts/resolve-existing-sandbox.sh edp artifacts/context/edp.env
              fi
            - set -a; . artifacts/context/runtime.env; . artifacts/context/edp.env; set +a
            - __VERIFY_SCRIPT__
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - __ARTIFACT_DIR__

        deploy_edp_dev:
          stage: deploy_dev
          needs:
            - job: build_edp_runtime
              artifacts: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_COMMIT_TITLE =~ /^Merge branch /'
            - when: never
          environment:
            name: __DEV_ENVIRONMENT_NAME__
          resource_group: __DEV_RESOURCE_GROUP__
          script:
            - set -a; . artifacts/context/runtime.env; set +a
            - __DEPLOY_DEV_SCRIPT__
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/deploy-edp-dev/

        approve_prd_deploy_by_committer:
          stage: approve_prd
          needs:
            - job: deploy_edp_dev
              artifacts: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_COMMIT_TITLE =~ /^Merge branch /'
              when: manual
            - when: never
          allow_failure: false
          manual_confirmation: Only the committer should approve PRD deployment.
          script:
            - ./ci/scripts/require-approver-match-commit.sh

        deploy_edp_prd:
          stage: deploy_prd
          needs:
            - job: build_edp_runtime
              artifacts: true
            - job: approve_prd_deploy_by_committer
              artifacts: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_COMMIT_TITLE =~ /^Merge branch /'
            - when: never
          environment:
            name: __PRD_ENVIRONMENT_NAME__
          resource_group: __PRD_RESOURCE_GROUP__
          script:
            - set -a; . artifacts/context/runtime.env; set +a
            - __DEPLOY_PRD_SCRIPT__
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - artifacts/deploy-edp-prd/

        cleanup_edp_mr_sandbox:
          stage: cleanup
          when: always
          needs:
            - job: prepare_edp_mr_context
              artifacts: true
          rules:
            - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
            - when: never
          script:
            - ./ci/scripts/cleanup-ci-sandbox.sh artifacts/context/edp.env

        """
            )
        .replace("__PROJECT_TITLE__", project_title)
        .replace("__PROJECT_SLUG__", project_slug)
        .replace("__VERIFY_SCRIPT__", verify_script)
        .replace("__DEPLOY_DEV_SCRIPT__", deploy_dev_script)
        .replace("__DEPLOY_PRD_SCRIPT__", deploy_prd_script)
        .replace("__ARTIFACT_DIR__", artifact_dir)
        .replace("__DEV_ENVIRONMENT_NAME__", dev_environment_name)
        .replace("__PRD_ENVIRONMENT_NAME__", prd_environment_name)
        .replace("__DEV_RESOURCE_GROUP__", dev_resource_group)
        .replace("__PRD_RESOURCE_GROUP__", prd_resource_group)
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
          ICEBERG_CATALOG_NAME: ${ICEBERG_CATALOG_NAME}
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
          SNOWFLAKE_CONTROL_DATABASE: ${SNOWFLAKE_CONTROL_DATABASE:-LOCAL_PLATFORM_CONTROL}
          SNOWFLAKE_CONTROL_SCHEMA: ${SNOWFLAKE_CONTROL_SCHEMA:-OPERATIONS}
          SNOWFLAKE_DBT_STAGE: ${SNOWFLAKE_DBT_STAGE:-DBT_PROJECT_STAGE}
          SNOWFLAKE_SDP_DATABASE: ${SNOWFLAKE_SDP_DATABASE}
          SNOWFLAKE_SDP_IN_SCHEMA: ${SNOWFLAKE_SDP_IN_SCHEMA}
          SNOWFLAKE_SDP_CORE_SCHEMA: ${SNOWFLAKE_SDP_CORE_SCHEMA}
          SNOWFLAKE_SDP_ACC_SCHEMA: ${SNOWFLAKE_SDP_ACC_SCHEMA}
          SNOWFLAKE_SDP_CUSTOMERS_DATABASE: ${SNOWFLAKE_SDP_CUSTOMERS_DATABASE}
          SNOWFLAKE_SDP_DBT_PROJECT: ${SNOWFLAKE_SDP_DBT_PROJECT:-DEV_DBT_PROJECT_SOURCE_FINNOVA}
          SNOWFLAKE_EDP_DATABASE: ${SNOWFLAKE_EDP_DATABASE}
          SNOWFLAKE_EDP_CUSTOMERS_DATABASE: ${SNOWFLAKE_EDP_CUSTOMERS_DATABASE}
          SNOWFLAKE_EDP_IN_SCHEMA: ${SNOWFLAKE_EDP_IN_SCHEMA}
          SNOWFLAKE_EDP_CORE_SCHEMA: ${SNOWFLAKE_EDP_CORE_SCHEMA}
          SNOWFLAKE_EDP_ACC_SCHEMA: ${SNOWFLAKE_EDP_ACC_SCHEMA}
          SNOWFLAKE_EDP_DBT_PROJECT: ${SNOWFLAKE_EDP_DBT_PROJECT:-DEV_DBT_PROJECT_EDP_ORDERS}
          SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT: ${SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT:-DEV_DBT_PROJECT_EDP_CUSTOMERS}
          SNOWFLAKE_CATALOG_INTEGRATION: ${SNOWFLAKE_CATALOG_INTEGRATION}
          SNOWFLAKE_CLONE_SCHEMA: ${SNOWFLAKE_CLONE_SCHEMA}
          SNOWFLAKE_LOCAL_RAW_SYNC: ${SNOWFLAKE_LOCAL_RAW_SYNC}
          SNOW_DBT_TARGET_NAME: ${SNOW_DBT_TARGET_NAME:-dev}
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
            ports:
              - "${AIRFLOW_METADATA_DB_PORT:-5432}:5432"
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
            ports:
              - "${SOURCE_POSTGRES_EXPOSE_PORT:-5433}:5432"
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
            ports:
              - "${MINIO_API_PORT:-9000}:9000"
              - "${MINIO_CONSOLE_PORT:-9001}:9001"
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
            ports:
              - "${AIRFLOW_PORT:-8088}:8080"
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
            user: "${AIRFLOW_UID:-50000}:0"
            volumes:
              - airflow-logs:/opt/airflow/logs
              - ./airflow/dags:/opt/airflow/dags
              - ./postgres:/opt/platform/postgres:ro

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

        x-common-env: &common-env
          PLATFORM_DOCKER_NETWORK: ${PLATFORM_DOCKER_NETWORK:-local-platform-net}
          AWS_ACCESS_KEY_ID: ${OBJECT_STORE_ACCESS_KEY_ID}
          AWS_SECRET_ACCESS_KEY: ${OBJECT_STORE_SECRET_ACCESS_KEY}
          AWS_DEFAULT_REGION: ${OBJECT_STORE_REGION}
          AWS_REGION: ${OBJECT_STORE_REGION}
          MINIO_ROOT_USER: ${MINIO_ROOT_USER}
          MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
          MINIO_BUCKET: ${MINIO_BUCKET}
          MINIO_MANIFEST_BUCKET: ${MINIO_MANIFEST_BUCKET:-dbt-manifests}
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
          SNOWFLAKE_ACCOUNT: ${SNOWFLAKE_ACCOUNT}
          SNOWFLAKE_USER: ${SNOWFLAKE_USER}
          SNOWFLAKE_PASSWORD: ${SNOWFLAKE_PASSWORD}
          SNOWFLAKE_ROLE: ${SNOWFLAKE_ROLE}
          SNOWFLAKE_WAREHOUSE: ${SNOWFLAKE_WAREHOUSE}
          SNOWFLAKE_CONTROL_DATABASE: ${SNOWFLAKE_CONTROL_DATABASE:-LOCAL_PLATFORM_CONTROL}
          SNOWFLAKE_CONTROL_SCHEMA: ${SNOWFLAKE_CONTROL_SCHEMA:-OPERATIONS}
          SNOWFLAKE_DBT_STAGE: ${SNOWFLAKE_DBT_STAGE:-DBT_PROJECT_STAGE}
          SNOWFLAKE_SDP_DATABASE: ${SNOWFLAKE_SDP_DATABASE}
          SNOWFLAKE_SDP_CUSTOMERS_DATABASE: ${SNOWFLAKE_SDP_CUSTOMERS_DATABASE}
          SNOWFLAKE_SDP_IN_SCHEMA: ${SNOWFLAKE_SDP_IN_SCHEMA}
          SNOWFLAKE_SDP_CORE_SCHEMA: ${SNOWFLAKE_SDP_CORE_SCHEMA}
          SNOWFLAKE_SDP_ACC_SCHEMA: ${SNOWFLAKE_SDP_ACC_SCHEMA}
          SNOWFLAKE_SDP_DBT_PROJECT: ${SNOWFLAKE_SDP_DBT_PROJECT:-DEV_DBT_PROJECT_SOURCE_FINNOVA}
          SNOWFLAKE_EDP_DATABASE: ${SNOWFLAKE_EDP_DATABASE}
          SNOWFLAKE_EDP_CUSTOMERS_DATABASE: ${SNOWFLAKE_EDP_CUSTOMERS_DATABASE}
          SNOWFLAKE_EDP_IN_SCHEMA: ${SNOWFLAKE_EDP_IN_SCHEMA}
          SNOWFLAKE_EDP_CORE_SCHEMA: ${SNOWFLAKE_EDP_CORE_SCHEMA}
          SNOWFLAKE_EDP_ACC_SCHEMA: ${SNOWFLAKE_EDP_ACC_SCHEMA}
          SNOWFLAKE_EDP_DBT_PROJECT: ${SNOWFLAKE_EDP_DBT_PROJECT:-DEV_DBT_PROJECT_EDP_ORDERS}
          SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT: ${SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT:-DEV_DBT_PROJECT_EDP_CUSTOMERS}
          SNOWFLAKE_CLONE_SCHEMA: ${SNOWFLAKE_CLONE_SCHEMA}
          SNOW_DBT_TARGET_NAME: ${SNOW_DBT_TARGET_NAME:-dev}
          DBT_THREADS: ${DBT_THREADS}

        services:
          dbt-executor:
            build:
              context: .
              dockerfile: dbt/Dockerfile
            image: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-edp-local}}/dbt-executor:dev
            environment: *common-env
            volumes:
              - ./dbt:/opt/platform/dbt
              - ./ci/snowflake:/opt/platform/ci/snowflake
            networks:
              - platform

        networks:
          platform:
            name: ${PLATFORM_DOCKER_NETWORK:-local-platform-net}
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
        project_readme(
            project_path,
            dedent(
                """\
                This is the source-system repository for Finnova.

                Managed artifacts:

                - Two Airflow DAGs for PostgreSQL -> MinIO/Iceberg ingestion: one for `orders`, one for `customers`
                - Two dlt ingestion entrypoints: one for `orders`, one for `customers`
                - One combined source dbt project for Snowflake `INBOUND`, `CORE`, and `ACCESS`, executed natively in Snowflake
                - Source dbt manifests are published to MinIO so the downstream EDP repositories can weave the public source models into their own dbt projects with dbt-loom
                - Two SDPs inside the same repository: `orders` and `customers`
                - `ci/scripts/` contains only CI helper scripts
                - `ci/` contains runner-only config and Snowflake foundation metadata

                Main CI entrypoint:

                - `./ci/scripts/prepare-ci-sandbox.sh sdp artifacts/context/sdp.env`
                - `./ci/scripts/verify-ingestion-promotion.sh`
                - `./ci/scripts/verify-sdp-promotion.sh`
                - `./ci/scripts/deploy-sdp-dev.sh`
                - `./ci/scripts/deploy-sdp-prd.sh`

                CI behaviour:

                - When a new non-default branch appears in GitLab, a GitLab webhook triggers the platform-side branch provisioner to create the branch sandbox automatically.
                - The initial branch-creation push event does not run the heavy CI validation pipeline; it exists only to provision the isolated developer sandbox.
                - Later branch push pipelines reuse one branch-scoped Snowflake zero-copy environment and run repeatable CI validation there.
                - The clone lifecycle is driven by `ci/snowflake/data_products.json`, so every registered Snowflake data product database is cloned, not just the sample SDP and EDP orders databases.
                - Branch clone databases are named from the original database plus `CI_CLO`, the owning project token, and the branch token, for example `DB_SDP_ORDERS_CI_CLO_SDP_FEATURE_X`.
                - Later non-default branch push pipelines write ingestion output to a stable branch-scoped MinIO/S3 prefix and Iceberg namespace and run repeatable CI validation there with `sqlfluff lint`, ingestion checks, and Snowflake-native `dbt parse`, `dbt run`, and `dbt test`.
                - Opening a merge request creates or reuses one MR-scoped zero-copy clone plus one MR-scoped MinIO/Iceberg namespace, and MR pipelines validate the candidate there in detail.
                - MR-scoped zero-copy environments stay in place while the merge request stays open and are destroyed automatically when the merge request is merged or closed.
                - A merge commit into `main` triggers the CD part of the same pipeline family: DEV deploy runs automatically, then the committer can approve the PRD deployment gate.
                - PRD deployment runs in the same post-merge pipeline after the approval gate and deploys to shared `PRD_` targets such as `PRD_local_platform_ingest`, `PRD_DB_SDP_ORDERS`, and `PRD_DB_SDP_CUSTOMERS`.
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
        project_readme(
            project_path,
            dedent(
                """\
                This is the Enterprise Data Product repository.

                Managed artifacts:

                - EDP dbt project for Snowflake `INBOUND`, `CORE`, and `ACCESS`, executed natively in Snowflake
                - The upstream source manifests are fetched from MinIO into `loom/manifest.json.gz` and woven into the project with dbt-loom before Snowflake deployment
                - `ci/scripts/` contains only CI helper scripts
                - `ci/` contains runner-only config and Snowflake foundation metadata

                Upstream dependency:

                - The published SDP `ACCESS` tables must already exist in Snowflake before the EDP promotion runs.

                Main CI entrypoint:

                - `./ci/scripts/prepare-ci-sandbox.sh edp artifacts/context/edp.env`
                - `./ci/scripts/verify-edp-promotion.sh proj_edp_orders`
                - `./ci/scripts/deploy-edp-dev.sh proj_edp_orders`
                - `./ci/scripts/deploy-edp-prd.sh proj_edp_orders`

                CI behaviour:

                - When a new non-default branch appears in GitLab, a GitLab webhook triggers the platform-side branch provisioner to create the branch sandbox automatically.
                - The initial branch-creation push event does not run the heavy CI validation pipeline; it exists only to provision the isolated developer sandbox.
                - Later branch push pipelines reuse one branch-scoped Snowflake zero-copy environment and run repeatable CI validation there.
                - The clone lifecycle is driven by `ci/snowflake/data_products.json`, so every registered Snowflake data product database is cloned, not just the sample SDP and EDP orders databases.
                - Branch clone databases are named from the original database plus `CI_CLO`, the owning project token, and the branch token, for example `DB_EDP_ORDERS_CI_CLO_EDP_FEATURE_X`.
                - Later non-default branch push pipelines run repeatable CI validation in the branch clone with `sqlfluff lint` plus Snowflake-native `dbt parse`, `dbt run`, and `dbt test`.
                - Opening a merge request creates or reuses one MR-scoped zero-copy clone, and MR pipelines validate the candidate there in detail.
                - MR-scoped zero-copy environments stay in place while the merge request stays open and are destroyed automatically when the merge request is merged or closed.
                - A merge commit into `main` triggers the CD part of the same pipeline family: DEV deploy runs automatically, then the committer can approve the PRD deployment gate.
                - PRD deployment runs in the same post-merge pipeline after the approval gate and deploys to shared `PRD_` targets such as `PRD_DB_EDP_ORDERS`.
                - Branch environments are preserved after the pipeline, can be destroyed explicitly with the manual `destroy_edp_branch_sandbox` job, and are also destroyed automatically when the GitLab branch is deleted.
                """
            ),
        ),
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
        project_readme(
            project_path,
            dedent(
                """\
                This is the Enterprise Data Product repository for customers.

                Managed artifacts:

                - EDP customers dbt project for Snowflake `INBOUND`, `CORE`, and `ACCESS`, executed natively in Snowflake
                - The upstream source manifests are fetched from MinIO into `loom/manifest.json.gz` and woven into the project with dbt-loom before Snowflake deployment
                - `ci/scripts/` contains only CI helper scripts
                - `ci/` contains runner-only config and Snowflake foundation metadata

                Upstream dependency:

                - The published SDP customers `ACCESS` tables must already exist in Snowflake before the EDP promotion runs.

                Main CI entrypoint:

                - `./ci/scripts/prepare-ci-sandbox.sh edp artifacts/context/edp.env`
                - `./ci/scripts/verify-edp-promotion.sh proj_edp_customers`
                - `./ci/scripts/deploy-edp-dev.sh proj_edp_customers`
                - `./ci/scripts/deploy-edp-prd.sh proj_edp_customers`
                """
            ),
        ),
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
