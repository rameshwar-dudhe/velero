# 05 — Troubleshooting

Real failures, in the order you are likely to hit them. Every symptom here was
either encountered while building this or is a known trap.

## Backup says `Completed` but the volume is empty

**The most dangerous failure Velero has, because it looks like success.**

Symptom: restore produces a healthy running pod with nothing in its volume.

Diagnose:

```bash
# ZERO PodVolumeBackups = no volume data in that backup, full stop.
kubectl -n velero get podvolumebackups -l velero.io/backup-name=<BACKUP>

velero backup logs <BACKUP> | grep -iE "skipping|hostpath|warn"
```

**Cheapest early signal:** the `WARNINGS` column of `velero backup get`. The
skipped-volume backup carried a warning while the healthy ones did not — the
phase was `Completed` in both cases.

```
NAME            STATUS      ERRORS   WARNINGS
demo-backup-1   Completed   0        1          ← volume silently skipped
demo-backup-2   Completed   0        0          ← volume actually backed up
```

Treat any non-zero `WARNINGS` as "read the log before trusting this backup".

### Cause 1 — hostPath PV (hit on this cluster)

```
level=warning msg="Volume data in pod velero-demo/demo-app-… is a hostPath
volume which is not supported for pod volume backup, skipping"
```

Velero's fs-backup refuses `hostPath` volumes, and `local-path-provisioner`
produces exactly those. Check:

```bash
kubectl get pv $(kubectl -n <ns> get pvc <pvc> -o jsonpath='{.spec.volumeName}') \
  -o jsonpath='{.spec.hostPath}{"\n"}{.spec.local}{"\n"}'
```

Non-empty `hostPath` → not backupable. **Fix:** move the PVC to the
`local-static` StorageClass (`local`-type PVs, which Velero accepts). See
[`02-local-cluster.md`](02-local-cluster.md).

### Cause 2 — node-agent not running on that pod's node

```bash
kubectl -n velero get pods -l name=node-agent -o wide   # one per node?
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints[*].key'
```

A tainted node without a matching toleration gets no agent, and every pod on it
loses its volume data silently. Fix with `nodeAgent.tolerations` (already set
here for the control-plane taint).

### Cause 3 — no volume backup method selected at all

`snapshotsEnabled: false` **and** `defaultVolumesToFsBackup: false` **and** no
pod annotation → only PVC/PV objects are backed up. Either set
`defaultVolumesToFsBackup: true` or annotate the pod:

```yaml
annotations:
  backup.velero.io/backup-volumes: data,uploads
```

### Cause 4 — CSI enabled but the VolumeSnapshotClass is unlabelled

```bash
kubectl label volumesnapshotclass <name> velero.io/csi-volumesnapshot-class=true
```

Velero ignores unlabelled classes and silently takes no snapshot.

## BackupStorageLocation is `Unavailable`

```bash
kubectl -n velero get backupstoragelocation
kubectl -n velero describe backupstoragelocation default
kubectl -n velero logs deploy/velero | grep -iE "backupstoragelocation|error"
```

| Message | Cause | Fix |
|---|---|---|
| `NoSuchBucket` | Bucket missing, or path-style not set | Create it; set `s3ForcePathStyle: "true"` for non-AWS |
| `InvalidAccessKeyId` / `SignatureDoesNotMatch` | Wrong keys, or secret not reloaded | Recreate the Secret, then `kubectl -n velero rollout restart deploy/velero` |
| `dial tcp … connection refused` | `s3Url` unreachable from the pod | See DNS check below |
| `x509: certificate signed by unknown authority` | Private CA | Set `caCert` (base64 PEM) on the BSL |
| `RequestTimeTooSkewed` | Node clock drift | Fix NTP on the nodes |

Test connectivity from inside the cluster:

```bash
kubectl -n velero run neta --rm -it --restart=Never --image=busybox:1.37 \
  -- sh -c 'nslookup minio.minio.svc.cluster.local; wget -qO- \
     http://minio.minio.svc.cluster.local:9000/minio/health/live && echo OK'
```

Verify the secret Velero actually holds:

```bash
kubectl -n velero get secret velero-minio-credentials -o jsonpath='{.data.cloud}' | base64 -d
kubectl -n minio get secret minio-root -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d; echo
```

Those two must agree.

## `velero backup logs` / `describe --details` fails, though the backup succeeded

```
error getting backup resource list: … dial tcp: lookup
minio.minio.svc.cluster.local on 127.0.0.53:53: server misbehaving
```

**Encountered here.** The CLI reads directly from object storage, and your
workstation cannot resolve cluster DNS. The backup itself is fine.

Fix — add a workstation-reachable URL to the BSL:

```yaml
config:
  s3Url:     http://minio.minio.svc.cluster.local:9000   # in-cluster
  publicUrl: http://192.168.56.134:30900                 # workstation
```

```bash
helm upgrade velero vmware-tanzu/velero --version 12.1.0 \
  -n velero -f values/values-local.yaml --wait
```

Or port-forward: `kubectl -n minio port-forward svc/minio 9000:9000` with
`publicUrl: http://localhost:9000`.

## Restored PVC stuck `Pending` forever

```bash
kubectl -n <ns> describe pvc <pvc> | tail -20
kubectl get pv -l velero.io/pv-pool=local-static \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name'
```

On this cluster the usual cause is **the static PV pool is exhausted**. A restore
needs a *free* PV; the original stays `Released` and never rebinds.

```bash
./scripts/recycle-local-pvs.sh
```

Other causes: the backup's `storageClassName` does not exist on this cluster (use
`--storage-class-mappings old:new`), or no node satisfies the PV's node affinity.

## Backup stuck `InProgress`

```bash
kubectl -n velero get backup <NAME> -o jsonpath='{.status}' | python3 -m json.tool
kubectl -n velero get podvolumebackups
kubectl -n velero logs -l name=node-agent --tail=100
```

Common causes:

- **node-agent OOMKilled** — Kopia is memory-hungry on large volumes.
  `kubectl -n velero get pods -l name=node-agent` showing restarts confirms it.
  Raise `nodeAgent.resources.limits.memory`.
- **Object store slow or full** — `kubectl -n minio exec deploy/minio -- df -h /data`.
- **Huge volume, many small files** — genuinely slow; raise
  `configuration.fsBackupTimeout` (default `4h`).

Cancel a stuck backup:

```bash
kubectl -n velero patch backup <NAME> --type=merge -p '{"status":{"phase":"Failed"}}'
```

## node-agent crash-looping

```bash
kubectl -n velero logs -l name=node-agent --previous --tail=50
kubectl -n velero describe pod -l name=node-agent | tail -30
```

| Cause | Fix |
|---|---|
| Wrong `podVolumePath` | Must match the kubelet root; `/var/lib/kubelet/pods` for kubeadm |
| PodSecurity blocks host mounts | Label the namespace `pod-security.kubernetes.io/enforce=privileged` |
| OpenShift SCC | `oc adm policy add-scc-to-user privileged -z velero -n velero` |
| GKE Autopilot | Host mounts are forbidden; fs-backup is impossible — use CSI snapshots |
| OOMKilled | Raise memory limits |

## Restore `PartiallyFailed`

```bash
velero restore logs <RESTORE> | grep -iE "error|warn" | head -40
```

Usually benign and expected:

- `already exists` — the resource was present; Velero skips rather than
  overwrites. Delete the namespace first, or restore into a new one.
- Admission webhooks rejecting restored objects — the webhook's own backing
  service may not be up yet. Restore its namespace first, then retry.
- Cluster-scoped resources missing — add `--include-cluster-resources=true` at
  backup time.

## Helm install fails on values validation

The chart ships a `values.schema.json`, so **unknown keys hard-fail**. Hit while
building this (`nodeAgent.privileged` is not a real key).

```bash
# Catch it before touching the cluster
helm template velero vmware-tanzu/velero --version 12.1.0 \
  -n velero -f values/values-local.yaml >/dev/null && echo OK

# See the authoritative key list
helm show values vmware-tanzu/velero --version 12.1.0 | less
```

## PVCs `Pending` with `no persistent volumes available`

```bash
kubectl get sc          # is there a (default) StorageClass at all?
```

This cluster originally had **none**, which is why every PVC hung. Fixed by
`manifests/local-path-provisioner.yaml`.

## MinIO `mc` fails with `mkdir /.mc: permission denied`

Hit while building the bucket-creation Job. The `mc` image ships `HOME=/`, which
a non-root UID cannot write.

```yaml
env:
  - name: HOME
    value: /tmp
  - name: MC_CONFIG_DIR
    value: /tmp/.mc
volumeMounts:
  - name: mc-config
    mountPath: /tmp        # emptyDir
```

## Uninstall hangs forever on deleting the CRDs

Hit during a real teardown here. `kubectl delete crd ... --wait` never returns.

```bash
kubectl get crd | grep velero.io
```

```
restores.velero.io    2026-08-14T19:16:06Z    ← Terminating, forever
```

**Why.** Velero puts finalizers on its own objects
(`restores.velero.io/external-resources-finalizer`). Only the Velero controller
clears them, and `helm uninstall` removed it. Deleting the CRD makes Kubernetes
add `customresourcecleanup.apiextensions.k8s.io` and try to delete every
`Restore` first — but those still carry the Velero finalizer that nothing can now
remove. Deadlock.

Confirm it:

```bash
kubectl get restores.velero.io -A -o json | python3 -c '
import sys,json
for i in json.load(sys.stdin)["items"]:
    m=i["metadata"]
    print(m["namespace"]+"/"+m["name"], m.get("finalizers"), bool(m.get("deletionTimestamp")))'
```

**Fix** — clear the finalizers; the CRD deletion then completes on its own:

```bash
kubectl -n velero patch restore.velero.io <name> \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```

Do this for any Velero kind that is stuck (`restores`, `backups`,
`podvolumebackups`, `backuprepositories`, …).

**Prevention.** Always strip finalizers *before* deleting CRDs.
`scripts/uninstall-local.sh` does this for every Velero resource type and uses
`--wait=false` with a bounded timeout, so it cannot hang.

## `audit-docs.sh` reports stale versions that are not actually there

Hit on that script's first run: it reported 10 stale version strings, all false.

**Why.** The audit greps the repo for a list of superseded version strings — and
the script *itself* holds that list, so grepping `scripts/*.sh` matched itself
every time.

> Note: this page deliberately does **not** quote those literal version strings.
> Writing them here would make the audit flag this very document — which is
> exactly what happened when this section was first drafted.

**Fix, already applied:** the search list excludes `audit-docs.sh`. If you add
another self-referential check, exclude the file the same way:

```bash
SEARCH_FILES=(README.md CLAUDE.md docs/*.md values/*.yaml manifests/*.yaml demo/*.yaml)
for s in scripts/*.sh; do
  [[ "$(basename "$s")" == "audit-docs.sh" ]] && continue
  SEARCH_FILES+=("$s")
done
```

The general lesson: a checker that scans the repo will scan itself. Verify a
"failure" is real before changing anything the checker complains about.

## Everything-is-broken diagnostic sweep

```bash
echo "── pods ──";      kubectl -n velero get pods -o wide
echo "── BSL ──";       kubectl -n velero get backupstoragelocation
echo "── backups ──";   kubectl -n velero get backups
echo "── PVBs ──";      kubectl -n velero get podvolumebackups
echo "── repos ──";     kubectl -n velero get backuprepositories
echo "── storage ──";   kubectl get sc && kubectl get pv
echo "── velero log ──";     kubectl -n velero logs deploy/velero --tail=50
echo "── node-agent log ──"; kubectl -n velero logs -l name=node-agent --tail=50
echo "── minio ──";     kubectl -n minio get pods,pvc
echo "── events ──";    kubectl -n velero get events --sort-by=.lastTimestamp | tail -20
```

## Raising the log level

```bash
helm upgrade velero vmware-tanzu/velero --version 12.1.0 -n velero \
  -f values/values-local.yaml --set configuration.logLevel=debug --wait
```

Revert afterwards — `debug` is extremely verbose.
