# Phase 12: Media Platform — VPN Download Client (qBittorrent + Gluetun)

## Status

**Planned.** qBittorrent runs beside **Gluetun** (ProtonVPN WireGuard) in one Pod, so
all of qBittorrent's internet traffic egresses through the VPN or is dropped. The
**kill switch is a hard, live-tested gate** (`plans/talos-media-stack.md` §176–188,
§751–758, §871) — nothing is activated until the failure test passes on the cluster.

An expert review of the initial design was incorporated in full (6 corrections +
credential simplification), verified against the Gluetun wiki. This doc records that
design so the hard-won decisions aren't lost.

## Confirmed facts (validated)

- `/dev/net/tun` present + world-writable (`crw-rw-rw-`) on all NUCs → Gluetun via
  `NET_ADMIN` + a `hostPath` CharDevice mount, **no privileged mode, no Talos change**.
- Pod CIDR `10.244.0.0/16`, service CIDR `10.96.0.0/12`.
- Images: Gluetun `v3.41.1`, qBittorrent `ghcr.io/home-operations/qbittorrent:5.2.3`.
- Gluetun VPN interface = `tun0`; control server on `:8000`, **auth required by default
  (≥ v3.39.1)**.

## Pod design (one app-template HelmRelease in `media`, Deployment + Recreate)

- **Gluetun native sidecar** — `initContainers.gluetun`, `restartPolicy: Always`,
  `capabilities.add: [NET_ADMIN]`, `hostPath /dev/net/tun` (CharDevice). A **startup
  probe on `GET localhost:8000/v1/vpn/status`** (the no-auth health role) so the
  qBittorrent container only starts after the tunnel + firewall are up (**fail-closed at
  boot**). Gluetun's firewall is the ongoing kill switch.
- **qBittorrent** — no `NET_ADMIN` (shares Gluetun's netns), WebUI `:8080`, config PVC
  (Longhorn RWO, Recreate, `helm.sh/resource-policy: keep`), `/data` = shared SMB PVC.
- HTTPRoute `qbittorrent.lab.supermorphic.com` (internal gateway); ClusterIP `:8080`.
  **Gluetun control server: no Service/HTTPRoute** (startup probe is localhost).
- Dedicated ServiceAccount, automount off.

## Fail-closed rationale (accurate framing)

qBittorrent holds no `NET_ADMIN`, so its unprivileged process cannot administer the
shared netns — Gluetun owns the routes/firewall. Fail-closed still *depends on* Gluetun
correctly installing and retaining those rules, which is exactly why the live failure
test (including a hard Gluetun-container kill) is mandatory, not assumed.

## Gluetun configuration (review-corrected)

- `VPN_SERVICE_PROVIDER=protonvpn`, `VPN_TYPE=wireguard`, `WIREGUARD_PRIVATE_KEY` (SOPS),
  `VPN_PORT_FORWARDING=on`, `PORT_FORWARD_ONLY=on` (auto-selects a port-forwarding-capable
  P2P server — no server pin, no Address needed).
- **[C1] `FIREWALL_INPUT_PORTS=8080`** — required so the WebUI is reachable via the Pod
  interface (Service, Envoy, *arr, kubelet probes). Without it those are dropped.
- **[C2] `FIREWALL_OUTBOUND_SUBNETS` — start empty, add only by test.** Cilium DNATs
  Service→Pod IP before Gluetun's egress firewall, so at most the **pod CIDR** (not the
  service CIDR) is ever needed. Observe Gluetun firewall logs during rollout; each
  permitted subnet is a deliberate non-VPN route.
- **[C3] DNS — keep Gluetun's default** (its resolver over the tunnel). qBittorrent
  resolves public trackers, not cluster Services, so do **not** set
  `DNS_KEEP_NAMESERVER=on` unless a test shows a required internal lookup.
- **[C4] Control-server auth** — mount `/gluetun/auth/config.toml` (via
  `HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH`) from the SOPS secret with two roles:
  `health` = `GET /v1/vpn/status` `auth=none` (startup probe + future Gatus); `vpn_control`
  = `PUT /v1/vpn/status`, `GET /v1/publicip/ip`, `GET /v1/portforward` `auth=apikey`
  (kill-switch verify). Never a blanket `HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE=none`.
- **[C5] both `VPN_PORT_FORWARDING_UP_COMMAND` and `_DOWN_COMMAND`** — the documented
  qBittorrent pattern (`wget … /api/v2/app/setPreferences` with `{{PORT}}` +
  `{{VPN_INTERFACE}}`): UP sets `listen_port={{PORT}}`, `current_network_interface=
  {{VPN_INTERFACE}}`, `random_port:false`, `upnp:false`; DOWN resets `listen_port:0`,
  interface `lo` (needed because of a qBittorrent reconnect bug).

qBittorrent enables **"Bypass authentication for clients on localhost"**
(`WebUI\LocalHostAuth=false`) so only the in-pod Gluetun hook calls the API without
creds; the WebUI still requires auth for LAN/Envoy/*arr (handoff §222 permits exactly
this). First-run setting (or pre-seeded `qBittorrent.conf`).

## Secrets

`just repo protonvpn-secrets` (clone `media-smb-secrets`) → SOPS secret `protonvpn` in
`media` with `WIREGUARD_PRIVATE_KEY` (**operator provides only the WireGuard PrivateKey**
— generated from the ProtonVPN dashboard with NAT-PMP/port-forwarding enabled) + a
recipe-generated control-server **apikey** baked into the mounted `config.toml`.

## Kill-switch acceptance gate — BLOCKING (`qbittorrent-killswitch-verify`, operator-run)

Not in `just ci`; Phase 12 is not flipped `suspend: false` / not "done" until it passes
live (handoff §751–758, §871):

1. **Baseline up:** public IP (`/v1/publicip/ip`) == ProtonVPN ≠ home WAN; forwarded port
   active; qBittorrent listening on it.
2. **Polite stop:** `PUT /v1/vpn/status {stopped}` → from the qBittorrent container an
   outbound request **times out**; the home WAN IP **never** appears.
3. **Hard failure:** kill/restart the Gluetun container → qBittorrent still cannot reach a
   public IP **during the restart** (validates the unexpected-failure path).
4. **DNS:** no resolution leaks via the node resolver while down.
5. **Recovery:** VPN back → forwarded port reacquired + reapplied → qBittorrent resumes
   without manual editing.

## PR breakdown

- **12-1** — qBittorrent+Gluetun manifests (staged `suspend: true`) + `just repo
  protonvpn-secrets` + `qbittorrent-validate` (→ `just ci`) + `qbittorrent-verify` +
  `qbittorrent-killswitch-verify` + `bootstrap qbittorrent`.
- Rollout (operator): `just repo protonvpn-secrets` → merge → `just bootstrap
  qbittorrent` → `just kube qbittorrent-verify` → **`just kube
  qbittorrent-killswitch-verify`** → flip `suspend: false`.

## First-run / manual settings

qBittorrent WebUI password, localhost-auth bypass toggle, categories, and save paths
(`/data/downloads/...`) are first-run settings in the config PVC. Sonarr/Radarr (Phase 13)
point their download client at `http://qbittorrent.media.svc.cluster.local:8080`.
