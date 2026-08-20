# Quick reference — one page

Everything you need day to day. If this page is enough, you do not need the rest.

---

## Install / rebuild

```bash
./scripts/install-all.sh          # storage → MinIO → Velero → test → UI  (~2 min)
```

## Uninstall

```bash
./scripts/uninstall-local.sh              # keep backups
./scripts/uninstall-local.sh --purge-data # delete backups too
./scripts/uninstall-local.sh --purge-all  # also remove the StorageClass
```

Before `--purge-all`, check nothing else uses the default StorageClass:
`kubectl get pvc -A | grep local-path`

## Back up

```bash
velero backup create NAME --include-namespaces NS --wait
velero backup create NAME --include-namespaces NS --ttl 720h --wait   # keep 30 days
velero backup get
```

## Restore

```bash
velero restore create --from-backup NAME --wait

# safest way to test — restore into a different namespace
velero restore create --from-backup NAME --namespace-mappings prod:prod-test --wait
```

## Schedule

```bash
velero schedule create daily --schedule="0 2 * * *" \
  --exclude-namespaces kube-system,velero,minio --ttl 336h
velero schedule get
```
Cron is **UTC**. `0 2 * * *` = 07:30 IST.

---

## THE ONE RULE

**A backup can say `Completed` and contain none of your data.**

Storage class decides it:

| Class | Velero can back up the data? |
|---|---|
| `local-path` *(the default)* | ❌ **NO — silently skipped** |
| `local-static` | ✅ yes |

So in any app whose data must survive:

```yaml
spec:
  storageClassName: local-static
```

**Check every backup this way** — the phase alone is not proof:

```bash
kubectl -n velero get podvolumebackups -l velero.io/backup-name=NAME
```
Zero rows = no volume data in that backup.

Quickest smell test — the `WARNINGS` column:

```bash
velero backup get
# WARNINGS 0 = good.  Non-zero = read the log before trusting it.
```

---

## Health check

```bash
kubectl -n velero get backupstoragelocation   # must say Available
kubectl -n velero get pods                    # 1 velero + 1 node-agent PER NODE
kubectl -n velero get podvolumebackups        # is volume data being captured?
kubectl -n velero logs deploy/velero --tail=50
```

## Test it actually works

```bash
./scripts/verify-backup-restore.sh   # ~2 min  — destroys + restores a namespace
./scripts/deep-test.sh               # ~10 min — 37 assertions, 255-file checksum
./scripts/audit-docs.sh              # ~1 min  — do the docs still match reality?
```

## Housekeeping

```bash
./scripts/recycle-local-pvs.sh       # after restores: return Released PVs to the pool
velero backup delete NAME --confirm  # NEVER `kubectl delete backup` — it orphans data
```

---

## Access

| | |
|---|---|
| Velero UI | `http://192.168.56.134:30902` — user `admin`, password in `.secrets/velero-ui.env` |
| MinIO console | `http://192.168.56.134:30901` — creds in `.secrets/minio.env` |
| MinIO S3 API | `http://192.168.56.134:30900` — anonymous `403` here is **correct** |

---

## When something is wrong

| Symptom | Most likely cause |
|---|---|
| `BackupStorageLocation` not `Available` | wrong keys, or bucket missing — `kubectl -n velero describe bsl default` |
| Backup `Completed` but volume empty | PVC is on `local-path` — move it to `local-static` |
| Restored PVC stuck `Pending` | static PV pool exhausted — `./scripts/recycle-local-pvs.sh` |
| `velero backup logs` fails, backup was fine | `publicUrl` missing on the BSL |
| Uninstall hangs on CRDs | Velero finalizers — the script handles it; don't delete CRDs by hand |
| Only one `node-agent` for two nodes | missing toleration — pods on the other node are unprotected |

---

## Going to a cloud cluster

Same chart, same commands. Only the target changes:

```bash
# 1. create the bucket yourself   2. create the Secret   3. fill in <PLACEHOLDERS>
helm upgrade --install velero vmware-tanzu/velero --version 12.1.0 \
  -n velero --create-namespace -f values/values-s3-generic.yaml --wait
```

Use `values-aws.yaml` / `values-gcp.yaml` / `values-azure.yaml` for those clouds.
On cloud, use CSI snapshots + `snapshotMoveData: true` instead of fs-backup, and
**label your VolumeSnapshotClass** or Velero silently skips snapshots:

```bash
kubectl label volumesnapshotclass NAME velero.io/csi-volumesnapshot-class=true
```

---

## Where to read more

| Need | Go to |
|---|---|
| Full step-by-step with expected output | `docs/00-walkthrough.md` |
| Why it is built this way / cluster constraints | `CLAUDE.md` |
| Cloud setup per provider | `docs/03-cloud-clusters.md` |
| Something is broken | `docs/05-troubleshooting.md` |
| Before trusting real data | `docs/06-production-notes.md` |
