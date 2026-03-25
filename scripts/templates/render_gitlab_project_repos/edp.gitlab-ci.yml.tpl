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
    - printf 'RUNTIME_IMAGE_PREFIX=%s\n' "${RUNTIME_IMAGE_PREFIX}" > artifacts/context/runtime.env
    - printf 'DBT_RUNNER_IMAGE=%s/dbt-executor:dev\n' "${RUNTIME_IMAGE_PREFIX}" >> artifacts/context/runtime.env
    - printf 'SNOW_DBT_RUNNER_IMAGE=%s/dbt-executor:dev\n' "${RUNTIME_IMAGE_PREFIX}" >> artifacts/context/runtime.env
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
