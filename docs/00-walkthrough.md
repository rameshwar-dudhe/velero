# 00 — Complete walkthrough, from an empty cluster

**Read this one first.** Every command that was actually run, in order, with the
output you should expect and what it means. Nothing is skipped.

- **Time:** about 15 minutes end to end
- **You need:** a working cluster, `kubectl`, `helm`, internet access
- **Result:** Velero + MinIO + a web UI, with a backup and restore you have
  proven works

> **In a hurry?** [`../QUICKREF.md`](../QUICKREF.md) is one page with the ten
> commands you actually use. Come back here when you want to understand *why*.

If you just want it running, the whole thing is one command:

```bash
./scripts/install-all.sh
```

The rest of this document explains what that command does, step by step, so you
can run the steps by hand and understand each one. **It is a reference, not a
novel** — use the contents table below and read the part you need.

---

## Contents

| Part | What you do |
|---|---|
| [0](#part-0--check-your-cluster) | Check your cluster |
| [1](#part-1--install-the-velero-cli) | Install the `velero` CLI |
| [2](#part-2--storage-the-most-important-part) | Storage — **the part that decides whether backups contain your data** |
| [3](#part-3--create-the-passwords) | Create passwords |
| [4](#part-4--install-minio-the-backup-target) | Install MinIO (where backups are stored) |
| [5](#part-5--install-velero) | Install Velero |
| [6](#part-6--check-it-is-healthy) | Check it is healthy |
| [7](#part-7--take-your-first-backup) | Take your first backup |
| [8](#part-8--the-real-test-destroy-and-restore) | **Destroy something and restore it** |
| [9](#part-9--install-the-web-ui) | Install the web UI |
| [10](#part-10--automatic-backups-on-a-schedule) | Automatic scheduled backups |
| [11](#part-11--daily-commands) | Daily commands |
| [12](#part-12--destroy-everything-and-rebuild) | Destroy everything and rebuild |
| [13](#part-13--if-something-breaks) | If something breaks |
| [14](#part-14--check-this-document-is-still-true) | Check this document is still true |

---

## Part 0 — Check your cluster

First, confirm you are pointing at the right cluster. This matters — you do not
want to install into the wrong one.

```bash
kubectl config current-context
kubectl cluster-info
kubectl get nodes -o wide
```

Expected here:

```
kubernetes-admin@k8s-ha
Kubernetes control plane is running at https://192.168.56.134:6443

NAME       STATUS   ROLES           VERSION   INTERNAL-IP
k8s-cp-0   Ready    control-plane   v1.36.3   192.168.56.134
k8s-w-0    Ready    worker          v1.36.3   192.168.56.135
```

Now check three things that change how Velero must be configured.

**1. Do you have a StorageClass?**

```bash
kubectl get sc
```

If this says `No resources found`, you have no storage at all. Every PVC in the
cluster will sit `Pending` forever, including MinIO's. Part 2 fixes this.

**2. Can your cluster take volume snapshots?**

```bash
kubectl get crd | grep snapshot.storage.k8s.io
```

Empty output means **no CSI snapshot support**. Velero must then copy files
instead of taking snapshots. That is what we do here.

**3. Are any nodes tainted?**

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints[*].key'
```

```
NODE       TAINTS
k8s-cp-0   node-role.kubernetes.io/control-plane
k8s-w-0    <none>
```

A tainted node will not run Velero's `node-agent` unless we add a toleration.
**If you skip that, every pod on that node loses its volume data silently.**

---

## Part 1 — Install the `velero` CLI

You can do everything with `kubectl` alone, but the CLI is far easier.

```bash
curl -sSL -o velero.tar.gz \
  https://github.com/vmware-tanzu/velero/releases/download/v1.18.1/velero-v1.18.1-linux-amd64.tar.gz
tar xzf velero.tar.gz
sudo install -m 0755 velero-v1.18.1-linux-amd64/velero /usr/local/bin/velero
velero version --client-only
```

```
Client:
	Version: v1.18.1
```

> Keep the CLI version matching the server version. A mismatch usually shows up
> as confusing errors in `velero backup describe`.

---

## Part 2 — Storage, the most important part

**Read this part even if you normally skip storage sections.** Getting it wrong
produces backups that look perfect and contain none of your data.

### 2a. Install a StorageClass

The cluster had none, so nothing could claim a volume.

```bash
kubectl apply -f manifests/local-path-provisioner.yaml
kubectl -n local-path-storage rollout status deploy/local-path-provisioner
```

```bash
kubectl get sc
```

```
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
local-path-retain      rancher.io/local-path   Retain          WaitForFirstConsumer
```

Two classes are created:

- `local-path` — the cluster default, for normal workloads.
- `local-path-retain` — same, but `Retain`, so deleting a PVC does **not** delete
  the files. MinIO uses this so that removing its PVC cannot destroy your backups.

### 2b. Why you need a second kind of storage

Here is the problem. `local-path` creates volumes like this:

```bash
kubectl get pv <name> -o jsonpath='{.spec.hostPath}'
```

```json
{"path":"/opt/local-path-provisioner/pvc-...","type":"DirectoryOrCreate"}
```

That is a **`hostPath`** volume. Velero's file copy **refuses hostPath volumes**:

```
level=warning msg="Volume data in pod ... is a hostPath volume which is not
supported for pod volume backup, skipping"
```

And here is the dangerous part — **the backup still reports `Completed`.** Only
your Deployments, ConfigMaps and Secrets are saved. The actual data in the volume
is not. Restore it and you get a healthy-looking pod with an empty disk.

### 2c. Install storage Velero can read

Velero accepts a different volume type called `local`. So we create a small pool
of those.

```bash
kubectl apply -f manifests/local-static-storage.yaml
kubectl -n local-path-storage wait --for=condition=complete job/local-static-mkdir --timeout=180s
```

```bash
kubectl get pv -l velero.io/pv-pool=local-static \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,PATH:.spec.local.path'
```

```
NAME                STATUS      PATH
local-static-pv-1   Available   /opt/velero-local-pvs/pv-1
local-static-pv-2   Available   /opt/velero-local-pvs/pv-2
local-static-pv-3   Available   /opt/velero-local-pvs/pv-3
local-static-pv-4   Available   /opt/velero-local-pvs/pv-4
```

A `Job` first creates those directories on the node, because `local` volumes
require the path to already exist.

### 2d. The rule to remember

| Use this class | For |
|---|---|
| `local-path` (default) | Caches, scratch, anything you can rebuild |
| **`local-static`** | Databases, uploads, **anything that must survive a restore** |

In your app:

```yaml
spec:
  storageClassName: local-static
```

> **On a cloud cluster none of this applies.** You already have a real CSI driver,
> so you use snapshots instead. See [`03-cloud-clusters.md`](03-cloud-clusters.md).

---

## Part 3 — Create the passwords

Never type passwords into a Helm values file. Helm saves values in a Secret in
etcd **in plaintext**, and keeps them in release history forever.

```bash
./scripts/gen-credentials.sh
```

```
==> Generating new MinIO credentials
    access key: velero-lu2vitoy
    secret key: MzRq...(40 chars, see /root/velero/.secrets/minio.env)
==> Secret minio/minio-root
==> Secret velero/velero-minio-credentials
```

This creates two Secrets from one generated 40-character password:

| Secret | Used by |
|---|---|
| `minio/minio-root` | MinIO itself, as its root login |
| `velero/velero-minio-credentials` | Velero, as S3 keys (AWS credentials format) |

Both must match, which is why one script makes both. The plaintext copy is saved
to `.secrets/minio.env` at mode `0600`, and `.secrets/` is gitignored.

Re-running reuses the same password. To change it:

```bash
./scripts/gen-credentials.sh --rotate
kubectl -n velero rollout restart deploy/velero daemonset/node-agent
kubectl -n minio  rollout restart deploy/minio
```

---

## Part 4 — Install MinIO, the backup target

Velero needs S3-compatible object storage. On a cloud you would use S3, GCS or
Blob. Here MinIO provides an S3 API inside the cluster.

```bash
kubectl apply -f manifests/minio.yaml
kubectl -n minio rollout status deploy/minio --timeout=300s
kubectl -n minio wait --for=condition=complete job/minio-create-bucket --timeout=180s
```

Check the bucket was created:

```bash
kubectl -n minio logs job/minio-create-bucket
```

```
waiting for MinIO to answer...
Added `local` successfully.
creating bucket 'velero' (ignore-existing)...
Bucket created successfully `local/velero`.
```

> **Velero never creates the bucket for you.** That is what this Job is for. On a
> cloud cluster you create the bucket yourself before installing.

How to reach MinIO:

| From | Address |
|---|---|
| Inside the cluster | `http://minio.minio.svc.cluster.local:9000` |
| Your machine (S3) | `http://192.168.56.134:30900` |
| Your machine (console) | `http://192.168.56.134:30901` |

---

## Part 5 — Install Velero

```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update

helm upgrade --install velero vmware-tanzu/velero \
  --version 12.1.0 \
  --namespace velero \
  --create-namespace \
  -f values/values-local.yaml \
  --wait --timeout 10m
```

### The five settings that matter, and why

Open `values/values-local.yaml` and look at these:

**1. The plugin.** MinIO speaks S3, so you use the AWS plugin. There is no
separate MinIO plugin.

```yaml
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.14.2
```

**2. Where backups go.**

```yaml
config:
  region: minio                 # MinIO ignores it, but the AWS SDK demands a value
  s3ForcePathStyle: "true"      # MinIO needs host:9000/bucket, not bucket.host:9000
  s3Url: http://minio.minio.svc.cluster.local:9000    # for pods inside the cluster
  publicUrl: http://192.168.56.134:30900              # for the CLI on your machine
```

`publicUrl` is easy to miss. The `velero` CLI downloads logs **straight from
object storage**, not through the API server. Your machine cannot resolve
`minio.minio.svc.cluster.local`, so without `publicUrl` you get this even when
the backup worked perfectly:

```
error getting backup resource list: ... dial tcp: lookup
minio.minio.svc.cluster.local ... server misbehaving
```

**3. Turn snapshots off.** This cluster has no snapshot driver. Leaving it on
creates a snapshot location that can never work.

```yaml
snapshotsEnabled: false
```

**4. Turn on the node-agent, and let it run everywhere.**

```yaml
deployNodeAgent: true
nodeAgent:
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
```

`node-agent` is the DaemonSet that actually copies file data. **Without it you
back up only Kubernetes objects.** The toleration lets it also cover the tainted
control-plane node.

**5. Back up volume contents by default.**

```yaml
configuration:
  defaultVolumesToFsBackup: true
```

Without this, every pod needs an annotation or its data is skipped.

---

## Part 6 — Check it is healthy

Three checks. Do all three.

**1. Are the pods running?**

```bash
kubectl -n velero get pods
```

```
NAME                      READY   STATUS
node-agent-hm6b2          1/1     Running     ← one per node
node-agent-zx4vj          1/1     Running
velero-78c74b4c87-gmwkw   1/1     Running
```

You should see **one `node-agent` per node**. Two nodes, two agents. If you only
see one, your toleration is missing and one node is uncovered.

**2. Can Velero reach the bucket?** This is the single most useful check.

```bash
kubectl -n velero get backupstoragelocation
```

```
NAME      PHASE       LAST VALIDATED   DEFAULT
default   Available   56s              true
```

**`Available` means the S3 login worked.** If it says `Unavailable`, stop and fix
that first — see [Part 13](#part-13--if-something-breaks).

**3. Does the CLI work?**

```bash
velero backup get
```

An empty list is correct at this point.

---

## Part 7 — Take your first backup

### 7a. Deploy something to back up

```bash
kubectl apply -f demo/demo-app.yaml
kubectl -n velero-demo rollout status deploy/demo-app
```

This creates a namespace `velero-demo` with, deliberately, one of everything that
can go wrong: a PVC with real data, a ConfigMap, a Secret, and a Service.

Note its PVC uses `local-static` — the class Velero can read.

### 7b. Put known data in the volume

You need data you can recognise later, to prove the restore actually worked.

```bash
POD=$(kubectl -n velero-demo get pod -l app=demo-app -o jsonpath='{.items[0].metadata.name}')

kubectl -n velero-demo exec "$POD" -c app -- sh -c \
  'echo "my-test-data=hello" >> /data/marker.txt; cat /data/marker.txt'
```

```
created-at=2026-08-14T19:24:39Z
my-test-data=hello
```

### 7c. Take the backup

```bash
velero backup create demo-backup-1 --include-namespaces velero-demo --wait
```

```
Backup request "demo-backup-1" submitted successfully.
Waiting for backup to complete. ......
Backup completed with status: Completed.
```

### 7d. Check the backup actually contains the data — do not skip this

`Completed` alone is **not** proof. Check the volume was copied:

```bash
kubectl -n velero get podvolumebackups -l velero.io/backup-name=demo-backup-1
```

```
NAME                  STATUS      VOLUME   UPLOADER   BYTES
demo-backup-1-plxml   Completed   data     kopia      84
```

**One entry per volume, `Completed`, with a byte count.** If this list is
**empty**, your volume data is *not* in the backup, no matter what the phase says.

Also useful:

```bash
velero backup describe demo-backup-1 --details | sed -n '/Backup Volumes/,$p'
```

```
Backup Volumes:
  Pod Volume Backups - kopia:
    Completed:
      velero-demo/demo-app-...: data (size: 84, incremental size: 84)
```

And the quickest warning sign of all:

```bash
velero backup get
```

```
NAME            STATUS      ERRORS   WARNINGS
demo-backup-1   Completed   0        0          ← 0 warnings is what you want
```

A backup that silently skipped a volume shows `WARNINGS 1` while still saying
`Completed`. **Treat any non-zero warning count as "read the log before trusting
this."**

### Other useful backup commands

```bash
# Multiple namespaces, keep for 30 days
velero backup create nightly --include-namespaces app1,app2 --ttl 720h --wait

# Everything except the noise
velero backup create full \
  --exclude-namespaces kube-system,velero,minio,local-path-storage --wait

# Objects only, no volume data (fast config snapshot)
velero backup create cfg-only --include-namespaces app1 \
  --snapshot-volumes=false --default-volumes-to-fs-backup=false --wait

# By label
velero backup create tier1 --selector 'backup-tier=critical' --wait
```

> Always exclude the namespace holding MinIO. Backing up your backup store into
> itself is pure waste.

---

## Part 8 — The real test: destroy and restore

A backup you have never restored is a guess. So let's delete the whole thing.

### 8a. Save what the data looks like now

```bash
POD=$(kubectl -n velero-demo get pod -l app=demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n velero-demo exec "$POD" -c app -- cat /data/marker.txt > /tmp/before.txt
cat /tmp/before.txt
```

### 8b. Destroy the namespace

```bash
kubectl delete ns velero-demo --wait=true
kubectl get ns velero-demo
```

```
Error from server (NotFound): namespaces "velero-demo" not found
```

It is completely gone — Deployment, PVC, data, all of it.

### 8c. Restore

```bash
velero restore create demo-restore-1 --from-backup demo-backup-1 --wait
```

```
Restore completed with status: Completed.
```

### 8d. Check what came back

```bash
kubectl -n velero-demo get all,pvc,cm,secret
kubectl -n velero get podvolumerestores
```

```
NAME                   STATUS      VOLUME   BYTES
demo-restore-1-gwqgn   Completed   data     84
```

### 8e. Prove the data is identical

```bash
RPOD=$(kubectl -n velero-demo get pod -l app=demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n velero-demo exec "$RPOD" -c app -- cat /data/marker.txt > /tmp/after.txt

diff /tmp/before.txt /tmp/after.txt && echo "IDENTICAL — restore works"
md5sum /tmp/before.txt /tmp/after.txt
```

```
IDENTICAL — restore works
4ddf178d7b99e6e218338f8601a156e8  /tmp/before.txt
4ddf178d7b99e6e218338f8601a156e8  /tmp/after.txt
```

**That is the proof.** Same bytes, after the namespace was destroyed.

> **Use `-c app` in `exec`.** A restored pod has an extra `restore-wait` init
> container, and without `-c` kubectl prints a `Defaulted container ...` notice
> that lands in your file and produces a fake diff. That exact mistake happened
> while building this.

### 8f. Two things you will notice

**The PVC bound to a different volume.**

```bash
kubectl get pv -l velero.io/pv-pool=local-static \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name'
```

```
local-static-pv-1   Released    demo-data     ← the old one, now stuck
local-static-pv-2   Bound       demo-data     ← the restore took a fresh one
local-static-pv-3   Available   <none>
```

Static volumes never return to the pool by themselves. Each restore consumes one.
Give them back:

```bash
./scripts/recycle-local-pvs.sh --dry-run   # see what it would do
./scripts/recycle-local-pvs.sh             # clear claimRef + wipe the directory
```

**Restores skip things that already exist.** Restoring on top of a live namespace
mostly does nothing. Either delete it first, or restore into a new one — which is
the safe way to test:

```bash
velero restore create test --from-backup demo-backup-1 \
  --namespace-mappings velero-demo:velero-demo-test --wait
```

### 8g. Do all of this in one command

```bash
./scripts/verify-backup-restore.sh
```

It performs every step above and **fails loudly** if the data does not match, if
no PodVolumeBackup was created, or if the namespace survives deletion. Run it
after any change to storage, Velero, or the cluster.

### 8h. And the thorough version

The script above is the two-minute smoke test — one file, one restore. When you
need real confidence (before trusting production data, or after any version
bump), run the deep suite:

```bash
./scripts/deep-test.sh          # ~8-12 min, 37 assertions
```

It builds a data tree designed to break things — 250 small files across nested
directories, an 8 MB random binary, a `файл-测试.txt`, a filename with spaces,
`chmod 600`/`755` files, an empty directory, a symlink — takes a **sha256 of every
file**, destroys the namespace, restores, and compares the whole manifest. Then it
also checks deduplication, restore into a different namespace, selective restore,
schedules, metrics, and that deleting a backup really frees bucket objects.

It includes one **negative** test worth knowing about: it deliberately puts a PVC
on `local-path` and asserts Velero *still* silently skips it. That test failing
would mean Velero changed and [Part 2](#part-2--storage-the-most-important-part)
needs revisiting.

```
════════ DEEP TEST RESULT ════════
  passed:        37
  failed:        0
  DEEP TEST PASSED — backups are trustworthy on this cluster.
```

Full breakdown: [`08-deep-test.md`](08-deep-test.md).

---

## Part 9 — Install the web UI

Velero has **no official UI**. This is the best maintained community one.

```bash
./scripts/install-ui.sh
```

Or by hand:

```bash
helm repo add otwld https://helm.otwld.com/
helm repo update

./scripts/gen-ui-credentials.sh          # generates a password + JWT secret

helm upgrade --install velero-ui otwld/velero-ui \
  --version 0.15.0 -n velero-ui --create-namespace \
  -f values/values-velero-ui.yaml --wait

kubectl apply -f manifests/velero-ui-nodeport.yaml
```

Open it:

```
http://192.168.56.134:30902
username: admin
password: cat .secrets/velero-ui.env
```

### Two chart defaults you must change

**1. The chart binds `cluster-admin` by default.**

`rbac.clusterAdministrator: true` is the shipped default. It gives the UI's
ServiceAccount full control of your cluster. Together with the chart's other
default of `admin`/`admin`, anyone who reaches the page owns the cluster.

`values-velero-ui.yaml` sets it to `false`, which uses the chart's own
least-privilege role instead. Always verify:

```bash
kubectl get clusterrolebinding velero-ui -o jsonpath='{.roleRef.name}'
```

```
velero-ui        ← correct. If it says cluster-admin, fix it.
```

**2. The JWT secret cannot be set through the chart.**

`AUTH_SECRET_PASSPHRASE` defaults to a published placeholder string. Leave it and
anyone can forge a login token and **skip the password entirely**. The chart
creates a Secret for it but never wires it into the Deployment, so setting
`secretPassPhrase.value` does nothing. We inject it directly:

```yaml
env:
  - name: AUTH_SECRET_PASSPHRASE
    valueFrom:
      secretKeyRef: { name: velero-ui-auth, key: AUTH_SECRET_PASSPHRASE }
```

### What the UI will not tell you

The UI shows Velero's state accurately — and inherits its blind spot. **A backup
that silently skipped your volume data still appears as `Completed`.** No
dashboard catches that. Keep running the verify script.

Also: UI access lets someone read Secrets in the `velero` namespace, which
includes your S3 keys. And it is plain HTTP. Details in
[`07-web-ui.md`](07-web-ui.md).

---

## Part 10 — Automatic backups on a schedule

A manual backup protects you until you forget. Schedules are the real thing.

### The easy way

```bash
velero schedule create daily \
  --schedule="0 2 * * *" \
  --exclude-namespaces kube-system,velero,minio,local-path-storage \
  --ttl 336h

velero schedule get
velero backup create --from-schedule daily     # run one right now to test it
```

### The better way — in version control

Edit `values/values-local.yaml`:

```yaml
schedules:
  daily-full:
    disabled: false
    schedule: "0 2 * * *"
    template:
      ttl: "336h"                 # keep 14 days
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

> **Cron runs in UTC**, not your local timezone. `0 2 * * *` is 02:00 UTC, which
> is **07:30 IST**. Adjust accordingly.

### A sensible starting policy

| Name | Cron | Keep | For |
|---|---|---|---|
| `hourly-critical` | `0 * * * *` | `168h` (7 days) | Databases |
| `daily-full` | `0 2 * * *` | `336h` (14 days) | All apps |
| `weekly-archive` | `0 3 * * 0` | `2160h` (90 days) | Long term |

### Deleting old backups

Retention is per-backup TTL. Velero's garbage collector runs hourly.

```bash
kubectl -n velero get backups \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,EXPIRES:.status.expiration'

velero backup delete <name> --confirm
```

> **Never use `kubectl delete backup`.** That deletes the record but leaves the
> data in the bucket forever, with nothing pointing at it. Always
> `velero backup delete --confirm`.

---

## Part 11 — Daily commands

```bash
# ── backup ────────────────────────────────────────────────────────────
velero backup create <name> --include-namespaces <ns> --wait
velero backup get
velero backup describe <name> --details
velero backup logs <name>

# ── restore ───────────────────────────────────────────────────────────
velero restore create --from-backup <name> --wait
velero restore create --from-backup <name> \
  --namespace-mappings prod:prod-test --wait      # safe test restore
velero restore describe <name> --details
velero restore logs <name>

# ── schedules ─────────────────────────────────────────────────────────
velero schedule get
velero schedule pause daily
velero schedule unpause daily

# ── health, in order of usefulness ────────────────────────────────────
kubectl -n velero get backupstoragelocation      # must say Available
kubectl -n velero get podvolumebackups           # is volume data present?
kubectl -n velero get pods
kubectl -n velero logs deploy/velero --tail=100
kubectl -n velero logs -l name=node-agent --tail=100

# ── storage housekeeping ──────────────────────────────────────────────
./scripts/recycle-local-pvs.sh                   # reclaim Released PVs
kubectl -n minio exec deploy/minio -- df -h /data  # is the store filling up?
```

---

## Part 12 — Destroy everything and rebuild

Useful for testing, and for proving these instructions are correct.

### Three levels of teardown

```bash
# 1. Remove software, KEEP all backup data
./scripts/uninstall-local.sh

# 2. Also delete all backups and wipe the node directories
./scripts/uninstall-local.sh --purge-data

# 3. Also remove the StorageClass — cluster returns to how it started
./scripts/uninstall-local.sh --purge-all
```

What each level touches:

| Level | Removes | Keeps |
|---|---|---|
| *(no flag)* | Velero, the UI, the demo namespace, MinIO's workloads | **the MinIO PVC — your backups** (it uses `reclaimPolicy: Retain`), and all StorageClasses |
| `--purge-data` | + MinIO's PVC, the `local-static` PV pool, the on-node directories | `local-path-provisioner` (the cluster default StorageClass) |
| `--purge-all` | + `local-path-provisioner` | nothing — the cluster is back to how it started |

> **Do not use `--purge-all` if other workloads use the `local-path`
> StorageClass.** It is the cluster default, so anything installed after Velero
> probably depends on it. Check first:
>
> ```bash
> kubectl get pvc -A | grep local-path
> ```
>
> If that lists namespaces other than this project's, use `--purge-data` instead
> and leave the provisioner in place.

To remove the provisioner later, deliberately and on its own:

```bash
kubectl delete -f manifests/local-path-provisioner.yaml
```

### What the teardown will and will not delete

`--purge-data` wipes the backing directories on the node, and it prints exactly
what it kept. Real output from a run where an unrelated app shared `local-path`:

```
==> Wiping backing directories on the node
    removing /host-opt/velero-local-pvs
    removing /host-opt/local-path-provisioner/pvc-424b547b-…_minio_minio-data
    kept (not ours):
    pvc-5e716223-…_platform-git_git-repos          ← someone else's data, untouched

==> Releasing orphaned PVs that belonged to THIS project
    persistentvolume "pvc-424b547b-…" deleted
    done (other workloads' volumes untouched)
```

Read that `kept (not ours)` line — it is the confirmation that the teardown
stayed inside its own lane.

### Teardown only ever deletes what this project owns

An early version of the purge matched volumes by **StorageClass name**, which
would have deleted *any* `local-path` volume in the cluster — including unrelated
apps that legitimately use the default class. That was caught before it ran, on a
cluster that by then had a monitoring stack using `local-path`:

```
WILL DELETE (ours):
  local-static-pv-1 … pv-4                   claim=velero-demo/demo-data
  pvc-513b0298-…                             claim=minio/minio-data
WILL KEEP (not ours):
  pvc-47bc5700-…    sc=local-path            claim=monitoring/victoriametrics
```

Ownership is now decided by the `velero.io/pv-pool` label or a `claimRef` into
`minio` / `velero` / `velero-demo` / `velero-ui` — never by StorageClass. The
node-directory wipe is scoped the same way: it removes `/opt/velero-local-pvs`
wholesale, but under the shared `/opt/local-path-provisioner` it deletes only
directories matching `*_<our-namespace>_*`.

**If you write your own teardown, scope it by ownership, not by StorageClass.**

The `--purge-data` step matters more than it looks. `local-path-retain` and the
static PVs use `reclaimPolicy: Retain`, so deleting a PVC **leaves the real files
on the node's disk**. Without wiping them, a "fresh" install silently inherits
old data. The script runs a Job on the node to remove
`/opt/velero-local-pvs` and `/opt/local-path-provisioner`.

### The uninstall deadlock you will hit if you do this by hand

If you delete Velero's CRDs yourself, the teardown **hangs forever**. This
happened during a real run here.

Velero puts finalizers on its own objects, for example
`restores.velero.io/external-resources-finalizer`. **Only the Velero controller
removes them** — and `helm uninstall` already deleted it. So:

1. You delete the CRDs.
2. Kubernetes adds `customresourcecleanup.apiextensions.k8s.io` and tries to
   remove every `Restore` object first.
3. Those objects still hold their Velero finalizer.
4. Nothing is left to clear it. `kubectl delete crd --wait` blocks indefinitely.

Symptom:

```bash
kubectl get crd | grep velero.io
```

```
restores.velero.io    2026-08-14T19:16:06Z     ← stuck Terminating
```

The fix — **strip the finalizers first, then delete the CRDs**:

```bash
kubectl -n velero get restores.velero.io \
  -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | \
  xargs -r -I{} kubectl -n velero patch restore.velero.io {} \
    --type=merge -p '{"metadata":{"finalizers":null}}'
```

`uninstall-local.sh` now does this automatically for every Velero resource type
before touching the CRDs, and deletes CRDs with `--wait=false` plus a bounded
timeout so it can never hang again. **This is the main reason to use the script
rather than hand-rolling the teardown.**

### Rebuild

```bash
./scripts/install-all.sh
```

That runs storage → MinIO → Velero → the destroy/restore verification → the web
UI, and stops with an error if any stage fails.

```bash
./scripts/install-all.sh --no-verify   # skip the test
./scripts/install-all.sh --no-ui       # skip the UI
```

Your credentials in `.secrets/` are reused, so the rebuilt MinIO has the same
keys. Delete `.secrets/` first if you want brand-new ones.

### This was actually done — here is the real output

Everything in this document was destroyed and rebuilt to check these instructions
are correct. Starting state after `--purge-all`:

```
$ kubectl get sc      → No resources found
$ kubectl get pv      → No resources found
$ kubectl get crd | grep velero.io  → (nothing)
$ kubectl get ns      → no velero, minio, velero-ui or local-path-storage
```

A genuinely empty cluster. Then one command:

```
$ ./scripts/install-all.sh

╔══ STAGE 1-3  storage, MinIO, Velero
    local-path-provisioner rolled out
    local-static PV pool ready (4 volumes)
    bucket 'velero' ready
    BackupStorageLocation phase=Available

╔══ STAGE 4  end-to-end verification
    3/7  backup verify-201044 → Completed
    4/7  PodVolumeBackups for this backup: 1
         verify-201044-h6bpw   Completed   data   kopia   70
    5/7  DESTROYING namespace velero-demo → deleted
    6/7  restore verify-restore-201044 → Completed
    7/7  PASS: volume data byte-identical, nested files intact,
              ConfigMap/Secret/Service all present

╔══ STAGE 5  web UI
    ClusterRoleBinding velero-ui -> velero-ui
    OK: scoped to the chart's own least-privilege role
    login OK, JWT issued
    /api/backups                   1
    /api/restores                  1
    /api/backup-storage-locations  1

╔══ ALL DONE in 249s
```

**Four minutes and nine seconds**, from nothing to a backup system with a proven
restore. The verification and the security check both run inside the install, so
a broken rebuild fails instead of quietly finishing.

### Repeated three times

The cycle is the test, not a formality. It has been run end to end three times,
each from a genuinely empty state (no StorageClass, no PVs, no `velero.io` CRDs,
no project namespaces):

| Cycle | Rebuild | Destroy/restore test | Docs audit |
|---|---|---|---|
| 1 | `249s` | PASS | — |
| 2 | `190s` | PASS | — |
| 3 | `183s` | PASS | 109 passed, 0 failed |

The first teardown deadlocked on the CRD finalizer described above. Cycles 2 and
3 ran clean, which is what validated the fix — the log now shows the finalizers
being cleared *before* the CRDs are deleted:

```
==> Clearing Velero finalizers (MUST happen before deleting the CRDs)
    cleared finalizers: restores/verify-restore-201044
    cleared finalizers: backups/verify-201044
    cleared finalizers: podvolumebackups/verify-201044-h6bpw
    cleared finalizers: podvolumerestores/verify-restore-201044-jp4sx
    cleared finalizers: backuprepositories/velero-demo-default-kopia
==> Removing Velero CRDs
    all velero.io CRDs removed          ← no hang
```

---

## Part 13 — If something breaks

### `BackupStorageLocation` is not `Available`

This blocks everything, so fix it first.

```bash
kubectl -n velero describe backupstoragelocation default
kubectl -n velero logs deploy/velero | grep -i error
```

| Error contains | Cause | Fix |
|---|---|---|
| `NoSuchBucket` | Bucket missing, or path-style not set | Re-run the bucket Job; set `s3ForcePathStyle: "true"` |
| `InvalidAccessKeyId`, `SignatureDoesNotMatch` | Keys wrong or not reloaded | Re-run `gen-credentials.sh`, then `kubectl -n velero rollout restart deploy/velero` |
| `connection refused` | Cannot reach `s3Url` | Test from a pod (below) |
| `certificate signed by unknown authority` | Private CA | Set `caCert` on the location |
| `RequestTimeTooSkewed` | Node clock is wrong | Fix NTP |

Test connectivity from inside the cluster:

```bash
kubectl -n velero run neta --rm -it --restart=Never --image=busybox:1.37 \
  -- sh -c 'wget -qO- http://minio.minio.svc.cluster.local:9000/minio/health/live && echo OK'
```

### Backup says `Completed` but the volume is empty

```bash
kubectl -n velero get podvolumebackups -l velero.io/backup-name=<BACKUP>   # empty = no data
velero backup logs <BACKUP> | grep -i "hostpath\|skipping"
```

Causes, in order of likelihood:

1. **The PVC uses `local-path`** (hostPath). Move it to `local-static`.
2. **node-agent is not on that node.** Check `kubectl -n velero get pods -o wide`
   shows one per node; add tolerations if not.
3. **No backup method chosen.** Set `defaultVolumesToFsBackup: true`.
4. **CSI in use but the VolumeSnapshotClass is unlabelled.** Label it.

### Restored PVC stuck `Pending`

The static PV pool is used up.

```bash
kubectl get pv -l velero.io/pv-pool=local-static
./scripts/recycle-local-pvs.sh
```

### `velero backup logs` fails but the backup succeeded

You are missing `publicUrl`. See [Part 5](#part-5--install-velero). Or just
port-forward:

```bash
kubectl -n minio port-forward svc/minio 9000:9000
```

### Backup stuck `InProgress`

```bash
kubectl -n velero get pods -l name=node-agent    # any RESTARTS? that means OOMKilled
kubectl -n velero logs -l name=node-agent --tail=100
kubectl -n minio exec deploy/minio -- df -h /data
```

Kopia uses a lot of memory on big volumes. Raise
`nodeAgent.resources.limits.memory`.

### Helm refuses your values file

The chart validates values against a schema, so **an unknown key is a hard
error**. Check before touching the cluster:

```bash
helm template velero vmware-tanzu/velero --version 12.1.0 \
  -n velero -f values/values-local.yaml >/dev/null && echo OK
```

### One command to dump everything

```bash
kubectl -n velero get pods,backupstoragelocation,backups,podvolumebackups
kubectl -n velero logs deploy/velero --tail=50
kubectl -n velero logs -l name=node-agent --tail=50
kubectl get sc,pv
kubectl -n minio get pods,pvc
```

---

## Part 14 — Check this document is still true

Docs rot silently. A chart bump, a renamed StorageClass, a changed port — and
suddenly a step here tells you to do something that no longer works.

```bash
./scripts/audit-docs.sh            # full audit, needs a live cluster
./scripts/audit-docs.sh --static   # files only
```

It asserts every concrete claim made across the docs against the repo files *and*
the running cluster — pinned versions, image tags, BackupStorageLocation config,
`velero server` flags, node-agent coverage, StorageClasses, PV pool size, node
ports, UI RBAC — plus that no `:latest` tag or stale version string survives
anywhere. It exits non-zero on any mismatch.

```
════ AUDIT RESULT: 109 passed, 0 failed ════
Documentation matches reality.
```

Versions live in one place at the top of that script. Bump a version there and in
the files, and the audit proves the docs were updated too.

**Run it after any version bump, values change, or cluster change.**

---

## Where to go next

| Document | For |
|---|---|
| [`01-architecture.md`](01-architecture.md) | How Velero works internally |
| [`02-local-cluster.md`](02-local-cluster.md) | Every value explained, MinIO access, storage in depth |
| [`03-cloud-clusters.md`](03-cloud-clusters.md) | AWS, GCP, Azure, DigitalOcean, CSI snapshots |
| [`04-operations.md`](04-operations.md) | Schedules, retention, database hooks, disaster recovery |
| [`05-troubleshooting.md`](05-troubleshooting.md) | Longer failure list |
| [`06-production-notes.md`](06-production-notes.md) | **Read before trusting this with real data** |
| [`07-web-ui.md`](07-web-ui.md) | The UI in detail |
| [`08-deep-test.md`](08-deep-test.md) | The 37-assertion deep test suite |

### The one thing to remember

**A backup you have not restored is not a backup.** Run
`./scripts/verify-backup-restore.sh` regularly. It is cheap, it takes about two
minutes, and it is the only thing that actually tells you your data is
recoverable.
