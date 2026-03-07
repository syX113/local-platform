# Local Platform

This repository provides a local integration platform for fast CI testing across `GitLab`, `GitLab Runner`, `Airflow`, `dlt`, `dbt`, `PostgreSQL`, `MinIO`, and `Snowflake`.

The default sample flow is:

`PostgreSQL -> Airflow -> dlt -> MinIO/Iceberg -> Snowflake -> dbt`

`dbt` and `dlt` always run in external containers. Locally those containers stand in for the real Fargate or EKS runtimes.

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

6. Bootstrap the local GitLab project and runner:

```bash
./scripts/bootstrap-gitlab.sh
```

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

Validate the Snowflake and dbt promotion flow:

```bash
./scripts/verify-dbt-promotion.sh
```

Run the zero-copy clone check:

```bash
docker compose run --rm dbt-executor python /opt/platform/dbt/scripts/zero_copy_clone_check.py
```

## GitLab CI Layout

The root pipeline fans out into child pipelines through [.gitlab/ci/generated/root-pipeline.yml](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/.gitlab/ci/generated/root-pipeline.yml).

Current shipped child pipelines:

- [.gitlab/ci/ingestion-promotion.yml](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/.gitlab/ci/ingestion-promotion.yml)
- [.gitlab/ci/dbt-promotion.yml](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/.gitlab/ci/dbt-promotion.yml)

Each child pipeline ends with a mock CD step so the CI/CD structure can be tested locally without a second environment.

## Scaffolding New Assets

Create a new ingestion pipeline scaffold:

```bash
python3 scripts/scaffold_ingestion_pipeline.py retail_orders
```

That creates:

- a new Airflow DAG
- a new dlt pipeline script
- a verification script
- a GitLab child pipeline and root-pipeline registration

Create a new SDP/EDP dbt product scaffold:

```bash
python3 scripts/scaffold_mesh_product.py finance_orders
```

That creates:

- Snowflake foundation SQL for the new product databases
- dbt model skeletons
- a dbt verification script
- a GitLab child pipeline and root-pipeline registration

Create a generic GitLab child pipeline scaffold:

```bash
python3 scripts/scaffold_gitlab_pipeline.py smoke_checks --kind generic --verify-script ./scripts/print-setup-summary.sh
```

If you edit the pipeline registry manually, regenerate the root fan-out file with:

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
