# Local Platform

This repo scaffolds a local platform for testing GitLab CI/CD, containerized GitLab runners, Airflow orchestration, dlt ingestion, dbt transformations, MinIO as an S3 stand-in, a seeded PostgreSQL source system, and Snowflake connectivity.

## What the stack does

- `gitlab-platform` runs GitLab locally for pipelines and repo hosting.
- `gitlab-fargate-runner` uses the Docker executor to approximate AWS Fargate-style ephemeral job containers.
- `lakehouse-object-store` provides local S3-compatible object storage via MinIO.
- `source-postgres-db` acts as the operational source database and ships with deterministic sample data.
- `airflow-metadata-db` stores Airflow metadata and the local Iceberg SQL catalog database.
- `Airflow` orchestrates a three-step pipeline:
  1. reseed PostgreSQL sample data
  2. launch a separate `dlt-extractor` container to read PostgreSQL and write Iceberg tables to object storage
  3. optionally launch a separate `dlt-extractor` container to mirror the raw export data into Snowflake for local mode
  4. launch a separate `dbt-executor` container to build Snowflake models
- `dbt` is executed outside Snowflake in a dedicated container and uses the Snowflake adapter to modify data in Snowflake.

## Pipeline shape

The default local data flow is:

`source-postgres-db` -> `Airflow` -> `dlt-extractor` -> `lakehouse-object-store` (Iceberg tables) -> `dbt-executor` -> `Snowflake`

`dbt-executor` is the local stand-in for the real external runtime. In production, that same role would typically be implemented as a Fargate task or an EKS job. Snowflake remains only the target warehouse and execution engine for SQL statements submitted by dbt.

The source PostgreSQL schema uses normalized tables (`customers`, `orders`, `order_items`) and exposes export views (`raw_orders_export`, `raw_order_items_export`) that dlt loads into Iceberg as `raw_orders` and `raw_order_items`.

## Important constraints

Two current Snowflake limitations shape this setup:

- A private `localhost:9000` MinIO endpoint is not reachable by Snowflake.
- Snowflake Open Catalog manages storage in Amazon S3, Google Cloud Storage, or Azure Storage, not MinIO.

Because of that, this repo supports two modes:

- Local mode:
  dlt writes Iceberg tables to MinIO and registers them in a local Postgres-backed Iceberg SQL catalog.
- Snowflake end-to-end mode:
  use the same dlt/dbt code, but switch the storage target from MinIO to real S3 and fill the Open Catalog and Snowflake credentials in `.env`.

## Quick start

1. Copy `.env.example` to `.env`.
2. Fill the Snowflake variables only if you want Snowflake connectivity.
3. Start or refresh the stack:

```bash
./scripts/bootstrap.sh
```

If you change `.env` later, rerun `./scripts/bootstrap.sh` so the long-running Airflow and GitLab services pick up the new values.

4. Wait for GitLab to finish booting, then bootstrap the project runner:

```bash
./scripts/bootstrap-gitlab.sh
```

Both setup scripts print a full access summary at the end, including local URLs, credentials from `.env`, runtime service names, important filesystem paths, generated GitLab runner/project details, and the local GitLab project URL. `bootstrap-gitlab.sh` also syncs the runtime-related `.env` values into the GitLab project's CI/CD variables so pipelines can run without manually re-entering Snowflake, MinIO, PostgreSQL, and dbt/dlt settings.

5. Reseed the source system at any time:

```bash
./scripts/load-source-sample-data.sh
```

6. Run the pipeline directly:

```bash
./scripts/run-local-pipeline.sh
```

7. Validate the Airflow DAG end to end from the command line:

```bash
./scripts/test-airflow-dag.sh
```

8. Or trigger the Airflow DAG at `http://localhost:8088` and the GitLab UI at `http://localhost:8080`.

If Snowflake credentials are not set, the direct script and Airflow DAG still run the PostgreSQL-to-Iceberg `dlt` load and skip the `dbt` step.

## GitLab promotion pipelines

The GitLab CI setup now fans out into two child pipelines from the root [.gitlab-ci.yml](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/.gitlab-ci.yml):

- [ingestion-promotion.yml](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/.gitlab/ci/ingestion-promotion.yml)
  validates and promotes the PostgreSQL -> Airflow/dlt -> MinIO/Iceberg path. It compiles the Airflow and dlt assets, runs the `local_platform_ingest` DAG in ingestion-only mode, verifies source counts, confirms Iceberg catalog entries, and checks MinIO parquet row counts.
- [dbt-promotion.yml](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/.gitlab/ci/dbt-promotion.yml)
  validates and promotes the Snowflake-facing dbt layer. It bootstraps Snowflake, refreshes the local landing data, runs `dbt parse`, runs `dbt build`, executes the zero-copy clone check, and verifies the modeled row counts in Snowflake.

Each child pipeline ends with a mock CD job that writes a small artifact instead of deploying anywhere. That keeps the promotion flow structurally complete while remaining safe in a single local environment.

The promotion logic lives in [verify-ingestion-promotion.sh](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/scripts/verify-ingestion-promotion.sh) and [verify-dbt-promotion.sh](/Users/taagiti2/Documents/01%20Projects/Valiant/repos/local-platform/scripts/verify-dbt-promotion.sh). Each child pipeline publishes its own `artifacts/` directory back to GitLab.

## Sample data

The sample source dataset is deterministic and loaded automatically on first source database startup. It can also be reset on demand with `./scripts/load-source-sample-data.sh`.

Current seed volume:

- 12 customers
- 30 orders
- 60 order items

## Snowflake bootstrap

To bootstrap the Snowflake warehouse and databases in local mode, run:

```bash
./scripts/bootstrap-snowflake.sh
```

This always applies the foundation SQL. If `OPEN_CATALOG_*` variables are present, it also applies the Open Catalog integration SQL and the catalog-linked raw database SQL. In strictly local MinIO mode those steps are skipped by design.

Then build the dbt project:

```bash
docker compose run --rm dbt-executor dbt build --project-dir /opt/platform/dbt --profiles-dir /opt/platform/dbt/profiles
```

To run the clone check that approximates a zero-copy CI test:

```bash
docker compose run --rm dbt-executor python /opt/platform/dbt/scripts/zero_copy_clone_check.py
```

## Notes on GitLab Runner behavior

The runner uses Docker executor containers on the same Docker network as GitLab, Airflow, MinIO, the PostgreSQL services, and the tooling images. That gives you the local ergonomics of ephemeral containers without pretending it is literally Fargate. The main gap is that Fargate networking, IAM, and task metadata are not reproduced locally.

For the same reason, the local `airflow-scheduler` service runs as `root` so `DockerOperator` can access the mounted Docker socket and launch the external `dlt-extractor` and `dbt-executor` containers. That is a local convenience for this sandbox, not the intended production security model.

The GitLab CI jobs use a separate `COMPOSE_PROJECT_NAME` per pipeline run and random host port assignments for MinIO and PostgreSQL. That avoids collisions with the always-on local platform stack while still using the same service definitions, images, and scripts.

The dbt promotion pipeline still uses the local Snowflake raw sync path when `SNOWFLAKE_LOCAL_RAW_SYNC=true`. That is the local stand-in for the production Open Catalog path, because Snowflake cannot query a private local MinIO endpoint directly.

## Source references

- Snowflake docs state that Open Catalog uses S3, GCS, or Azure storage and that Snowflake can query but not write to Open Catalog-managed tables.
- Snowflake docs also state that catalog-linked databases are supported for REST catalog integrations such as Snowflake Open Catalog.
- GitLab docs show the current runner creation workflow based on `POST /user/runners`.
- dlt docs show Iceberg support on the filesystem destination and support for SQL or REST catalogs.
