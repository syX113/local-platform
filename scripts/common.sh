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

  local root_dir="${ROOT_DIR:-$(pwd)}"
  local platform_root="${LOCAL_PLATFORM_ROOT:-}"

  if [ -z "${platform_root}" ]; then
    platform_root="${root_dir}"
    export LOCAL_PLATFORM_ROOT="${platform_root}"

    local temp_env
    temp_env="$(mktemp)"
    awk -v root="${platform_root}" '
      BEGIN { updated = 0 }
      /^LOCAL_PLATFORM_ROOT=/ {
        print "LOCAL_PLATFORM_ROOT=\"" root "\""
        updated = 1
        next
      }
      { print }
      END {
        if (!updated) {
          print "LOCAL_PLATFORM_ROOT=\"" root "\""
        }
      }
    ' .env > "${temp_env}"
    mv "${temp_env}" .env
  fi
}

resolve_host_dbt_project_dir() {
  local project_slug="${1:?dbt project slug is required}"

  if [ -f "${ROOT_DIR}/dbt/projects/${project_slug}/dbt_project.yml" ]; then
    printf '%s/dbt/projects/%s\n' "${ROOT_DIR}" "${project_slug}"
    return 0
  fi

  if [ -f "${ROOT_DIR}/dbt/dbt_project.yml" ]; then
    printf '%s/dbt\n' "${ROOT_DIR}"
    return 0
  fi

  echo "unable to resolve dbt project dir for ${project_slug}" >&2
  return 1
}

resolve_container_dbt_project_dir() {
  local project_slug="${1:?dbt project slug is required}"

  if [ -f "${ROOT_DIR}/dbt/projects/${project_slug}/dbt_project.yml" ]; then
    printf '/opt/platform/dbt/projects/%s\n' "${project_slug}"
    return 0
  fi

  if [ -f "${ROOT_DIR}/dbt/dbt_project.yml" ]; then
    printf '/opt/platform/dbt\n'
    return 0
  fi

  echo "unable to resolve container dbt project dir for ${project_slug}" >&2
  return 1
}
