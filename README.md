# Local Platform

This repository provides a local integration platform for fast CI/CD testing across `GitLab`, `GitLab Runner`, `Airflow`, `dlt`, `dbt`, `PostgreSQL`, `MinIO`, and `Snowflake`.

The default sample flow is:

`PostgreSQL -> Airflow -> dlt -> MinIO/Iceberg -> Snowflake -> dbt`

`dlt` always runs in an external runtime container. `dbt` is deployed as a Snowflake dbt project object and executed natively inside Snowflake. The local `dbt-executor` container exists only to package and trigger Snowflake-native `dbt parse`, `dbt run`, `dbt test`, and `dbt build` through Snowflake CLI.

The platform repo is the control plane. During GitLab bootstrap it renders and pushes three separate GitLab project repos:

- `proj_source_finnova`: owns the Airflow DAG, the dlt ingestion code, and both SDP dbt projects for the Finnova source
- `proj_edp_orders`: owns the orders EDP dbt project
- `proj_edp_customers`: owns the customers EDP dbt project

The dbt source-of-truth now lives only under `dbt/projects/*`. The old flat `dbt/models` and root `dbt/dbt_project.yml` layout is not used anymore.

## Services

- `gitlab-platform`: local GitLab UI and API
- `gitlab-fargate-runner`: local Docker executor runner that approximates ephemeral Fargate-style jobs
- `airflow-webserver` and `airflow-scheduler`: orchestration layer
- `dlt-extractor`: ingestion runtime container
- `dbt-executor`: Snowflake CLI trigger runtime for Snowflake-native dbt project deploy/execute operations
- `source-postgres-db`: operational source database with deterministic sample data
- `lakehouse-object-store`: MinIO as local S3-compatible storage
- `airflow-metadata-db`: Airflow metadata plus local Iceberg SQL catalog

## Sample Data Products

The repo ships with four sample Snowflake data products built by dbt.

### SDP Orders

Database: `DB_SDP_ORDERS`

Schemas:

- `INBOUND`
- `CORE`
- `ACCESS`

Objects:

- `INBOUND.EXT_ORDERS_RAW`
- `INBOUND.EXT_ORDER_ITEMS_RAW`
- `CORE.T_ORDERS_CLEAN`
- `CORE.T_ORDER_ITEMS_CLEAN`
- `CORE.T_CUSTOMER_ORDER_SUMMARY`
- `ACCESS.T_ORDERS_ORDER_GRAIN`
- `ACCESS.T_ORDERS_CUSTOMER_GRAIN`
- `ACCESS.T_ORDER_LINES_ORDER_GRAIN`

Meaning:

- `INBOUND` is the source-facing landing layer.
- In local mode, `EXT_*` objects are Snowflake transient-table stand-ins for external tables because Snowflake cannot query private local MinIO directly.
- With real S3 plus Open Catalog, this layer is where the true external-table pattern belongs.
- `CORE` contains basic cleanup and shaping.
- `ACCESS` publishes reusable order-grain and customer-grain outputs for downstream products.

### SDP Customers

Database: `DB_SDP_CUSTOMERS`

Schemas:

- `INBOUND`
- `CORE`
- `ACCESS`

Objects:

- `INBOUND.EXT_CUSTOMERS_RAW`
- `CORE.T_CUSTOMERS_CLEAN`
- `CORE.T_CUSTOMER_REGION_SUMMARY`
- `CORE.T_CUSTOMER_SEGMENT_SUMMARY`
- `ACCESS.T_CUSTOMERS_ENTITY_GRAIN`
- `ACCESS.T_CUSTOMERS_REGION_GRAIN`
- `ACCESS.T_CUSTOMERS_SEGMENT_GRAIN`

### EDP Orders

Database target after first EDP deployment: `DB_EDP_ORDERS`

Schemas:

- `INBOUND`
- `CORE`
- `ACCESS`

Objects:

- `INBOUND.V_IN_ORDERS_ORDER_GRAIN`
- `INBOUND.V_IN_ORDERS_CUSTOMER_GRAIN`
- `INBOUND.V_IN_ORDER_LINES_ORDER_GRAIN`
- `CORE.T_ORDERS_3NF`
- `CORE.T_ORDER_LINES_3NF`
- `CORE.T_CUSTOMERS_3NF`
- `CORE.DIM_CUSTOMERS`
- `CORE.DIM_ORDER_STATUS`
- `CORE.FCT_ORDER_REVENUE_STAR`
- `ACCESS.T_ORDERS_ONLY`
- `ACCESS.T_ORDERS_COMPLETE`
- `ACCESS.T_ORDERS_FULFILLED`

Meaning:

- `INBOUND` consumes the published `ACCESS` layer from the SDP.
- `CORE` contains the business model: first 3NF tables, then the star schema.
- `ACCESS` publishes business-facing outputs derived from the star schema.

### EDP Customers

Database target after first EDP deployment: `DB_EDP_CUSTOMERS`

Schemas:

- `INBOUND`
- `CORE`
- `ACCESS`

Objects:

- `INBOUND.V_IN_CUSTOMERS_ENTITY_GRAIN`
- `INBOUND.V_IN_CUSTOMERS_REGION_GRAIN`
- `INBOUND.V_IN_CUSTOMERS_SEGMENT_GRAIN`
- `CORE.T_CUSTOMERS_3NF`
- `CORE.T_REGIONS_3NF`
- `CORE.T_SEGMENTS_3NF`
- `CORE.DIM_REGIONS`
- `CORE.DIM_SEGMENTS`
- `CORE.FCT_CUSTOMER_VALUE_STAR`
- `ACCESS.T_CUSTOMERS_ONLY`
- `ACCESS.T_CUSTOMERS_COMPLETE`
- `ACCESS.T_CUSTOMERS_HIGH_VALUE`

## dbt Naming

The dbt nodes follow the `model_sdp_*` and `model_edp_*` naming pattern.

Examples:

- `model_sdp_orders_core_orders_clean`
- `model_sdp_orders_access_orders_customer_grain`
- `model_edp_orders_core_fct_order_revenue_star`
- `model_edp_orders_access_orders_complete`
- `model_sdp_customers_access_customers_entity_grain`
- `model_edp_customers_access_customers_complete`

## Full Reset And Bootstrap

Unix/macOS:

```bash
./scripts/reset-platform.sh
./scripts/bootstrap.sh
```

After GitLab is reachable on `http://localhost:8080`, finish the GitLab bootstrap:

```bash
./scripts/bootstrap-gitlab.sh
```

Windows PowerShell:

```powershell
pwsh ./scripts/windows/reset-platform.ps1
pwsh ./scripts/windows/bootstrap.ps1
pwsh ./scripts/windows/bootstrap-gitlab.ps1
```

Those are the intended full local restart flows.

## Quick Start

1. Copy `.env.example` to `.env`.
2. Fill the Snowflake variables if you want Snowflake connectivity.
3. Reset if you want a clean rebuild:

Unix/macOS:

```bash
./scripts/reset-platform.sh
```

Windows:

```powershell
pwsh ./scripts/windows/reset-platform.ps1
```

4. Bootstrap the platform:

Unix/macOS:

```bash
./scripts/bootstrap.sh
```

Windows:

```powershell
pwsh ./scripts/windows/bootstrap.ps1
```

5. Wait for the web UIs:

- GitLab: `http://localhost:8080`
- Airflow: `http://localhost:8088`
- MinIO console: `http://localhost:9001`

GitLab is the slowest service in the stack. After a full reset it can take a few minutes before `http://localhost:8080/users/sign_in` stops returning warm-up errors.

Recommended local host settings for stability:

- Rancher Desktop or Docker should have at least `6` CPUs and `12 GB` RAM available to the VM.
- If you use Rancher Desktop only for this Docker Compose stack, disable Kubernetes to free memory for GitLab and the CI runner.

6. Bootstrap the local GitLab projects and runner:

Unix/macOS:

```bash
./scripts/bootstrap-gitlab.sh
```

Windows:

```powershell
pwsh ./scripts/windows/bootstrap-gitlab.ps1
```

The runner is intentionally started by `bootstrap-gitlab.sh`, not by the base bootstrap, so GitLab can finish warming up before CI job polling begins.

Local GitLab CI runs against the already bootstrapped shared platform stack. It does not spin up a second isolated copy of GitLab, Airflow, MinIO, and PostgreSQL inside each pipeline run. That keeps local GitLab stable and makes the pipelines much cheaper to run on one machine.

7. Print the current URLs, credentials, paths, and generated GitLab details at any time:

Unix/macOS:

```bash
./scripts/print-setup-summary.sh
```

Windows:

```powershell
pwsh ./scripts/windows/print-setup-summary.ps1
```

## Host Script Layout

- `scripts/*.sh`: Unix/macOS operator scripts and Linux-oriented internal helpers
- `scripts/windows/*.ps1`: Windows host operator scripts for reset, bootstrap, GitLab bootstrap, Snowflake-only rebuild, repo publish, and daily-use entrypoints
- Internal CI helpers remain Linux-oriented because GitLab jobs and the runtime containers execute inside Linux containers, even when the host machine is Windows

## Windows Usage

The platform can be operated from Windows, but the runtime model stays the same:

- Windows runs the host/operator commands through `pwsh`
- `GitLab`, `Airflow`, `dbt`, `dlt`, `PostgreSQL`, and `MinIO` still run inside Linux containers
- the same `.env` file is used on Windows, Unix, and macOS

Recommended Windows prerequisites:

- PowerShell 7 available as `pwsh`
- Docker Desktop or Rancher Desktop configured for Linux containers
- at least `6` CPUs and `12 GB` RAM assigned to the Docker VM for GitLab stability
- run all commands from the repository root

If your Windows execution policy blocks local PowerShell scripts, run them explicitly with:

```powershell
pwsh -ExecutionPolicy Bypass ./scripts/windows/bootstrap.ps1
```

The normal Windows operator flow is:

```powershell
pwsh ./scripts/windows/reset-platform.ps1
pwsh ./scripts/windows/bootstrap.ps1
pwsh ./scripts/windows/bootstrap-gitlab.ps1
```

For a Snowflake-only rebuild on Windows:

```powershell
pwsh ./scripts/windows/bootstrap-snowflake-products.ps1
```

For a one-command sample run on Windows:

```powershell
pwsh ./scripts/windows/run-local-pipeline.ps1
```

Important scope note:

- the main operator entrypoints have Windows PowerShell equivalents
- many lower-level validation and CI helper scripts remain `.sh` because the CI system and runtime containers are Linux-based
- if you want to run those lower-level `.sh` helpers directly from a Windows host, use Git Bash or WSL

## Branch Isolation

The platform now provisions developer sandboxes from GitLab branch events, not from a periodic branch scan.

- A background service `gitlab-branch-provisioner` receives GitLab project webhooks for branch ref changes.
- When a new branch appears in GitLab, the service provisions the associated isolated environment automatically.
- SDP branches get Snowflake branch clones plus a branch-specific MinIO/S3 prefix and Iceberg namespace.
- EDP branches get Snowflake branch clones.
- The Snowflake clone scope is driven by [data_products.json](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/snowflake/data_products.json), so every registered data product database is cloned for branch isolation, not just the current sample SDP and EDP orders databases.
- Branch clone databases are named from the original database plus the owning project and branch, for example `DB_EDP_ORDERS_CI_CLO_EDP_FEATURE_X`.
- The owning project token stays in the clone name so the same branch name can exist in both GitLab projects without reusing the same Snowflake clone by accident.
- The branch pipeline then reuses that pre-created sandbox instead of creating a second one.
- When the branch is deleted in GitLab, the provisioner destroys the associated sandbox automatically.

In practice this means a developer can create a new branch in GitLab and then work only against the isolated clone objects and temporary storage path for that branch. The sandbox creation is event-driven and does not depend on a periodic polling interval.

If you scaffold an additional Snowflake data product with [scaffold_mesh_product.py](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/scripts/scaffold_mesh_product.py), its SDP and EDP databases are added to the clone registry automatically.

You can watch the provisioner with:

```bash
docker compose logs -f gitlab-branch-provisioner
```

## DEV And PRD Deployment Model

The platform now supports a real deployment step for the sample products without launching duplicate long-lived services.

- deployment always targets the already running shared local services
- deployed artifacts are marked with explicit `DEV_` and `PRD_` targets or dedicated runtime image prefixes
- the deployment target is stable, so repeated default-branch runs update the same DEV or PRD objects instead of creating more ephemeral services

Current DEV targets after a fresh initialization:

- Airflow DAGs: `DEV_local_platform_orders_ingest`, `DEV_local_platform_customers_ingest`
- dlt pipeline names: `DEV_local_platform_orders_ingest`, `DEV_local_platform_customers_ingest`
- source system namespace: `postgres`
- Iceberg catalog name: `dev`
- MinIO/S3 prefix: `landing/dev`
- resulting Iceberg layout: `landing/dev/postgres/{table_name}/...`
- Snowflake SDP database: `DB_SDP_ORDERS`
- Snowflake SDP customers database: `DB_SDP_CUSTOMERS`
- Snowflake EDP orders database target: `DB_EDP_ORDERS` (not materialized after initialization; branch and MR CI use isolated suffixed databases)
- Snowflake EDP customers database target after initialization: `DB_EDP_CUSTOMERS`
- Snowflake dbt project objects after initialization: `DEV_DBT_PROJECT_SOURCE_FINNOVA`, `DEV_DBT_PROJECT_EDP_ORDERS`, `DEV_DBT_PROJECT_EDP_CUSTOMERS`
- Only the EDP customers database is materialized during initialization; the EDP orders dbt project is deployed but its DEV database is created only by CD deployment or isolated branch/MR test runs
- DEV SDP runtime image prefix: `local-platform-dev-sdp`
- DEV EDP runtime image prefix: `local-platform-dev-edp`

Current PRD targets:

- Airflow DAGs: `PRD_local_platform_orders_ingest`, `PRD_local_platform_customers_ingest`
- dlt pipeline names: `PRD_local_platform_orders_ingest`, `PRD_local_platform_customers_ingest`
- source system namespace: `postgres`
- Iceberg catalog name: `prd`
- MinIO/S3 prefix: `landing/prd`
- resulting Iceberg layout: `landing/prd/postgres/{table_name}/...`
- Snowflake SDP database target after initialization: `PRD_DB_SDP_ORDERS`
- Snowflake SDP customers database target after initialization: `PRD_DB_SDP_CUSTOMERS`
- Snowflake EDP orders database target: `PRD_DB_EDP_ORDERS` (not materialized after initialization; PRD database is created only by PRD CD deployment)
- Snowflake EDP customers database target after initialization: `PRD_DB_EDP_CUSTOMERS`
- Snowflake dbt project objects after initialization: `PRD_DBT_PROJECT_SOURCE_FINNOVA`, `PRD_DBT_PROJECT_EDP_ORDERS`, `PRD_DBT_PROJECT_EDP_CUSTOMERS`
- Only the EDP customers PRD database is materialized during initialization; the EDP orders PRD dbt project is deployed but its PRD database is created only by PRD CD deployment
- PRD SDP runtime image prefix: `local-platform-prd-sdp`
- PRD EDP runtime image prefix: `local-platform-prd-edp`

Storage layout rules:

- DEV ingestion writes to `landing/dev/{source_system}/{table_name}/...`
- PRD ingestion writes to `landing/prd/{source_system}/{table_name}/...`
- branch and MR sandboxes write to `landing/ci/{project}/{sandbox_kind}/{source_system}/{sandbox_namespace}/...`
- sandbox marker/config files live under `config/ci/...`
- dlt/Iceberg also create technical namespace objects such as `_dlt_*` and `init` inside the namespace root; those are expected runtime artifacts, while platform-owned config markers are kept under `config/...`

This gives you a clear distinction between:

- branch sandboxes: isolated, temporary, branch-associated
- DEV deployment: stable shared development target
- PRD deployment: stable shared production-style target for final deployment testing

## Useful Commands

Reset and rebuild:

```bash
./scripts/reset-platform.sh
./scripts/bootstrap.sh
./scripts/bootstrap-gitlab.sh
```

```powershell
pwsh ./scripts/windows/reset-platform.ps1
pwsh ./scripts/windows/bootstrap.ps1
pwsh ./scripts/windows/bootstrap-gitlab.ps1
```

Reload only the sample source data:

```bash
./scripts/load-source-sample-data.sh
```

```powershell
pwsh ./scripts/windows/load-source-sample-data.ps1
```

Run the default local pipeline:

```bash
./scripts/run-local-pipeline.sh
```

```powershell
pwsh ./scripts/windows/run-local-pipeline.ps1
```

Test the Airflow DAG from the CLI:

```bash
./scripts/test-airflow-dag.sh
```

Ensure Snowflake foundation only:

```bash
bash ./scripts/ensure-snowflake-foundation.sh
```

```powershell
pwsh ./scripts/windows/ensure-snowflake-foundation.ps1
```

Reset and rebuild the initialized Snowflake state:

```bash
./scripts/bootstrap-snowflake-products.sh
```

```powershell
pwsh ./scripts/windows/bootstrap-snowflake-products.ps1
```

Deploy the sample PRD artifacts into the shared running platform:

```bash
./scripts/deploy-sdp-dev.sh
./scripts/deploy-edp-dev.sh
./scripts/deploy-sdp-prd.sh
./scripts/deploy-edp-prd.sh
```

## Script Reference

The scripts below are the important control-plane entrypoints for this repository. If you are operating the platform manually, start with the `Bootstrap And Reset`, `Daily Use`, and `GitLab Publishing` groups.

The Unix/macOS commands are the `.sh` entrypoints under `scripts/`. Windows host equivalents live under `scripts/windows/` as PowerShell scripts.

### Bootstrap And Reset

- `./scripts/reset-platform.sh`
  Stops the local stack, removes containers, volumes, generated runtime clutter, drops registered Snowflake CI clone databases when credentials and the local `dbt-executor` image are available, and gives you a clean starting point.
- `./scripts/bootstrap.sh`
  Builds and starts the base local platform, seeds the sample source data, and prints the current access summary.
- `./scripts/bootstrap-gitlab.sh`
  Finishes the GitLab setup: creates or resolves the SDP and EDP projects, configures branch webhooks, registers runners, publishes the rendered repos, and syncs GitLab CI variables.
  On a fresh bootstrap where the GitLab projects are newly created, each hosted repo is initialized with a single `main` commit named `init-artifacts` so users start from a clean history.
- `./scripts/bootstrap-snowflake-products.sh`
  Drops lingering Snowflake CI clone databases, recreates the Snowflake foundation from scratch, reloads the raw inbound data, deploys and builds the DEV and PRD SDP dbt projects, and verifies that EDP remains undeployed and empty until the EDP CI/CD flow promotes it.
- `./scripts/cleanup-snowflake-ci-clones.sh`
  Drops all Snowflake CI clone databases for the registered data products, for example `DB_SDP_ORDERS_CI_CLO_*` and `DB_EDP_ORDERS_CI_CLO_*`, and purges Snowflake dbt project objects from the control schema.
- `./scripts/print-setup-summary.sh`
  Prints the current URLs, credentials, paths, project ids, tokens, and important runtime locations.
- `pwsh ./scripts/windows/reset-platform.ps1`
  Windows host equivalent of the full reset flow.
- `pwsh ./scripts/windows/bootstrap.ps1`
  Windows host equivalent of the base platform bootstrap.
- `pwsh ./scripts/windows/bootstrap-gitlab.ps1`
  Windows host equivalent of the GitLab bootstrap and repo publish flow.
- `pwsh ./scripts/windows/bootstrap-snowflake-products.ps1`
  Windows host equivalent of the Snowflake-only initialization flow with DEV and PRD SDP deployed and EDP left undeployed.
- `pwsh ./scripts/windows/print-setup-summary.ps1`
  Windows host equivalent of the access summary output.

### Daily Use

- `./scripts/load-source-sample-data.sh`
  Reseeds the deterministic PostgreSQL sample data.
- `./scripts/run-local-pipeline.sh`
  Runs the default local sample flow against the running platform using the explicit DEV Airflow DAG, DEV dlt settings, and Snowflake-native SDP dbt execution. EDP is intentionally left undeployed here.
- `pwsh ./scripts/windows/load-source-sample-data.ps1`
  Windows host equivalent of the PostgreSQL sample-data reload.
- `pwsh ./scripts/windows/run-local-pipeline.ps1`
  Windows host equivalent of the one-command local sample flow with only SDP materialized in Snowflake.
- `./scripts/test-airflow-dag.sh`
  Runs the Airflow DAG from the CLI for fast orchestration validation without using the UI.
- `./scripts/verify-ingestion-promotion.sh`
  Validates the source ingestion path only: PostgreSQL -> Airflow -> dlt -> MinIO/Iceberg.
- `./scripts/verify-sdp-promotion.sh`
  Validates the SDP Snowflake/dbt promotion path. It deploys the SDP Snowflake dbt project object and executes `parse`, `run`, and `test` inside Snowflake. Internal `--skip-foundation`, `--skip-raw-sync`, and `--skip-dbt` flags exist for bootstrap and CI reuse.
- `./scripts/verify-edp-promotion.sh`
  Validates the EDP Snowflake/dbt promotion path. It deploys the EDP Snowflake dbt project object and executes `parse`, `run`, and `test` inside Snowflake. Internal `--skip-foundation` and `--skip-dbt` flags exist for bootstrap and CI reuse.
- `./scripts/deploy-airflow-dag.sh dev|prd|current orders|customers`
  Deploys the selected scoped Airflow DAG wrapper into the shared Airflow service so the source ingestion pipelines are available separately for `orders` and `customers` in DEV, PRD, or CI sandbox mode.
- `./scripts/deploy-snowflake-dbt-project.sh`
  Packages a dbt project, uploads it to the Snowflake control stage, and creates or replaces the target Snowflake dbt project object.
- `./scripts/execute-snowflake-dbt-project.sh`
  Triggers `parse`, `run`, `test`, or `build` on a deployed Snowflake dbt project object.
- `./scripts/drop-snowflake-dbt-project.sh`
  Drops a Snowflake dbt project object and removes its staged project files from the Snowflake control stage.
- `./scripts/deploy-sdp-dev.sh`  
  Deploys the owned SDP artifacts into the shared DEV target automatically after merge: refreshes the shared Airflow services in place, deploys both `DEV_` source DAGs (`orders` and `customers`), validates both ingestion paths again, and deploys plus executes the shared source dbt project object natively in Snowflake.
- `./scripts/deploy-edp-dev.sh`  
  Deploys the owned EDP artifacts into the shared DEV target automatically after merge by deploying plus executing the EDP dbt project object natively in Snowflake.
- `./scripts/deploy-sdp-prd.sh`
  Retags the shared runtime images to stable PRD refs, deploys the `PRD_` Airflow ingestion DAG, validates the PRD ingestion path, and deploys plus executes the SDP dbt project object in `PRD_DB_SDP_ORDERS`.
- `./scripts/deploy-edp-prd.sh`
  Retags the shared Snowflake trigger runtime image to a stable PRD ref and deploys plus executes the EDP dbt project object in `PRD_DB_EDP_ORDERS`.

### GitLab Publishing And Project Sync

- `./scripts/publish-platform-repos.sh`
  Renders the hosted SDP and EDP GitLab repos from this control repo and pushes only those rendered repos to local GitLab.
- `python3 scripts/render_gitlab_project_repos.py`
  Regenerates the rendered SDP and EDP working trees under `gitlab-projects/generated/` without publishing them.
- `./scripts/sync-gitlab-ci-variables.sh`
  Pushes the current CI/CD variables from the local platform into the two GitLab projects.
- `pwsh ./scripts/windows/publish-platform-repos.ps1`
  Windows host equivalent of the rendered-repo publish flow.
- `pwsh ./scripts/windows/sync-gitlab-ci-variables.ps1`
  Windows host equivalent of the GitLab CI/CD variable sync.

### Branch Sandbox Lifecycle

- `./scripts/manage-branch-sandbox.sh`
  Manual helper to create or destroy a branch sandbox outside of the automatic GitLab webhook flow.
- `./scripts/prepare-ci-sandbox.sh`
  Internal CI helper that creates or reuses the Snowflake clone environment and, for SDP, the isolated MinIO/Iceberg namespace.
- `./scripts/cleanup-ci-sandbox.sh`
  Internal CI helper that preserves or destroys a sandbox depending on branch/default-branch rules.
- `./scripts/manage-merge-request-sandbox.sh`
  Internal helper for merge-request-scoped sandbox lifecycle. It provisions MR clones when a merge request is opened and destroys them again when the merge request is merged or closed.
- `./scripts/require-approver-match-commit.sh`
  Internal approval guard used by GitLab manual PRD jobs. It checks that the GitLab user who played the approval step matches the checked-out commit identity before PRD deployment is allowed to continue.

### Scaffolding New Assets

- `python3 scripts/scaffold_ingestion_pipeline.py <name>`
  Creates a new ingestion scaffold such as a DAG, dlt pipeline, and validation helper.
- `python3 scripts/scaffold_mesh_product.py <name>`
  Creates a new Snowflake data-product scaffold, dbt model skeletons, and validation helpers.
- `python3 scripts/scaffold_support.py`
  Shared helper module used by the scaffolders. This is not an operator entrypoint.

### Internal Shared Helpers

- `./scripts/ensure-snowflake-foundation.sh`
  Applies the base Snowflake foundation SQL. Safe to run manually, but usually called by the promotion scripts.
- `pwsh ./scripts/windows/ensure-snowflake-foundation.ps1`
  Windows host equivalent of the Snowflake foundation helper.
- `./scripts/common.sh`
  Shared shell helper library for env loading, path resolution, and clone naming. This is internal plumbing and normally not called directly.
- `./scripts/windows/common.ps1`
  Shared PowerShell helper library for the Windows host operator scripts. This is internal plumbing and normally not called directly.

## Validation Commands

These validation helpers are Linux-oriented shell entrypoints because they mirror the GitLab CI/runtime environment.
On Unix/macOS, run them directly. On Windows, use Git Bash or WSL if you want to run these low-level helpers manually.

Validate the ingestion promotion flow:

```bash
./scripts/verify-ingestion-promotion.sh
```

Validate the SDP dbt promotion flow:

```bash
./scripts/verify-sdp-promotion.sh
```

Validate the EDP dbt promotion flow:

```bash
./scripts/verify-edp-promotion.sh
```

Run the zero-copy clone check:

```bash
docker compose run --rm dbt-executor python /opt/platform/dbt/scripts/zero_copy_clone_check.py
```

## GitLab Project Split

The local platform keeps a strict separation between the source repo and the hosted/platform GitLab repos.

- source repo: this repository, with Docker assets, Airflow, dlt, dbt, bootstrap scripts, and render logic
- platform repos: rendered working trees under [gitlab-projects/generated/proj_source_finnova](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/gitlab-projects/generated/proj_source_finnova), [gitlab-projects/generated/proj_edp_orders](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/gitlab-projects/generated/proj_edp_orders), and [gitlab-projects/generated/proj_edp_customers](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/gitlab-projects/generated/proj_edp_customers)

Only the rendered platform repos are pushed to the hosted GitLab instance. The source repo itself is not bootstrapped into GitLab and `bootstrap-gitlab.sh` or `publish-platform-repos.sh` do not add or change a remote on the source repo root.

The ownership split is:

- `proj_source_finnova`: promotes the Airflow DAG, dlt ingestion runtime, and both SDP dbt models for the Finnova source
- `proj_edp_orders`: promotes only the orders EDP dbt models that consume the SDP access layer
- `proj_edp_customers`: promotes only the customers EDP dbt models that consume the SDP access layer

Each generated project ships its own `.gitlab-ci.yml` with isolated CI/CD verification:

- the platform auto-provisions a branch sandbox from GitLab webhook events when a new non-default branch appears in GitLab
- branch-creation pushes do not run the heavy validation pipeline; they only create the isolated developer sandbox
- later non-default branch push pipelines reuse one stable branch-scoped Snowflake zero-copy environment so developers do not touch the shared DEV databases
- the SDP pipeline also reuses one stable branch-scoped MinIO/S3 prefix, dlt pipeline name, and Iceberg namespace
- branch CI runs `sqlfluff lint` plus repeated Snowflake-native `dbt parse`, `dbt run`, and `dbt test` validations against that preserved sandbox
- opening a merge request creates one MR-scoped zero-copy environment; MR pipelines validate there in detail and that MR sandbox stays alive until the merge request is merged or closed
- merging the merge request to `main` triggers the post-merge CD pipeline automatically; it deploys directly into the shared DEV target
- the same post-merge pipeline then stops at a manual PRD approval gate that must be played by the commit identity, and only then deploys into the shared PRD target
- non-default branch pipelines preserve the branch sandbox after the pipeline
- branch sandboxes are destroyed automatically only when the branch itself is deleted in GitLab
- if the source branch is kept after merge, the branch sandbox also stays in place until that branch is explicitly deleted

The SDP project pipeline is intentionally split into two CI validation steps so cold-start GitLab runs stay stable:

- `ci_validate_sdp_ingestion`: validates the Airflow DAG, dlt runtime, and Iceberg output in the isolated branch sandbox
- `ci_validate_sdp_models`: validates and rebuilds the SDP dbt models in Snowflake after ingestion has succeeded

The EDP project pipeline keeps a single CI validation step because it only owns dbt:

- `ci_validate_edp_models`: validates and rebuilds the EDP dbt models in Snowflake against the isolated clone

Default-branch and PRD pipelines now include real deployment jobs:

- `deploy_sdp_dev`: deploys the shared DEV Airflow DAG, DEV dlt runtime settings, and the SDP Snowflake dbt project artifacts automatically after merge
- `deploy_edp_dev`: deploys the shared DEV EDP Snowflake dbt project artifacts automatically after merge
- `deploy_sdp_prd`: deploys the PRD Airflow DAG plus the PRD SDP Snowflake dbt project artifacts
- `deploy_edp_prd`: deploys the PRD EDP Snowflake dbt project artifacts

The expected GitLab operator flow is:

1. Create a new branch in `proj_source_finnova`, `proj_edp_orders`, or `proj_edp_customers`.
2. Wait for the platform webhook handler to create the isolated branch sandbox automatically.
3. Push commits to that branch and rerun the branch CI pipeline as often as needed.
4. Open a merge request. The platform creates an MR-scoped sandbox automatically and the MR pipeline validates the candidate there in detail.
5. Merge the merge request to `main`. The post-merge default-branch pipeline deploys to the shared DEV target automatically.
6. If the DEV deployment is green, play the PRD approval job in that same post-merge pipeline. The PRD deployment then starts automatically.
7. If the merge request is closed or merged, the MR-scoped sandbox is destroyed automatically. If the source branch is deleted too, the branch-scoped sandbox is destroyed as well.

Those generated CI pipelines assume the base local platform has already been started with `./scripts/bootstrap.sh` and `./scripts/bootstrap-gitlab.sh`. They reuse the shared local runtime images and services instead of rebuilding or destroying the full platform stack inside the runner.

The generator for those repos is [render_gitlab_project_repos.py](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/scripts/render_gitlab_project_repos.py).

The rendered GitLab repos keep only product-owned code at the top level. Runner-only helpers live under `ci/`, so the hosted SDP and EDP repos stay focused on Airflow, dlt, dbt, and the CI/CD definitions that exercise them.

To republish the rendered repos after source changes, run:

```bash
./scripts/publish-platform-repos.sh
```

## Scaffolding New Assets

Create a new ingestion pipeline scaffold:

```bash
python3 scripts/scaffold_ingestion_pipeline.py retail_orders
```

That creates:

- a new Airflow DAG
- a new dlt pipeline script
- a verification script
- local source assets that can be transferred into the rendered SDP platform repo the next time you run `./scripts/publish-platform-repos.sh`

Create a new SDP/EDP dbt product scaffold:

```bash
python3 scripts/scaffold_mesh_product.py finance_orders
```

That creates:

- Snowflake foundation SQL for the new product databases
- dbt model skeletons
- a dbt verification script
- local source assets that can be transferred into the rendered SDP or EDP platform repo after you rerun `./scripts/publish-platform-repos.sh`

## Local Constraints

- Snowflake cannot read private `localhost` MinIO endpoints.
- Snowflake Open Catalog requires real cloud object storage, not local MinIO.
- Because of that, local mode uses the `snowflake_raw_sync.py` bridge to mirror the SDP inbound layer into Snowflake before Snowflake-native dbt runs.
- The GitLab runner uses Docker executor locally. It is a pragmatic stand-in for Fargate, not a literal reproduction of AWS networking or IAM.

## Sample Source Data

The seeded PostgreSQL source contains:

- `12` customers
- `30` orders
- `60` order items

The default validations currently prove:

- PostgreSQL -> Airflow/dlt -> MinIO/Iceberg works
- Snowflake inbound raw sync works
- SDP dbt product build works
- EDP dbt product build works
- zero-copy clone smoke test works
- GitLab child pipelines for ingestion and dbt promotion work locally
