# GitLab Project Rendering

The source repository is the local platform control repo. It is not intended to be pushed directly into the hosted/platform GitLab instance.

The actual hosted GitLab projects are rendered into `gitlab-projects/generated/` and pushed from there:

- `gitlab-projects/generated/proj_sdp_orders`
- `gitlab-projects/generated/proj_edp_orders`

That separation is intentional:

- source repo: owns templates, bootstrap scripts, Docker assets, Airflow, dlt, dbt, and render logic
- rendered platform repos: contain only the artifacts needed by the hosted GitLab projects

Use these commands:

- first-time GitLab setup: `./scripts/bootstrap-gitlab.sh`
- republish rendered platform repos after source changes: `./scripts/publish-platform-repos.sh`

Neither command adds or changes a remote on the source repository root.
