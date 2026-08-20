#!/usr/bin/env bash
# =============================================================================
# One-command install of the whole local stack:
#   local-path-provisioner  -> default StorageClass (cluster had none)
#   local-static SC + PVs   -> the PVs Velero's fs-backup can actually read
#   MinIO                   -> S3-compatible backup target + `velero` bucket
#   Velero + node-agent     -> via the official Helm chart
#
# Idempotent: safe to re-run. Existing credentials are reused.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CHART_VERSION="${CHART_VERSION:-12.1.0}"
VELERO_NS="${VELERO_NAMESPACE:-velero}"
MINIO_NS="${MINIO_NAMESPACE:-minio}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

step "Checking prerequisites"
for bin in kubectl helm; do
  command -v "$bin" >/dev/null || { echo "ERROR: $bin not found in PATH"; exit 1; }
done
kubectl cluster-info >/dev/null || { echo "ERROR: cannot reach the cluster"; exit 1; }
echo "    context: $(kubectl config current-context)"
echo "    server:  $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

step "Adding the Velero Helm repo"
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update vmware-tanzu >/dev/null
echo "    chart version: ${CHART_VERSION}"

step "Installing local-path-provisioner (default StorageClass)"
kubectl apply -f manifests/local-path-provisioner.yaml
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s

step "Installing local-static StorageClass + static 'local' PV pool"
# Needed because local-path produces hostPath PVs, which Velero's fs-backup
# skips SILENTLY. See the header of manifests/local-static-storage.yaml.
kubectl apply -f manifests/local-static-storage.yaml
kubectl -n local-path-storage wait --for=condition=complete \
  job/local-static-mkdir --timeout=180s

step "Generating credentials and creating Secrets"
./scripts/gen-credentials.sh

step "Deploying MinIO"
kubectl apply -f manifests/minio.yaml
kubectl -n "${MINIO_NS}" rollout status deploy/minio --timeout=300s
kubectl -n "${MINIO_NS}" wait --for=condition=complete \
  job/minio-create-bucket --timeout=180s
echo "    bucket 'velero' ready"

step "Installing Velero via Helm"
helm upgrade --install velero vmware-tanzu/velero \
  --version "${CHART_VERSION}" \
  --namespace "${VELERO_NS}" \
  --create-namespace \
  -f values/values-local.yaml \
  --wait --timeout 10m

step "Waiting for the BackupStorageLocation to validate"
# 'Available' means Velero successfully authenticated to MinIO and can list the
# bucket. 'Unavailable' here is the single most useful early failure signal.
for i in $(seq 1 30); do
  phase="$(kubectl -n "${VELERO_NS}" get backupstoragelocation default \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${phase}" == "Available" ]] && break
  echo "    phase=${phase:-<pending>} (${i}/30)"
  sleep 5
done
[[ "${phase:-}" == "Available" ]] || {
  echo "ERROR: BackupStorageLocation is '${phase:-unknown}', not Available."
  echo "       kubectl -n ${VELERO_NS} describe backupstoragelocation default"
  echo "       kubectl -n ${VELERO_NS} logs deploy/velero | tail -50"
  exit 1
}

step "Done"
kubectl -n "${VELERO_NS}" get pods
kubectl -n "${VELERO_NS}" get backupstoragelocation
cat <<'EOF'

Next steps:
  ./scripts/verify-backup-restore.sh    # full end-to-end proof
  velero backup create my-first --include-namespaces <ns> --wait
  velero backup get

MinIO console:  http://<node-ip>:30901   (credentials in .secrets/minio.env)
EOF
