# Script Groups

This directory is the control-plane entrypoint for the local platform source repository.

Main groups:

- Bootstrap and reset:
  - `bootstrap.sh`
  - `bootstrap-gitlab.sh`
  - `bootstrap-snowflake-products.sh`
  - `reset-platform.sh`
- GitLab publishing and sync:
  - `publish-platform-repos.sh`
  - `render_gitlab_project_repos.py`
  - `sync-gitlab-ci-variables.sh`
- Runtime validation:
  - `run-local-pipeline.sh`
  - `test-airflow-dag.sh`
  - `verify-ingestion-promotion.sh`
  - `verify-sdp-promotion.sh`
  - `verify-edp-promotion.sh`
  - `verify-dbt-promotion.sh`
- CI sandbox lifecycle:
  - `prepare-ci-sandbox.sh`
  - `cleanup-ci-sandbox.sh`
  - `manage-branch-sandbox.sh`
  - `verify-sdp-cd-clone.sh`
  - `verify-edp-cd-clone.sh`
- Scaffolding:
  - `scaffold_ingestion_pipeline.py`
  - `scaffold_mesh_product.py`
  - `scaffold_support.py`

Shared helpers:

- `common.sh`
- `ensure-snowflake-foundation.sh`
- `print-setup-summary.sh`
