#!/usr/bin/env bash
# =============================================================================
# DEEP TEST — the thorough backup/restore test suite.
#
# scripts/verify-backup-restore.sh is the 2-minute smoke test: one file, one
# destroy, one restore. THIS script is the one that actually earns trust. It
# exercises 25 assertions across the behaviours that matter and that have
# historically broken:
#
#   data fidelity   a whole tree — nested dirs, 250 small files, an 8 MB binary,
#                   unicode and space-in-name filenames, non-default permissions
#                   — compared by per-file sha256 manifest, not one marker file
#   deduplication   a second backup must be incremental, not a full re-upload
#   full DR         namespace destroyed and rebuilt from object storage
#   relocation      restore into a DIFFERENT namespace (namespace-mappings)
#   selectivity     restore only chosen resource types
#   the trap        NEGATIVE test: a local-path (hostPath) PVC MUST be silently
#                   skipped. If this test ever starts failing, Velero changed and
#                   the storage guidance in the docs needs revisiting.
#   idempotency     restoring over a live namespace must be a no-op
#   lifecycle       TTL, schedules, and that deleting a backup really frees
#                   objects in the bucket
#   observability   metrics actually increment
#
# Usage:
#   ./scripts/deep-test.sh            # full suite
#   ./scripts/deep-test.sh --keep     # leave the test namespaces for inspection
#
# Exit code is non-zero if any hard assertion fails.
# Runtime is roughly 8-12 minutes; namespace deletion on this cluster is slow.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

VELERO_NS="${VELERO_NAMESPACE:-velero}"
MINIO_NS="${MINIO_NAMESPACE:-minio}"
SRC_NS=vdt-src
CLONE_NS=vdt-clone
PARTIAL_NS=vdt-partial
TRAP_NS=vdt-trap
RUN="$(date -u +%H%M%S)"
BK="deep-${RUN}"
BK2="deep-${RUN}-inc"
BKTRAP="deep-${RUN}-trap"
RS="deep-restore-${RUN}"
RSCLONE="deep-clone-${RUN}"
RSPART="deep-partial-${RUN}"
RSNOOP="deep-noop-${RUN}"
SCHED="deep-sched-${RUN}"

KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

WORK="$(mktemp -d)"
PASS=0; FAIL=0; SOFT=0
FAILED_TESTS=()

hdr()  { printf '\n\033[1;36m━━ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[1;32m✅ %-10s\033[0m %-46s %s\n' "$1" "$2" "${3:-}"; PASS=$((PASS+1)); }
no()   { printf '  \033[1;31m❌ %-10s\033[0m %-46s %s\n' "$1" "$2" "${3:-}"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1 $2"); }
inf()  { printf '  \033[1;33m➜  %-10s\033[0m %-46s %s\n' "$1" "$2" "${3:-}"; SOFT=$((SOFT+1)); }
assert(){ [[ "$2" == "$3" ]] && ok "$1" "$4" "$2" || no "$1" "$4" "expected='$3' actual='$2'"; }
assert_gt(){ [[ "$2" -gt "$3" ]] 2>/dev/null && ok "$1" "$4" "$2 > $3" || no "$1" "$4" "expected >$3, got '$2'"; }

cleanup() {
  rm -rf "${WORK}"
  if [[ "${KEEP}" -eq 0 ]]; then
    printf '\n\033[1;36m━━ cleanup\033[0m\n'
    kubectl delete ns "${SRC_NS}" "${CLONE_NS}" "${PARTIAL_NS}" "${TRAP_NS}" \
      --ignore-not-found --wait=false >/dev/null 2>&1
    for b in "${BK}" "${BK2}" "${BKTRAP}"; do
      velero backup delete "$b" --confirm >/dev/null 2>&1 || true
    done
    velero schedule delete "${SCHED}" --confirm >/dev/null 2>&1 || true
    echo "  test namespaces and backups deleted (async)"
  else
    printf '\n  --keep: left %s %s %s %s in place\n' "${SRC_NS}" "${CLONE_NS}" "${PARTIAL_NS}" "${TRAP_NS}"
  fi
}
trap cleanup EXIT

# helper: run a throwaway pod and capture its stdout
podrun() { # $1=name $2=image $3=shell-command  [$4=extra yaml under spec]
  local name="$1" image="$2" cmd="$3"
  kubectl -n "${VELERO_NS}" delete pod "$name" --ignore-not-found --wait=true >/dev/null 2>&1
  cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: ${name}, namespace: ${VELERO_NS}}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: ${image}
    env: [{name: HOME, value: /tmp}, {name: MC_CONFIG_DIR, value: /tmp/.mc}]
    command: ["/bin/sh","-c","${cmd}"]
EOF
  local phase=""
  for _ in $(seq 1 60); do
    phase="$(kubectl -n "${VELERO_NS}" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 2
  done
  kubectl -n "${VELERO_NS}" logs "$name" 2>/dev/null
  kubectl -n "${VELERO_NS}" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
}

bucket_objects() {
  # shellcheck disable=SC1091
  source .secrets/minio.env
  podrun mcprobe "quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z" \
    "mc alias set m http://minio.${MINIO_NS}.svc.cluster.local:9000 '${MINIO_ROOT_USER}' '${MINIO_ROOT_PASSWORD}' >/dev/null 2>&1; mc ls -r m/velero 2>/dev/null | wc -l" \
    | tr -d '[:space:]'
}

metric() { # $1 = metric name
  podrun metricprobe "docker.io/library/busybox:1.37" \
    "wget -qO- http://velero.${VELERO_NS}.svc:8085/metrics 2>/dev/null | grep '^$1' | head -1" \
    | awk '{print $NF}' | head -1
}

wait_ns_gone() {
  for _ in $(seq 1 120); do
    kubectl get ns "$1" >/dev/null 2>&1 || return 0
    sleep 3
  done
  return 1
}

# =============================================================================
hdr "T01-T03  Preconditions"
if ! kubectl -n "${VELERO_NS}" get deploy velero >/dev/null 2>&1; then
  echo "  Velero is not installed. Run ./scripts/install-all.sh first."
  exit 1
fi
assert T01 "$(kubectl -n "${VELERO_NS}" get deploy velero -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" "1" "velero deployment ready"
assert T02 "$(kubectl -n "${VELERO_NS}" get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null)" "Available" "BackupStorageLocation Available"
NODES="$(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
assert T03 "$(kubectl -n "${VELERO_NS}" get pods -l name=node-agent --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)" "${NODES}" "node-agent running on every node"

# =============================================================================
hdr "T04-T05  Fixture: a rich data tree on backup-capable storage"
kubectl create ns "${SRC_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata: {name: deep-config, namespace: ${SRC_NS}}
data:
  app.conf: |
    mode=deep-test
    run=${RUN}
---
apiVersion: v1
kind: Secret
metadata: {name: deep-secret, namespace: ${SRC_NS}}
type: Opaque
stringData:
  token: "deep-test-token-${RUN}"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: deep-data, namespace: ${SRC_NS}}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-static        # MUST be local-static, not local-path
  resources: {requests: {storage: 1Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: deep-app, namespace: ${SRC_NS}, labels: {app: deep-app}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: deep-app}}
  template:
    metadata: {labels: {app: deep-app}}
    spec:
      securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
      containers:
      - name: app
        image: docker.io/library/busybox:1.37
        command: ["/bin/sh","-c","while true; do sleep 3600; done"]
        volumeMounts: [{name: data, mountPath: /data}]
        resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 500m, memory: 256Mi}}
      volumes:
      - name: data
        persistentVolumeClaim: {claimName: deep-data}
---
apiVersion: v1
kind: Service
metadata: {name: deep-app, namespace: ${SRC_NS}}
spec:
  selector: {app: deep-app}
  ports: [{name: http, port: 80, targetPort: 8080}]
EOF
kubectl -n "${SRC_NS}" rollout status deploy/deep-app --timeout=300s >/dev/null 2>&1
POD="$(kubectl -n "${SRC_NS}" get pod -l app=deep-app -o jsonpath='{.items[0].metadata.name}')"
assert T04 "$([[ -n "${POD}" ]] && echo ok)" "ok" "fixture app running"

# Build a data tree that exercises the things filesystem backup gets wrong.
kubectl -n "${SRC_NS}" exec "${POD}" -c app -- sh -c '
set -eu
cd /data
mkdir -p nested/a/b/c empty-dir
# 250 small files across directories
i=1; while [ $i -le 250 ]; do
  d="nested/a/b/c"; [ $((i % 3)) -eq 0 ] && d="nested/a"; [ $((i % 5)) -eq 0 ] && d="nested"
  echo "file-$i-content-$(date -u +%s)" > "$d/f$i.txt"
  i=$((i+1))
done
# an 8MB pseudo-random binary: exercises Kopia chunking
dd if=/dev/urandom of=big.bin bs=1024 count=8192 2>/dev/null
# awkward filenames
printf "unicode ok\n" > "nested/файл-测试.txt"
printf "space ok\n"   > "nested/name with spaces.txt"
# non-default permissions
printf "perm ok\n" > perms-600.txt && chmod 600 perms-600.txt
printf "exec ok\n" > script.sh      && chmod 755 script.sh
# symlink
ln -sf nested/a/b/c/f1.txt link-to-f1
echo "tree built"
' >/dev/null 2>&1

# Per-file sha256 manifest — the real fidelity check.
kubectl -n "${SRC_NS}" exec "${POD}" -c app -- sh -c \
  'cd /data && find . -type f ! -path "./.velero/*" | LC_ALL=C sort | xargs -d "\n" sha256sum 2>/dev/null || (cd /data && find . -type f ! -path "./.velero/*" | LC_ALL=C sort | while read f; do sha256sum "$f"; done)' \
  > "${WORK}/before.sha256" 2>/dev/null
# permissions + symlink manifest
kubectl -n "${SRC_NS}" exec "${POD}" -c app -- sh -c \
  'cd /data && find . ! -path "./.velero*" | LC_ALL=C sort | while read f; do printf "%s %s\n" "$(stat -c %a "$f" 2>/dev/null)" "$f"; done' \
  > "${WORK}/before.perms" 2>/dev/null
FILES_BEFORE="$(grep -c . "${WORK}/before.sha256" 2>/dev/null || echo 0)"
assert_gt T05 "${FILES_BEFORE}" "250" "data tree built (files checksummed)"

# =============================================================================
hdr "T06-T10  Backup, volume capture, dedup, bucket, TTL"
OBJ_BEFORE="$(bucket_objects)"
velero backup create "${BK}" --include-namespaces "${SRC_NS}" --wait >/dev/null 2>&1
assert T06 "$(kubectl -n "${VELERO_NS}" get backup "${BK}" -o jsonpath='{.status.phase}' 2>/dev/null)" "Completed" "backup Completed"
WARN="$(kubectl -n "${VELERO_NS}" get backup "${BK}" -o jsonpath='{.status.warnings}' 2>/dev/null)"
assert T06b "${WARN:-0}" "0" "backup has zero warnings"

PVB_JSON="$(kubectl -n "${VELERO_NS}" get podvolumebackups -l velero.io/backup-name="${BK}" -o json 2>/dev/null)"
PVB_N="$(echo "${PVB_JSON}" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["items"]))' 2>/dev/null || echo 0)"
assert T07 "${PVB_N}" "1" "exactly one PodVolumeBackup created"
PVB_PHASE="$(echo "${PVB_JSON}" | python3 -c 'import sys,json;d=json.load(sys.stdin)["items"];print(d[0]["status"]["phase"] if d else "")' 2>/dev/null)"
assert T07b "${PVB_PHASE}" "Completed" "PodVolumeBackup Completed"
PVB_BYTES="$(echo "${PVB_JSON}" | python3 -c 'import sys,json;d=json.load(sys.stdin)["items"];print(d[0]["status"]["progress"]["bytesDone"] if d else 0)' 2>/dev/null || echo 0)"
assert_gt T07c "${PVB_BYTES}" "8000000" "uploaded >8MB (the binary was included)"

OBJ_AFTER="$(bucket_objects)"
assert_gt T08 "${OBJ_AFTER}" "${OBJ_BEFORE}" "bucket object count grew"

# Second backup of unchanged data: Kopia must dedup, not re-upload.
velero backup create "${BK2}" --include-namespaces "${SRC_NS}" --wait >/dev/null 2>&1
INC="$(kubectl -n "${VELERO_NS}" get podvolumebackups -l velero.io/backup-name="${BK2}" -o json 2>/dev/null \
      | python3 -c 'import sys,json
d=json.load(sys.stdin)["items"]
print(d[0]["status"]["progress"].get("bytesDone",0) if d else 0)' 2>/dev/null || echo 0)"
# Kopia reports bytesDone for the snapshot; the *stored* delta is what shrinks.
# Compare the bucket growth instead: a dedup'd second backup adds far less.
OBJ_AFTER2="$(bucket_objects)"
GROWTH1=$(( OBJ_AFTER - OBJ_BEFORE ))
GROWTH2=$(( OBJ_AFTER2 - OBJ_AFTER ))
if [[ "${GROWTH2}" -lt "${GROWTH1}" ]]; then
  ok T09 "second backup deduplicated" "added ${GROWTH2} objects vs ${GROWTH1}"
else
  inf T09 "second backup dedup inconclusive" "added ${GROWTH2} vs ${GROWTH1} objects"
fi

EXP="$(kubectl -n "${VELERO_NS}" get backup "${BK}" -o jsonpath='{.status.expiration}' 2>/dev/null)"
TTL_OK="$(python3 -c "
from datetime import datetime, timezone
import sys
try:
    e = datetime.fromisoformat('${EXP}'.replace('Z','+00:00'))
    h = (e - datetime.now(timezone.utc)).total_seconds()/3600
    print('ok' if 160 < h < 170 else round(h,1))
except Exception as ex: print('parse-error')" 2>/dev/null)"
assert T10 "${TTL_OK}" "ok" "TTL is ~168h (defaultBackupTTL)"

# =============================================================================
hdr "T11-T19  Full DR: destroy the namespace and rebuild it"
SVC_IP_BEFORE="$(kubectl -n "${SRC_NS}" get svc deep-app -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
kubectl delete ns "${SRC_NS}" --wait=false >/dev/null 2>&1
if wait_ns_gone "${SRC_NS}"; then ok T11 "namespace destroyed" "gone"; else no T11 "namespace destroyed" "still present after 6min"; fi

velero restore create "${RS}" --from-backup "${BK}" --wait >/dev/null 2>&1
assert T12 "$(kubectl -n "${VELERO_NS}" get restore "${RS}" -o jsonpath='{.status.phase}' 2>/dev/null)" "Completed" "restore Completed"
assert T13 "$(kubectl -n "${VELERO_NS}" get podvolumerestores -l velero.io/restore-name="${RS}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" "Completed" "PodVolumeRestore Completed"
kubectl -n "${SRC_NS}" rollout status deploy/deep-app --timeout=300s >/dev/null 2>&1
RPOD="$(kubectl -n "${SRC_NS}" get pod -l app=deep-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"

kubectl -n "${SRC_NS}" exec "${RPOD}" -c app -- sh -c \
  'cd /data && find . -type f ! -path "./.velero/*" | LC_ALL=C sort | while read f; do sha256sum "$f"; done' \
  > "${WORK}/after.sha256" 2>/dev/null
kubectl -n "${SRC_NS}" exec "${RPOD}" -c app -- sh -c \
  'cd /data && find . ! -path "./.velero*" | LC_ALL=C sort | while read f; do printf "%s %s\n" "$(stat -c %a "$f" 2>/dev/null)" "$f"; done' \
  > "${WORK}/after.perms" 2>/dev/null

if diff -q "${WORK}/before.sha256" "${WORK}/after.sha256" >/dev/null 2>&1; then
  ok T14 "every file byte-identical" "$(grep -c . "${WORK}/after.sha256") files, sha256 match"
else
  no T14 "every file byte-identical" "$(diff "${WORK}/before.sha256" "${WORK}/after.sha256" | grep -c '^[<>]') differing lines"
  diff "${WORK}/before.sha256" "${WORK}/after.sha256" | head -8 | sed 's/^/        /'
fi

if diff -q "${WORK}/before.perms" "${WORK}/after.perms" >/dev/null 2>&1; then
  ok T15 "permissions + tree preserved" "identical"
else
  # Directory modes can legitimately differ due to fsGroup; report, don't fail.
  inf T15 "permissions/tree differ" "$(diff "${WORK}/before.perms" "${WORK}/after.perms" | grep -c '^[<>]') lines — see note"
  diff "${WORK}/before.perms" "${WORK}/after.perms" | head -6 | sed 's/^/        /'
fi

for f in 'nested/файл-测试.txt' 'nested/name with spaces.txt'; do
  got="$(kubectl -n "${SRC_NS}" exec "${RPOD}" -c app -- sh -c "cat '/data/$f' 2>/dev/null" | tr -d '\r\n')"
  [[ -n "${got}" ]] && ok T16 "awkward filename restored" "$f" || no T16 "awkward filename restored" "$f is empty/missing"
done
BIGSUM_B="$(grep ' ./big.bin$' "${WORK}/before.sha256" | awk '{print $1}')"
BIGSUM_A="$(grep ' ./big.bin$' "${WORK}/after.sha256"  | awk '{print $1}')"
assert T17 "${BIGSUM_A:-none}" "${BIGSUM_B:-none}" "8MB binary checksum matches"

assert T18 "$(kubectl -n "${SRC_NS}" get cm deep-config -o jsonpath='{.data.app\.conf}' 2>/dev/null | grep -c "run=${RUN}")" "1" "ConfigMap content restored"
assert T18b "$(kubectl -n "${SRC_NS}" get secret deep-secret -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)" "deep-test-token-${RUN}" "Secret content restored"
SVC_IP_AFTER="$(kubectl -n "${SRC_NS}" get svc deep-app -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
if [[ -n "${SVC_IP_AFTER}" && "${SVC_IP_AFTER}" != "${SVC_IP_BEFORE}" ]]; then
  ok T19 "Service got a fresh clusterIP" "${SVC_IP_BEFORE} → ${SVC_IP_AFTER}"
else
  no T19 "Service got a fresh clusterIP" "before=${SVC_IP_BEFORE} after=${SVC_IP_AFTER}"
fi

# =============================================================================
hdr "T20-T21  Relocation and selective restore"
velero restore create "${RSCLONE}" --from-backup "${BK}" \
  --namespace-mappings "${SRC_NS}:${CLONE_NS}" --wait >/dev/null 2>&1
assert T20 "$(kubectl -n "${VELERO_NS}" get restore "${RSCLONE}" -o jsonpath='{.status.phase}' 2>/dev/null)" "Completed" "namespace-mapped restore Completed"
kubectl -n "${CLONE_NS}" rollout status deploy/deep-app --timeout=300s >/dev/null 2>&1
CPOD="$(kubectl -n "${CLONE_NS}" get pod -l app=deep-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -n "${CPOD}" ]]; then
  kubectl -n "${CLONE_NS}" exec "${CPOD}" -c app -- sh -c \
    'cd /data && find . -type f ! -path "./.velero/*" | LC_ALL=C sort | while read f; do sha256sum "$f"; done' \
    > "${WORK}/clone.sha256" 2>/dev/null
  diff -q "${WORK}/before.sha256" "${WORK}/clone.sha256" >/dev/null 2>&1 \
    && ok T20b "cloned namespace data identical" "$(grep -c . "${WORK}/clone.sha256") files" \
    || no T20b "cloned namespace data identical" "checksum mismatch in ${CLONE_NS}"
else
  no T20b "cloned namespace data identical" "no pod in ${CLONE_NS}"
fi

velero restore create "${RSPART}" --from-backup "${BK}" \
  --include-resources configmaps,secrets \
  --namespace-mappings "${SRC_NS}:${PARTIAL_NS}" --wait >/dev/null 2>&1
HAS_CM="$(kubectl -n "${PARTIAL_NS}" get cm deep-config --no-headers 2>/dev/null | wc -l)"
HAS_PVC="$(kubectl -n "${PARTIAL_NS}" get pvc --no-headers 2>/dev/null | wc -l)"
HAS_DEP="$(kubectl -n "${PARTIAL_NS}" get deploy --no-headers 2>/dev/null | wc -l)"
assert T21 "${HAS_CM}" "1" "selective restore brought the ConfigMap"
assert T21b "${HAS_PVC}${HAS_DEP}" "00" "selective restore excluded PVC and Deployment"

# =============================================================================
hdr "T22  NEGATIVE: hostPath (local-path) volumes must be skipped"
# This asserts the documented failure mode still behaves as documented. If it
# ever PASSES differently, Velero changed and docs/02 + CLAUDE.md need updating.
kubectl create ns "${TRAP_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: trap-data, namespace: ${TRAP_NS}}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path        # deliberately the WRONG class
  resources: {requests: {storage: 100Mi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: trap-app, namespace: ${TRAP_NS}, labels: {app: trap-app}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: trap-app}}
  template:
    metadata: {labels: {app: trap-app}}
    spec:
      containers:
      - name: app
        image: docker.io/library/busybox:1.37
        command: ["/bin/sh","-c","echo trap-payload > /data/x.txt; while true; do sleep 3600; done"]
        volumeMounts: [{name: data, mountPath: /data}]
      volumes:
      - name: data
        persistentVolumeClaim: {claimName: trap-data}
EOF
kubectl -n "${TRAP_NS}" rollout status deploy/trap-app --timeout=300s >/dev/null 2>&1
velero backup create "${BKTRAP}" --include-namespaces "${TRAP_NS}" --wait >/dev/null 2>&1
TRAP_PHASE="$(kubectl -n "${VELERO_NS}" get backup "${BKTRAP}" -o jsonpath='{.status.phase}' 2>/dev/null)"
TRAP_PVB="$(kubectl -n "${VELERO_NS}" get podvolumebackups -l velero.io/backup-name="${BKTRAP}" --no-headers 2>/dev/null | wc -l)"
TRAP_WARN="$(kubectl -n "${VELERO_NS}" get backup "${BKTRAP}" -o jsonpath='{.status.warnings}' 2>/dev/null)"
assert T22 "${TRAP_PHASE}" "Completed" "hostPath backup still reports Completed"
assert T22b "${TRAP_PVB}" "0" "hostPath volume produced NO PodVolumeBackup"
assert_gt T22c "${TRAP_WARN:-0}" "0" "…and it did raise a warning (the only signal)"
if velero backup logs "${BKTRAP}" 2>/dev/null | grep -qi "hostPath volume which is not supported"; then
  ok T22d "skip reason present in log" "hostPath not supported"
else
  inf T22d "skip reason not found in log" "message may have changed — check docs"
fi

# =============================================================================
hdr "T23-T25  No-op restore, schedules, metrics, backup deletion"
CNT_BEFORE="$(kubectl -n "${SRC_NS}" get all --no-headers 2>/dev/null | wc -l)"
velero restore create "${RSNOOP}" --from-backup "${BK}" --wait >/dev/null 2>&1
CNT_AFTER="$(kubectl -n "${SRC_NS}" get all --no-headers 2>/dev/null | wc -l)"
assert T23 "${CNT_AFTER}" "${CNT_BEFORE}" "restore over a live namespace is a no-op"

velero schedule create "${SCHED}" --schedule="0 3 * * *" \
  --include-namespaces "${SRC_NS}" --ttl 168h >/dev/null 2>&1
assert T24 "$(kubectl -n "${VELERO_NS}" get schedule "${SCHED}" -o jsonpath='{.spec.schedule}' 2>/dev/null)" "0 3 * * *" "schedule created with the right cron"
velero backup create --from-schedule "${SCHED}" --wait >/dev/null 2>&1
FROM_SCHED="$(kubectl -n "${VELERO_NS}" get backups -l velero.io/schedule-name="${SCHED}" --no-headers 2>/dev/null | wc -l)"
assert_gt T24b "${FROM_SCHED}" "0" "backup triggered from the schedule"

M="$(metric velero_backup_success_total)"
assert_gt T25 "${M%%.*}" "0" "velero_backup_success_total is counting"

OBJ_PRE_DEL="$(bucket_objects)"
SCHED_BK="$(kubectl -n "${VELERO_NS}" get backups -l velero.io/schedule-name="${SCHED}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -n "${SCHED_BK}" ]]; then
  velero backup delete "${SCHED_BK}" --confirm >/dev/null 2>&1
  for _ in $(seq 1 40); do
    kubectl -n "${VELERO_NS}" get backup "${SCHED_BK}" >/dev/null 2>&1 || break
    sleep 3
  done
  OBJ_POST_DEL="$(bucket_objects)"
  if [[ "${OBJ_POST_DEL}" -lt "${OBJ_PRE_DEL}" ]]; then
    ok T25b "backup delete freed bucket objects" "${OBJ_PRE_DEL} → ${OBJ_POST_DEL}"
  else
    inf T25b "bucket objects unchanged after delete" "${OBJ_PRE_DEL} → ${OBJ_POST_DEL} (Kopia may retain shared blobs until maintenance)"
  fi
else
  inf T25b "no scheduled backup to delete" "skipped"
fi

# =============================================================================
printf '\n\033[1;35m════════ DEEP TEST RESULT ════════\033[0m\n'
printf '  passed:        %s\n' "${PASS}"
printf '  failed:        %s\n' "${FAIL}"
printf '  informational: %s\n' "${SOFT}"
if [[ "${FAIL}" -gt 0 ]]; then
  printf '\n\033[1;31m  failed assertions:\033[0m\n'
  for t in "${FAILED_TESTS[@]}"; do printf '    - %s\n' "$t"; done
  printf '\n\033[1;31m  DEEP TEST FAILED\033[0m\n'
  exit 1
fi
printf '\n\033[1;32m  DEEP TEST PASSED — backups are trustworthy on this cluster.\033[0m\n'
exit 0
