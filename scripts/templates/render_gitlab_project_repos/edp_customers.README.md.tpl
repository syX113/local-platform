This is the Enterprise Data Product repository for customers.

Managed artifacts:

- EDP customers dbt project for Snowflake `INBOUND`, `CORE`, and `ACCESS`, executed natively in Snowflake
- The upstream source manifests are fetched from MinIO into `loom/manifest.json.gz` and woven into the project with dbt-loom before Snowflake deployment
- `ci/scripts/` contains only CI helper scripts
- `ci/` contains runner-only config and Snowflake foundation metadata

Upstream dependency:

- The published SDP customers `ACCESS` tables must already exist in Snowflake before the EDP promotion runs.

Main CI entrypoint:

- `./ci/scripts/prepare-ci-sandbox.sh edp artifacts/context/edp.env`
- `./ci/scripts/verify-edp-promotion.sh proj_edp_customers`
- `./ci/scripts/deploy-edp-dev.sh proj_edp_customers`
- `./ci/scripts/deploy-edp-prd.sh proj_edp_customers`
