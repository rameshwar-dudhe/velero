# 01 — Architecture: how Velero actually works

Understanding these five moving parts makes every failure mode obvious.

## The components

| Component | Kind | Job |
|---|---|---|
| **velero** | Deployment (1 replica) | Runs the controllers. Watches `Backup`/`Restore`/`Schedule` CRs, walks the Kubernetes API, writes object metadata to the bucket. Handles **no volume data itself.** |
| **node-agent** | DaemonSet | Reads and writes actual file data. Mounts the kubelet pod directory from the host and streams volume contents to object storage with Kopia. **No node-agent → no volume data in your backups.** |
| **plugin** | initContainer | Provider-specific code, copied into `/plugins` at startup. Teaches Velero to speak S3 / GCS / Azure Blob, and to snapshot that cloud's disks. |
| **BackupStorageLocation (BSL)** | CRD | *Where object metadata and Kopia data go.* Must reach `Available`. |
| **VolumeSnapshotLocation (VSL)** | CRD | *Where cloud disk snapshots go.* Irrelevant without a CSI/cloud snapshotter — disabled on this local cluster. |

The single most important distinction: **`velero` backs up API objects,
`node-agent` backs up file data.** Nearly every "my restore is empty" report is a
node-agent problem, not a Velero one.

## Backup data path

```
velero backup create app --include-namespaces app
        │
        ▼
 Backup CR created in namespace velero
        │
        ▼
 velero Deployment
   ├─ discovers API resources in the namespace
   ├─ for each pod, decides per volume:
   │     CSI snapshot?  fs-backup?  or skip?
   ├─ writes <bucket>/backups/<name>/…  (gzipped JSON of every object)
   └─ creates a PodVolumeBackup CR per volume needing fs-backup
                    │
                    ▼
        node-agent on THAT pod's node
          ├─ reads /var/lib/kubelet/pods/<uid>/volumes/…
          ├─ Kopia: content-addressed, deduplicated, incremental
          └─ writes <bucket>/kopia/<namespace>/…
```

Two independent streams land in one bucket:
`backups/` (object metadata) and `kopia/` (file data). A backup missing its
`kopia/` half restores as a running pod with an **empty volume**.

## Restore data path

```
velero restore create --from-backup app
        │
        ▼
 velero Deployment
   ├─ downloads object metadata from the bucket
   ├─ strips cluster-specific fields (clusterIP, PV binding, UIDs,
   │  resourceVersion) so objects are valid in the target cluster
   ├─ recreates objects in restore-priority order
   │    CRDs → namespaces → StorageClasses → PVs → PVCs → Secrets/ConfigMaps
   │    → ServiceAccounts → pods → everything else
   └─ injects a `restore-wait` initContainer into each pod with fs-backup data
                    │
                    ▼
        pod starts, blocked on restore-wait
                    │
        node-agent restores the volume via Kopia
                    │
        restore-wait exits → application container starts
```

That injected `restore-wait` initContainer is why a restored pod has an extra
container, and why `kubectl exec` without `-c app` prints a
`Defaulted container` notice. It also guarantees the app never sees a
half-populated volume.

## The three ways volume data gets backed up

| Strategy | Requires | Speed | Portable across clusters |
|---|---|---|---|
| **fs-backup** (Kopia) | node-agent only | Slow — reads every file | Yes |
| **CSI snapshot** | CSI driver + external-snapshotter + `VolumeSnapshotClass` | Fast | **No** — snapshot stays in the storage backend |
| **CSI snapshot + data movement** | above + `snapshotMoveData: true` | Fast snapshot, then upload | Yes |

**This local cluster uses fs-backup**, because it has no CSI snapshot capability
at all. **Cloud clusters should use the third option** — it is both fast and
portable, and it survives losing the storage backend, which a bare CSI snapshot
does not.

## How Velero decides per volume

In priority order:

1. Volume is `hostPath` → **skipped with a warning**, backup still says
   `Completed`. This is the trap documented in
   [`05-troubleshooting.md`](05-troubleshooting.md).
2. Pod annotated `backup.velero.io/backup-volumes-excludes=<vol>` → skipped.
3. Pod annotated `backup.velero.io/backup-volumes=<vol>` → fs-backup.
4. `defaultVolumesToFsBackup: true` (set here) → fs-backup for all eligible volumes.
5. CSI enabled and a matching `VolumeSnapshotClass` exists → CSI snapshot.
6. Otherwise → **only the PVC/PV objects are backed up, not the data.**

Case 6 is silent and common. Always verify with:

```bash
kubectl -n velero get podvolumebackups -l velero.io/backup-name=<BACKUP>
```

## What lands in the bucket

```
velero/                                  # bucket
├── backups/<backup-name>/
│   ├── <name>.tar.gz                    # every API object
│   ├── <name>-logs.gz                   # the backup log
│   ├── <name>-volumeinfo.json.gz        # which volumes, which method
│   ├── <name>-resource-list.json.gz     # what `describe --details` reads
│   └── velero-backup.json
├── restores/<restore-name>/
└── kopia/<namespace>/                   # deduplicated file data
    ├── kopia.repository
    └── p??/…
```

`velero backup describe --details` and `velero backup logs` fetch these
**directly from object storage**, not through the API server. That is why the CLI
needs a reachable endpoint — see `publicUrl` in
[`02-local-cluster.md`](02-local-cluster.md).

## What Velero does *not* do

- **It does not create your bucket.** Create it first.
- **It does not give application consistency.** A database backed up mid-write
  restores as a crashed database. Use backup hooks
  (`pre.hook.backup.velero.io/command`) to quiesce — see
  [`04-operations.md`](04-operations.md).
- **It does not back up the etcd/control plane.** It backs up API objects, which
  is a different (and usually more useful) thing.
- **It is not a replacement for storage-level replication.** It is
  point-in-time recovery, with an RPO equal to your schedule interval.
