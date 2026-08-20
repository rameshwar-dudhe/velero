#!/usr/bin/env bash
# =============================================================================
# Returns `Released` static local PVs to `Available` so they can be reused.
#
# WHY YOU NEED THIS
# A static PV with reclaimPolicy: Retain does NOT return to the pool when its
# PVC is deleted — it sits in `Released` forever, because Kubernetes has no
# recycler for `local` volumes. Each backup/restore cycle therefore burns one
# PV out of the pool in manifests/local-static-storage.yaml, and once they are
# all Released, restores of PVC-backed apps hang in Pending.
#
# This script does the two things Kubernetes will not do for you:
#   1. clears spec.claimRef            -> Released becomes Available
#   2. empties the backing directory   -> no stale files bleed into the next
#                                         workload that binds the PV
#
# Step 2 matters for correctness: a Kopia restore writes its files into the
# volume but does not delete pre-existing ones, so leftovers from a previous
# tenant would silently survive into the restored volume.
#
# Usage:
#   ./scripts/recycle-local-pvs.sh            # recycle all Released PVs
#   ./scripts/recycle-local-pvs.sh --dry-run  # just show what would happen
# =============================================================================
set -euo pipefail

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

step "Finding Released PVs in the local-static pool"
mapfile -t RELEASED < <(
  kubectl get pv -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
for i in d.get("items", []):
    spec = i.get("spec", {})
    if spec.get("storageClassName") != "local-static":
        continue
    if i.get("status", {}).get("phase") != "Released":
        continue
    path = spec.get("local", {}).get("path", "")
    print(i["metadata"]["name"], path)
'
)

if [[ "${#RELEASED[@]}" -eq 0 ]]; then
  echo "    none — nothing to do."
  kubectl get pv -l velero.io/pv-pool=local-static \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name'
  exit 0
fi

PATHS=()
for entry in "${RELEASED[@]}"; do
  name="${entry%% *}"; path="${entry##* }"
  echo "    ${name}  ->  ${path}"
  PATHS+=("${path}")
done

if [[ "${DRY}" -eq 1 ]]; then
  echo
  echo "--dry-run: would clear claimRef and empty the directories above."
  exit 0
fi

step "Emptying the backing directories on the node"
# Build the list of host paths to clear, mapped under /host-opt.
CLEAN_CMDS=""
for p in "${PATHS[@]}"; do
  # /opt/velero-local-pvs/pv-N -> /host-opt/velero-local-pvs/pv-N
  hp="/host-opt${p#/opt}"
  CLEAN_CMDS+="echo 'clearing ${hp}'; rm -rf '${hp}'/* '${hp}'/.[!.]* 2>/dev/null || true;"
done

JOB="local-static-recycle"
# Fixed name, deleted first: re-running never accumulates completed Jobs.
kubectl -n local-path-storage delete job "${JOB}" --ignore-not-found --wait=true >/dev/null 2>&1 || true

cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: local-path-storage
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      nodeSelector:
        kubernetes.io/hostname: k8s-w-0
      containers:
        - name: clean
          image: docker.io/library/busybox:1.37
          securityContext:
            runAsUser: 0
          command: ["/bin/sh","-c","set -eu; ${CLEAN_CMDS} echo done"]
          volumeMounts:
            - name: host-opt
              mountPath: /host-opt
      volumes:
        - name: host-opt
          hostPath:
            path: /opt
            type: Directory
EOF

kubectl -n local-path-storage wait --for=condition=complete "job/${JOB}" --timeout=180s
kubectl -n local-path-storage logs "job/${JOB}" | sed 's/^/    /'

step "Clearing claimRef so the PVs return to Available"
for entry in "${RELEASED[@]}"; do
  name="${entry%% *}"
  kubectl patch pv "${name}" --type=json \
    -p='[{"op":"remove","path":"/spec/claimRef"}]' >/dev/null
  echo "    ${name} -> Available"
done

step "Pool state"
kubectl get pv -l velero.io/pv-pool=local-static \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name,PATH:.spec.local.path'
