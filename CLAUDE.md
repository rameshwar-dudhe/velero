# CLAUDE.md — context for future sessions

Read this before touching anything. It records the cluster's constraints, the
decisions already made and why, and the traps that were hit the hard way. The
user should not have to explain any of this again.

---

## What this repo is

Velero backup/restore for Kubernetes, deployed with the official
`vmware-tanzu/velero` Helm chart. One chart, one workflow, six values files, so
the **same procedure works on this local cluster and on any cloud cluster**.

Everything is scripted and idempotent. The whole stack builds with:

```bash
./scripts/install-all.sh
```

---

## The cluster

| | |
|---|---|
| Name / API | `k8s-ha` @ `https://192.168.56.134:6443`, kubeadm, **v1.36.3** |
| Nodes | `k8s-cp-0` 192.168.56.134 — control-plane, **`NoSchedule` taint**<br>`k8s-w-0` 192.168.56.135 — worker, **the only schedulable node** |
| CNI | Calico via tigera-operator |
| This workstation | `claude` @ 192.168.56.133 — **not a cluster node**, only `kubectl`/`helm` client |

### Three constraints that dictated every design choice

1. **The cluster shipped with no StorageClass at all.** Every PVC sat `Pending`
   forever. `manifests/local-path-provisioner.yaml` fixes this and is now the
   cluster default.
2. **No CSI snapshot support.** No `snapshot.storage.k8s.io` CRDs; the only CSI
   driver is `csi.tigera.io` (Calico, `Ephemeral`-only, not storage). So volume
   backups **must** use node-agent + Kopia file-system backup, and
   `snapshotsEnabled: false`.
3. **Control-plane is tainted.** The node-agent DaemonSet needs a toleration or
   pods on `k8s-cp-0` silently lose their volume data.

---

## Working agreements with this user

- **Do work inside the cluster, not on this workstation.** Do not install
  tooling, pull images, or run containers locally as a side effect. If you do,
  revert it and say so. (The `velero` CLI at `/usr/local/bin/velero` was
  explicitly approved; ask before anything else.)
- **Show cluster state before changing it.** Lead with a read-only survey.
- **Never touch their other workloads.** They run `argocd`, and cycle a
  `monitoring` stack and a `guestbook` app in and out. Those are not ours.
- The user writes in Hinglish; replies in Hinglish/simple English are fine.
  Repo docs stay in plain English.

---

## THE TRAP — read before changing anything about storage

**A Velero backup can report `Completed` and contain none of your data.**

`local-path-provisioner` provisions PVs with a **`hostPath`** volume source, and
Velero's fs-backup refuses those:

```
level=warning msg="Volume data in pod ... is a hostPath volume which is not
supported for pod volume backup, skipping"
```

The backup still says `Completed`. Only the Kubernetes objects are saved; the
volume restores **empty**. This happened here on the first attempt.

**The fix, already in place:** `manifests/local-static-storage.yaml` provides a
`local-static` StorageClass backed by a pool of 4 pre-created **`local`**-type
PVs, which Velero *does* accept.

| StorageClass | Use for | Velero fs-backup |
|---|---|---|
| `local-path` (default) | scratch, caches, rebuildable data | ❌ silently skipped |
| `local-path-retain` | MinIO's own PVC (Retain) | ❌ |
| **`local-static`** | anything that must survive a restore | ✅ |

**How to check any backup — never trust the phase alone:**

```bash
kubectl -n velero get podvolumebackups -l velero.io/backup-name=<BACKUP>
# ZERO rows = no volume data in that backup, whatever the phase says
```

Cheapest signal: the `WARNINGS` column of `velero backup get`. A skipped-volume
backup shows `1` while still saying `Completed`.

---

## Layout

```
values/     values-local.yaml       ← DEPLOYED. MinIO target, Kopia fs-backup
            values-velero-ui.yaml   ← DEPLOYED. web UI, RBAC de-escalated
            values-s3-generic.yaml  any S3 store (DO Spaces, Ceph, R2, Wasabi…)
            values-aws.yaml / values-gcp.yaml / values-azure.yaml
manifests/  local-path-provisioner.yaml  default StorageClass (cluster had none)
            local-static-storage.yaml    `local` PVs fs-backup can read + mkdir Job
            minio.yaml                   S3 backend + bucket-creation Job
            velero-ui-nodeport.yaml      UI access (chart can't pin a nodePort)
demo/       demo-app.yaml           PVC + ConfigMap + Secret + Service test workload
scripts/    install-all.sh          storage → MinIO → Velero → verify → UI
            install-local.sh, install-ui.sh
            gen-credentials.sh, gen-ui-credentials.sh
            verify-backup-restore.sh, recycle-local-pvs.sh, uninstall-local.sh
docs/       00-walkthrough.md       ← the main doc, every command + expected output
            01..07                  architecture, local, cloud, ops, troubleshooting,
                                    production notes, web UI
.secrets/   minio.env, velero-ui.env    generated, mode 600, gitignored
```

---

## Deployed configuration

| | |
|---|---|
| Velero chart | `vmware-tanzu/velero` **12.1.0**, app **v1.18.1** |
| AWS plugin | `velero/velero-plugin-for-aws:v1.14.2` (v1.14.x ↔ Velero 1.18.x) |
| UI chart | `otwld/velero-ui` **0.15.0**, app **0.10.2** |
| MinIO | `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z` |
| mc | `quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z` |
| local-path-provisioner | `v0.0.37` |
| busybox | `1.37` |

Namespaces: `velero`, `minio`, `velero-ui`, `velero-demo`, `local-path-storage`.
NodePorts: **30900** MinIO S3, **30901** MinIO console, **30902** Velero UI.

### Non-obvious settings and why

| Setting | Value | Reason |
|---|---|---|
| `snapshotsEnabled` | `false` | No snapshotter exists; `true` creates a VSL that can never validate |
| `deployNodeAgent` | `true` | Without it, only API objects are backed up — no file data |
| `defaultVolumesToFsBackup` | `true` | No CSI snapshots; otherwise every pod needs a `backup.velero.io/backup-volumes` annotation |
| `nodeAgent.tolerations` | control-plane taint | Else pods on `k8s-cp-0` lose their volume data silently |
| `config.s3ForcePathStyle` | `"true"` | MinIO needs `host:9000/bucket`, not `bucket.host:9000` |
| `config.region` | `minio` | Ignored by MinIO but the AWS SDK requires non-empty |
| `config.publicUrl` | `http://192.168.56.134:30900` | The CLI reads logs **straight from object storage**; the workstation can't resolve cluster DNS |
| `credentials.existingSecret` | `velero-minio-credentials` | Helm stores values in etcd in plaintext — never put secrets in a values file |
| `rbac.clusterAdministrator` (UI) | `false` | Chart default binds **`cluster-admin`** |
| MinIO PVC class | `local-path-retain` | `Retain`, so deleting the PVC can't destroy the backup repository |

---

## The operating loop

Re-run these three after **any** change to Velero, storage, or the cluster. About
four minutes total.

```bash
./scripts/install-all.sh              # 1. build  → "ALL DONE in <n>s"
./scripts/verify-backup-restore.sh    # 2. quick proof     → "PASS"
./scripts/deep-test.sh                # 2b. deep proof     → "37 passed, 0 failed"
./scripts/audit-docs.sh               # 3. docs are true   → "109 passed, 0 failed"
```

`deep-test.sh` is the one to run before trusting real data, and after **any**
Velero/chart/storage/cluster upgrade. 37 assertions: a 255-file sha256 manifest
(nested dirs, 8 MB binary, unicode and space-in-name files, permissions, symlink,
empty dir), dedup proof, full namespace DR, namespace-mapped relocation,
selective restore, schedules, metrics, bucket reclaim on delete — plus a
**negative test that asserts the hostPath trap still behaves as documented**. If
that negative test ever fails, Velero changed and the storage guidance here needs
revisiting. See `docs/08-deep-test.md`.

Built, verified and destroyed three times so far — the teardown/rebuild cycle is
the test, not a formality:

| Cycle | Rebuild | Smoke | Deep test | Docs audit |
|---|---|---|---|---|
| 1 | 249s | PASS | — | — |
| 2 | 190s | PASS | — | — |
| 3 | 183s | PASS | — | 109 / 0 |
| 4 | 149s | — | **37 / 0** | 109 / 0 |
| 5 | 120s | — | **37 / 0** | 109 / 0 |

Cycle 1's teardown deadlocked on the CRD finalizer (trap 2 below); every cycle
since has run clean, which is what validated the fix. Cycles 4 and 5 produced
byte-identical deep-test numbers (255 files, 8,395,536 bytes, dedup 14 vs 21,
bucket reclaim 85 → 79) — the results are a property of the system, not of one run.

## Traps already hit — do not rediscover these

1. **hostPath volumes are skipped silently.** See THE TRAP above.

2. **Uninstall deadlocks on CRDs.** Velero puts finalizers on its own objects
   (`restores.velero.io/external-resources-finalizer`) and only the Velero
   controller clears them — which `helm uninstall` already deleted. Deleting the
   CRDs then hangs forever. `uninstall-local.sh` strips finalizers **before**
   deleting CRDs and uses `--wait=false` with a bounded timeout.

3. **Teardown must be scoped by ownership, not StorageClass.** An early version
   deleted PVs matching `local-path`, which would have destroyed unrelated
   workloads' volumes. Ownership = the `velero.io/pv-pool` label or a `claimRef`
   into `minio`/`velero`/`velero-demo`/`velero-ui`. The node-directory wipe is
   scoped the same way (`*_<our-ns>_*` under `/opt/local-path-provisioner`).

4. **`--purge-all` removes the default StorageClass.** Do not use it if other
   workloads use `local-path` — check `kubectl get pvc -A | grep local-path`
   first. Use `--purge-data` instead.

5. **The velero chart has a `values.schema.json`.** Unknown keys are a *hard
   failure* (`nodeAgent.privileged` is not real). Always dry-run:
   `helm template velero vmware-tanzu/velero --version 12.1.0 -n velero -f values/values-local.yaml >/dev/null`

6. **`velero backup logs` fails without `publicUrl`**, even when the backup
   succeeded — the CLI fetches from object storage, not the API server.

7. **`kubectl exec` on a restored pod needs `-c app`.** Restored pods gain a
   `restore-wait` init container; without `-c`, kubectl prints a
   `Defaulted container ...` notice that corrupts captured output and produces a
   fake diff. This caused a false failure once.

8. **A restore consumes a static PV.** The original goes `Released` and never
   rebinds. Run `./scripts/recycle-local-pvs.sh` afterwards or the pool runs out
   and restores hang `Pending`.

9. **The `mc` image ships `HOME=/`**, unwritable by uid 1000 →
   `mkdir /.mc: permission denied`. Set `HOME=/tmp` + `MC_CONFIG_DIR=/tmp/.mc`
   with an emptyDir.

10. **The UI chart cannot set its own JWT passphrase.** It creates a Secret from
    `configuration.general.secretPassPhrase.value` but **never references it in
    the Deployment**. Left at the published default, anyone can forge a session
    token and bypass login. `values-velero-ui.yaml` injects
    `AUTH_SECRET_PASSPHRASE` via `env` + `secretKeyRef` instead.

11. **Namespace deletion on this cluster is slow** (minutes). Teardown looks
    hung but usually is not — check before intervening.

12. **The UI chart's Service has no `nodePort` field**, hence the separate
    `manifests/velero-ui-nodeport.yaml`.

13. **A repo checker scans itself.** `audit-docs.sh` greps for known-bad version
    strings and initially matched its own list, reporting 10 false failures.
    Its search list now excludes itself. Confirm any audit "failure" is real
    before changing what it complains about.

---

## Conventions to keep

- **Every image and chart version pinned.** No `latest` tags anywhere.
- **No credentials in any values file.** Generated by the `gen-*` scripts into
  Secrets and `.secrets/*.env` (mode 600, gitignored).
- Scripts are idempotent and **fail loudly** — `install-local.sh` errors if the
  BackupStorageLocation never reaches `Available`; `install-ui.sh` errors if the
  UI ends up bound to `cluster-admin`.
- Verification means **byte-comparing restored data**, not reading a status
  field.

---

## Keeping the docs honest

`./scripts/audit-docs.sh` asserts **every concrete claim the docs make** against
the repo files and the live cluster: pinned versions, image tags, BSL config,
server flags, node-agent coverage, StorageClasses, PV pool size, node ports, UI
RBAC, and that no `:latest` tag or stale version string survives anywhere. It
exits non-zero on any mismatch.

```bash
./scripts/audit-docs.sh            # full (109 checks, needs a live cluster)
./scripts/audit-docs.sh --static   # files only, no cluster
```

**Run it after any version bump or config change.** Versions live in one place at
the top of that script — change them there and in the files, and the audit proves
the docs were updated too. Last run: **109 passed, 0 failed.**

## Commands

```bash
# build / rebuild everything (~3 min, includes the destroy/restore test)
./scripts/install-all.sh
./scripts/install-all.sh --no-verify --no-ui

# check the docs still match reality
./scripts/audit-docs.sh

# prove it works: deploys an app, backs it up, DESTROYS the namespace,
# restores, and byte-compares the volume data
./scripts/verify-backup-restore.sh

# teardown
./scripts/uninstall-local.sh              # keep backup data
./scripts/uninstall-local.sh --purge-data # delete backups + wipe node dirs
./scripts/uninstall-local.sh --purge-all  # also remove the StorageClass (careful)

# housekeeping
./scripts/recycle-local-pvs.sh            # return Released static PVs to the pool
./scripts/gen-credentials.sh --rotate     # new MinIO keys
./scripts/gen-ui-credentials.sh --rotate  # new UI password

# health, most useful first
kubectl -n velero get backupstoragelocation      # must be Available
kubectl -n velero get podvolumebackups           # volume data actually captured?
velero backup get                                # WARNINGS column matters
kubectl -n velero logs deploy/velero --tail=100
```

### Access

| | |
|---|---|
| Velero UI | http://192.168.56.134:30902 — user `admin`, password in `.secrets/velero-ui.env` |
| MinIO console | http://192.168.56.134:30901 — creds in `.secrets/minio.env` |
| MinIO S3 API | http://192.168.56.134:30900 — anonymous `GET /` returning **403 is correct** |

---

## Moving to a cloud cluster

Only the target and the volume strategy change. Use `values-s3-generic.yaml`
(or the aws/gcp/azure file), replace every `<PLACEHOLDER>`, create the bucket and
the credentials Secret yourself, then install with the same command.

| | Local | Cloud |
|---|---|---|
| Storage | MinIO in-cluster | S3 / GCS / Blob / Spaces |
| Volume data | Kopia fs-backup | CSI snapshot + `snapshotMoveData: true` |
| `snapshotsEnabled` | `false` | `true` |
| `features` | *(empty)* | `EnableCSI` |
| Credentials | generated keys | IRSA / Workload Identity |
| `s3ForcePathStyle` | `"true"` | `"true"` for third parties, **omit for real AWS S3** |

Most common cloud mistake: an **unlabelled** VolumeSnapshotClass. Velero ignores
it and silently takes no snapshot.
`kubectl label volumesnapshotclass <n> velero.io/csi-volumesnapshot-class=true`

---

## Known limitation, stated honestly

**Backups live on `k8s-w-0`'s local disk, inside the cluster they protect.** That
covers accidental deletes, bad deploys and lost PVCs — but not losing that disk,
the node, or the cluster. It is an undo button, not disaster recovery. The fix is
four lines: point the BackupStorageLocation at external object storage using
`values-s3-generic.yaml`. Full checklist in `docs/06-production-notes.md`.
