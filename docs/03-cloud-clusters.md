# 03 — Cloud / managed Kubernetes

The same chart and the same commands as the local cluster. Only the backup target
and the volume strategy change.

## What changes, and nothing else

| | Local (MinIO) | Cloud |
|---|---|---|
| Object storage | MinIO in-cluster | S3 / GCS / Blob / Spaces |
| Plugin | `plugin-for-aws` | matching cloud plugin (`aws` for any S3-compatible store) |
| Volume data | Kopia fs-backup | CSI snapshot + data movement |
| `snapshotsEnabled` | `false` | `true` |
| `features` | *(empty)* | `EnableCSI` |
| `defaultSnapshotMoveData` | *(unset)* | `true` |
| `defaultVolumesToFsBackup` | `true` | `false` |
| Credentials | generated keys in a Secret | **IRSA / Workload Identity** preferred |

## Generic S3-compatible — `values/values-s3-generic.yaml`

Covers DigitalOcean Spaces, Ceph RGW, Wasabi, Backblaze B2, Cloudflare R2,
Linode, Scaleway, external MinIO, StorageGRID, Dell ECS — anything speaking S3.

### 1. Create the bucket

Velero never creates it. Using DigitalOcean Spaces as the example:

```bash
s3cmd --host=nyc3.digitaloceanspaces.com \
      --host-bucket='%(bucket)s.nyc3.digitaloceanspaces.com' \
      mb s3://my-velero-bucket
```

### 2. Create the credentials Secret

Never put keys in a values file — Helm stores release values in plaintext in a
Secret in etcd, and they persist in release history.

```bash
kubectl create namespace velero
kubectl -n velero create secret generic velero-s3-credentials \
  --from-literal=cloud='[default]
aws_access_key_id=<ACCESS_KEY>
aws_secret_access_key=<SECRET_KEY>
'
```

### 3. Endpoint and region

Region is often a dummy value, but the AWS SDK requires it to be non-empty.

| Provider | `s3Url` | `region` |
|---|---|---|
| DigitalOcean Spaces | `https://nyc3.digitaloceanspaces.com` | `nyc3` |
| Cloudflare R2 | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` | `auto` |
| Wasabi | `https://s3.eu-central-1.wasabisys.com` | `eu-central-1` |
| Backblaze B2 | `https://s3.us-west-004.backblazeb2.com` | `us-west-004` |
| Linode | `https://us-east-1.linodeobjects.com` | `us-east-1` |
| Scaleway | `https://s3.fr-par.scw.cloud` | `fr-par` |
| Ceph RGW | `https://rgw.internal.example.com` | `default` |
| External MinIO | `https://minio.example.com` | `minio` |

`s3ForcePathStyle: "true"` is required for essentially every non-AWS
implementation. **Omit it for real AWS S3.**

### 4. Multiple clusters, one bucket

```yaml
prefix: prod-eu-1
```

Without a distinct prefix per cluster, two clusters will collide on backup names
and fight over the same Kopia repository.

### 5. Private CA / self-signed TLS

Prefer supplying the CA over disabling verification:

```yaml
- name: default
  caCert: <base64 of ca.crt>       # base64 -w0 ca.crt
  config:
    insecureSkipTLSVerify: "false"
```

If you must skip verification, the CLI needs the flag too:
`velero backup describe X --insecure-skip-tls-verify`.

### 6. Install

```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update
helm upgrade --install velero vmware-tanzu/velero \
  --version 12.1.0 -n velero --create-namespace \
  -f values/values-s3-generic.yaml --wait --timeout 10m

kubectl -n velero get backupstoragelocation    # must be Available
```

## CSI snapshots and data movement

This is the part that makes cloud backups both fast and portable.

### Why data movement matters

A bare CSI snapshot lives **inside the storage backend**. Lose the volume, the
region, or the account, and the snapshot goes with it. `snapshotMoveData: true`
tells Velero to snapshot, then upload the snapshot's contents to your bucket:

```yaml
configuration:
  features: EnableCSI
  defaultSnapshotMoveData: true
  defaultVolumesToFsBackup: false
```

You get snapshot speed *and* an object-storage copy that survives losing the
storage backend, plus cross-region and cross-cluster restore.

### Prerequisites

```bash
# 1. external-snapshotter CRDs (managed services usually ship these)
kubectl get crd volumesnapshotclasses.snapshot.storage.k8s.io

# 2. a VolumeSnapshotClass, LABELLED — Velero ignores unlabelled ones
kubectl get volumesnapshotclass
kubectl label volumesnapshotclass <name> velero.io/csi-volumesnapshot-class=true
```

That label is the single most common omission. Without it Velero silently falls
back to no volume backup at all.

### Verifying it works

```bash
velero backup create test --include-namespaces myapp --wait
velero backup describe test --details | sed -n '/Backup Volumes/,$p'
# Expect entries under "CSI Snapshots" with "Data Movement: included"
kubectl -n velero get datauploads     # the data-movement objects
```

## AWS / EKS — `values/values-aws.yaml`

Full IAM policy and bucket commands are in the file header. Key points:

- **Use IRSA.** Set `credentials.useSecret: false`, delete the `credential:`
  block from the BSL, and annotate the ServiceAccount:
  ```yaml
  serviceAccount:
    server:
      annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::<ACCT>:role/velero-irsa
  ```
- **Two regions, not one.** `backupStorageLocation.config.region` is the
  *bucket's* region; `volumeSnapshotLocation.config.region` is the *volumes'*
  region. They are often different.
- **Do not set `s3Url` or `s3ForcePathStyle`** for real S3.
- Use the EBS CSI driver, not the deprecated in-tree provisioner.

## GCP / GKE — `values/values-gcp.yaml`

- **Use Workload Identity.** Set `credentials.useSecret: false`, annotate the SA
  with `iam.gke.io/gcp-service-account`, and set
  `backupStorageLocation.config.serviceAccount`.
- **The Secret format differs.** For GCP the `cloud` key holds the **raw JSON
  key file**, not AWS INI:
  ```bash
  kubectl -n velero create secret generic velero-gcp-credentials \
    --from-file=cloud=creds.json
  ```
- Bucket name has no `gs://` prefix.
- Roles needed: `roles/compute.storageAdmin` on the project, `objectAdmin` on the
  bucket.

## Azure / AKS — `values/values-azure.yaml`

- **The Secret format differs again** — `KEY=VALUE` lines, not INI, not JSON.
- **`AZURE_RESOURCE_GROUP` must be the *node* resource group** (usually
  `MC_<rg>_<cluster>_<region>`), the one holding the managed disks — not the
  resource group of the cluster object. This is the most common Azure mistake.
- `bucket:` is the **blob container** name.
- Workload Identity needs both a pod label and an SA annotation:
  ```yaml
  podLabels:
    azure.workload.identity/use: "true"
  serviceAccount:
    server:
      annotations:
        azure.workload.identity/client-id: <MANAGED_IDENTITY_CLIENT_ID>
  ```
- The storage account must be GPv2.

## Managed-service gotchas

| Platform | Watch out for |
|---|---|
| **EKS** | Bottlerocket/AL2023 keep the default `podVolumePath`. IRSA needs the SA annotation *and* `podSecurityContext.fsGroup` in some setups. |
| **GKE Autopilot** | Rejects privileged DaemonSets and host mounts. node-agent (and therefore fs-backup) **will not run**. Use CSI snapshots + data movement only. |
| **AKS** | Node resource group, as above. |
| **OpenShift** | node-agent needs the `privileged` SCC: `oc adm policy add-scc-to-user privileged -z velero -n velero`. |
| **k3s / RKE2** | Kubelet root may be `/var/lib/kubelet` (fine) — verify, since some installs relocate it. |
| **Any** | The `VolumeSnapshotClass` label is mandatory. |

## Migrating between clusters

Velero's real superpower — the same backup restores into a different cluster.

```bash
# On the SOURCE cluster
velero backup create migrate-1 --include-namespaces myapp --wait

# On the TARGET cluster: install Velero pointing at the SAME bucket and prefix,
# but READ-ONLY so it cannot garbage-collect the source's backups:
#   accessMode: ReadOnly
# Wait for the sync (backupSyncPeriod, default 1m), then:
velero backup get                       # the source's backups appear
velero restore create --from-backup migrate-1 --wait
```

Notes:
- StorageClass names must exist on the target, or map them:
  `velero restore create … --storage-class-mappings gp2:gp3`
- CSI snapshots do **not** cross clusters unless `snapshotMoveData: true` was set
  at backup time. This is the main reason to enable it.
- Flip the target BSL back to `ReadWrite` once it owns its own backups.
