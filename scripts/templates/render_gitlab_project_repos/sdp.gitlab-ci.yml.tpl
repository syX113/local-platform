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
    - source ./ci/scripts/common.sh
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
    - compose_build_services airflow-webserver dlt-extractor dbt-executor
    - printf 'RUNTIME_IMAGE_PREFIX=%s\n' "${RUNTIME_IMAGE_PREFIX}" > artifacts/context/runtime.env
    - printf 'DLT_RUNNER_IMAGE=%s/dlt-extractor:dev\n' "${RUNTIME_IMAGE_PREFIX}" >> artifacts/context/runtime.env
    - printf 'DBT_RUNNER_IMAGE=%s/dbt-executor:dev\n' "${RUNTIME_IMAGE_PREFIX}" >> artifacts/context/runtime.env
    - printf 'SNOW_DBT_RUNNER_IMAGE=%s/dbt-executor:dev\n' "${RUNTIME_IMAGE_PREFIX}" >> artifacts/context/runtime.env
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
    - __SQLFLUFF_LINT__

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
    - |
      __SOURCE_INGESTION_VALIDATE__
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
    - |
      __SOURCE_MODEL_VALIDATE__
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
