# 02 — Local / on-prem cluster

Everything specific to running Velero on `k8s-ha` (or any bare kubeadm cluster
with no cloud storage).

## What the cluster looked like before

```
$ kubectl get sc                 → No resources found
$ kubectl get pv                 → No resources found
$ kubectl get crd | grep snapshot → (nothing)
$ kubectl get csidrivers         → csi.tigera.io   (Calico, Ephemeral only)
$ kubectl get nodes
  k8s-cp-0   control-plane   NoSchedule taint
  k8s-w-0    worker          schedulable
```

Three consequences that drove the whole design:

1. **No StorageClass** → MinIO could not get a volume, and four PVCs in your
   `monitoring` namespace were stuck `Pending`.
2. **No CSI snapshotter** → volume backups must use Kopia fs-backup.
3. **Only one schedulable node** → node-agent needs a toleration to also cover
   `k8s-cp-0`.

## Install

```bash
./scripts/install-local.sh
```

Idempotent, and it fails loudly if the BackupStorageLocation does not reach
`Available`. Steps, in order:

| # | Step | Why the order matters |
|---|---|---|
| 1 | `local-path-provisioner` | Nothing can claim a volume until a StorageClass exists |
| 2 | `local-static` SC + PV pool + mkdir Job | `local` PVs need their directories to pre-exist |
| 3 | `gen-credentials.sh` | Both Secrets must exist before the pods that consume them |
| 4 | MinIO + bucket Job | Velero's BSL validation fails if the bucket is absent |
| 5 | Velero Helm install | — |
| 6 | Wait for BSL `Available` | The real proof that S3 auth works |

## The storage problem, in full

This is the part that makes or breaks local Velero.

### `local-path` (the default) — cannot be backed up

`local-path-provisioner` creates PVs like this:

```yaml
spec:
  hostPath:                     # ← the problem
    path: /opt/local-path-provisioner/pvc-…
    type: DirectoryOrCreate
```

Velero's fs-backup rejects `hostPath` volumes outright:

```
level=warning msg="Volume data in pod <ns>/<pod> is a hostPath volume
which is not supported for pod volume backup, skipping"
```

The backup still reports **`Completed`**. Only the PVC and PV *objects* are
saved. Restoring gives you a healthy-looking pod with an empty volume.

### `local-static` — can be backed up

`manifests/local-static-storage.yaml` provides a pool of PVs using the `local`
volume source, which Velero accepts:

```yaml
spec:
  local:                        # ← accepted by fs-backup
    path: /opt/velero-local-pvs/pv-1
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: ["k8s-w-0"]
```

Use it for anything whose data must survive:

```yaml
spec:
  storageClassName: local-static
```

### Which to use

| Use | For |
|---|---|
| `local-path` (default) | Caches, scratch, rebuildable data, the monitoring stack |
| `local-static` | Databases, uploads, anything you would be upset to lose |

### Managing the static PV pool

`local` PVs are not dynamically provisioned, so the pool is finite (4 by
default), and **a restore consumes one**: the original PV goes to `Released` and
never rebinds, while the restored PVC binds to a free one.

```bash
# Check the pool
kubectl get pv -l velero.io/pv-pool=local-static \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name'

# Return Released PVs to Available (also wipes their directories)
./scripts/recycle-local-pvs.sh
./scripts/recycle-local-pvs.sh --dry-run
```

Add more by copying a PV block in `manifests/local-static-storage.yaml`, adding
its directory to the mkdir Job's loop, and re-applying.

> **Better long-term option.** If you want dynamic provisioning *and* real
> snapshots on-prem, install a CSI driver that supports them — Longhorn,
> OpenEBS (LVM/ZFS engines), Ceph/Rook, or a vendor CSI driver. Then this whole
> static-pool arrangement disappears and you configure the cluster exactly like
> [`03-cloud-clusters.md`](03-cloud-clusters.md). Longhorn needs `open-iscsi` on
> the nodes and roughly 1–2 GB RAM, which is why it was not installed here.

## MinIO

| | |
|---|---|
| In-cluster S3 URL | `http://minio.minio.svc.cluster.local:9000` |
| From your workstation | `http://192.168.56.134:30900` (S3), `:30901` (console) |
| Bucket | `velero` |
| Storage | 20Gi PVC on `local-path-retain` (`reclaimPolicy: Retain`) |
| Credentials | `.secrets/minio.env`, mode `0600` |

```bash
# Credentials
cat .secrets/minio.env

# Browse the bucket with mc, from inside the cluster
kubectl -n minio run mc --rm -it --restart=Never \
  --image=quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z \
  --env=HOME=/tmp --env=MC_CONFIG_DIR=/tmp/.mc --command -- sh -c '
    mc alias set m http://minio.minio.svc.cluster.local:9000 <USER> <PASS> &&
    mc ls -r m/velero | head -30'

# Rotate credentials (updates both Secrets; restart Velero afterwards)
./scripts/gen-credentials.sh --rotate
kubectl -n velero rollout restart deploy/velero daemonset/node-agent
kubectl -n minio  rollout restart deploy/minio
```

`reclaimPolicy: Retain` on that PVC is deliberate: deleting the PVC must not
destroy your backup repository.

## Why `publicUrl` is set

The BSL carries two URLs:

```yaml
config:
  s3Url:     http://minio.minio.svc.cluster.local:9000   # in-cluster pods
  publicUrl: http://192.168.56.134:30900                 # your workstation
```

The `velero` CLI downloads logs and metadata **straight from object storage**.
Your workstation cannot resolve cluster DNS, so without `publicUrl` you get:

```
$ velero backup describe demo --details
Resource List: <error getting backup resource list: … dial tcp: lookup
minio.minio.svc.cluster.local on 127.0.0.53:53: server misbehaving>
```

— even though the backup succeeded. `publicUrl` fixes `backup logs`,
`describe --details`, and `restore logs`.

If your node IPs differ, update it and run:

```bash
helm upgrade velero vmware-tanzu/velero --version 12.1.0 \
  -n velero -f values/values-local.yaml --wait
```

Alternative, if you would rather not expose a NodePort: drop `publicUrl`, delete
the `minio-nodeport` Service, and port-forward when you need the CLI —
`kubectl -n minio port-forward svc/minio 9000:9000` with
`publicUrl: http://localhost:9000`.

## Every non-obvious value explained

| Value | Setting | Reason |
|---|---|---|
| `snapshotsEnabled` | `false` | No snapshotter exists; `true` creates a VSL that can never work and logs errors on every backup |
| `deployNodeAgent` | `true` | Without it, volume data is never backed up |
| `defaultVolumesToFsBackup` | `true` | No CSI snapshots, so copy file contents. Otherwise every pod needs a `backup.velero.io/backup-volumes` annotation |
| `uploaderType` | `kopia` | Modern default; Restic is deprecated |
| `nodeAgent.tolerations` | control-plane taint | Pods on `k8s-cp-0` would otherwise have no agent to back them up |
| `nodeAgent.podVolumePath` | `/var/lib/kubelet/pods` | Correct for kubeadm + containerd |
| `config.s3ForcePathStyle` | `"true"` | MinIO needs `host:9000/bucket`, not `bucket.host:9000` |
| `config.region` | `minio` | Ignored by MinIO, but the AWS SDK requires a non-empty value |
| `credentials.existingSecret` | `velero-minio-credentials` | Keeps keys out of the values file and out of Helm history in etcd |
| `defaultBackupTTL` | `168h` | 7-day lab retention; raise for real use |
| `metrics.serviceMonitor.enabled` | `false` | You run the plain prometheus chart, so the `ServiceMonitor` CRD does not exist |

## Uninstall

```bash
./scripts/uninstall-local.sh                # keeps backup data
./scripts/uninstall-local.sh --purge-data   # also deletes the MinIO PVC, the PV
                                            # pool, and the on-node directories
./scripts/uninstall-local.sh --purge-all    # also removes local-path-provisioner
```

`local-path-provisioner` is kept by the first two levels **deliberately** — it is
the cluster's only default StorageClass, so anything installed after Velero
probably depends on it. Check before reaching for `--purge-all`:

```bash
kubectl get pvc -A | grep local-path
```

If that lists namespaces outside this project, stay on `--purge-data`. To remove
the provisioner later, on its own:

```bash
kubectl delete -f manifests/local-path-provisioner.yaml
```

### Three things the teardown does that a hand-rolled one will not

1. **Clears Velero's finalizers before deleting the CRDs.** Without this the
   teardown hangs forever — see [`05-troubleshooting.md`](05-troubleshooting.md).
2. **Deletes PVs by ownership, not by StorageClass** — the `velero.io/pv-pool`
   label or a `claimRef` into `minio`/`velero`/`velero-demo`/`velero-ui`. Matching
   on `local-path` alone would destroy unrelated workloads' volumes.
3. **Scopes the on-node wipe the same way** — `/opt/velero-local-pvs` goes
   entirely, but under the shared `/opt/local-path-provisioner` only directories
   matching `*_<our-namespace>_*`. It prints what it kept:

```
    kept (not ours):
    pvc-5e716223-…_platform-git_git-repos
```
