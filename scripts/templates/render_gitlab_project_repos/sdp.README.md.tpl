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
