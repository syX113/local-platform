#!/usr/bin/env sh
set -eu

CONFIG_FILE="/etc/gitlab-runner/config.toml"

until [ -s "${CONFIG_FILE}" ]; do
  echo "waiting for ${CONFIG_FILE}"
  sleep 5
done

exec gitlab-runner run --working-directory /home/gitlab-runner --user gitlab-runner
