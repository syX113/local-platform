FROM docker:29.1.3-cli

RUN apk add --no-cache bash python3

WORKDIR /opt/platform

COPY gitlab-branch-provisioner/gitlab_branch_provisioner.py /opt/platform/gitlab_branch_provisioner.py

ENTRYPOINT ["python3", "/opt/platform/gitlab_branch_provisioner.py"]
