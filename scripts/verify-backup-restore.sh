#!/usr/bin/env bash
# =============================================================================
# End-to-end proof that backups actually work: deploy an app with a PVC, write
# known data, back it up, DESTROY the namespace, restore, and byte-compare.
#
# This exists because "backup Completed" does NOT mean your data was captured.
# The check that matters is the diff at the end, plus a non-zero
# PodVolumeBackup — a backup with zero PodVolumeBackups contains no volume data.
#
# Usage: ./scripts/verify-backup-restore.sh [backup-name-suffix]
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

SUFFIX="${1:-$(date -u +%H%M%S)}"
BACKUP="verify-${SUFFIX}"
RESTORE="verify-restore-${SUFFIX}"
NS=velero-demo
VELERO_NS="${VELERO_NAMESPACE:-velero}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mFAIL: %s\033[0m\n' "$1"; exit 1; }
pass() { printf '\n\033[1;32mPASS: %s\033[0m\n' "$1"; }

step "1/7  Deploying demo app (PVC + ConfigMap + Secret + Service)"
kubectl apply -f demo/demo-app.yaml
kubectl -n "${NS}" rollout status deploy/demo-app --timeout=300s

step "2/7  Writing known data into the PVC"
POD="$(kubectl -n "${NS}" get pod -l app=demo-app -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "${NS}" exec "${POD}" -c app -- sh -c \
  "echo 'verify-run=${SUFFIX}' >> /data/marker.txt; \
   mkdir -p /data/nested; echo 'nested file content' > /data/nested/deep.txt"
# -c app matters: after a restore the pod gains a `restore-wait` init container,
# and without -c kubectl prints a "Defaulted container" notice that would
# corrupt the captured file and produce a bogus diff.
kubectl -n "${NS}" exec "${POD}" -c app -- cat /data/marker.txt >"${WORK}/before.txt"
echo "--- data before backup ---"; cat "${WORK}/before.txt"

step "3/7  Creating backup '${BACKUP}'"
velero backup create "${BACKUP}" --include-namespaces "${NS}" --wait

phase="$(kubectl -n "${VELERO_NS}" get backup "${BACKUP}" -o jsonpath='{.status.phase}')"
[[ "${phase}" == "Completed" ]] || fail "backup phase is '${phase}', expected Completed"

step "4/7  Verifying volume data was actually captured"
# A backup can report Completed while silently skipping volumes (e.g. hostPath
# PVs). Zero PodVolumeBackups means the volume contents are NOT in the backup.
pvb_count="$(kubectl -n "${VELERO_NS}" get podvolumebackups \
  -l velero.io/backup-name="${BACKUP}" --no-headers 2>/dev/null | wc -l)"
echo "    PodVolumeBackups for this backup: ${pvb_count}"
kubectl -n "${VELERO_NS}" get podvolumebackups -l velero.io/backup-name="${BACKUP}" \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volume,UPLOADER:.spec.uploaderType,BYTES:.status.progress.bytesDone' 2>/dev/null || true
[[ "${pvb_count}" -ge 1 ]] || fail \
  "no PodVolumeBackup was created — the PVC data is NOT in this backup.
       Almost always: the PVC uses a StorageClass that yields hostPath PVs
       (e.g. local-path). Use the local-static StorageClass instead.
       Confirm with: velero backup logs ${BACKUP} | grep -i hostpath"

step "5/7  DESTROYING namespace ${NS}"
kubectl delete ns "${NS}" --wait=true
kubectl get ns "${NS}" >/dev/null 2>&1 && fail "namespace still exists"
echo "    gone."

step "6/7  Restoring from '${BACKUP}'"
velero restore create "${RESTORE}" --from-backup "${BACKUP}" --wait
rphase="$(kubectl -n "${VELERO_NS}" get restore "${RESTORE}" -o jsonpath='{.status.phase}')"
[[ "${rphase}" == "Completed" ]] || fail "restore phase is '${rphase}', expected Completed"
kubectl -n "${NS}" rollout status deploy/demo-app --timeout=300s

step "7/7  Byte-comparing restored volume data"
RPOD="$(kubectl -n "${NS}" get pod -l app=demo-app -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "${NS}" exec "${RPOD}" -c app -- cat /data/marker.txt >"${WORK}/after.txt"
echo "--- data after restore ---"; cat "${WORK}/after.txt"

if ! diff -q "${WORK}/before.txt" "${WORK}/after.txt" >/dev/null; then
  diff "${WORK}/before.txt" "${WORK}/after.txt" || true
  fail "restored volume data differs from the original"
fi

# The nested file proves directory trees survive, not just a single file.
kubectl -n "${NS}" exec "${RPOD}" -c app -- test -f /data/nested/deep.txt \
  || fail "nested file /data/nested/deep.txt missing after restore"

# And the non-volume objects.
kubectl -n "${NS}" get configmap demo-config >/dev/null || fail "ConfigMap missing"
kubectl -n "${NS}" get secret demo-secret   >/dev/null || fail "Secret missing"
kubectl -n "${NS}" get service demo-app     >/dev/null || fail "Service missing"

pass "namespace destroyed and fully restored — volume data byte-identical,
      nested files intact, ConfigMap/Secret/Service all present.
      backup=${BACKUP} restore=${RESTORE}"

cat <<EOF

Clean up the demo when you're done:
  kubectl delete ns ${NS}
  velero backup delete ${BACKUP} --confirm
EOF
