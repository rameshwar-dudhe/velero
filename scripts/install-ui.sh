#!/usr/bin/env bash
# =============================================================================
# Installs the Velero web UI (otwld/velero-ui) with BOTH dangerous chart
# defaults corrected. See docs/07-web-ui.md for the full reasoning.
#
#   1. rbac.clusterAdministrator -> false   (chart default binds cluster-admin)
#   2. real password + real JWT passphrase  (chart defaults are admin/admin and
#                                            a published placeholder passphrase)
#
# Requires Velero to be installed first — the UI reads Velero's CRs.
# Idempotent: safe to re-run.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

UI_CHART_VERSION="${UI_CHART_VERSION:-0.15.0}"
UI_NS="${VELERO_UI_NAMESPACE:-velero-ui}"
VELERO_NS="${VELERO_NAMESPACE:-velero}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

step "Checking prerequisites"
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found"; exit 1; }
command -v helm    >/dev/null || { echo "ERROR: helm not found";    exit 1; }
kubectl -n "${VELERO_NS}" get deploy velero >/dev/null 2>&1 || {
  echo "ERROR: Velero is not installed in namespace '${VELERO_NS}'."
  echo "       Run ./scripts/install-local.sh first — the UI has nothing to show without it."
  exit 1
}
echo "    Velero found in namespace ${VELERO_NS}"

step "Adding the otwld Helm repo"
helm repo add otwld https://helm.otwld.com/ >/dev/null 2>&1 || true
helm repo update otwld >/dev/null
echo "    chart version: ${UI_CHART_VERSION}"

step "Generating UI credentials and creating the Secret"
./scripts/gen-ui-credentials.sh

step "Installing the UI via Helm"
helm upgrade --install velero-ui otwld/velero-ui \
  --version "${UI_CHART_VERSION}" \
  --namespace "${UI_NS}" \
  --create-namespace \
  -f values/values-velero-ui.yaml \
  --wait --timeout 6m

step "Creating the NodePort Service"
# The chart's Service template has no nodePort field, so external access needs
# its own Service.
kubectl apply -f manifests/velero-ui-nodeport.yaml

step "SECURITY CHECK: confirming the UI is NOT bound to cluster-admin"
BOUND="$(kubectl get clusterrolebinding velero-ui -o jsonpath='{.roleRef.name}' 2>/dev/null || echo '')"
echo "    ClusterRoleBinding velero-ui -> ${BOUND}"
if [[ "${BOUND}" == "cluster-admin" ]]; then
  echo "ERROR: the UI is bound to cluster-admin. rbac.clusterAdministrator must be false."
  echo "       Check values/values-velero-ui.yaml and re-run."
  exit 1
fi
[[ "${BOUND}" == "velero-ui" ]] && echo "    OK: scoped to the chart's own least-privilege role"

step "Waiting for the UI to answer"
NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')"
NODE_PORT="$(kubectl -n "${UI_NS}" get svc velero-ui-nodeport -o jsonpath='{.spec.ports[0].nodePort}')"
URL="http://${NODE_IP}:${NODE_PORT}"
for i in $(seq 1 30); do
  # `curl -w` already prints 000 on failure, so a `|| echo 000` fallback would
  # concatenate into "000000". Blank the empty case instead.
  code="$(curl -s -o /dev/null -w '%{http_code}' "${URL}/" 2>/dev/null || true)"
  [[ -z "${code}" ]] && code="000"
  [[ "${code}" == "200" ]] && break
  echo "    HTTP ${code} (${i}/30)"
  sleep 4
done
[[ "${code:-}" == "200" ]] || {
  echo "ERROR: the UI did not answer at ${URL} (last HTTP ${code:-none})"
  echo "       kubectl -n ${UI_NS} logs deploy/velero-ui --tail=50"
  exit 1
}

step "Verifying login works and the UI can see Velero's data"
# shellcheck disable=SC1091
source .secrets/velero-ui.env
TOKEN="$(curl -s -X POST "${URL}/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${UI_USERNAME}\",\"password\":\"${UI_PASSWORD}\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || echo '')"
[[ -n "${TOKEN}" ]] || { echo "ERROR: login failed with the generated credentials"; exit 1; }
echo "    login OK, JWT issued"
for ep in backups restores backup-storage-locations; do
  n="$(curl -s "${URL}/api/${ep}" -H "Authorization: Bearer ${TOKEN}" \
       | python3 -c 'import sys,json
d=json.load(sys.stdin); i=d.get("payload") or d.get("data") or d.get("items") or []
if isinstance(i,dict): i=i.get("items",[])
print(len(i))' 2>/dev/null || echo '?')"
  printf '    /api/%-28s %s\n' "${ep}" "${n}"
done

step "Done"
cat <<EOF

  URL:      ${URL}
  username: ${UI_USERNAME}
  password: ${UI_PASSWORD}

  (also in .secrets/velero-ui.env — rotate with ./scripts/gen-ui-credentials.sh --rotate)

  NOTE: this is plain HTTP on your LAN, and UI access lets someone read the
  Secrets in the ${VELERO_NS} namespace (your S3 keys). See docs/07-web-ui.md.
EOF
