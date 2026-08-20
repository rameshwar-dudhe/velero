#!/usr/bin/env bash
# =============================================================================
# Generates MinIO credentials and creates the two Secrets Velero needs.
#
#   minio/minio-root                 -> MinIO server's own root user/password
#   velero/velero-minio-credentials  -> same creds in AWS credentials-file format
#                                       (the AWS plugin is what talks S3 to MinIO)
#
# Idempotent: re-running reuses the credentials already saved in .secrets/minio.env
# so you never accidentally rotate the creds out from under an existing backup
# repository. Pass --rotate to force new ones.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/.secrets"
ENV_FILE="${SECRETS_DIR}/minio.env"

VELERO_NS="${VELERO_NAMESPACE:-velero}"
MINIO_NS="${MINIO_NAMESPACE:-minio}"

ROTATE=0
[[ "${1:-}" == "--rotate" ]] && ROTATE=1

mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

# --- 1. Get or generate credentials -----------------------------------------
if [[ -f "${ENV_FILE}" && "${ROTATE}" -eq 0 ]]; then
  echo "==> Reusing existing credentials from ${ENV_FILE}"
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
else
  echo "==> Generating new MinIO credentials"
  # Alphanumeric only: avoids any quoting/URL-encoding trouble in the
  # AWS credentials file, mc aliases, and shell one-liners.
  # Read a bounded chunk of /dev/urandom rather than piping it into `head`,
  # which would SIGPIPE `tr` and trip `set -o pipefail`.
  rand_alnum() { # $1 = charset, $2 = length
    LC_ALL=C tr -dc "$1" <<<"$(head -c 4096 /dev/urandom | base64 -w0)" | cut -c "1-$2"
  }
  MINIO_ROOT_USER="velero-$(rand_alnum 'a-z0-9' 8)"
  MINIO_ROOT_PASSWORD="$(rand_alnum 'A-Za-z0-9' 40)"
  cat >"${ENV_FILE}" <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/gen-credentials.sh
# KEEP PRIVATE. This file is gitignored.
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
EOF
  chmod 600 "${ENV_FILE}"
fi

echo "    access key: ${MINIO_ROOT_USER}"
echo "    secret key: ${MINIO_ROOT_PASSWORD:0:4}...(${#MINIO_ROOT_PASSWORD} chars, see ${ENV_FILE})"

# --- 2. Namespaces ----------------------------------------------------------
# Created via apply, not `kubectl create`, so that manifests/minio.yaml can later
# apply the same Namespace without the "missing last-applied-configuration"
# warning that a bare `create` produces.
for ns in "${MINIO_NS}" "${VELERO_NS}"; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "    namespace ${ns} ready"
done

# --- 3. MinIO server root secret -------------------------------------------
echo "==> Secret ${MINIO_NS}/minio-root"
kubectl -n "${MINIO_NS}" create secret generic minio-root \
  --from-literal=MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  --from-literal=MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- 4. Velero's S3 credentials --------------------------------------------
# The velero-plugin-for-aws reads a standard AWS credentials file from the key
# named in the chart's `credentials.existingSecret` + BSL `credential` config.
echo "==> Secret ${VELERO_NS}/velero-minio-credentials"
kubectl -n "${VELERO_NS}" create secret generic velero-minio-credentials \
  --from-literal=cloud="[default]
aws_access_key_id=${MINIO_ROOT_USER}
aws_secret_access_key=${MINIO_ROOT_PASSWORD}
" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "==> Done. Credentials saved to ${ENV_FILE} (mode 600)."
