#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/common.sh"
ensure_platform_env

ARTIFACT_DIR="${ROOT_DIR}/artifacts/dbt"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${ARTIFACT_DIR}"

./scripts/verify-ingestion-promotion.sh "${1:-2026-03-07}"
./scripts/verify-sdp-promotion.sh
./scripts/verify-edp-promotion.sh

cp -R "${ROOT_DIR}/artifacts/ingestion" "${ARTIFACT_DIR}/ingestion"
cp -R "${ROOT_DIR}/artifacts/sdp" "${ARTIFACT_DIR}/sdp"
cp -R "${ROOT_DIR}/artifacts/edp" "${ARTIFACT_DIR}/edp"

cat > "${ARTIFACT_DIR}/summary.txt" <<EOF
DBT promotion succeeded.
included.ingestion=artifacts/dbt/ingestion
included.sdp=artifacts/dbt/sdp
included.edp=artifacts/dbt/edp
EOF
