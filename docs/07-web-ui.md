# 07 — Web UI

## There is no official Velero UI

Velero is CLI + CRDs by design. Upstream has never shipped a web interface, so
every UI is either a community project or a vendor product wrapping Velero.

| Option | Notes |
|---|---|
| **[otwld/velero-ui](https://github.com/otwld/velero-ui)** | **Installed here.** Most actively maintained, Apache-2.0, real Helm chart. Real-time dashboard for all Velero resources, OIDC (GitHub/GitLab/Google/Microsoft), Casbin RBAC policies |
| [seriohub/vui-ui](https://github.com/seriohub/vui-ui) | Multi-cluster support, notifications, cron-schedule heatmap |
| [mmohamed/velero-dashboard](https://github.com/mmohamed/velero-dashboard) | Deliberately minimal — backup/restore/schedule management only |
| `k9s` | Terminal UI; browses Velero CRDs like any resource. Workstation install |
| Headlamp / Lens | General K8s UIs; show Velero CRs as custom resources |
| CloudCasa, Kasten K10, OpenShift OADP, Tanzu Mission Control | Vendor products (K10 is not Velero-based) |

## What is deployed

| | |
|---|---|
| Chart | `otwld/velero-ui` **0.15.0** (app **0.10.2**) |
| Namespace | `velero-ui` |
| URL | **http://192.168.56.134:30902** (any node IP works) |
| Username | `admin` |
| Password | generated — `cat .secrets/velero-ui.env` |
| RBAC | scoped ClusterRole, **not** `cluster-admin` |

```bash
./scripts/gen-ui-credentials.sh          # generates creds + Secret
helm upgrade --install velero-ui otwld/velero-ui --version 0.15.0 \
  -n velero-ui --create-namespace -f values/values-velero-ui.yaml --wait
kubectl apply -f manifests/velero-ui-nodeport.yaml
```

## Two chart defaults that had to be fixed

### 1. `rbac.clusterAdministrator: true` — binds `cluster-admin`

The chart's default binds the built-in `cluster-admin` ClusterRole to the UI's
ServiceAccount. Combined with its other default of `admin`/`admin`, a stock
install hands **full cluster control to anyone who can reach the Service**.

Setting it `false` uses the chart's own purpose-built ClusterRole, which grants
only what the UI needs:

```yaml
rules:
  - nonResourceURLs: ['/readyz','/healthz','/livez','/version']   # get
  - apiGroups: [""]        resources: [namespaces]  verbs: [get, list]
  - apiGroups: ["velero.io"] resources: ["*"]       verbs: ["*"]
```

plus namespaced Roles for `pods`, `pods/log`, `secrets` and `configmaps` in the
`velero` namespace. Verify what it actually bound:

```bash
kubectl get clusterrolebinding velero-ui -o jsonpath='{.roleRef.name}{"\n"}'
# must print: velero-ui   (NOT cluster-admin)
```

> **Residual risk:** that scoped role still reads Secrets in the `velero`
> namespace, which include your object-storage credentials. That is inherent to
> displaying backup details — no RBAC setting removes it. Anyone with UI access
> can effectively read your S3 keys.

### 2. Default credentials, and a chart gap around the JWT secret

```
BASIC_AUTH_USERNAME=admin
BASIC_AUTH_PASSWORD=admin
AUTH_SECRET_PASSPHRASE="this is not a secret passphrase"
```

The passphrase signs session JWTs. Left at its published default, anyone can
**forge a valid session token and skip the login entirely** — so it matters as
much as the password.

**The chart cannot set it.** `configuration.general.secretPassPhrase.value`
creates a Secret that the Deployment never references, so the value has no
effect. That is why `values-velero-ui.yaml` sets
`secretPassPhrase.useSecret: false` (to avoid leaving a misleading Secret behind)
and injects both variables itself:

```yaml
env:
  - name: BASIC_AUTH_PASSWORD
    valueFrom:
      secretKeyRef: { name: velero-ui-auth, key: BASIC_AUTH_PASSWORD }
  - name: AUTH_SECRET_PASSPHRASE
    valueFrom:
      secretKeyRef: { name: velero-ui-auth, key: AUTH_SECRET_PASSPHRASE }
```

Confirm the pod reads from the Secret rather than a literal:

```bash
kubectl -n velero-ui get deploy velero-ui \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{" "}{.valueFrom.secretKeyRef.name}{"\n"}{end}'
```

## Verified working

```
login with generated password    → 200, JWT issued
login with admin/admin           → rejected
GET /api/backups                 → 2      (CLI: 2)  ✓
GET /api/restores                → 2      (CLI: 2)  ✓
GET /api/backup-storage-locations→ 1      (CLI: 1)  ✓
GET /api/pod-volume-backups      → 2                ✓
GET /api/stats                   → {"totalBackups":2,"totalSchedules":0,
                                    "totalRestores":2,"totalStorageLocations":1}
```

Quirk worth knowing: a wrong password returns **HTTP 500**, not `401`. It is
rejected correctly, the status code is just wrong.

## Rotating the password

```bash
./scripts/gen-ui-credentials.sh --rotate
kubectl -n velero-ui rollout restart deploy/velero-ui
```

## What the UI will not tell you

The UI shows Velero's own resources faithfully, but it inherits Velero's
blind spot: **a backup that silently skipped your volume data still displays as
`Completed`**. The `hostPath` trap in
[`05-troubleshooting.md`](05-troubleshooting.md) is invisible in any dashboard —
it only appears in `velero backup logs` and in the PodVolumeBackup count.

Keep using `./scripts/verify-backup-restore.sh`. A dashboard showing green is not
evidence your data is recoverable.

## Before exposing this anywhere real

- [ ] **It is plain HTTP.** The password and every JWT cross the network in the
      clear. Use the `ingress` block in `values/values-velero-ui.yaml` with TLS
      and delete `manifests/velero-ui-nodeport.yaml`.
- [ ] Remove or firewall NodePort `30902`.
- [ ] Switch to OIDC (`OIDC_CLIENT_ID` etc.) instead of basic auth, so access
      follows your identity provider and can be revoked centrally.
- [ ] Enable `configuration.policies` for per-user/group permissions if more than
      one person gets access — otherwise everyone is a full admin who can delete
      every backup.
- [ ] Remember that UI access ≈ read access to the `velero` namespace's Secrets.

## Removing it

```bash
helm -n velero-ui uninstall velero-ui
kubectl delete -f manifests/velero-ui-nodeport.yaml --ignore-not-found
kubectl delete ns velero-ui
```

`./scripts/uninstall-local.sh` does this too.

## The monitoring alternative

A UI shows you state; it does not page you when a schedule silently stops firing.
Velero's metrics endpoint is live on `:8085` and the Service is already annotated
for Prometheus scraping:

```
velero_backup_success_total{schedule=""} 3
velero_backup_total 2
velero_backup_last_successful_timestamp{schedule=""} 1.786735859e+09
```

If you reinstall Prometheus + Grafana, set `configuration.general.grafanaUrl` in
`values-velero-ui.yaml` and the UI will link straight to your dashboard. The
alert that matters most is on `velero_backup_last_successful_timestamp` going
**stale** — see [`04-operations.md`](04-operations.md).
