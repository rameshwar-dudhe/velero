# 06 — Production notes

What this deployment is, what it is not, and what to change before trusting it
with data you cannot lose.

## The honest summary

What is running on `k8s-ha` is a **correct and fully verified Velero
installation** — backups work, restores work, volume data is byte-identical after
a namespace was destroyed. It is a legitimate lab and learning setup, and the
Velero configuration itself is production-shaped.

The **backup target is not production-grade**, for one structural reason.

## The structural problem: backups live in the cluster they protect

```
   cluster k8s-ha
   ┌──────────────────────────────────────┐
   │  your workloads                      │
   │  MinIO ── PVC on k8s-w-0's local disk│  ← backups are HERE
   └──────────────────────────────────────┘
```

Every backup sits on `k8s-w-0`'s local disk, inside the cluster being backed up.
So this setup protects you against:

- ✅ accidental `kubectl delete namespace`
- ✅ a bad deploy, a corrupted config, a botched migration
- ✅ losing a single workload or its PVC
- ✅ migrating a namespace to another cluster

and **not** against:

- ❌ losing `k8s-w-0`'s disk — backups and MinIO's own data go with it
- ❌ losing the cluster
- ❌ ransomware or a compromise with cluster credentials, which reaches the
  backups too
- ❌ the host or datacenter

**A backup on the same disk as the thing it protects is not a backup.** It is an
undo button — genuinely useful, but do not mistake it for disaster recovery.

## Fixing that: get the backups off-cluster

Pick one, cheapest first.

### 1. Point Velero at external object storage (best)

Change four lines and the problem disappears. Cloud buckets cost roughly cents
per GB per month, and versioning plus object-lock gives you ransomware
resistance.

```yaml
config:
  region: nyc3
  s3Url: https://nyc3.digitaloceanspaces.com
  s3ForcePathStyle: "true"
```

Use `values/values-s3-generic.yaml`. Enable **bucket versioning** and, if
available, **object lock / immutability** so a compromised cluster credential
cannot erase history.

### 2. A second BackupStorageLocation

Keep MinIO for fast local restores and add an off-site copy:

```yaml
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: velero
      default: true
      config: { region: minio, s3ForcePathStyle: "true",
                s3Url: http://minio.minio.svc.cluster.local:9000 }
    - name: offsite
      provider: aws
      bucket: my-offsite-bucket
      credential: { name: velero-offsite-credentials, key: cloud }
      config: { region: eu-central-1 }
```

```bash
velero schedule create daily-local   --schedule="0 2 * * *" --storage-location default
velero schedule create weekly-remote --schedule="0 4 * * 0" --storage-location offsite --ttl 2160h
```

### 3. Replicate MinIO's bucket off-cluster

```bash
mc mirror --watch local/velero remote/velero-offsite
```

### 4. Move MinIO off the cluster entirely

Run it on separate hardware and point `s3Url` at it. The backup target should
never share a failure domain with what it protects.

## Checklist before trusting this with real data

### Storage and durability
- [ ] Backups replicated **off this cluster** (above)
- [ ] Bucket versioning enabled
- [ ] Object lock / immutability, if the provider offers it
- [ ] MinIO PVC sized for real retention — currently **20Gi**; Kopia dedupes, but measure
- [ ] Disk-usage alert on MinIO (a full backup store fails silently)
- [ ] Replace the static `local` PV pool with a real CSI driver (Longhorn,
      OpenEBS LVM/ZFS, Ceph/Rook) so you get dynamic provisioning *and* snapshots

### Security
- [ ] **TLS on MinIO.** It currently serves plain HTTP; the NodePort is
      unencrypted on your LAN, so S3 keys cross the network in the clear.
- [ ] Remove the `minio-nodeport` Service, or firewall `30900`/`30901`
- [ ] Replace MinIO root credentials with a **scoped MinIO user** limited to the
      `velero` bucket, instead of root
- [ ] On cloud: **IRSA / Workload Identity** instead of static keys
- [ ] Encrypt at rest — SSE-S3/SSE-KMS on cloud, or MinIO KMS
- [ ] Restrict RBAC on the `velero` namespace: its ServiceAccount can read every
      Secret in the cluster, so read access to backups ≈ read access to all Secrets
- [ ] Rotate credentials on a schedule (`./scripts/gen-credentials.sh --rotate`)

### Reliability
- [ ] Multiple schedules with tiered retention (see [`04-operations.md`](04-operations.md))
- [ ] Alert on `velero_backup_last_successful_timestamp` going **stale** — this
      catches a silently broken schedule, which no failure counter will
- [ ] Alert on `velero_backup_failure_total` and `velero_backup_partial_failure_total`
- [ ] Backup hooks for every database (a mid-write copy restores as a crashed DB)
- [ ] `nodeAgent` memory limits sized to your largest volume — Kopia OOMs are the
      most common node-agent failure
- [ ] Raise `defaultBackupTTL` from the lab's `168h`

### Process
- [ ] **Restore rehearsals on a schedule.** An untested backup is a hypothesis.
      `./scripts/verify-backup-restore.sh` is the cheap repeatable version.
- [ ] Written RTO/RPO targets, with the schedule interval matching the RPO
- [ ] DR runbook rehearsed on a throwaway cluster
- [ ] Someone other than its author has executed a restore

## Specific weaknesses of this deployment

| Weakness | Impact | Fix |
|---|---|---|
| MinIO in the protected cluster | No protection from cluster/disk loss | Off-cluster target |
| MinIO on `k8s-w-0` local disk | Node loss destroys backups | Off-cluster target |
| MinIO on plain HTTP | S3 keys in cleartext on the LAN | TLS + `caCert` |
| MinIO NodePort exposed | Anyone on the LAN reaches the console | Remove or firewall |
| Static PV pool, 4 volumes | Restores exhaust it; needs manual recycling | Real CSI driver |
| `local` PVs pinned to `k8s-w-0` | Volumes cannot move nodes | Real CSI driver |
| MinIO root creds used by Velero | Over-privileged | Scoped MinIO user |
| Single Velero replica | Brief gap during restarts | Acceptable — Velero is not HA by design |
| No TTL on the demo backups | Clutter | `velero backup delete <name> --confirm` |
| fs-backup only | Slower, and no crash-consistent point-in-time | CSI driver + `snapshotMoveData` |

## What is genuinely production-shaped here

Worth keeping as-is when you move to a real target:

- Pinned versions everywhere — chart `12.1.0`, Velero `v1.18.1`, plugins
  `v1.14.2`, MinIO and `mc` at explicit releases. No `latest`.
- **No credentials in any values file**, so nothing sensitive lands in Helm
  release history in etcd.
- Generated 40-character random secrets, stored mode `0600`, gitignored.
- `snapshotsEnabled: false` matched to actual cluster capability instead of
  copied from a tutorial.
- node-agent tolerations covering the tainted control-plane node, so no pod's
  volumes are silently skipped.
- `reclaimPolicy: Retain` on the MinIO PVC — deleting a PVC cannot destroy the
  backup repository.
- Resource requests and limits on every component.
- Idempotent scripts, and an end-to-end verification that **destroys and restores
  a namespace and byte-compares the data** rather than trusting a `Completed`
  phase.
- `cleanUpCRDs: false`, so an accidental `helm uninstall` cannot delete your
  Backup records.

## Version upgrades

```bash
helm repo update
helm search repo vmware-tanzu/velero --versions | head -5

# Velero manages its own CRDs (upgradeCRDs: true)
helm upgrade velero vmware-tanzu/velero --version <NEW> \
  -n velero -f values/values-local.yaml --wait

kubectl -n velero get pods
kubectl -n velero get backupstoragelocation      # still Available?
./scripts/verify-backup-restore.sh               # then prove it still works
```

Keep the plugin version aligned with the Velero minor version — plugin `v1.14.x`
pairs with Velero `v1.18.x`. A mismatch usually shows up as a plugin that fails
to load at startup.

Read the release notes before crossing a minor version; Velero occasionally
changes defaults (Restic → Kopia was one such change).
