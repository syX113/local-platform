#!/usr/bin/env bash

trim_identifier() {
  local value="${1:?value is required}"
  local max_len="${2:?max length is required}"
  printf '%s' "${value:0:${max_len}}"
}

stable_token() {
  local raw="${1:?raw token is required}"
  cksum <<<"${raw}" | awk '{print $1}'
}

sanitize_branch_token() {
  local raw="${1:?raw token is required}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "${raw}" | tr -cs 'a-z0-9' '_')"
  raw="${raw#_}"
  raw="${raw%_}"
  printf '%s' "${raw}"
}

build_clone_database_name() {
  local base_name="${1:?base name is required}"
  local owner_token="${2:?owner token is required}"
  local branch_token_raw="${3:?branch token is required}"
  local max_len="${4:?max length is required}"

  local branch_upper prefix prefix_len remaining hash suffix_len trimmed_len branch_trimmed

  branch_upper="$(printf '%s' "${branch_token_raw}" | tr '[:lower:]' '[:upper:]')"
  prefix="${base_name}_CI_CLO_${owner_token}_"
  prefix_len="${#prefix}"

  if [ "${prefix_len}" -ge "${max_len}" ]; then
    printf '%s' "$(trim_identifier "${prefix}" "${max_len}")"
    return 0
  fi

  remaining=$((max_len - prefix_len))
  if [ "${#branch_upper}" -le "${remaining}" ]; then
    printf '%s%s' "${prefix}" "${branch_upper}"
    return 0
  fi

  hash="$(stable_token "${base_name}_${owner_token}_${branch_token_raw}")"
  suffix_len=$((1 + ${#hash}))
  trimmed_len=$((remaining - suffix_len))
  if [ "${trimmed_len}" -lt 1 ]; then
    printf '%s%s' "${prefix}" "$(trim_identifier "${hash}" "${remaining}")"
    return 0
  fi

  branch_trimmed="$(trim_identifier "${branch_upper}" "${trimmed_len}")"
  printf '%s%s_%s' "${prefix}" "${branch_trimmed}" "${hash}"
}

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
    if [ -f .env.example ]; then
      cp .env.example .env
    elif [ -f ci/.env.example ]; then
      cp ci/.env.example .env
    else
      echo "unable to create .env: no .env.example or ci/.env.example found" >&2
      return 1
    fi
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
