#!/usr/bin/env bash
set -euo pipefail

approver_email="${GITLAB_USER_EMAIL:-}"
approver_name="${GITLAB_USER_NAME:-}"
approver_login="${GITLAB_USER_LOGIN:-}"

if [ -z "${approver_email}" ] && [ -z "${approver_name}" ] && [ -z "${approver_login}" ]; then
  echo "unable to determine the GitLab user who approved this job" >&2
  exit 1
fi

if [ -z "${CI_COMMIT_SHA:-}" ]; then
  echo "CI_COMMIT_SHA is required for approval validation" >&2
  exit 1
fi

normalize() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//; s/ *$//'
}

commit_author_email="$(git show -s --format=%ae "${CI_COMMIT_SHA}")"
commit_author_name="$(git show -s --format=%an "${CI_COMMIT_SHA}")"
commit_committer_email="$(git show -s --format=%ce "${CI_COMMIT_SHA}")"
commit_committer_name="$(git show -s --format=%cn "${CI_COMMIT_SHA}")"

approver_email_norm="$(normalize "${approver_email}")"
approver_name_norm="$(normalize "${approver_name}")"
approver_login_norm="$(normalize "${approver_login}")"
committer_email_norm="$(normalize "${commit_committer_email}")"
committer_name_norm="$(normalize "${commit_committer_name}")"
author_email_norm="$(normalize "${commit_author_email}")"
author_name_norm="$(normalize "${commit_author_name}")"

matches_identity() {
  local target_email="${1:-}"
  local target_name="${2:-}"

  if [ -n "${approver_email_norm}" ] && [ -n "${target_email}" ] && [ "${approver_email_norm}" = "${target_email}" ]; then
    return 0
  fi
  if [ -n "${approver_name_norm}" ] && [ -n "${target_name}" ] && [ "${approver_name_norm}" = "${target_name}" ]; then
    return 0
  fi
  if [ -n "${approver_login_norm}" ] && [ -n "${target_name}" ] && [ "${approver_login_norm}" = "${target_name}" ]; then
    return 0
  fi
  return 1
}

if matches_identity "${committer_email_norm}" "${committer_name_norm}"; then
  printf 'approval.validated=committer\n'
  exit 0
fi

if matches_identity "${author_email_norm}" "${author_name_norm}"; then
  printf 'approval.validated=author\n'
  exit 0
fi

cat >&2 <<EOF
approval denied:
  approver_login=${approver_login:-<unset>}
  approver_name=${approver_name:-<unset>}
  approver_email=${approver_email:-<unset>}
  commit_committer_name=${commit_committer_name:-<unset>}
  commit_committer_email=${commit_committer_email:-<unset>}
  commit_author_name=${commit_author_name:-<unset>}
  commit_author_email=${commit_author_email:-<unset>}
EOF
exit 1
