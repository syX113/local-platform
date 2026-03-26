This is the domain-oriented repository for __DOMAIN_LABEL__.

Managed artifacts:

- One dbt project for __DOMAIN_LABEL__, executed natively in Snowflake
- Upstream source manifests are fetched from MinIO into `loom/manifest.json.gz` and woven into the project with dbt-loom before Snowflake deployment
- `ci/scripts/` contains only CI helper scripts
- `ci/` contains runner-only config and Snowflake foundation metadata

Domain scope:

- __DOMAIN_SCOPES__

Upstream source scopes:

- __SOURCE_SCOPES__

Upstream dependency:

- The published source-system repository `__UPSTREAM_PROJECT_SLUG__` must already expose the referenced source `ACCESS` tables before domain promotion runs.

Main CI entrypoint:

- `./ci/scripts/prepare-ci-sandbox.sh __PROJECT_SLUG__ artifacts/context/__PROJECT_SLUG__.env`
- `./ci/scripts/verify-edp-promotion.sh __PROJECT_SLUG__`
- `./ci/scripts/deploy-edp-dev.sh __PROJECT_SLUG__`
- `./ci/scripts/deploy-edp-prd.sh __PROJECT_SLUG__`

CI behaviour:

- When a new non-default branch appears in GitLab, a GitLab webhook triggers the platform-side branch provisioner to create the branch sandbox automatically.
- The initial branch-creation push event does not run the heavy CI validation pipeline; it exists only to provision the isolated developer sandbox.
- Later branch push pipelines reuse one branch-scoped Snowflake zero-copy environment and run repeatable CI validation there.
- Opening a merge request creates or reuses one MR-scoped zero-copy clone and the MR pipeline validates the candidate there in detail.
- A merge commit into `main` triggers DEV deploy automatically, then the committer can approve the PRD deployment gate.
- PRD deployment runs in the same post-merge pipeline after the approval gate and deploys to shared `PRD_` targets for the domain.
