#!/usr/bin/env bash
# =============================================================================
# Checks that the documentation still matches reality.
#
# Docs rot silently: a chart bump, a changed port, a renamed StorageClass, and
# suddenly the walkthrough tells you to do something that no longer works. This
# script asserts every concrete claim the docs make against (a) the files in this
# repo and (b) the live cluster, and exits non-zero on any mismatch.
#
# Run it after any version bump, values change, or cluster change.
#
#   ./scripts/audit-docs.sh              # full audit (needs a live cluster)
#   ./scripts/audit-docs.sh --static     # files only, no cluster required
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

STATIC_ONLY=0
[[ "${1:-}" == "--static" ]] && STATIC_ONLY=1

PASS=0; FAIL=0
section() { printf '\n\033[1;36m══ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[1;32m✅\033[0m %-44s %s\n' "$1" "${2:-}"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m❌\033[0m %-44s expected=%s actual=%s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }
chk()  { [[ "$2" == "$3" ]] && ok "$1" "$2" || bad "$1" "$3" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── the single source of truth for versions ─────────────────────────────────
# If you bump a version, change it HERE and in the files; the audit then proves
# the docs were updated too.
VELERO_CHART="12.1.0"
VELERO_APP="v1.18.1"
AWS_PLUGIN="v1.14.2"
UI_CHART="0.15.0"
UI_APP="0.10.2"
MINIO_IMG="quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z"
MC_IMG="quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z"
LPP_IMG="docker.io/rancher/local-path-provisioner:v0.0.37"

# =============================================================================
section "1. Files exist and are non-empty"
for f in README.md CLAUDE.md QUICKREF.md .gitignore \
         docs/00-walkthrough.md docs/01-architecture.md docs/02-local-cluster.md \
         docs/03-cloud-clusters.md docs/04-operations.md docs/05-troubleshooting.md \
         docs/06-production-notes.md docs/07-web-ui.md \
         values/values-local.yaml values/values-s3-generic.yaml values/values-aws.yaml \
         values/values-gcp.yaml values/values-azure.yaml values/values-velero-ui.yaml \
         manifests/local-path-provisioner.yaml manifests/local-static-storage.yaml \
         manifests/minio.yaml manifests/velero-ui-nodeport.yaml demo/demo-app.yaml \
         scripts/install-all.sh scripts/install-local.sh scripts/install-ui.sh \
         scripts/gen-credentials.sh scripts/gen-ui-credentials.sh \
         docs/08-deep-test.md \
         scripts/verify-backup-restore.sh scripts/recycle-local-pvs.sh \
         scripts/deep-test.sh scripts/uninstall-local.sh scripts/audit-docs.sh; do
  [[ -s "$f" ]] && ok "$f" "$(wc -l <"$f") lines" || bad "$f" "present" "MISSING/EMPTY"
done

# =============================================================================
section "2. Scripts are executable and syntactically valid"
for f in scripts/*.sh; do
  [[ -x "$f" ]] || bad "$(basename "$f") executable" "yes" "no"
  bash -n "$f" 2>/dev/null && ok "$(basename "$f") syntax" "ok" \
                           || bad "$(basename "$f") syntax" "valid" "SYNTAX ERROR"
done

# =============================================================================
section "3. Pinned versions in files match this script's source of truth"
chk "velero chart in install-local.sh" \
    "$(grep -oE 'CHART_VERSION:-[0-9.]+' scripts/install-local.sh | cut -d- -f2)" "${VELERO_CHART}"
chk "ui chart in install-ui.sh" \
    "$(grep -oE 'UI_CHART_VERSION:-[0-9.]+' scripts/install-ui.sh | cut -d- -f2)" "${UI_CHART}"
chk "velero image tag in values-local" \
    "$(grep -oE 'tag: v[0-9.]+' values/values-local.yaml | head -1 | awk '{print $2}')" "${VELERO_APP}"
chk "aws plugin in values-local" \
    "$(grep -oE 'velero-plugin-for-aws:v[0-9.]+' values/values-local.yaml | head -1 | cut -d: -f2)" "${AWS_PLUGIN}"
chk "minio image in manifest" \
    "$(grep -oE 'quay\.io/minio/minio:[A-Za-z0-9.T-]+' manifests/minio.yaml | head -1)" "${MINIO_IMG}"
chk "mc image in manifest" \
    "$(grep -oE 'quay\.io/minio/mc:[A-Za-z0-9.T-]+' manifests/minio.yaml | head -1)" "${MC_IMG}"
chk "local-path image in manifest" \
    "$(grep -oE 'docker\.io/rancher/local-path-provisioner:v[0-9.]+' manifests/local-path-provisioner.yaml | head -1)" "${LPP_IMG}"

n=$(grep -rhoE 'image: [^ ]+:latest' manifests/ values/ demo/ 2>/dev/null | wc -l)
chk "no ':latest' image tags anywhere" "$n" "0"

# =============================================================================
section "4. Docs reference only things that exist"
for c in install-all install-local install-ui gen-credentials gen-ui-credentials \
         verify-backup-restore deep-test recycle-local-pvs uninstall-local; do
  if grep -rql "${c}.sh" README.md CLAUDE.md docs/*.md 2>/dev/null; then
    [[ -f "scripts/${c}.sh" ]] && ok "docs cite scripts/${c}.sh" "exists" \
                              || bad "docs cite scripts/${c}.sh" "exists" "MISSING"
  fi
done
for p in $(grep -hoE '\-f [a-z]+/[A-Za-z0-9._-]+\.yaml' scripts/*.sh | awk '{print $2}' | sort -u); do
  [[ -f "$p" ]] && ok "script applies $p" "exists" || bad "script applies $p" "exists" "MISSING"
done
for fl in --purge-data --purge-all --no-verify --no-ui --rotate --dry-run; do
  grep -rqL -- "$fl" scripts/*.sh >/dev/null 2>&1
  if grep -rq -- "$fl" README.md CLAUDE.md docs/*.md 2>/dev/null; then
    grep -rq -- "$fl" scripts/*.sh 2>/dev/null && ok "docs claim flag $fl" "implemented" \
                                              || bad "docs claim flag $fl" "implemented" "NOT IMPLEMENTED"
  fi
done

# =============================================================================
section "5. Stale version strings (must be none)"
# This file necessarily *contains* the stale strings it looks for, so it must
# exclude itself — otherwise every check self-matches and reports a false
# failure. (That happened on the first run.)
STALE=0
SEARCH_FILES=(README.md CLAUDE.md docs/*.md values/*.yaml manifests/*.yaml demo/*.yaml)
for s in scripts/*.sh; do
  [[ "$(basename "$s")" == "audit-docs.sh" ]] && continue
  SEARCH_FILES+=("$s")
done
for bad_v in 12.0.0 12.0.1 12.0.2 12.0.3 11.4.0 v1.13.1 v1.13.2 v0.0.33 0.14.0 0.13.3; do
  hit="$(grep -rln "$bad_v" "${SEARCH_FILES[@]}" 2>/dev/null | head -3 | tr '\n' ' ')"
  if [[ -n "$hit" ]]; then
    bad "stale reference '$bad_v'" "absent" "found in: ${hit}"
    STALE=1
  fi
done
[[ "$STALE" -eq 0 ]] && ok "no stale version references" "clean"

# =============================================================================
section "6. Every values file still renders against its chart"
if have helm; then
  helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1
  helm repo add otwld        https://helm.otwld.com/                    >/dev/null 2>&1
  helm repo update vmware-tanzu otwld >/dev/null 2>&1
  for f in values/*.yaml; do
    if [[ "$f" == *velero-ui* ]]; then ref="otwld/velero-ui --version ${UI_CHART}"
    else ref="vmware-tanzu/velero --version ${VELERO_CHART}"; fi
    # shellcheck disable=SC2086
    if helm template audit $ref -n audit -f "$f" >/dev/null 2>&1; then
      ok "$(basename "$f") renders" "ok"
    else
      bad "$(basename "$f") renders" "ok" "TEMPLATE FAILED"
    fi
  done
else
  echo "  (helm not found — skipped)"
fi

# =============================================================================
if [[ "${STATIC_ONLY}" -eq 1 ]]; then
  printf '\n\033[1;35m── STATIC AUDIT: %s passed, %s failed ──\033[0m\n' "${PASS}" "${FAIL}"
  [[ "${FAIL}" -eq 0 ]] || exit 1
  exit 0
fi

# =============================================================================
section "7. LIVE CLUSTER: versions match the docs"
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "  cluster unreachable — run with --static to skip live checks"
  exit 1
fi
if ! kubectl -n velero get deploy velero >/dev/null 2>&1; then
  echo "  Velero is not installed. Run ./scripts/install-all.sh first,"
  echo "  or use --static to audit the files only."
  printf '\n\033[1;35m── PARTIAL AUDIT: %s passed, %s failed ──\033[0m\n' "${PASS}" "${FAIL}"
  [[ "${FAIL}" -eq 0 ]] || exit 1
  exit 0
fi

hchart() { helm -n "$1" list -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["chart"])' 2>/dev/null; }
happ()   { helm -n "$1" list -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["app_version"])' 2>/dev/null; }

chk "deployed velero chart"    "$(hchart velero)"    "velero-${VELERO_CHART}"
chk "deployed velero app"      "$(happ velero)"      "${VELERO_APP#v}"
chk "deployed ui chart"        "$(hchart velero-ui)" "velero-ui-${UI_CHART}"
chk "deployed ui app"          "$(happ velero-ui)"   "${UI_APP}"
chk "velero container image"   "$(kubectl -n velero get deploy velero -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" "velero/velero:${VELERO_APP}"
chk "aws plugin initContainer" "$(kubectl -n velero get deploy velero -o jsonpath='{.spec.template.spec.initContainers[0].image}' 2>/dev/null)" "velero/velero-plugin-for-aws:${AWS_PLUGIN}"
chk "minio image"              "$(kubectl -n minio get deploy minio -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" "${MINIO_IMG}"
chk "local-path image"         "$(kubectl -n local-path-storage get deploy local-path-provisioner -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" "${LPP_IMG}"
have velero && chk "velero CLI version" "$(velero version --client-only 2>/dev/null | grep -oE 'v1\.[0-9.]+' | head -1)" "${VELERO_APP}"

# =============================================================================
section "8. LIVE: BackupStorageLocation matches documented config"
BSL="$(kubectl -n velero get backupstoragelocation default -o json 2>/dev/null)"
bslget() { echo "${BSL}" | python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
chk "BSL phase"             "$(bslget 'd["status"]["phase"]')" "Available"
chk "BSL bucket"            "$(bslget 'd["spec"]["objectStorage"]["bucket"]')" "velero"
chk "BSL region"            "$(bslget 'd["spec"]["config"]["region"]')" "minio"
chk "BSL s3ForcePathStyle"  "$(bslget 'd["spec"]["config"]["s3ForcePathStyle"]')" "true"
chk "BSL s3Url"             "$(bslget 'd["spec"]["config"]["s3Url"]')" "http://minio.minio.svc.cluster.local:9000"
chk "BSL publicUrl set"     "$(bslget 'd["spec"]["config"].get("publicUrl","") != ""')" "True"
chk "BSL credential secret" "$(bslget 'd["spec"]["credential"]["name"]')" "velero-minio-credentials"

# =============================================================================
section "9. LIVE: server flags the docs promise"
ARGS="$(kubectl -n velero get deploy velero -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null)"
for f in --uploader-type=kopia --default-volumes-to-fs-backup --default-backup-ttl=168h; do
  grep -q -- "$f" <<<"${ARGS}" && ok "server flag $f" "present" \
                               || bad "server flag $f" "present" "MISSING"
done
chk "VolumeSnapshotLocations (snapshotsEnabled:false)" \
    "$(kubectl -n velero get volumesnapshotlocations --no-headers 2>/dev/null | wc -l)" "0"

# =============================================================================
section "10. LIVE: node-agent covers every node"
NODES="$(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
chk "node-agent pods == node count" \
    "$(kubectl -n velero get pods -l name=node-agent --no-headers 2>/dev/null | wc -l)" "${NODES}"
kubectl -n velero get ds node-agent -o jsonpath='{.spec.template.spec.tolerations}' 2>/dev/null \
  | grep -q control-plane && ok "control-plane toleration" "present" \
                          || bad "control-plane toleration" "present" "MISSING"

# =============================================================================
section "11. LIVE: storage classes, PV pool, node ports"
chk "storage classes" \
    "$(kubectl get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ',' | sed 's/,$//')" \
    "local-path,local-path-retain,local-static"
chk "default storage class" \
    "$(kubectl get sc -o json 2>/dev/null | python3 -c 'import sys,json;print(next(i["metadata"]["name"] for i in json.load(sys.stdin)["items"] if i["metadata"].get("annotations",{}).get("storageclass.kubernetes.io/is-default-class")=="true"))' 2>/dev/null)" \
    "local-path"
chk "local-static PV pool size" \
    "$(kubectl get pv -l velero.io/pv-pool=local-static --no-headers 2>/dev/null | wc -l)" "4"
chk "MinIO PVC storage class" \
    "$(kubectl -n minio get pvc minio-data -o jsonpath='{.spec.storageClassName}' 2>/dev/null)" "local-path-retain"
chk "MinIO S3 nodePort"      "$(kubectl -n minio get svc minio-nodeport -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)" "30900"
chk "MinIO console nodePort" "$(kubectl -n minio get svc minio-nodeport -o jsonpath='{.spec.ports[1].nodePort}' 2>/dev/null)" "30901"
chk "velero metrics port"    "$(kubectl -n velero get svc velero -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)" "8085"

# =============================================================================
section "12. LIVE: web UI security claims"
if kubectl -n velero-ui get deploy velero-ui >/dev/null 2>&1; then
  BOUND="$(kubectl get clusterrolebinding velero-ui -o jsonpath='{.roleRef.name}' 2>/dev/null)"
  if [[ "${BOUND}" == "cluster-admin" ]]; then
    bad "UI NOT bound to cluster-admin" "velero-ui" "cluster-admin  ← DANGEROUS"
  else
    ok "UI NOT bound to cluster-admin" "${BOUND}"
  fi
  chk "UI nodePort" "$(kubectl -n velero-ui get svc velero-ui-nodeport -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)" "30902"
  for v in BASIC_AUTH_PASSWORD AUTH_SECRET_PASSPHRASE; do
    src="$(kubectl -n velero-ui get deploy velero-ui -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='${v}')].valueFrom.secretKeyRef.name}" 2>/dev/null)"
    chk "UI ${v} from Secret" "${src}" "velero-ui-auth"
  done
else
  echo "  (velero-ui not installed — skipped)"
fi

# =============================================================================
printf '\n\033[1;35m════ AUDIT RESULT: %s passed, %s failed ════\033[0m\n' "${PASS}" "${FAIL}"
if [[ "${FAIL}" -eq 0 ]]; then
  echo "Documentation matches reality."
  exit 0
else
  echo "MISMATCH: update the docs (or the config) so they agree, then re-run."
  exit 1
fi
