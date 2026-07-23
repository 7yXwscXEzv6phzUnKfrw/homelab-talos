# Phase 11: Media Platform — Shared Storage and Plex

## Status

**Planned.** Phase 11 stands up the shared SMB `/data` filesystem and brings Plex
into the cluster (it historically ran off-cluster on the Mac Mini). The gating
milestone is a single-replica Plex that recreates on another NUC after a node
failure. The VPN download client (Phase 12), the *arr automation apps (Phase 13),
and requests + observability (Phase 14) follow as their own phases.

| Deliverable | State |
|---|---|
| SMB CSI driver + shared `/data` RWX filesystem | **Complete** (bootstrapped) |
| Plex (single replica, node-reschedule verified) | **Reschedule verified** (2026-07-23); HW transcode pending (11-3) |
| Plex hardware transcoding (Intel QuickSync) | Planned |

## Delivery pattern (every app)

Same as Phase 10: `kubernetes/apps/<domain>/<app>/` with a staged `ks.yaml`
(`suspend: true`) → `app/` (manifests/HelmRelease + any SOPS secret) → optional
`config/`. Guarded workflow: `just repo <app>-secrets` (if secrets) →
`just kube <app>-validate` → commit/push/PR → merge → `just bootstrap <app>` →
`just kube <app>-verify` → durable `suspend: false` flip.

Media apps use the bjw-s **app-template `5.0.1`** chart (OCIRepository
`oci://ghcr.io/bjw-s-labs/helm/app-template`), one HelmRelease per app, all image
tags pinned. UIs are exposed only through the `internal` Envoy Gateway
(`sectionName: https`, `*.lab.supermorphic.com`), with the app namespace carrying
`gateway.supermorphic.com/access: internal`.

## Shared `/data` storage foundation

- `kubernetes/apps/storage/csi-driver-smb/` — the SMB CSI driver
  (`smb.csi.k8s.io`), chart pinned, namespace `csi-driver-smb` (PSA `privileged`),
  `dependsOn: cilium`.
- `kubernetes/apps/media/` — the `media` namespace (PSA `privileged` +
  gateway-access label), a shared `app-template` OCIRepository, and a **single
  static RWX PersistentVolume** bound to `//192.168.0.3/Prometheus` with a
  `media-data` PVC mounted at `/data` in every media pod.
- One share, one PVC: `downloads/` and `media/` are subfolders on the same share so
  Sonarr/Radarr imports **hardlink** instead of copying. Bulk media never lives on
  Longhorn.
- Directory layout:
  ```text
  /data/
  ├── downloads/{incomplete,movies,tv}
  └── media/{movies,tv}
  ```
- SMB credentials come from a SOPS Secret written by `just repo media-smb-secrets`;
  runtime UID/GID and SMB mount modes (`uid=/gid=/file_mode=/dir_mode=`) are chosen
  so Plex and the later *arr/qBittorrent apps share consistent ownership without a
  startup `chown` of the library.

### Acceptance evidence — hardlink proof

<!-- TODO: record `ln` + `stat -c %h`/inode evidence showing a file moved between
     /data/downloads and /data/media becomes a hardlink (Phase-9 deferred step 10). -->

## Plex

This is **single-active Plex with automatic Kubernetes + Longhorn recovery across
nodes** — not highly available Plex. On a hard node failure expect a **minutes-not-
seconds** outage while Kubernetes marks the node gone, Longhorn detaches/reattaches the
config volume, and Plex starts and checks its database.

- `kubernetes/apps/media/plex/` — app-template HelmRelease, single Plex container
  (pinned image), config PVC on Longhorn (**ReadWriteOncePod**) with `strategy:
  Recreate`, media from the shared `media-data` RWX PVC at `/data`, transcode scratch on
  a node-local `emptyDir` (never the NAS). A 120s termination grace period lets Plex
  close its SQLite DB cleanly on planned drains.
- Exposed at `plex.lab.supermorphic.com` through the internal Envoy gateway only,
  LAN-only; remote/public streaming deferred. **No MetalLB LoadBalancer / no direct
  `:32400` LAN IP** — so local GDM auto-discovery does not work; clients connect via the
  custom access URL (below).
- Plex stays a single replica (no active-active support). The RWX SMB share is
  shared across pods/apps, not for Plex replicas.

### First-run (manual, one-time)
- Sign in at `https://plex.lab.supermorphic.com` (the short-lived `plex.tv/claim` token
  is never committed).
- **Settings → Network → Custom server access URLs:** add
  `https://plex.lab.supermorphic.com` so clients reach Plex through the gateway (needed
  because there is no direct `:32400` LAN IP).
- Add libraries from `/data/media/movies` and `/data/media/tv`.
- **Settings → Transcoder:** set the transcode temporary directory to `/transcode`.
- **Enable Plex's scheduled database backups** (Settings → Scheduled Tasks) as a second
  layer beyond Longhorn.
- **Disable "Empty trash automatically after every scan"** so a transient SMB/NAS outage
  does not delete library entries when media briefly disappears.

### Backups
The Plex `/config` PVC is **already covered by the existing Longhorn RecurringJobs**
(`daily-snapshot` + `daily-backup`, group `default`) — no Plex-specific or higher-cadence
jobs are added (they would conflict with the global policy). Longhorn replication is not
a backup; the daily off-cluster backup to the NAS + Plex's own scheduled DB backup are.
Periodically restore a Longhorn backup into a throwaway PVC to prove it (see the test
matrix).

### Acceptance evidence — node-failure reschedule (Phase-11 gate)

The point of this phase: prove the single Plex replica recreates on another NUC when
its node goes away, with the Longhorn config volume re-attaching and the SMB media
re-mounting.

- **Safe form (guarded recipe):** `just kube plex-reschedule-verify` cordons the node
  running Plex, deletes the pod, waits for it to come back **Ready on a different
  node**, then uncordons. This exercises the config re-attach + SMB re-mount + Recreate
  path without a full outage.
- **Full node-down form:** power off / reboot the node running Plex and confirm the pod
  reschedules once Longhorn releases the config volume (its node-down timeout). If the
  replacement pod stays Pending, tune Longhorn's node-down pod-deletion policy; if it is
  stuck specifically on the old pod's `ReadWriteOncePod` claim, force-delete the old pod
  (or revert `/config` to `ReadWriteOnce`).

Full acceptance test matrix to record before calling Phase 11 done:

| Test | Expectation |
|---|---|
| Planned drain (`plex-reschedule-verify` / `kubectl drain`) | Plex stops cleanly, config re-attaches on another NUC, same server identity + library |
| Hard node-down (power off the Plex node) | Automated recovery after Longhorn's node-down timeout; measure RTO |
| One Longhorn replica lost | Plex keeps serving from the surviving replica; replica rebuilds |
| SMB/NAS outage | `/config` DB stays healthy; media returns when the share is back; library not trashed |
| Longhorn restore | Restore the `/config` backup into a throwaway PVC and start an isolated Plex against it |

**Evidence (2026-07-23):** `just kube plex-reschedule-verify` passed — pod moved
`nuc2 -> nuc1`, the RWOP config volume re-attached and the SMB media re-mounted, and
Plex returned Ready. This is the Phase-11 core milestone (single replica recreates on
another NUC). The Plex bootstrap's `plex-verify` also passed (Kustomization + HelmRelease
Ready, rollout complete, HTTPRoute Accepted, Pi-hole DNS, `/identity` over TLS).

<!-- TODO (remaining, when convenient): hard node-down RTO measurement, one-replica-loss
     check, SMB-outage behavior, and a Longhorn restore-into-new-PVC test. -->

## Plex hardware transcoding (Intel QuickSync)

- Confirm the `siderolabs/i915` extension exposes `/dev/dri/renderD128` on every
  NUC, deploy the Intel GPU device plugin, validate `gpu.intel.com/i915` resource
  discovery, and request it in the Plex pod.
- The `gpu.intel.com/i915` request itself targets Plex to GPU-capable nodes (the device
  plugin advertises the resource only where `/dev/dri` exists), so no hard node-pin; a
  `media.supermorphic.com/plex-capable` label + nodeAffinity is the fallback for finer
  control.
- Gated after the reschedule milestone so GPU scheduling does not complicate that
  proof. All three NUCs carry `i915`, so the pod can still schedule anywhere.

### Acceptance evidence — hardware transcode

<!-- TODO: confirm a transcode session uses /dev/dri (QuickSync), not software. -->

## Recovery notes

<!-- TODO (finalized in Phase 14): Plex config PVC recovery via Longhorn backup;
     bulk media is NAS-owned (not in Longhorn backups); reschedule behavior. -->
