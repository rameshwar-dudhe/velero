# 08 — The deep test

```bash
./scripts/deep-test.sh            # full suite, ~8-12 min
./scripts/deep-test.sh --keep     # leave the test namespaces for inspection
```

**Latest run: 37 assertions, 0 failed.** Run twice on separate from-scratch
installs, producing identical numbers — 255 files checksummed, 8,395,536 bytes
uploaded, dedup adding 14 objects vs 21, bucket reclaim 85 → 79 on delete. That
reproducibility matters: the result is a property of the system, not of one run.

## Why this exists separately from `verify-backup-restore.sh`

| | `verify-backup-restore.sh` | `deep-test.sh` |
|---|---|---|
| Runtime | ~2 min | ~8–12 min |
| Data | one marker file | 255 files, 8 MB binary, unicode/space names, custom permissions, symlink |
| Comparison | `diff` on one file | **per-file sha256 manifest** of the whole tree |
| Scenarios | destroy + restore | 37 assertions across 12 behaviours |
| Negative tests | none | yes — asserts the hostPath trap still behaves as documented |
| Use it for | every change, quick confidence | before trusting real data; after any upgrade |

The smoke test answers *"did anything come back?"*. The deep test answers *"did
**everything** come back, byte for byte, and do all the surrounding behaviours
still hold?"*

## What each group proves

### T01–T03 Preconditions
Velero ready, BackupStorageLocation `Available`, and **one node-agent per node**.
That last one matters: a missing agent means pods on that node silently lose
their volume data.

### T04–T05 A fixture designed to break things
The test builds a data tree that exercises what filesystem backup usually gets
wrong:

| Thing | Why it's in there |
|---|---|
| 250 small files across nested dirs | many-small-files is the slow, error-prone case |
| an 8 MB `/dev/urandom` binary | forces Kopia to chunk and reassemble |
| `нested/файл-测试.txt` | non-ASCII filenames |
| `nested/name with spaces.txt` | filenames needing quoting |
| `chmod 600` and `chmod 755` files | permission preservation |
| an empty directory | directories with no contents are easy to lose |
| a symlink | links must not be silently dereferenced |

Then it records `sha256sum` of **every file** plus a mode manifest. That manifest
is the actual test.

### T06–T10 Backup, capture, dedup, TTL
- backup `Completed` **with zero warnings**
- exactly one `PodVolumeBackup`, `Completed`, **>8 MB uploaded** — proof the
  binary was really included, not skipped
- bucket object count grew
- **deduplication proven**: a second backup of unchanged data adds far fewer
  objects than the first (observed: 14 vs 21)
- expiration lands ~168h out, matching `defaultBackupTTL`

### T11–T19 Full disaster recovery
Destroys the namespace outright, restores from object storage, then:

- **every one of the 255 files matches by sha256** — this is the assertion that
  matters most
- permissions and the directory tree are identical
- unicode and space-in-name files came back readable
- the 8 MB binary's checksum matches
- ConfigMap and Secret contents are intact
- the Service got a **fresh `clusterIP`** — proving Velero strips cluster-specific
  fields rather than restoring a stale IP

### T20–T21 Relocation and selectivity
- restore into a **different** namespace via `--namespace-mappings`, and all 255
  files match there too — this is the migration path
- `--include-resources configmaps,secrets` restores only those, and **provably
  does not** bring the PVC or Deployment

### T22 The negative test — the most valuable one here
This asserts the documented failure mode **still fails the same way**:

```
✅ T22   hostPath backup still reports Completed        Completed
✅ T22b  hostPath volume produced NO PodVolumeBackup    0
✅ T22c  …and it did raise a warning (the only signal)  1 > 0
✅ T22d  skip reason present in log                     hostPath not supported
```

It deploys a PVC on `local-path` — deliberately the wrong StorageClass — and
asserts Velero silently skips it while still reporting `Completed`.

> **If T22 ever fails, that is news, not a bug.** It means Velero's behaviour
> changed, and the storage guidance in [`02-local-cluster.md`](02-local-cluster.md)
> and `CLAUDE.md` needs revisiting. That is exactly why it is a test.

It also pins down the *only* signal you get: a non-zero `WARNINGS` count.

### T23–T25 Lifecycle and observability
- restoring over a live namespace is a **no-op** (resource count unchanged)
- a `Schedule` is created with the right cron and `--from-schedule` triggers a
  real backup
- `velero_backup_success_total` is actually counting
- **`velero backup delete` frees objects in the bucket** (observed: 85 → 79) —
  proof that deletion reclaims space rather than orphaning data

## Hard failures vs informational

Two of the checks are deliberately informational rather than hard failures,
because a difference there is explainable rather than wrong:

- **T09 dedup** — reported as info if the second backup does not add fewer
  objects. Kopia's blob packing can occasionally make a small second backup look
  flat.
- **T15 permissions** — reported as info if directory modes differ, since
  `fsGroup` legitimately rewrites group bits on the mounted volume.

Everything else is a hard assertion. The script exits non-zero if any fails and
prints the list.

## Reading the output

```
━━ T11-T19  Full DR: destroy the namespace and rebuild it
  ✅ T11   namespace destroyed                gone
  ✅ T14   every file byte-identical          255 files, sha256 match
  ✅ T19   Service got a fresh clusterIP      10.96.203.51 → 10.99.20.19

════════ DEEP TEST RESULT ════════
  passed:        37
  failed:        0
  informational: 0

  DEEP TEST PASSED — backups are trustworthy on this cluster.
```

## Cleanup

The script deletes its own namespaces (`vdt-src`, `vdt-clone`, `vdt-partial`,
`vdt-trap`), its backups, and its schedule on exit — including when it fails, via
a `trap`. Pass `--keep` to inspect the aftermath.

Because each restore consumes a static `local-static` PV, run the recycler after
a few runs:

```bash
./scripts/recycle-local-pvs.sh
```

## When to run it

| Situation | Test |
|---|---|
| routine change, quick confidence | `verify-backup-restore.sh` |
| **Velero or chart version bump** | **`deep-test.sh`** |
| storage driver or StorageClass change | **`deep-test.sh`** |
| before trusting it with real data | **`deep-test.sh`** |
| after a cluster upgrade | **`deep-test.sh`** |
| checking the docs are still accurate | `audit-docs.sh` |

The three together are the full quality gate:

```bash
./scripts/install-all.sh        # build
./scripts/deep-test.sh          # 37 assertions — is the data really safe?
./scripts/audit-docs.sh         # 109 assertions — do the docs still match?
```
