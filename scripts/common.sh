#!/usr/bin/env bash

load_env_preserving_existing() {
  local env_file="${1:?env file is required}"

  if [ ! -f "${env_file}" ]; then
    return 0
  fi

  local preserved_env
  preserved_env="$(mktemp)"

  env | while IFS='=' read -r key value; do
    printf '%s=%q\n' "${key}" "${value}"
  done > "${preserved_env}"

  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a

  while IFS= read -r assignment; do
    eval "export ${assignment}"
  done < "${preserved_env}"

  rm -f "${preserved_env}"
}

ensure_platform_env() {
  if [ ! -f .env ]; then
    cp .env.example .env
    echo "created .env from .env.example"
  fi

  load_env_preserving_existing .env
}
