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
