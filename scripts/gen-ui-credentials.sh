#!/usr/bin/env bash
# =============================================================================
# Generates credentials for Velero UI and creates the Secret it reads them from.
#
# WHY THIS IS NOT OPTIONAL
# The chart ships these defaults:
#     BASIC_AUTH_USERNAME=admin
#     BASIC_AUTH_PASSWORD=admin
#     AUTH_SECRET_PASSPHRASE="this is not a secret passphrase"
# A web UI that can create and DELETE every backup in the cluster, reachable on a
# NodePort, behind admin/admin, is not something to leave as shipped.
#
# The passphrase signs the session JWTs. Left at its published default, anyone
# can forge a valid session token and skip the login entirely — so it matters
# just as much as the password.
#
# CHART GAP WORKED AROUND HERE: the chart creates a Secret from
# `configuration.general.secretPassPhrase.value` but never references it in the
# Deployment, so that value has no effect. We inject both variables ourselves
# via `env` + secretKeyRef in values/values-velero-ui.yaml.
#
# Idempotent: reuses existing credentials unless --rotate is passed.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/.secrets"
ENV_FILE="${SECRETS_DIR}/velero-ui.env"

UI_NS="${VELERO_UI_NAMESPACE:-velero-ui}"

ROTATE=0
[[ "${1:-}" == "--rotate" ]] && ROTATE=1

mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

rand_alnum() { # $1 = charset, $2 = length
  LC_ALL=C tr -dc "$1" <<<"$(head -c 4096 /dev/urandom | base64 -w0)" | cut -c "1-$2"
}

if [[ -f "${ENV_FILE}" && "${ROTATE}" -eq 0 ]]; then
  echo "==> Reusing existing credentials from ${ENV_FILE}"
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
else
  echo "==> Generating new Velero UI credentials"
  UI_USERNAME="${UI_USERNAME:-admin}"
  UI_PASSWORD="$(rand_alnum 'A-Za-z0-9' 28)"
  UI_PASSPHRASE="$(rand_alnum 'A-Za-z0-9' 56)"
  cat >"${ENV_FILE}" <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/gen-ui-credentials.sh
# KEEP PRIVATE. This file is gitignored.
UI_USERNAME=${UI_USERNAME}
UI_PASSWORD=${UI_PASSWORD}
UI_PASSPHRASE=${UI_PASSPHRASE}
EOF
  chmod 600 "${ENV_FILE}"
fi

echo "    username: ${UI_USERNAME}"
echo "    password: ${UI_PASSWORD}"
echo "    (also saved in ${ENV_FILE})"

kubectl get namespace "${UI_NS}" >/dev/null 2>&1 || kubectl create namespace "${UI_NS}"

echo "==> Secret ${UI_NS}/velero-ui-auth"
kubectl -n "${UI_NS}" create secret generic velero-ui-auth \
  --from-literal=BASIC_AUTH_USERNAME="${UI_USERNAME}" \
  --from-literal=BASIC_AUTH_PASSWORD="${UI_PASSWORD}" \
  --from-literal=AUTH_SECRET_PASSPHRASE="${UI_PASSPHRASE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "==> Done. If the UI is already running, restart it to pick up changes:"
echo "    kubectl -n ${UI_NS} rollout restart deploy/velero-ui"
