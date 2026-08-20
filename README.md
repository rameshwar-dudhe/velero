# Velero on Kubernetes — Helm Deployment (local + cloud)

Production-shaped Velero backup/restore for Kubernetes, driven entirely by the
official `vmware-tanzu/velero` Helm chart. One chart, one workflow, six values
files — so the **same procedure works on a local/on-prem cluster and on any
managed cloud cluster**.

| | |
|---|---|
| Chart | `vmware-tanzu/velero` **12.1.0** |
| Velero | **v1.18.1** |
| Plugins | `velero-plugin-for-{aws,gcp,microsoft-azure}` **v1.14.2** |
| Uploader | **Kopia** |
| Deployed to | `k8s-ha` @ `192.168.56.134:6443` — Kubernetes **v1.36.3**, 2 nodes |
| Web UI | `otwld/velero-ui` **0.15.0** → http://192.168.56.134:30902 (see [`docs/07-web-ui.md`](docs/07-web-ui.md)) |
| Status | **Verified end-to-end** — namespace destroyed and fully restored, volume data byte-identical |

---

## Table of contents

- [What is actually running](#what-is-actually-running)
- [Architecture](#architecture)
- [Verified result](#verified-result)
- [Quick start](#quick-start)
- [Operating procedure](#operating-procedure)
- [Repository layout](#repository-layout)
- [The one trap that will bite you](#the-one-trap-that-will-bite-you)
- [Everyday commands](#everyday-commands)
- [Going to a cloud cluster](#going-to-a-cloud-cluster)
- [Documentation](#documentation)
- [Security notes](#security-notes)

---

## What is actually running

Your cluster had **no StorageClass and no CSI snapshot support**, which dictated
every design choice here. Four components were installed:

| Component | Namespace | Why it is needed |
|---|---|---|
| `local-path-provisioner` v0.0.37 | `local-path-storage` | The cluster had **zero** StorageClasses, so every PVC sat `Pending` forever. Now the cluster default. |
| `local-static` SC + 4 static PVs | *(cluster-scoped)* | Velero's file-system backup **cannot read `hostPath` PVs**, which is all local-path produces. These `local`-type PVs are the ones Velero can actually back up. |
| MinIO | `minio` | Velero needs S3-compatible object storage. There is no cloud bucket here, so MinIO provides one, with the `velero` bucket pre-created. |
| Velero + node-agent | `velero` | The backup engine. `node-agent` is the DaemonSet that streams volume data with Kopia — **without it you back up only Kubernetes objects, not data.** |

A side effect worth knowing: installing the default StorageClass also unblocked
the four `Pending` PVCs in your `monitoring` namespace (grafana, prometheus,
victoriametrics, loki).

### Deliberate configuration choices

- **`snapshotsEnabled: false`** — there is no external-snapshotter, no
  `VolumeSnapshotClass` and no CSI storage driver on this cluster (the only CSI
  driver is `csi.tigera.io`, which is Calico and `Ephemeral`-only). Leaving this
  `true` creates a `VolumeSnapshotLocation` that can never work.
- **`defaultVolumesToFsBackup: true`** — with no CSI snapshots, volume *contents*
  must be copied over the filesystem. Without this you must annotate every pod
  with `backup.velero.io/backup-volumes=<name>` or its data is skipped.
- **node-agent tolerates the control-plane taint** — `k8s-cp-0` carries
  `node-role.kubernetes.io/control-plane:NoSchedule`. Without the toleration the
  DaemonSet would not run there, and any pod on that node would lose its volume
  data silently.
- **`publicUrl` on the BackupStorageLocation** — the `velero` CLI runs on your
  workstation, which cannot resolve `minio.minio.svc.cluster.local`. Without
  `publicUrl`, `velero backup logs` and `backup describe --details` fail even
  though the backup itself succeeded.
- **Credentials are never in a values file.** They live in Secrets created by
  `scripts/gen-credentials.sh`. Values files land in Helm release history in
  plaintext inside etcd; secrets do not belong there.

---

## Architecture

```
        YOUR WORKSTATION (192.168.56.133)
        ┌──────────────────────────────────────┐
        │  kubectl        helm       velero    │
        │                              │       │
        └──────────────────────────────┼───────┘
                   │ kube-api          │ reads backup logs/metadata
                   │ :6443             │ via publicUrl → NodePort :30900
  ═════════════════▼═══════════════════▼════════════════════════════
   CLUSTER k8s-ha                          namespace: velero
                                    ┌──────────────────────────────┐
                                    │ velero (Deployment)          │
                                    │  ├─ backup/restore controllers│
                                    │  └─ initContainer:           │
                                    │       plugin-for-aws v1.14.2 │
                                    │                              │
                                    │ node-agent (DaemonSet)       │
                                    │  ├─ on k8s-cp-0  (tolerated) │
                                    │  └─ on k8s-w-0               │
                                    │     reads /var/lib/kubelet/  │
                                    │     pods, uploads via Kopia  │
                                    └───────────┬──────────────────┘
                                                │ S3 API
                                                │ s3Url=http://minio.minio
                                                │        .svc:9000
                                    ┌───────────▼──────────────────┐
       namespace: minio             │ MinIO (S3-compatible)        │
                                    │  bucket: velero              │
                                    │  PVC 20Gi on local-path-     │
                                    │       retain (Retain policy) │
                                    └──────────────────────────────┘

   WORKLOAD STORAGE
     local-path     (default) → hostPath PVs → Velero CANNOT fs-backup these
     local-static             → local PVs    → Velero CAN back these up  ✅
```

On a **cloud** cluster the bottom-left box is replaced by S3/GCS/Blob, and
node-agent uses CSI snapshots + `snapshotMoveData` instead of fs-backup. Nothing
else changes — see [`docs/03-cloud-clusters.md`](docs/03-cloud-clusters.md).

---

## Verified result

This was not assumed — it was executed against your cluster:

```
1. demo app deployed with PVC + ConfigMap + Secret + Service
2. wrote known data into the PVC
3. velero backup create  → Completed, 24 items
     PodVolumeBackup: Completed, uploaded via kopia
4. kubectl delete ns velero-demo   → namespace GONE
5. velero restore create → Completed
     PodVolumeRestore: Completed
6. compared restored volume data to the original:

   4ddf178d7b99e6e218338f8601a156e8  original-marker.txt
   4ddf178d7b99e6e218338f8601a156e8  restored-marker.txt

   *** identical ***
```

Nested directories, the ConfigMap, the Secret and the Service all came back.
Note that the restored PVC bound to a **different** PV (`local-static-pv-2`, not
`pv-1`) — the original PV is left in `Released` state, which is why
[`scripts/recycle-local-pvs.sh`](scripts/recycle-local-pvs.sh) exists.

Re-run the whole proof any time:

```bash
./scripts/verify-backup-restore.sh
```

---

## Quick start

> **Just want the commands?** → [`QUICKREF.md`](QUICKREF.md) — one page, ~2 min read.
>
> **Want to understand it?** → [`docs/00-walkthrough.md`](docs/00-walkthrough.md) —
> the complete step-by-step guide with every command, the output to expect, and
> what it means, from an empty cluster through backup, restore, schedules and the UI.

### Local / on-prem cluster

```bash
# Everything: storage + MinIO + Velero + the destroy/restore test + the web UI.
./scripts/install-all.sh

# Or step by step:
./scripts/install-local.sh            # storage + MinIO + Velero
./scripts/verify-backup-restore.sh    # prove it works
./scripts/install-ui.sh               # web dashboard
```

Check the docs still match the live system:

```bash
./scripts/audit-docs.sh            # 109 checks: versions, config, RBAC, ports, flags
./scripts/audit-docs.sh --static   # files only, no cluster needed
```

Teardown, at three levels:

```bash
./scripts/uninstall-local.sh              # keep all backup data
./scripts/uninstall-local.sh --purge-data # delete backups + wipe node dirs
./scripts/uninstall-local.sh --purge-all  # also remove the StorageClass
```

The `velero` CLI is already installed at `/usr/local/bin/velero` (v1.18.1). If
you need it elsewhere:

```bash
curl -sSL -o velero.tar.gz \
  https://github.com/vmware-tanzu/velero/releases/download/v1.18.1/velero-v1.18.1-linux-amd64.tar.gz
tar xzf velero.tar.gz && sudo install -m0755 velero-*/velero /usr/local/bin/velero
```

### Cloud cluster

```bash
# 1. create the bucket yourself (Velero never creates it)
# 2. create the credentials Secret — never put keys in a values file
kubectl create namespace velero
kubectl -n velero create secret generic velero-s3-credentials \
  --from-literal=cloud='[default]
aws_access_key_id=<KEY>
aws_secret_access_key=<SECRET>
'

# 3. edit the <PLACEHOLDERS> in your values file, then install
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm upgrade --install velero vmware-tanzu/velero \
  --version 12.1.0 -n velero --create-namespace \
  -f values/values-s3-generic.yaml --wait
```

---

## Operating procedure

The whole lifecycle, in the order you actually use it.

| # | Step | Command | What proves it worked |
|---|---|---|---|
| 1 | **Build** | `./scripts/install-all.sh` | ends with `ALL DONE in <n>s`; fails loudly at any stage that does not verify |
| 2 | **Prove restores work (quick)** | `./scripts/verify-backup-restore.sh` | `PASS` — a namespace was destroyed and its volume data came back byte-identical |
| 2b | **Prove it deeply** | `./scripts/deep-test.sh` | `37 passed, 0 failed` — 255 files sha256-matched, dedup, relocation, selective restore, the hostPath trap |
| 3 | **Prove the docs are true** | `./scripts/audit-docs.sh` | `109 passed, 0 failed` |
| 4 | **Use it** | `velero backup create …` / `velero restore create …` | non-zero `PodVolumeBackups`, `0` in the `WARNINGS` column |
| 5 | **Housekeeping** | `./scripts/recycle-local-pvs.sh` | static PV pool back to `Available` |
| 6 | **Tear down** | `./scripts/uninstall-local.sh [--purge-data|--purge-all]` | `0` velero.io CRDs, no project namespaces |

Steps 1–3 are the loop to re-run after **any** change to Velero, storage, or the
cluster. Together they take about four minutes and answer the only question that
matters: *can I actually get my data back, and do the instructions still match
the system?*

### Verified history

This repo has been built from an empty cluster, verified, and torn down
repeatedly — the teardown/rebuild cycle is the test, not a formality.

| Cycle | Rebuild | Smoke test | Deep test | Docs audit |
|---|---|---|---|---|
| 1 | `249s` | PASS | — | — |
| 2 | `190s` | PASS | — | — |
| 3 | `183s` | PASS | — | **109 passed, 0 failed** |
| 4 | `149s` | — | **37 passed, 0 failed** | 109 passed, 0 failed |
| 5 | `120s` | — | **37 passed, 0 failed** | 109 passed, 0 failed |

Each cycle started from a genuinely empty state: no StorageClass, no PVs, no
`velero.io` CRDs, no project namespaces.

Cycles 4 and 5 ran the deep suite and produced **identical numbers** — 255 files
checksummed, 8,395,536 bytes uploaded, dedup adding 14 objects vs 21, bucket
reclaim 85 → 79 on delete. That reproducibility is the point: the result is a
property of the system, not of one lucky run.

## Repository layout

```
.
├── README.md
├── QUICKREF.md                    # one page — the commands you actually use
├── CLAUDE.md                     # cluster constraints, decisions, traps — read first
├── values/
│   ├── values-local.yaml         # ← DEPLOYED HERE. MinIO target, Kopia fs-backup
│   ├── values-s3-generic.yaml    # any S3-compatible store (DO Spaces, Ceph, R2, Wasabi…)
│   ├── values-aws.yaml           # S3 + EBS CSI snapshots, IRSA notes + IAM policy
│   ├── values-gcp.yaml           # GCS + PD CSI snapshots, Workload Identity notes
│   ├── values-azure.yaml         # Blob + Disk CSI snapshots, Workload Identity notes
│   └── values-velero-ui.yaml     # ← DEPLOYED HERE. web UI, de-escalated RBAC
├── manifests/
│   ├── local-path-provisioner.yaml  # default StorageClass (cluster had none)
│   ├── local-static-storage.yaml    # `local` PVs that fs-backup can read
│   ├── minio.yaml                   # S3 backend + bucket-creation Job
│   └── velero-ui-nodeport.yaml      # external access to the UI (chart can't pin it)
├── demo/
│   └── demo-app.yaml             # PVC + ConfigMap + Secret + Service test workload
├── scripts/
│   ├── install-all.sh            # ONE COMMAND: storage → MinIO → Velero → test → UI
│   ├── install-local.sh          # storage + MinIO + Velero, idempotent
│   ├── install-ui.sh             # web UI with both unsafe chart defaults fixed
│   ├── gen-credentials.sh        # generates creds, creates both Secrets
│   ├── gen-ui-credentials.sh     # UI password + JWT passphrase (never leave defaults)
│   ├── verify-backup-restore.sh  # quick: destroys + restores a namespace, diffs the data
│   ├── deep-test.sh              # thorough: 37 assertions, 255-file sha256 manifest
│   ├── recycle-local-pvs.sh      # returns Released static PVs to the pool
│   ├── audit-docs.sh             # asserts the docs still match reality (109 checks)
│   └── uninstall-local.sh        # tear down; --purge-data / --purge-all
├── docs/                         # see Documentation below
└── .secrets/minio.env            # generated, gitignored, mode 0600
```

---

## The one trap that will bite you

**A backup can report `Completed` and contain none of your data.**

This happened here on the first attempt. The backup said `Completed`, 24 items.
Buried in its log:

```
level=warning msg="Volume data in pod velero-demo/demo-app-… is a hostPath
volume which is not supported for pod volume backup, skipping"
```

`local-path-provisioner` provisions PVs with a `hostPath` volume source, and
Velero's file-system backup **refuses hostPath volumes**. The Kubernetes objects
were backed up; the PVC contents were not. A restore would have produced a
running pod with an empty volume — the worst possible failure mode, because it
looks like success.

**How to check, always:**

```bash
# A backup with zero PodVolumeBackups contains NO volume data.
kubectl -n velero get podvolumebackups -l velero.io/backup-name=<BACKUP>

# Or read it off the backup itself:
velero backup describe <BACKUP> --details | sed -n '/Backup Volumes/,$p'
```

**The fix on this cluster:** put anything whose data must survive on the
`local-static` StorageClass, not the default `local-path`.

```yaml
spec:
  storageClassName: local-static   # local PVs — Velero CAN back these up
```

On a cloud cluster this trap does not apply; use CSI snapshots instead. Full
explanation in [`docs/05-troubleshooting.md`](docs/05-troubleshooting.md).

---

## Everyday commands

```bash
# --- backup ---------------------------------------------------------------
velero backup create <name> --include-namespaces app1,app2 --wait
velero backup create <name> --include-namespaces app1 --ttl 720h --wait
velero backup get
velero backup describe <name> --details
velero backup logs <name>

# --- restore --------------------------------------------------------------
velero restore create --from-backup <name> --wait
velero restore create --from-backup <name> \
  --namespace-mappings prod:prod-clone --wait     # restore into a new namespace
velero restore describe <name> --details
velero restore logs <name>

# --- schedules ------------------------------------------------------------
velero schedule create daily --schedule="0 2 * * *" \
  --exclude-namespaces kube-system,velero,minio --ttl 336h
velero schedule get
velero backup create --from-schedule daily        # run one now

# --- health ---------------------------------------------------------------
kubectl -n velero get backupstoragelocation       # must be Available
kubectl -n velero get pods
kubectl -n velero logs deploy/velero --tail=100
kubectl -n velero get podvolumebackups
```

Full runbook, including disaster recovery onto a fresh cluster:
[`docs/04-operations.md`](docs/04-operations.md).

---

## Going to a cloud cluster

Only the backup target and the volume-snapshot strategy change:

| | Local (here) | Cloud |
|---|---|---|
| Object storage | MinIO in-cluster | S3 / GCS / Blob / Spaces |
| Plugin | `plugin-for-aws` (MinIO speaks S3) | matching cloud plugin |
| Volume data | Kopia fs-backup | CSI snapshot + `snapshotMoveData: true` |
| `snapshotsEnabled` | `false` | `true` |
| `features` | *(empty)* | `EnableCSI` |
| Credentials | Secret from generated keys | **IRSA / Workload Identity** preferred |
| `s3ForcePathStyle` | `"true"` | `"true"` for third parties, **omit for real AWS S3** |

Pick your values file, replace every `<PLACEHOLDER>`, create the Secret, install.
Details and per-provider prerequisites: [`docs/03-cloud-clusters.md`](docs/03-cloud-clusters.md).

---

## Documentation

| Document | Contents |
|---|---|
| **[`docs/00-walkthrough.md`](docs/00-walkthrough.md)** | **Start here.** Every command from an empty cluster to a verified restore, with expected output. Install, backup, restore, UI, schedules, teardown, rebuild |
| [`docs/01-architecture.md`](docs/01-architecture.md) | How Velero works, what each component does, the backup and restore data paths |
| [`docs/02-local-cluster.md`](docs/02-local-cluster.md) | Local install, the storage problem in depth, MinIO access, every value explained |
| [`docs/03-cloud-clusters.md`](docs/03-cloud-clusters.md) | S3-compatible deep dive, AWS/GCP/Azure, CSI snapshots and data movement |
| [`docs/04-operations.md`](docs/04-operations.md) | Backup, restore, schedules, retention, full-cluster DR runbook |
| [`docs/05-troubleshooting.md`](docs/05-troubleshooting.md) | The hostPath trap, BSL `Unavailable`, stuck backups, DNS/publicUrl, Pending PVCs |
| [`docs/06-production-notes.md`](docs/06-production-notes.md) | What to change before trusting this with real data |
| [`docs/07-web-ui.md`](docs/07-web-ui.md) | Velero has no official UI; the community options, and the two dangerous chart defaults fixed here |
| [`docs/08-deep-test.md`](docs/08-deep-test.md) | The 37-assertion test suite — what each group proves, and why the hostPath negative test is the most valuable one |

---

## Security notes

- MinIO credentials are generated (40-char random secret), stored in Secrets,
  and written to `.secrets/minio.env` at mode `0600`. That directory is
  gitignored. Rotate with `./scripts/gen-credentials.sh --rotate`.
- No credential appears in any values file, so none enters Helm release history.
- The MinIO NodePort (`30900`/`30901`) is **plain HTTP on your LAN**. It is there
  for convenience on a lab network. Do not expose it beyond that; see
  [`docs/06-production-notes.md`](docs/06-production-notes.md).
- `demo/demo-app.yaml` contains a deliberately fake token. It is a test fixture,
  not a real secret.
