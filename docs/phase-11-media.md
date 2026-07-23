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
| Plex (single replica, node-reschedule verified) | In progress (PR 11-2) |
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

- `kubernetes/apps/media/plex/` — app-template HelmRelease, single Plex container
  (pinned image), config PVC on Longhorn (RWO) with `strategy: Recreate`, media from
  the `media-data` RWX PVC at `/data/media`, transcode scratch on node-local
  `emptyDir`/`tmpfs` (never the NAS).
- Exposed at `plex.lab.supermorphic.com`, LAN-only; remote/public streaming
  deferred.
- Plex stays a single replica (no active-active support). The RWX SMB share is
  shared across pods/apps, not for Plex replicas.
- First-run: the Plex claim token (`plex.tv/claim`) is a short-lived manual step —
  never committed.

### Acceptance evidence — node-failure reschedule (Phase-11 gate)

The point of this phase: prove the single Plex replica recreates on another NUC when
its node goes away, with the Longhorn RWO config volume re-attaching and the SMB media
re-mounting.

- **Safe form (guarded recipe):** `just kube plex-reschedule-verify` cordons the node
  running Plex, deletes the pod, waits for it to come back **Ready on a different
  node**, then uncordons. This exercises the RWO re-attach + SMB re-mount + Recreate
  path without a full outage.
- **Full node-down form:** power off / reboot the node running Plex and confirm the pod
  reschedules once Longhorn releases the RWO volume (its node-down timeout). If
  reschedule is too slow, tune Longhorn's node-down pod-deletion policy.

<!-- TODO: paste the plex-reschedule-verify output (orig node -> new node) and, if run,
     the full node-down observation, once executed against the live cluster. -->

## Plex hardware transcoding (Intel QuickSync)

- Confirm the `siderolabs/i915` extension exposes `/dev/dri/renderD128` on every
  NUC, deploy the Intel GPU device plugin, validate `gpu.intel.com/i915` resource
  discovery, and request it in the Plex pod.
- Gated after the reschedule milestone so GPU scheduling does not complicate that
  proof. All three NUCs carry `i915`, so the pod can still schedule anywhere.

### Acceptance evidence — hardware transcode

<!-- TODO: confirm a transcode session uses /dev/dri (QuickSync), not software. -->

## Recovery notes

<!-- TODO (finalized in Phase 14): Plex config PVC recovery via Longhorn backup;
     bulk media is NAS-owned (not in Longhorn backups); reschedule behavior. -->
