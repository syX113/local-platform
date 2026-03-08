# GitLab Project Rendering

The source repository is the local platform control repo. It is not intended to be pushed directly into the hosted/platform GitLab instance.

The actual hosted GitLab projects are rendered into `gitlab-projects/generated/` and pushed from there:

- `gitlab-projects/generated/proj_sdp_orders`
- `gitlab-projects/generated/proj_edp_orders`

After the GitLab bootstrap, the platform-side `gitlab-branch-provisioner` service receives branch events from those hosted projects through GitLab webhooks.

- A new non-default branch in `proj_sdp_orders` triggers creation of a branch-scoped Snowflake clone set plus a branch-scoped MinIO/S3 and Iceberg sandbox.
- A new non-default branch in `proj_edp_orders` triggers creation of a branch-scoped Snowflake clone set.
- Deleting the branch in GitLab destroys the associated sandbox again.

That separation is intentional:

- source repo: owns templates, bootstrap scripts, Docker assets, Airflow, dlt, dbt, and render logic
- rendered platform repos: contain only the artifacts needed by the hosted GitLab projects

Use these commands:

- first-time GitLab setup: `./scripts/bootstrap-gitlab.sh`
- republish rendered platform repos after source changes: `./scripts/publish-platform-repos.sh`

Neither command adds or changes a remote on the source repository root.
