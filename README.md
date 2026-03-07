# Local Platform

This repository provides a local integration platform for fast CI testing across `GitLab`, `GitLab Runner`, `Airflow`, `dlt`, `dbt`, `PostgreSQL`, `MinIO`, and `Snowflake`.

The default sample flow is:

`PostgreSQL -> Airflow -> dlt -> MinIO/Iceberg -> Snowflake -> dbt`

`dbt` and `dlt` always run in external containers. Locally those containers stand in for the real Fargate or EKS runtimes.

The platform repo is the control plane. During GitLab bootstrap it renders and pushes two separate GitLab project repos:

- `proj_sdp_orders`: owns the Airflow DAG, the dlt ingestion code, and the SDP dbt project
- `proj_edp_orders`: owns the EDP dbt project

## Services

- `gitlab-platform`: local GitLab UI and API
- `gitlab-fargate-runner`: local Docker executor runner that approximates ephemeral Fargate-style jobs
- `airflow-webserver` and `airflow-scheduler`: orchestration layer
- `dlt-extractor`: ingestion runtime container
- `dbt-executor`: dbt runtime container
- `source-postgres-db`: operational source database with deterministic sample data
- `lakehouse-object-store`: MinIO as local S3-compatible storage
- `airflow-metadata-db`: Airflow metadata plus local Iceberg SQL catalog

## Sample Data Products

The repo ships with two sample Snowflake data products built by dbt.

### SDP

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

### EDP

Database: `DB_EDP_ORDERS`

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

## dbt Naming

The dbt nodes follow the `model_sdp_orders_*` and `model_edp_orders_*` naming pattern.

Examples:

- `model_sdp_orders_core_orders_clean`
- `model_sdp_orders_access_orders_customer_grain`
- `model_edp_orders_core_fct_order_revenue_star`
- `model_edp_orders_access_orders_complete`

## Full Reset And Bootstrap

To kill everything and start again from a clean local state:

```bash
./scripts/reset-platform.sh
./scripts/bootstrap.sh
```

After GitLab is reachable on `http://localhost:8080`, finish the GitLab bootstrap:

```bash
./scripts/bootstrap-gitlab.sh
```

That is the intended full local restart flow.

## Quick Start

1. Copy `.env.example` to `.env`.
2. Fill the Snowflake variables if you want Snowflake connectivity.
3. Reset if you want a clean rebuild:

```bash
./scripts/reset-platform.sh
```

4. Bootstrap the platform:

```bash
./scripts/bootstrap.sh
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

```bash
./scripts/bootstrap-gitlab.sh
```

The runner is intentionally started by `bootstrap-gitlab.sh`, not by the base bootstrap, so GitLab can finish warming up before CI job polling begins.

Local GitLab CI runs against the already bootstrapped shared platform stack. It does not spin up a second isolated copy of GitLab, Airflow, MinIO, and PostgreSQL inside each pipeline run. That keeps local GitLab stable and makes the pipelines much cheaper to run on one machine.

7. Print the current URLs, credentials, paths, and generated GitLab details at any time:

```bash
./scripts/print-setup-summary.sh
```

## Useful Commands

Reset and rebuild:

```bash
./scripts/reset-platform.sh
./scripts/bootstrap.sh
./scripts/bootstrap-gitlab.sh
```

Reload only the sample source data:

```bash
./scripts/load-source-sample-data.sh
```

Run the default local pipeline:

```bash
./scripts/run-local-pipeline.sh
```

Test the Airflow DAG from the CLI:

```bash
./scripts/test-airflow-dag.sh
```

Bootstrap Snowflake only:

```bash
./scripts/bootstrap-snowflake.sh
```

## Validation Commands

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

Run both promotion validations in sequence:

```bash
./scripts/verify-dbt-promotion.sh
```

Run the zero-copy clone check:

```bash
docker compose run --rm dbt-executor python /opt/platform/dbt/scripts/zero_copy_clone_check.py
```

## GitLab Project Split

The local platform bootstraps two GitLab projects and keeps their generated working trees under [gitlab-projects/generated/proj_sdp_orders](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/gitlab-projects/generated/proj_sdp_orders) and [gitlab-projects/generated/proj_edp_orders](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/gitlab-projects/generated/proj_edp_orders).

The ownership split is:

- `proj_sdp_orders`: promotes the Airflow DAG, dlt ingestion runtime, and the SDP dbt models
- `proj_edp_orders`: promotes only the EDP dbt models that consume the SDP access layer

Each generated project ships its own `.gitlab-ci.yml` and ends with a mock CD stage so the CI/CD shape can be tested locally without a second environment.

The SDP project pipeline is intentionally split into two promotion steps so cold-start GitLab runs stay stable:

- `promote_sdp_ingestion`: validates the Airflow DAG, dlt runtime, and Iceberg output
- `promote_sdp_models`: validates and rebuilds the SDP dbt models in Snowflake after ingestion has succeeded

Those generated CI pipelines assume the base local platform has already been started with `./scripts/bootstrap.sh` and `./scripts/bootstrap-gitlab.sh`. They reuse the shared local runtime images and services instead of rebuilding or destroying the full platform stack inside the runner.

The generator for those repos is [render_gitlab_project_repos.py](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/scripts/render_gitlab_project_repos.py).

## Scaffolding New Assets

Create a new ingestion pipeline scaffold:

```bash
python3 scripts/scaffold_ingestion_pipeline.py retail_orders
```

That creates:

- a new Airflow DAG
- a new dlt pipeline script
- a verification script
- local platform repo assets that will be copied into the generated SDP GitLab project the next time you run `python3 scripts/render_gitlab_project_repos.py`

Create a new SDP/EDP dbt product scaffold:

```bash
python3 scripts/scaffold_mesh_product.py finance_orders
```

That creates:

- Snowflake foundation SQL for the new product databases
- dbt model skeletons
- a dbt verification script
- local platform repo assets that can be published into the generated SDP or EDP GitLab project after you rerun `python3 scripts/render_gitlab_project_repos.py`

Create a generic platform-repo GitLab child pipeline scaffold:

```bash
python3 scripts/scaffold_gitlab_pipeline.py smoke_checks --kind generic --verify-script ./scripts/print-setup-summary.sh
```

To regenerate the split SDP and EDP GitLab repos after changing shared assets, run:

```bash
python3 scripts/render_gitlab_project_repos.py
```

If you edit the platform repo child-pipeline registry manually, regenerate the root fan-out file with:

```bash
python3 scripts/render_gitlab_root_pipeline.py
```

## Local Constraints

- Snowflake cannot read private `localhost` MinIO endpoints.
- Snowflake Open Catalog requires real cloud object storage, not local MinIO.
- Because of that, local mode uses the `snowflake_raw_sync.py` bridge to mirror the SDP inbound layer into Snowflake before dbt runs.
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
