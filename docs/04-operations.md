# 04 — Operations runbook

Backup, restore, schedules, retention, and full-cluster disaster recovery.

## Backups

```bash
# A namespace
velero backup create app1-$(date -u +%Y%m%d) --include-namespaces app1 --wait

# Several, with explicit retention
velero backup create nightly --include-namespaces app1,app2 --ttl 720h --wait

# Everything except the noise
velero backup create full \
  --exclude-namespaces kube-system,velero,minio,local-path-storage --wait

# By label instead of namespace
velero backup create tier1 --selector 'backup-tier=critical' --wait

# Objects only, skip all volume data (fast, for config snapshots)
velero backup create objects-only --include-namespaces app1 \
  --snapshot-volumes=false --default-volumes-to-fs-backup=false --wait

# Specific resource types
velero backup create cfg --include-resources configmaps,secrets --wait
```

Always exclude the namespace holding your object store (`minio` here) — backing
the backup target up into itself is pure waste.

### Confirming a backup is real

`Completed` is not proof. Check all three:

```bash
# 1. phase
velero backup get

# 2. volume data actually captured — ZERO here means no volume data exists
kubectl -n velero get podvolumebackups -l velero.io/backup-name=<BACKUP>

# 3. what was and was not included
velero backup describe <BACKUP> --details | sed -n '/Backup Volumes/,$p'
velero backup logs <BACKUP> | grep -iE "warn|error|skipping"
```

A `PartiallyFailed` backup is usable but incomplete — read the log before
trusting it.

## Restores

```bash
# Straight restore (into the original namespace)
velero restore create --from-backup <BACKUP> --wait

# Into a different namespace — the safe way to test a restore
velero restore create clone-test --from-backup <BACKUP> \
  --namespace-mappings prod:prod-restore-test --wait

# Only some resources
velero restore create --from-backup <BACKUP> \
  --include-resources configmaps,secrets --wait

# Single namespace out of a bigger backup
velero restore create --from-backup full --include-namespaces app1 --wait

# Map StorageClasses when moving between clusters
velero restore create --from-backup <BACKUP> \
  --storage-class-mappings local-path:local-static --wait

# Inspect
velero restore describe <RESTORE> --details
velero restore logs <RESTORE>
```

### Restore behaviour worth knowing

- **Existing resources are skipped, not overwritten** by default. Restoring over
  a live namespace mostly does nothing. Delete first, or restore into a new
  namespace.
- **Restored pods gain a `restore-wait` initContainer** while node-agent
  repopulates volumes. Use `kubectl exec <pod> -c <container>` to avoid the
  `Defaulted container` notice.
- **On this local cluster a restore consumes a static PV.** The old PV goes
  `Released` and never rebinds. Run `./scripts/recycle-local-pvs.sh` afterwards.
- **Service `clusterIP` is stripped and reassigned**, so restored Services get
  new IPs. Anything hardcoding an IP will break; use DNS names.

## Schedules

Either declare them in the values file (version-controlled — preferred):

```yaml
schedules:
  daily-full:
    disabled: false
    schedule: "0 2 * * *"
    template:
      ttl: "336h"                # 14 days
      storageLocation: default
      defaultVolumesToFsBackup: true
      excludedNamespaces:
        - kube-system
        - velero
        - minio
        - local-path-storage
```

```bash
helm upgrade velero vmware-tanzu/velero --version 12.1.0 \
  -n velero -f values/values-local.yaml --wait
```

Or imperatively:

```bash
velero schedule create daily --schedule="0 2 * * *" \
  --exclude-namespaces kube-system,velero,minio --ttl 336h

velero schedule get
velero schedule pause daily
velero schedule unpause daily
velero backup create --from-schedule daily     # run one immediately
velero schedule delete daily --confirm
```

Cron runs in the **Velero pod's timezone (UTC)**. `0 2 * * *` is 02:00 UTC —
07:30 IST. Adjust, or set a `TZ` env var via `configuration.extraEnvVars`.

### A sane starting policy

| Schedule | Cron | TTL | Covers |
|---|---|---|---|
| `hourly-critical` | `0 * * * *` | `168h` (7d) | Databases, anything with a tight RPO |
| `daily-full` | `0 2 * * *` | `336h` (14d) | All app namespaces |
| `weekly-archive` | `0 3 * * 0` | `2160h` (90d) | Long-term retention |

## Retention

Retention is **per-backup TTL**, not a global policy. Velero's GC controller
deletes expired backups hourly.

```bash
# What expires when
kubectl -n velero get backups \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,EXPIRES:.status.expiration'

# Change retention on an existing backup
kubectl -n velero patch backup <NAME> --type=merge -p '{"spec":{"ttl":"720h"}}'

# Delete a backup AND its data in object storage
velero backup delete <NAME> --confirm
```

> Never delete a Backup CR with `kubectl delete backup`. That orphans the data in
> the bucket, which then occupies space forever with nothing referencing it.
> Always use `velero backup delete`.

Kopia is deduplicated and incremental, so a daily schedule costs far less than
`days × volume size`. A maintenance job prunes unreferenced blobs
(`defaultRepoMaintainFrequency: 24h`).

## Application-consistent backups

A database copied mid-write restores as a crashed database. Use hooks to quiesce.

PostgreSQL example:

```yaml
metadata:
  annotations:
    pre.hook.backup.velero.io/command: '["/bin/sh","-c","psql -U postgres -c \"SELECT pg_backup_start(''velero'');\""]'
    pre.hook.backup.velero.io/timeout: "5m"
    post.hook.backup.velero.io/command: '["/bin/sh","-c","psql -U postgres -c \"SELECT pg_backup_stop();\""]'
```

MySQL, using a lock held for the duration:

```yaml
    pre.hook.backup.velero.io/command: '["/bin/sh","-c","mysql -e \"FLUSH TABLES WITH READ LOCK; SYSTEM sleep 30;\" &"]'
```

Often simpler and more reliable: have a pre-hook run `pg_dump`/`mysqldump` to a
file on the backed-up PVC, and restore from that dump.

Restore hooks work too:

```yaml
    post.hook.restore.velero.io/command: '["/bin/sh","-c","/scripts/reindex.sh"]'
```

## Monitoring

Velero exposes Prometheus metrics on `:8085`, and the Service is annotated for
scraping. Worth alerting on:

| Metric | Alert when |
|---|---|
| `velero_backup_failure_total` | increases |
| `velero_backup_partial_failure_total` | increases |
| `velero_backup_last_successful_timestamp` | older than your schedule interval × 2 |
| `velero_volume_snapshot_failure_total` | increases |
| `velero_backup_deletion_failure_total` | increases |

The most valuable alert is on **`velero_backup_last_successful_timestamp` going
stale** — it catches a silently broken schedule, which no failure counter will.

```promql
time() - velero_backup_last_successful_timestamp{schedule="daily-full"} > 172800
```

If you run the Prometheus Operator, set `metrics.serviceMonitor.enabled: true`
(off here because this cluster runs the plain prometheus chart, so the
`ServiceMonitor` CRD does not exist).

## Disaster recovery: rebuild onto a fresh cluster

The scenario Velero exists for.

```bash
# 1. New cluster. Recreate storage prerequisites first — StorageClass names
#    referenced by your PVCs must exist, or use --storage-class-mappings.
kubectl apply -f manifests/local-path-provisioner.yaml
kubectl apply -f manifests/local-static-storage.yaml

# 2. Point Velero at the SAME bucket. If MinIO itself was lost, restore MinIO's
#    data directory from your off-cluster copy first (see 06-production-notes).
./scripts/gen-credentials.sh          # must reproduce the SAME keys
kubectl apply -f manifests/minio.yaml
helm upgrade --install velero vmware-tanzu/velero --version 12.1.0 \
  -n velero --create-namespace -f values/values-local.yaml --wait

# 3. Wait for the backup sync (backupSyncPeriod, default 1m)
velero backup get                     # existing backups appear

# 4. Restore, most important namespaces first
velero restore create --from-backup <BACKUP> --include-namespaces critical-app --wait
velero restore describe <RESTORE> --details

# 5. Verify data, not just pod status
kubectl -n critical-app exec deploy/<app> -c <container> -- ls -la /data
```

Ordering that matters: CRDs and operators before the workloads that depend on
them; `local-static` PVs must exist before PVC-backed apps are restored.

> **Rehearse this.** A DR procedure that has never been executed is a hypothesis.
> `./scripts/verify-backup-restore.sh` is the cheap, repeatable version — run it
> after any change to storage, Velero, or the cluster.
