#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
from textwrap import dedent

from scaffold_support import ROOT_DIR, ensure_new_file, register_child_pipeline, require_slug


def create_ingestion_child_pipeline(
    *,
    slug: str,
    child_pipeline_path: Path,
    verify_script_path: str,
    artifact_dir: str,
    workflow_name: str,
    registry_job_name: str,
    registry_stage: str = "ingestion",
    needs: list[str] | None = None,
) -> None:
    content = dedent(
        f"""\
        include:
          - local: .gitlab/ci/common.yml

        workflow:
          name: {workflow_name}

        stages:
          - build
          - validate
          - promote
          - mock_cd

        build_{slug}_ingestion_runtimes:
          stage: build
          script:
            - docker compose build airflow-metadata-db source-postgres-db airflow-webserver dlt-extractor

        validate_{slug}_ingestion_assets:
          stage: validate
          script:
            - docker compose config -q
            - docker compose run --rm --no-deps --entrypoint python airflow-webserver -m compileall /opt/airflow/dags
            - docker compose run --rm --no-deps --entrypoint python dlt-extractor -m compileall /opt/platform/dlt

        promote_{slug}_ingestion:
          stage: promote
          script:
            - {verify_script_path}
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - {artifact_dir}/

        mock_cd_{slug}_ingestion:
          stage: mock_cd
          needs:
            - promote_{slug}_ingestion
          script:
            - mkdir -p {artifact_dir}
            - printf 'mock_cd={slug}_ingestion\\nstatus=skipped_real_deploy\\nreason=no_second_environment\\n' > {artifact_dir}/mock_cd.txt
            - cat {artifact_dir}/mock_cd.txt
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - {artifact_dir}/mock_cd.txt
        """
    )
    ensure_new_file(child_pipeline_path, content)
    register_child_pipeline(
        job_name=registry_job_name,
        stage=registry_stage,
        include_path=str(child_pipeline_path.relative_to(ROOT_DIR)),
        needs=needs,
    )


def create_dbt_child_pipeline(
    *,
    slug: str,
    child_pipeline_path: Path,
    verify_script_path: str,
    artifact_dir: str,
    workflow_name: str,
    registry_job_name: str,
    registry_stage: str = "dbt",
    needs: list[str] | None = None,
) -> None:
    content = dedent(
        f"""\
        include:
          - local: .gitlab/ci/common.yml

        workflow:
          name: {workflow_name}

        stages:
          - build
          - validate
          - promote
          - mock_cd

        build_{slug}_dbt_runtimes:
          stage: build
          script:
            - docker compose build airflow-metadata-db source-postgres-db dlt-extractor dbt-executor

        validate_{slug}_dbt_assets:
          stage: validate
          script:
            - docker compose config -q
            - docker compose run --rm --no-deps --entrypoint python dlt-extractor -m compileall /opt/platform/dlt
            - docker compose run --rm --no-deps --entrypoint python dbt-executor -m compileall /opt/platform/dbt
            - docker compose run --rm --no-deps dbt-executor dbt parse --project-dir /opt/platform/dbt --profiles-dir /opt/platform/dbt/profiles

        promote_{slug}_dbt:
          stage: promote
          script:
            - {verify_script_path}
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - {artifact_dir}/

        mock_cd_{slug}_dbt:
          stage: mock_cd
          needs:
            - promote_{slug}_dbt
          script:
            - mkdir -p {artifact_dir}
            - printf 'mock_cd={slug}_dbt\\nstatus=skipped_real_deploy\\nreason=no_second_environment\\n' > {artifact_dir}/mock_cd.txt
            - cat {artifact_dir}/mock_cd.txt
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - {artifact_dir}/mock_cd.txt
        """
    )
    ensure_new_file(child_pipeline_path, content)
    register_child_pipeline(
        job_name=registry_job_name,
        stage=registry_stage,
        include_path=str(child_pipeline_path.relative_to(ROOT_DIR)),
        needs=needs,
    )


def create_generic_child_pipeline(
    *,
    slug: str,
    child_pipeline_path: Path,
    verify_script_path: str,
    artifact_dir: str,
    workflow_name: str,
    registry_job_name: str,
    registry_stage: str,
    needs: list[str] | None = None,
) -> None:
    content = dedent(
        f"""\
        include:
          - local: .gitlab/ci/common.yml

        workflow:
          name: {workflow_name}

        stages:
          - validate
          - promote
          - mock_cd

        validate_{slug}_assets:
          stage: validate
          script:
            - docker compose config -q

        promote_{slug}:
          stage: promote
          script:
            - {verify_script_path}
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - {artifact_dir}/

        mock_cd_{slug}:
          stage: mock_cd
          needs:
            - promote_{slug}
          script:
            - mkdir -p {artifact_dir}
            - printf 'mock_cd={slug}\\nstatus=skipped_real_deploy\\nreason=no_second_environment\\n' > {artifact_dir}/mock_cd.txt
            - cat {artifact_dir}/mock_cd.txt
          artifacts:
            when: always
            expire_in: 7 days
            paths:
              - {artifact_dir}/mock_cd.txt
        """
    )
    ensure_new_file(child_pipeline_path, content)
    register_child_pipeline(
        job_name=registry_job_name,
        stage=registry_stage,
        include_path=str(child_pipeline_path.relative_to(ROOT_DIR)),
        needs=needs,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Scaffold a GitLab child pipeline and register it in the root pipeline.")
    parser.add_argument("slug", help="Pipeline slug, for example retail_orders")
    parser.add_argument("--kind", choices=("ingestion", "dbt", "generic"), default="generic")
    parser.add_argument("--verify-script", required=True, help="Repository-relative command to run in the promote stage")
    parser.add_argument("--artifact-dir", default="artifacts/scaffold", help="Artifact directory to publish")
    parser.add_argument("--workflow-name", help="Child pipeline workflow name")
    parser.add_argument("--registry-job-name", help="Job name in the root pipeline fan-out")
    parser.add_argument("--registry-stage", help="Stage in the root pipeline fan-out")
    parser.add_argument("--needs", nargs="*", default=[], help="Root pipeline jobs this child pipeline should wait for")
    parser.add_argument("--path", help="Repository-relative path for the child pipeline YAML")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    slug = require_slug(args.slug)
    kind = args.kind
    registry_stage = args.registry_stage or ("ingestion" if kind == "ingestion" else "dbt" if kind == "dbt" else "custom")
    workflow_name = args.workflow_name or f"{slug.replace('_', ' ').title()} {kind.upper()} Promotion"
    registry_job_name = args.registry_job_name or f"promote_{slug}_{kind}_pipeline"
    relative_path = args.path or f".gitlab/ci/{slug}-{kind}-promotion.yml"
    child_pipeline_path = ROOT_DIR / relative_path

    if kind == "ingestion":
        create_ingestion_child_pipeline(
            slug=slug,
            child_pipeline_path=child_pipeline_path,
            verify_script_path=args.verify_script,
            artifact_dir=args.artifact_dir,
            workflow_name=workflow_name,
            registry_job_name=registry_job_name,
            registry_stage=registry_stage,
            needs=args.needs,
        )
    elif kind == "dbt":
        create_dbt_child_pipeline(
            slug=slug,
            child_pipeline_path=child_pipeline_path,
            verify_script_path=args.verify_script,
            artifact_dir=args.artifact_dir,
            workflow_name=workflow_name,
            registry_job_name=registry_job_name,
            registry_stage=registry_stage,
            needs=args.needs,
        )
    else:
        create_generic_child_pipeline(
            slug=slug,
            child_pipeline_path=child_pipeline_path,
            verify_script_path=args.verify_script,
            artifact_dir=args.artifact_dir,
            workflow_name=workflow_name,
            registry_job_name=registry_job_name,
            registry_stage=registry_stage,
            needs=args.needs,
        )

    print(f"created {relative_path}")
    print(f"registered {registry_job_name} in the root GitLab pipeline")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
