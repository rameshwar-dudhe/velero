#!/usr/bin/env bash
# =============================================================================
# THE ONE COMMAND. Builds the whole stack from nothing:
#
#   1. storage    — local-path-provisioner + local-static PV pool
#   2. MinIO      — S3-compatible backup target + `velero` bucket
#   3. Velero     — server + node-agent, via the official Helm chart
#   4. verify     — destroys and restores a namespace, byte-compares the data
#   5. Velero UI  — web dashboard, with both unsafe chart defaults corrected
#
# Every step is idempotent, so re-running is safe.
#
# Usage:
#   ./scripts/install-all.sh              # everything, including the verify test
#   ./scripts/install-all.sh --no-verify  # skip the destroy/restore test
#   ./scripts/install-all.sh --no-ui      # skip the web UI
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

DO_VERIFY=1
DO_UI=1
for arg in "$@"; do
  case "${arg}" in
    --no-verify) DO_VERIFY=0 ;;
    --no-ui)     DO_UI=0 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: ${arg}"; exit 1 ;;
  esac
done

banner() { printf '\n\033[1;35m╔══ %s\033[0m\n' "$1"; }

START="$(date -u +%s)"

banner "STAGE 1-3  storage, MinIO, Velero"
./scripts/install-local.sh

if [[ "${DO_VERIFY}" -eq 1 ]]; then
  banner "STAGE 4  end-to-end verification (destroys + restores a namespace)"
  ./scripts/verify-backup-restore.sh
else
  banner "STAGE 4  SKIPPED (--no-verify)"
  echo "  You have an unproven backup system. Run ./scripts/verify-backup-restore.sh soon."
fi

if [[ "${DO_UI}" -eq 1 ]]; then
  banner "STAGE 5  web UI"
  ./scripts/install-ui.sh
else
  banner "STAGE 5  SKIPPED (--no-ui)"
fi

ELAPSED=$(( $(date -u +%s) - START ))

banner "ALL DONE in ${ELAPSED}s"
kubectl -n velero get pods
echo
kubectl -n velero get backupstoragelocation
echo
velero backup get 2>/dev/null || true
