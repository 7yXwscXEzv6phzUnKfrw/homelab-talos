# Phase 9: Storage (Longhorn block; media storage deferred to Phase 11) — Implementation Plan

> **Scope change (2026-07-22):** Phase 9 ships **Longhorn only**. The NFS `/data`
> media layer (Part C below) is **deferred to Phase 11** and will be redesigned
> for **SMB/CIFS**, not NFS. Reasons: the UNAS Pro has **NFS disabled** (it serves
> UniFi Drive shares over SMB/CIFS), the media consumer (**Plex runs on the Mac
> Mini**, not the cluster), and the only in-cluster consumers (Sonarr/Radarr/etc.)
> are Phase 11. Nothing in Phase 9/10 depends on `/data` — Phase 10 greenfield apps
> use Longhorn block storage. See `reference-nas-unas-pro` memory. Parts A, B, D,
> E below describe the Longhorn work that shipped; Part C is retained as historical
> context for the Phase 11 redesign.

## Context

The foundation milestone (Phases 0–8) is essentially complete: the three-node
Talos cluster, Cilium, Flux, and the internal platform (cert-manager, MetalLB,
Envoy Gateway, ExternalDNS, echo) are live and the 24-hour soak is passing. Phase
9 adds the storage layer that the greenfield apps (Phase 10) and media stack
(Phase 11) depend on:

- **Longhorn** replicated block storage for application config/state, backed up to
  the existing UNAS Pro over CIFS.
- **NFS CSI** for bulk downloads+media on the UNAS Pro, exposed as **one
  hardlink-safe `/data` filesystem** so Sonarr/Radarr do instant hardlinked
  imports instead of copy-then-delete.

This mirrors the guarded, Flux-managed, SOPS-encrypted patterns already
established in Phase 7, plus two Talos machine-config changes. Authoritative spec:
[`talos-flux-platform-plan.md`](talos-flux-platform-plan.md) Phase 9.

### ⚠️ Sequencing gate
**Do not begin Phase 9 mutations until the Phase 8 soak gate passes** (~2026-07-22
07:22 MDT). The Talos volume re-cap (Part A) reboots each node, which would reset
the soak. Per the plan, the old SSDs also stay untouched until Phase 8 closes.

## Locked decisions

| Decision | Value | Source |
|---|---|---|
| Longhorn version | **1.12.0** (chart `https://charts.longhorn.io`) | latest stable 2026-06-02; 1.11+ needs k8s ≥1.34, covers k8s 1.35.6 |
| Namespace | `longhorn-system` (privileged PodSecurity) | legacy + Longhorn requirement |
| Replicas / anti-affinity | 2 replicas, **hard** node anti-affinity (`replicaSoftAntiAffinity: false`) | plan step 4 |
| Data path | `/var/mnt/longhorn` (the Talos user volume) | plan step 3 |
| Backup target | **reuse `cifs://192.168.0.3/Longhorn`**, secret `nas-credentials` (`CIFS_USERNAME`/`CIFS_PASSWORD`) re-encrypted under the new age key | user; `homelab-gitops/infra/longhorn/values.yaml` |
| Recurring jobs | daily snapshot (retain 7) + daily backup (retain 7) | user |
| Longhorn volume cap | **`maxSize: 500GiB`, drop `grow`** (recreates the empty XFS volume) | user + plan step 1 |
| NFS server | `192.168.0.3` (UNAS Pro) | user |
| NFS `/data` | **single static export** with `downloads/`+`media/` siblings; `nfsvers=4.1,hard`; one PV/PVC = whole export (hardlink-safe) | plan steps 8–10 |

### Open item — RESOLVED (2026-07-22): deferred to Phase 11 as SMB
The "exact UNAS NFS export path" is moot: the UNAS Pro has **NFS disabled** and
serves shares over **SMB/CIFS** (UniFi Drive). The media bulk share is
`//192.168.0.3/Prometheus` (folders `media/movies`, `media/tv`); Plex consumes it
off-cluster from the Mac Mini. The in-cluster media `/data` layer is deferred to
**Phase 11** and will use **`csi-driver-smb`** against that share (SMB supports
hardlinks within a share, preserving the Sonarr/Radarr hardlink requirement). The
Longhorn CIFS backup target (`cifs://192.168.0.3/Longhorn`) is unaffected.

## Part A — Talos machine-config changes (do first, before installing Longhorn)

Two edits bundled into one talhelper change, applied one node at a time:

1. **Volume re-cap** — `talos/talconfig.yaml` `userVolumes[longhorn]`: set
   `provisioning.maxSize: 500GiB`, remove `grow: true`, remove `minSize: 700GiB`
   (or set ≤ cap). Reclaims ~280 GiB/node for node-local scratch. Safe now because
   the volume is empty (pre-Longhorn); XFS can't shrink online so Talos
   destroys+recreates it.
2. **kubelet extraMounts** — `talos/patches/machine.yaml`: add
   `machine.kubelet.extraMounts` exposing the Longhorn data dir with shared
   propagation (Longhorn manager/CSI pods bind-mount it). This does **not** exist
   today and is required for Longhorn on Talos:
   ```yaml
   machine:
     kubelet:
       extraMounts:
         - destination: /var/mnt/longhorn
           type: bind
           source: /var/mnt/longhorn
           options: [bind, rshared, rw]
   ```

**Guard updates** (or `just talos validate`/`source-validate` will fail):
- `talos/mod.just` — the guard asserting the longhorn volume `minSize == 700GiB`
  (~line 77) → assert the new `maxSize: 500GiB` and absence of `grow`.
- `.just/bootstrap.just` — the historical Phase-4 live-size guards
  (`836832854016` at ~lines 52, 338) are in unused Phase-4 recipes; update or note
  them so they don't mislead. The `reboot` recipe only checks `u-longhorn`
  `phase: ready` (~line 1058), so it is unaffected.

**Applying the change (tooling gap to resolve):** `just talos apply-live` is
no-reboot-only; the volume destroy/recreate very likely needs a reboot, so
apply-live's dry-run will refuse it. Add a guarded reboot-capable day-2 apply
recipe **`just talos apply-node <node>`** (mirrors `apply-live` but uses
`talosctl apply-config --mode=auto` and, like `bootstrap reboot`, runs the
pre-health gate + post-apply recovery verification incl. `u-longhorn` back to
`ready` at the new size). Gate with `TALOS_APPLY_NODE_CONFIRM='apply-node:<node>:<ip>'`.
Then per node: `just talos generate` → `just talos validate` → `just talos apply-node nucN`.
(If the dry-run shows the change is actually no-reboot, `apply-live` suffices and
`apply-node` is unnecessary — decide from the dry-run.)

## Part B — Longhorn (Flux app: `kubernetes/apps/storage/longhorn/`)

New `storage` namespace-domain following the Phase 7 app pattern. Files:

- `kubernetes/apps/storage/kustomization.yaml` → lists `./longhorn/ks.yaml`,
  `./csi-driver-nfs/ks.yaml`.
- Add `./storage` to `kubernetes/apps/kustomization.yaml`.
- `storage/longhorn/ks.yaml` — **two** Flux Kustomizations (Phase 7 metallb
  pattern): `longhorn` (controller) → `longhorn-config` (`dependsOn: [longhorn]`)
  for the CIFS secret + RecurringJobs. Both `dependsOn: cilium` at minimum;
  `decryption: sops/sops-age`; staged `suspend: true`.
- `storage/longhorn/app/`: `helmrepository.yaml` (charts.longhorn.io),
  `helmrelease.yaml` (chart `longhorn` `version: 1.12.0`, valuesFrom ConfigMap),
  `namespace.yaml` (`pod-security.kubernetes.io/*: privileged`, like metallb),
  `values.yaml`, `kustomization.yaml` (+ configMapGenerator).
- `storage/longhorn/config/`: `nas-credentials.sops.yaml` (Opaque, CIFS creds),
  `recurring-jobs.yaml` (RecurringJob CRs), `kustomization.yaml`.

**values.yaml** (mirror the legacy `homelab-gitops/infra/longhorn/values.yaml`
that worked, plus the plan's additions):
```yaml
preUpgradeChecker: { jobEnabled: false }
defaultSettings:
  defaultDataPath: /var/mnt/longhorn      # NEW: Talos user volume
  replicaSoftAntiAffinity: false          # NEW: hard node anti-affinity
  backupTarget: "cifs://192.168.0.3/Longhorn"
  backupTargetCredentialSecret: nas-credentials
  snapshotDataIntegrity: enabled
  backupCompressionMethod: gzip
metrics: { serviceMonitor: { enabled: false } }   # no Prometheus until Phase 10
persistence:
  defaultClass: true
  defaultClassReplicaCount: 2
```
(Legacy `longhornManager` NoSchedule toleration is unnecessary here —
`allowSchedulingOnControlPlanes: true` means no control-plane taint — omit unless
verification shows otherwise.)

**RecurringJobs** (`config/recurring-jobs.yaml`, `longhorn.io/v1beta2`): a
`snapshot` job (cron daily, retain 7) and a `backup` job (cron daily, retain 7),
both in the `default` group so they apply to all volumes.

**CIFS secret** (`config/nas-credentials.sops.yaml`): recreate `nas-credentials`
in `longhorn-system` with `CIFS_USERNAME`/`CIFS_PASSWORD` in `stringData`,
**re-encrypted under the new repo age key** (`age1da2c…`, per `.sops.yaml`) — do
not copy the legacy ciphertext. Authored via the guarded secret recipe below.

## Part C — media bulk `/data` — DEFERRED TO PHASE 11 (redesign as SMB)

> **Not built in Phase 9.** The NFS design below is superseded: the UNAS serves
> SMB/CIFS, not NFS, and there is no in-cluster media consumer until Phase 11. In
> Phase 11, build **`csi-driver-smb`** against `//192.168.0.3/Prometheus`
> (credentials via the same guarded SOPS pattern as `nas-credentials`), exposing a
> single static RWX PV so `media/movies` + `media/tv` (and future `downloads/`)
> share one filesystem for hardlink-safe imports. The NFS notes below are kept
> only as a starting point for that Phase 11 work.

- ~~Install **`csi-driver-nfs`** (kubernetes-csi/csi-driver-nfs Helm chart, latest
  stable). No Talos extension needed — Talos mounts NFSv4 via its in-kernel client.~~
- Expose the bulk export as **one static PV** (not dynamic subdir provisioning,
  which would fragment the filesystem and defeat hardlinks):
  - `PersistentVolume` with `csi.driver: nfs.csi.k8s.io`,
    `volumeAttributes: { server: 192.168.0.3, share: <UNAS data export path> }`,
    `mountOptions: [nfsvers=4.1, hard]`, `accessModes: [ReadWriteMany]`,
    `persistentVolumeReclaimPolicy: Retain`.
  - A matching `PersistentVolumeClaim` (RWX) that media apps mount once at `/data`;
    address `/data/downloads` and `/data/media`. One PVC = whole export = one
    filesystem ⇒ hardlinks work.
- StorageClass: a non-provisioning/`storageClassName: ""` static bind, or a
  csi-driver-nfs StorageClass reserved for any future dynamic NFS needs — but the
  `/data` volume itself is the static PV above.

## Part D — Guarded Just workflow (mirror the Phase 7 trio)

- `just repo storage-secrets` (in `.just/repository.just`, like `phase7-secrets`):
  read `CIFS_USERNAME`/`CIFS_PASSWORD` from env, optionally verify against the
  share (best-effort `smbclient`), write only SOPS ciphertext to
  `storage/longhorn/config/nas-credentials.sops.yaml`. Gate:
  `STORAGE_SECRETS_CONFIRM`.
- `just kube storage-validate` (read-only): validate the storage source graph,
  `sops filestatus` the CIFS secret, render pinned Longhorn + csi-driver-nfs
  charts, assert StorageClass params (2 replicas, `/var/mnt/longhorn`,
  anti-affinity) and the NFS PV mount options. `require-bash` guard.
- `just bootstrap storage` (guarded mutation): clean-published-Git gate, all-child
  Kustomizations staged `suspend: true`, `just repo secrets` + `storage-validate`,
  resume in order (longhorn → longhorn-config → csi-driver-nfs → data PV/PVC),
  `flux reconcile`/`kubectl wait Ready`, cleanup-trap re-suspend on failure. Gate:
  `STORAGE_BOOTSTRAP_CONFIRM`.
- `just kube storage-verify` (read-only acceptance): see Exit Gate below.
- README command-table rows for each (Recipe | Purpose | Requires | Availability).

## Part E — Docs

- `docs/phase-9-storage.md`: implementation evidence, the CIFS/NFS integration
  runbook (like `docs/pihole-integration.md`), volume-recap procedure, recovery
  commands, and acceptance evidence table.
- `kubernetes/apps/storage/longhorn/README.md` + `csi-driver-nfs/README.md`
  (pinned version in backticks + purpose, per repo convention).
- Update the master plan Phase 9 status when complete.

## Critical files

- Talos: `talos/talconfig.yaml` (userVolumes), `talos/patches/machine.yaml`
  (kubelet extraMounts), `talos/mod.just` (volume guard), new `apply-node` recipe.
- Flux apps: `kubernetes/apps/storage/**`, `kubernetes/apps/kustomization.yaml`.
- Just: `.just/repository.just` (storage-secrets), `.just/bootstrap.just`
  (storage), `kubernetes/mod.just` (storage-validate/-verify), `README.md`.
- Reference (read-only): `homelab-gitops/infra/longhorn/{values.yaml,longhorn.yaml,nas-credentials.yaml}`.

## Verification / Exit Gate

Run end-to-end via `just kube storage-verify` after `just bootstrap storage`:

1. **Longhorn health** — `longhorn-manager`, `instance-manager`, CSI pods Running;
   3 nodes registered with a schedulable disk at `/var/mnt/longhorn`; a test PVC
   (default `longhorn` StorageClass) binds, and its 2 replicas land on 2 different
   nodes (hard anti-affinity).
2. **Backup target** — Longhorn shows the CIFS target healthy; take a manual
   backup of the test PVC and **restore it into a new PVC** (data matches).
3. **Replica rebuild after reboot** — `just bootstrap reboot <node>`; confirm the
   evacuated replica rebuilds and the volume returns healthy.
4. **NFS `/data`** — the static PVC binds RWX; a pod writes/reads under
   `/data/downloads` and `/data/media`.
5. **Hardlink proof** — `ln` (or `cp -l`) a file between `/data/downloads` and
   `/data/media`, confirm identical inode + link count 2 and no extra space used
   (this is the make-or-break test for the media stack).
6. Cilium/Talos/etcd/foundation acceptance still green (`foundation-verify`).

## Notes / risks

- **k8s 1.35 vs Longhorn 1.12** — 1.12 is the newest stable and 1.11 already
  supports k8s ≥1.34; verify 1.12.0's published support matrix lists 1.35 at
  install time (the plan mandates this check).
- **Volume re-cap is destructive** but safe now (empty, pre-Longhorn); it becomes
  a disruptive replica evacuation if deferred until after Longhorn holds data — so
  do Part A first.
- **Transcode scratch** (plan step 9) is a *decision recorded here, built in
  Phase 11*: use node-local NVMe headroom reclaimed in Part A (a future
  `local-path` StorageClass) or `emptyDir`/`tmpfs` — never NFS. Not a Phase 9
  build item.
