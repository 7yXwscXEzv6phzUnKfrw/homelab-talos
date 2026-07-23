# Media Stack Architecture Plan (repository-native)

Stage-1 deliverable for the media platform (`plans/talos-media-stack.md`). It records
the repository-native design that Phases 11–14 of
[`talos-flux-platform-plan.md`](talos-flux-platform-plan.md) implement:
Plex, qBittorrent + Gluetun (ProtonVPN WireGuard), Prowlarr, Sonarr, Radarr, and
Overseerr. Plex is the media server and moves **into** the cluster (previously on the
Mac Mini). All decisions below are grounded in the current repo, not the handoff's
placeholders.

## Repository findings (verified conventions)

- **GitOps chain:** Flux root `kubernetes/flux/clusters/prod` → `cluster-apps`
  Kustomization → `kubernetes/apps/kustomization.yaml` lists category dirs → each
  category `kustomization.yaml` lists app `ks.yaml`s. New category `media` is added
  with `- ./media`.
- **App anatomy:** `kubernetes/apps/<domain>/<app>/{ks.yaml, app/, [config/]}`.
  `ks.yaml` is a Flux `Kustomization` in `flux-system`; `dependsOn` uses other
  `ks.yaml` `metadata.name`s; `decryption {provider: sops, secretRef {name:
  sops-age}}` is present only when the path holds a `*.sops.yaml`.
- **Chart sources:** both HelmRepository (gatus, longhorn, trivy) and OCIRepository
  (cilium, cert-manager, envoy-gateway) are in use. **bjw-s app-template is not yet
  used** — this stack introduces it (community standard for *arr + gluetun-sidecar
  pods). HelmRelease values live in a standalone `values.yaml` → `configMapGenerator`
  (`disableNameSuffixHash: true`, label `reconcile.fluxcd.io/watch: Enabled`) →
  `valuesFrom`.
- **Exposure:** HTTPRoute → Gateway `internal`/`networking`/`sectionName: https`,
  host `<app>.lab.supermorphic.com`, annotation `external-dns.k8s.io/audience:
  internal`; namespace label `gateway.supermorphic.com/access: internal` is
  mandatory. Wildcard `*.lab.supermorphic.com` cert
  (`wildcard-lab-supermorphic-com-tls`) already covers every name — no cert work.
- **Storage today:** Longhorn `1.12.0`, default StorageClass `longhorn`, 2 replicas
  hard anti-affinity, `/var/mnt/longhorn`, daily snapshot+backup RecurringJobs
  (`default` group) to `cifs://192.168.0.3/Longhorn`. **No shared-filesystem CSI
  driver exists** — `csi-driver-smb` + a shared `/data` RWX filesystem is a Phase-11
  prerequisite.
- **SOPS:** `.sops.yaml` rule[1] encrypts `data|stringData` under one age recipient;
  secrets created only via guarded `just repo *-secrets` (operator-run,
  `*_CONFIRM`-gated, never printing values). Clone the `storage-secrets` pattern.
- **`just`:** each app adds a cluster-independent `<app>-validate` (derives chart
  version from the manifest via `yq`; `kustomize build` + pinned `helm template`) to
  the root `.justfile ci`; `<app>-verify` + `bootstrap <app>` stay operator-only.
- **Talos/security:** Cilium kube-proxy replacement (tunnel/vxlan); `tun` is built
  into the Talos kernel (no extension); `siderolabs/i915` already enabled (QuickSync).
  Namespaces carry PSA labels; only NET_ADMIN/host-mount workloads use `privileged`.
  No NetworkPolicy/CiliumNetworkPolicy in use today.

## Architecture decisions

1. **Chart:** bjw-s **app-template `5.0.1`** (OCIRepository), one HelmRelease per
   app; qBittorrent+Gluetun = one HelmRelease / one Pod. Image tags pinned; the
   upstream qBittorrent/Gluetun example is a capability reference only, not copied.
2. **Namespace:** one `media` namespace, PSA `privileged` (NET_ADMIN forces it) +
   gateway-access label. Simpler service discovery and shared-PVC access than
   splitting; matches `longhorn-system`/`monitoring` which are already privileged.
3. **Shared media:** one static RWX PV → `//192.168.0.3/Prometheus`, one `media-data`
   PVC mounted `/data` everywhere, `downloads/` + `media/` siblings on the one share
   (hardlink-safe). Bulk media never on Longhorn.
4. **App config:** Longhorn RWO PVC per app, Deployment `strategy: Recreate` (RWO
   rule); auto-covered by the existing Longhorn backup RecurringJobs.
5. **Plex media server:** in-cluster, single replica, QuickSync via `/dev/dri` (Intel
   device plugin), transcode scratch node-local. No Jellyfin.
6. **VPN:** Gluetun native sidecar (startup fail-closed) + firewall kill switch;
   `NET_ADMIN` + `hostPath /dev/net/tun` (CharDevice), no privileged mode. ProtonVPN
   WireGuard; port forwarding via Gluetun-native `VPN_PORT_FORWARDING_UP_COMMAND` →
   qBittorrent API on localhost. Control API in-cluster only.
7. **First-run config:** *arr/qBittorrent API keys and inter-app links are manual and
   persist in config PVCs — no brittle declarative API automation.

## Dependency graph (Flux `dependsOn`)

```text
cilium
├── csi-driver-smb                     (Phase 11)
├── media                              (namespace + shared app-template OCIRepository)
│   └── media-storage  [media, csi-driver-smb]        (static RWX PV + media-data PVC)
│       ├── plex            [media-storage, internal-gateway]        (Phase 11)
│       ├── qbittorrent     [media-storage, internal-gateway]        (Phase 12)
│       ├── prowlarr        [media-storage, internal-gateway]        (Phase 13)
│       ├── sonarr          [media-storage, internal-gateway]        (Phase 13)
│       ├── radarr          [media-storage, internal-gateway]        (Phase 13)
│       └── overseerr       [media-storage, internal-gateway]        (Phase 14)
└── intel-device-plugin                (Phase 11, for Plex QuickSync)
```

## Proposed file tree

```text
kubernetes/apps/storage/csi-driver-smb/{ks.yaml, app/{helmrepository,helmrelease,namespace,values,kustomization}.yaml}
kubernetes/apps/media/
├── kustomization.yaml
├── namespace/{ks.yaml, app/{namespace,ocirepository,kustomization}.yaml}
├── storage/{ks.yaml, app/{persistentvolume,persistentvolumeclaim,smb-credentials.sops,kustomization}.yaml}
├── plex/{ks.yaml, app/{helmrelease,values,httproute,kustomization}.yaml}          # Phase 11
├── qbittorrent/{ks.yaml, app/{helmrelease,values,httproute,protonvpn.sops,kustomization}.yaml}  # Phase 12
├── prowlarr/ sonarr/ radarr/                                                       # Phase 13
└── overseerr/                                                                      # Phase 14
kubernetes/apps/kube-system/intel-device-plugin/  (or storage/) {ks.yaml, app/...}  # Phase 11
```

## Storage, networking, security, secrets

- **Storage:** see decisions 3–4. Transcode scratch = node-local `emptyDir`/`tmpfs`.
  Confirm SMB mount UID/GID/modes vs the app-template default `568:568` at build.
- **Service-to-service:** in-cluster DNS only (`*.media.svc.cluster.local`), never via
  the gateway. Sonarr/Radarr → `qbittorrent:8080`; Prowlarr → Sonarr/Radarr APIs;
  Overseerr → Sonarr/Radarr + Plex.
- **Security:** only qBittorrent/Gluetun is privileged (NET_ADMIN + `/dev/net/tun`);
  Plex uses `/dev/dri` but no NET_ADMIN. No host networking/hostPort/runtime socket;
  dedicated ServiceAccounts, automount off where unused. Gluetun control API never
  exposed. Gluetun `FIREWALL_OUTBOUND_SUBNETS` includes the cluster pod+service CIDRs
  (from `talos/talconfig.yaml`) so *arr↔qBittorrent and kube-dns work through the kill
  switch. Trivy Operator scans the new images.
- **Secrets:** `smb-credentials` (SMB) and `protonvpn` (WireGuard key) as SOPS
  Secrets via new `just repo media-smb-secrets` / `protonvpn-secrets` recipes. No
  plaintext WireGuard keys, qBittorrent passwords, or API keys in Git.

## Validation plan

- Per app: `just kube <app>-validate` in `just ci` (kubeconform + pinned render).
- Operator verify (`just kube <app>-verify`): Kustomization + HelmRelease Ready,
  rollout, HTTPRoute Accepted, Pi-hole DNS, TLS curl.
- Phase gates (see `talos-flux-platform-plan.md`): hardlink proof; Plex node-failure
  reschedule; VPN public-IP=ProtonVPN + fail-closed kill-switch + port-forward
  reacquire; end-to-end request→download→hardlink-import→visible-in-Plex.

## Open questions / blockers

1. Plex image + tag (`ghcr.io/home-operations/plex` vs `plexinc/pms-docker`) and the
   Intel device-plugin form (operator vs standalone DaemonSet).
2. SMB mount UID/GID/modes vs app-template `568:568`.
3. Longhorn node-down pod-deletion / RWO detach timing for acceptable reschedule.
4. qBittorrent localhost auth-bypass vs injected creds for the Gluetun up-command
   (decide in Phase 12; localhost-only bypass is the documented default).
5. Pinned versions: csi-driver-smb chart, app-template `5.0.1`, Plex, each *arr,
   gluetun, intel-device-plugin.
