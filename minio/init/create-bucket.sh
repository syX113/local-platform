#!/usr/bin/env sh
set -eu

until mc alias set local "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"; do
  echo "waiting for MinIO"
  sleep 3
done

mc mb --ignore-existing "local/${MINIO_BUCKET}"
