#!/usr/bin/env bash
# =============================================================================
# Tears the stack down, in dependency order.
#
# LEVELS — each one includes the previous:
#
#   (no flag)      Remove Velero, the UI, the demo namespace, and MinIO's
#                  workloads. KEEPS your backup data (the MinIO PVC uses
#                  reclaimPolicy: Retain) and keeps the storage classes.
#
#   --purge-data   Also delete MinIO's PVC, the local-static PV pool, and WIPE
#                  the backing directories on the node. THIS DESTROYS ALL
#                  BACKUPS. Use for a genuine from-scratch rebuild.
#
#   --purge-all    Also remove local-path-provisioner, returning the cluster to
#                  having no StorageClass at all — exactly how it started.
#
# Never touches namespaces this project did not create.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

VELERO_NS="${VELERO_NAMESPACE:-velero}"
MINIO_NS="${MINIO_NAMESPACE:-minio}"
UI_NS="${VELERO_UI_NAMESPACE:-velero-ui}"

PURGE_DATA=0
PURGE_ALL=0
case "${1:-}" in
  --purge-data) PURGE_DATA=1 ;;
  --purge-all)  PURGE_DATA=1; PURGE_ALL=1 ;;
  "")           ;;
  *) echo "unknown flag: ${1}. Use --purge-data or --purge-all."; exit 1 ;;
esac

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

if [[ "${PURGE_DATA}" -eq 1 ]]; then
  printf '\n\033[1;31m!! %s\033[0m\n' "PURGE MODE — all backup data will be destroyed."
fi

# ── application layer ───────────────────────────────────────────────────────
step "Removing the demo namespace"
kubectl delete ns velero-demo --ignore-not-found --wait=true

step "Removing Velero UI"
helm -n "${UI_NS}" uninstall velero-ui --wait 2>/dev/null || echo "    (not installed)"
kubectl delete -f manifests/velero-ui-nodeport.yaml --ignore-not-found 2>/dev/null || true
kubectl delete ns "${UI_NS}" --ignore-not-found --wait=true

step "Removing the Velero Helm release"
helm -n "${VELERO_NS}" uninstall velero --wait 2>/dev/null || echo "    (not installed)"

step "Clearing Velero finalizers (MUST happen before deleting the CRDs)"
# Velero puts finalizers on its own resources, e.g.
#   restores.velero.io/external-resources-finalizer
# Only the Velero controller removes them — and we just uninstalled it. Deleting
# the CRDs first therefore DEADLOCKS: the apiextensions cleanup finalizer waits
# forever for custom resources that nothing is left to finalize, and
# `kubectl delete crd --wait` hangs indefinitely.
#
# This bit us during a real teardown: restores.velero.io sat in Terminating with
# two Restore objects still holding their finalizer. So strip finalizers first.
for kind in restores backups schedules podvolumebackups podvolumerestores \
            backuprepositories datauploads datadownloads \
            deletebackuprequests downloadrequests serverstatusrequests \
            backupstoragelocations volumesnapshotlocations; do
  kubectl api-resources --api-group=velero.io -o name 2>/dev/null \
    | grep -q "^${kind}\.velero\.io$" || continue
  for name in $(kubectl -n "${VELERO_NS}" get "${kind}.velero.io" \
                  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl -n "${VELERO_NS}" patch "${kind}.velero.io" "${name}" \
      --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 \
      && echo "    cleared finalizers: ${kind}/${name}"
  done
done
echo "    done"

step "Removing Velero CRDs"
# The chart deliberately leaves CRDs behind (cleanUpCRDs: false) so that an
# accidental `helm uninstall` cannot destroy your Backup records. Explicit here.
# --wait=false: never block on CRD cleanup even if a finalizer was missed above.
kubectl get crd -o name 2>/dev/null | grep 'velero.io' | xargs -r kubectl delete --wait=false

# Now wait, but with a bound rather than forever, and report clearly on timeout.
for i in $(seq 1 30); do
  remaining="$(kubectl get crd -o name 2>/dev/null | grep -c 'velero.io' || true)"
  [[ "${remaining}" -eq 0 ]] && break
  sleep 3
done
if [[ "${remaining:-0}" -ne 0 ]]; then
  echo "    WARNING: ${remaining} velero.io CRD(s) still terminating."
  echo "    A custom resource still holds a finalizer. Find and clear it with:"
  echo "      kubectl get crd | grep velero.io"
  echo "      kubectl get <crd-name> -A -o json | grep -B5 finalizers"
  echo "      kubectl -n ${VELERO_NS} patch <kind> <name> --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
else
  echo "    all velero.io CRDs removed"
fi

kubectl delete ns "${VELERO_NS}" --ignore-not-found --wait=true

# ── storage layer ───────────────────────────────────────────────────────────
step "Removing MinIO"
if [[ "${PURGE_DATA}" -eq 1 ]]; then
  echo "    purging: deleting the whole namespace including the PVC"
  kubectl delete ns "${MINIO_NS}" --ignore-not-found --wait=true
else
  kubectl -n "${MINIO_NS}" delete deploy/minio svc/minio svc/minio-nodeport \
    job/minio-create-bucket --ignore-not-found 2>/dev/null || true
  echo "    KEPT: PVC minio-data (your backups). Use --purge-data to delete it."
fi

step "Removing the static local PV pool"
if [[ "${PURGE_DATA}" -eq 1 ]]; then
  kubectl delete -f manifests/local-static-storage.yaml --ignore-not-found 2>/dev/null || true
else
  echo "    KEPT. Use --purge-data to remove."
fi

# ── on-node data ────────────────────────────────────────────────────────────
# Deleting a PVC whose StorageClass uses reclaimPolicy: Retain leaves the real
# files on the node's disk. Without this step a "fresh" reinstall silently
# inherits gigabytes of orphaned data.
if [[ "${PURGE_DATA}" -eq 1 ]]; then
  step "Wiping backing directories on the node"
  kubectl get ns local-path-storage >/dev/null 2>&1 || kubectl create ns local-path-storage
  kubectl -n local-path-storage delete job node-data-purge --ignore-not-found --wait=true >/dev/null 2>&1 || true
  cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: node-data-purge
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
        - name: purge
          image: docker.io/library/busybox:1.37
          securityContext:
            runAsUser: 0
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              # Our own static PV pool: safe to remove wholesale.
              if [ -d /host-opt/velero-local-pvs ]; then
                echo "removing /host-opt/velero-local-pvs"
                rm -rf /host-opt/velero-local-pvs
              else
                echo "/host-opt/velero-local-pvs already absent"
              fi
              # local-path is SHARED with other workloads. Its directories are
              # named pvc-<uid>_<namespace>_<pvcname>, so delete only the ones
              # belonging to this project. Wiping the whole directory would
              # destroy unrelated apps' data.
              if [ -d /host-opt/local-path-provisioner ]; then
                for ns in minio velero velero-demo velero-ui; do
                  for d in /host-opt/local-path-provisioner/*_${ns}_*; do
                    [ -e "$d" ] || continue
                    echo "removing $d"
                    rm -rf "$d"
                  done
                done
                echo "kept (not ours):"
                ls -1 /host-opt/local-path-provisioner 2>/dev/null || echo "  (none)"
              fi
          volumeMounts:
            - name: host-opt
              mountPath: /host-opt
      volumes:
        - name: host-opt
          hostPath:
            path: /opt
            type: DirectoryOrCreate
EOF
  kubectl -n local-path-storage wait --for=condition=complete job/node-data-purge --timeout=180s
  kubectl -n local-path-storage logs job/node-data-purge | sed 's/^/    /'
  kubectl -n local-path-storage delete job node-data-purge --ignore-not-found >/dev/null 2>&1 || true

  step "Releasing orphaned PVs that belonged to THIS project"
  # Scoped deliberately. An earlier version matched on storageClassName alone,
  # which would have deleted ANY local-path volume in the cluster — including
  # other people's workloads that legitimately use the default StorageClass.
  # Match only on ownership: our PV pool label, or a claimRef into a namespace
  # this project owns.
  kubectl get pv -o json 2>/dev/null | python3 -c '
import sys, json
OURS = {"minio", "velero", "velero-demo", "velero-ui"}
d = json.load(sys.stdin)
for i in d.get("items", []):
    meta = i.get("metadata", {})
    spec = i.get("spec", {})
    labels = meta.get("labels") or {}
    claim = spec.get("claimRef") or {}
    mine = (
        labels.get("velero.io/pv-pool") == "local-static"
        or claim.get("namespace") in OURS
    )
    if mine:
        print(meta["name"])
' | xargs -r kubectl delete pv --wait=false 2>/dev/null || true
  echo "    done (other workloads' volumes untouched)"
fi

# ── provisioner ─────────────────────────────────────────────────────────────
step "local-path-provisioner"
if [[ "${PURGE_ALL}" -eq 1 ]]; then
  echo "    purge-all: removing it. The cluster will have NO StorageClass again."
  kubectl delete -f manifests/local-path-provisioner.yaml --ignore-not-found --wait=true 2>/dev/null || true
else
  cat <<'EOF'
    KEPT ON PURPOSE. It is the cluster's default StorageClass and other workloads
    may depend on it. Remove it with --purge-all, or by hand:
      kubectl delete -f manifests/local-path-provisioner.yaml
EOF
fi

step "Done"
echo "Credential files under .secrets/ were left in place, so a reinstall reuses"
echo "the same keys. Delete them (or pass --rotate to the gen scripts) to change."
echo
kubectl get ns 2>/dev/null | grep -E "velero|minio|local-path" || echo "No project namespaces remain."
kubectl get sc 2>/dev/null || true
