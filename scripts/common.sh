#!/usr/bin/env bash

load_env_preserving_existing() {
  local env_file="${1:?env file is required}"

  if [ ! -f "${env_file}" ]; then
    return 0
  fi

  local preserved_env
  preserved_env="$(mktemp)"

  # Use null-delimited env output so CI variables containing newlines do not
  # corrupt the restore file.
  while IFS='=' read -r -d '' key value; do
    printf 'export %s=%q\n' "${key}" "${value}"
  done < <(env -0) > "${preserved_env}"

  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a

  # shellcheck disable=SC1090
  source "${preserved_env}"

  rm -f "${preserved_env}"
}

ensure_platform_env() {
  if [ ! -f .env ]; then
    cp .env.example .env
    echo "created .env from .env.example"
  fi

  load_env_preserving_existing .env
}
