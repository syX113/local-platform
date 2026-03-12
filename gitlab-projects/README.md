# GitLab Project Rendering

The source repository is the local platform control repo. It is not intended to be pushed directly into the hosted/platform GitLab instance.

The actual hosted GitLab projects are rendered into `gitlab-projects/generated/` and pushed from there:

- `gitlab-projects/generated/proj_source_finnova`
- `gitlab-projects/generated/proj_edp_orders`
- `gitlab-projects/generated/proj_edp_customers`

Those rendered repos keep the business artifacts at the top level (`airflow/`, `dlt/`, `dbt/`) and put runner-only metadata such as env templates, Snowflake foundation files, and CI helper scripts under `ci/`.

After the GitLab bootstrap, the platform-side `gitlab-branch-provisioner` service receives branch events from those hosted projects through GitLab webhooks.

- A new non-default branch in `proj_source_finnova` triggers creation of a branch-scoped Snowflake clone set plus a branch-scoped MinIO/S3 and Iceberg sandbox.
- A new non-default branch in `proj_edp_orders` triggers creation of a branch-scoped Snowflake clone set.
- A new non-default branch in `proj_edp_customers` triggers creation of a branch-scoped Snowflake clone set.
- The Snowflake clone set is resolved from `ci/snowflake/data_products.json`, so every registered data product database is included in the sandbox.
- Clone databases follow the original database name plus `CI_CLO`, the owning project token, and the branch token, for example `DB_EDP_ORDERS_CI_CLO_EDP_FEATURE_X`.
- The project token is part of the name so the same branch name can exist in both GitLab repos without sharing one Snowflake clone.
- Deleting the branch in GitLab destroys the associated sandbox again.

That separation is intentional:

- source repo: owns templates, bootstrap scripts, Docker assets, Airflow, dlt, dbt, and render logic
- rendered platform repos: contain only the artifacts needed by the hosted GitLab projects

Use these commands:

- first-time GitLab setup: `./scripts/bootstrap-gitlab.sh`
- republish rendered platform repos after source changes: `./scripts/publish-platform-repos.sh`

Neither command adds or changes a remote on the source repository root.
