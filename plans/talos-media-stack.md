# Agent Handoff: Kubernetes Media Stack Architecture Review and Implementation Plan

## Objective

Review the existing `homelab-talos` Talos + Flux repository and produce a repository-native architecture and implementation plan for a media automation stack consisting of:

- Seerr
- Sonarr
- Radarr
- Prowlarr
- qBittorrent
- Gluetun using ProtonVPN WireGuard
- The existing or planned media server integration, without deploying a new media server unless the repository already defines one or the owner explicitly adds it to scope

This is a Kubernetes and Flux GitOps implementation. Do not design or introduce Docker Compose, Ansible, Semaphore, or the separate `homelab-playbook` repository.

The repository itself is the source of truth. Inspect it deeply before proposing manifests, naming, dependencies, storage, routing, secrets, or operational procedures.

## Required Working Method

Work in two stages.

### Stage 1: Repository Review and Architecture Plan

First, inspect the repository and write a detailed plan at:

```text
plans/media-stack-architecture-plan.md
```

Do not begin implementation until the plan is complete and internally consistent.

The plan must replace every placeholder and assumption in this handoff with details discovered from the current `homelab-talos` repository. Cite exact repository paths, Kubernetes resource names, namespaces, storage classes, Gateway names, DNS zones, certificate resources, Flux dependencies, and existing conventions.

### Stage 2: Implementation

After completing the review, implement the approved architecture using the repository’s established Flux, Kustomize, HelmRelease, SOPS, Gateway API, and documentation patterns.

Do not introduce a new framework or directory convention when an existing repository pattern already solves the requirement.

## Repository Context to Preserve

The repository currently uses this broad structure:

```text
homelab-talos/
├── clusterconfig/
├── docs/
├── kubernetes/
│   ├── apps/
│   │   ├── flux-system/
│   │   ├── kube-system/
│   │   ├── monitoring/
│   │   ├── networking/
│   │   ├── security/
│   │   ├── storage/
│   │   └── testing/
│   └── flux/clusters/prod/
├── plans/
└── talos/
```

Relevant platform components already present include:

- Talos Linux
- Flux
- Cilium
- MetalLB
- Envoy Gateway
- An internal Gateway
- external-dns
- cert-manager
- Longhorn
- Gatus
- kube-prometheus-stack
- SOPS with age encryption

Known storage decisions from prior repository work include:

- Talos `STATE` and `EPHEMERAL` are handled separately from Longhorn data.
- Longhorn uses `/var/mnt/longhorn`.
- Longhorn was designed with two replicas by default.
- SOPS-encrypted secrets are committed; plaintext credentials are never committed.

Confirm all of these details against the current repository. The live repository takes precedence over this summary.

## Mandatory Repository Inspection

At minimum, read and analyze:

```text
README.md
kubernetes/README.md
docs/phase-6-flux.md
docs/phase-7-foundation.md
docs/phase-9-storage.md
docs/phase-10-platform.md
docs/sops.md
docs/recovery.md
kubernetes/flux/clusters/prod/apps.yaml
kubernetes/apps/kustomization.yaml
kubernetes/apps/networking/kustomization.yaml
kubernetes/apps/networking/internal-gateway/
kubernetes/apps/networking/external-dns/
kubernetes/apps/networking/envoy-gateway/
kubernetes/apps/security/cert-manager/
kubernetes/apps/storage/longhorn/
kubernetes/apps/monitoring/gatus/
kubernetes/apps/monitoring/kube-prometheus-stack/
```

Also inspect representative applications to learn the repository’s exact conventions:

```text
kubernetes/apps/monitoring/gatus/
kubernetes/apps/monitoring/kube-prometheus-stack/
kubernetes/apps/testing/echo/
kubernetes/apps/networking/external-dns/
kubernetes/apps/storage/longhorn/
```

Determine and document:

1. How namespaces are created and owned.
2. Whether applications use `HelmRepository` or `OCIRepository`.
3. How HelmRelease values are split between `helmrelease.yaml` and `values.yaml`.
4. How each application-level `ks.yaml` declares Flux dependencies.
5. How top-level category `kustomization.yaml` files include applications.
6. How HTTPRoutes attach to the internal Gateway.
7. How TLS is supplied to the Gateway and HTTPRoutes.
8. How external-dns derives internal DNS records.
9. How SOPS secrets are named, included, decrypted, and referenced.
10. How storage classes, PVCs, backup jobs, monitoring, and health checks are currently modeled.
11. How image versions and chart versions are pinned and updated.
12. Whether Pod Security, CiliumNetworkPolicy, NetworkPolicy, service accounts, or other security defaults are already established.

Do not guess any of these details.

## Target Architecture

### Application Boundaries

Deploy the stack as separate, single-replica Kubernetes workloads, with one required exception:

| Workload | Kubernetes boundary |
|---|---|
| Seerr | Separate workload and Service |
| Sonarr | Separate workload and Service |
| Radarr | Separate workload and Service |
| Prowlarr | Separate workload and Service |
| qBittorrent + Gluetun | Two containers in the same Pod |
| Media server | Existing or separately planned workload |

Do not create one umbrella Pod for the entire stack.

Do not run Seerr, Sonarr, Radarr, or Prowlarr through the ProtonVPN tunnel unless a later, explicit architecture decision changes that requirement.

### Why qBittorrent and Gluetun Share a Pod

All containers in a Kubernetes Pod share the Pod network namespace. qBittorrent must therefore run beside Gluetun in the same Pod so Gluetun can control the Pod’s default route and firewall behavior.

The desired network path is:

```text
qBittorrent process
    -> shared Pod network namespace
    -> Gluetun-managed WireGuard tunnel
    -> ProtonVPN
    -> torrent peers
```

The other applications communicate with qBittorrent through a Kubernetes Service selecting this Pod.

The qBittorrent Web UI and API must remain reachable from approved cluster and LAN clients, while qBittorrent’s internet-bound traffic must fail closed when the VPN is unavailable.

### Required Startup and Kill-Switch Behavior

Do not rely solely on unordered container startup.

The implementation must prevent qBittorrent from beginning network activity before Gluetun has established its firewall and VPN tunnel. Select a repository-compatible mechanism, such as:

- A qBittorrent startup wrapper that waits for the local Gluetun health or control endpoint before executing qBittorrent.
- A supported Kubernetes native-sidecar ordering mechanism.
- Another method that demonstrably prevents startup leakage.

Gluetun’s firewall kill switch must remain the ongoing protection after startup.

The architecture plan must explain the selected mechanism and its failure behavior.

### ProtonVPN Configuration

Use ProtonVPN through Gluetun with WireGuard unless current repository constraints prove WireGuard unsuitable.

Store all sensitive values in a SOPS-encrypted Secret, including at least the applicable ProtonVPN WireGuard credential material.

Do not commit:

- WireGuard private keys
- OpenVPN credentials
- qBittorrent passwords
- API keys
- Cookie secrets
- Generated plaintext Secrets

Gluetun’s control server must not be exposed through an HTTPRoute or LAN-facing Service.

### ProtonVPN Port Forwarding

ProtonVPN assigns a forwarded port dynamically when port forwarding is enabled. The architecture must include an automated way to update qBittorrent’s incoming listening port whenever Gluetun receives or renews the forwarded port.

Use the current Gluetun-supported port-forwarding mechanism rather than manually setting a permanent qBittorrent peer port.

The plan must specify:

1. How Gluetun obtains the ProtonVPN forwarded port.
2. How the value is applied to qBittorrent.
3. How it is reapplied after VPN reconnects.
4. How local authentication between the Gluetun hook and qBittorrent is secured.
5. How the current port is verified operationally.
6. What logs or metrics expose failures.

Do not disable qBittorrent authentication for remote or LAN clients. A localhost-only bypass may be considered only when required by the supported Gluetun integration and must be documented.

## Service-to-Service Flow

Use Kubernetes Services and in-cluster DNS names. Do not make internal application calls traverse Envoy Gateway unless there is a specific, documented reason.

Expected logical flow:

```text
User
  -> internal Envoy Gateway
  -> Seerr Service
  -> Sonarr and Radarr Services

Prowlarr
  -> Sonarr and Radarr APIs

Sonarr and Radarr
  -> qBittorrent Service
  -> shared qBittorrent/Gluetun Pod

qBittorrent
  -> ProtonVPN tunnel
  -> external peers

Sonarr and Radarr
  -> shared media filesystem
  -> media server library
```

The plan must provide the final namespace-qualified service endpoints selected from the actual manifests.

Example only:

```text
http://sonarr.media.svc.cluster.local:8989
http://radarr.media.svc.cluster.local:7878
http://prowlarr.media.svc.cluster.local:9696
http://qbittorrent.media.svc.cluster.local:8080
```

Replace these examples with the actual repository design.

## Storage Architecture

### Separate Application Configuration from Media Data

Use two storage classes of data:

1. Application configuration and databases
2. Downloads and finished media

Recommended logical mapping:

| Application | Configuration storage | Shared media storage |
|---|---|---|
| Seerr | Longhorn-backed PVC | None |
| Prowlarr | Longhorn-backed PVC | None |
| Sonarr | Longhorn-backed PVC | `/data` |
| Radarr | Longhorn-backed PVC | `/data` |
| qBittorrent | Longhorn-backed PVC | `/data` |
| Gluetun | Minimal persistent state only if required | None |
| Media server | Existing config strategy | Media library path |

Confirm the actual storage class names and backup policy from the repository.

### Bulk Media Must Not Default to Longhorn

Do not automatically place the torrent payload and finished media library on replicated Longhorn volumes.

The agent must inspect the current NAS integration and determine the intended Kubernetes access method. Preferred characteristics are:

- A NAS-backed PersistentVolume or CSI-backed PVC
- ReadWriteMany where needed
- One shared filesystem mounted consistently by qBittorrent, Sonarr, Radarr, and the media server
- Stable behavior when Pods reschedule to another NUC
- A backup and snapshot strategy owned by the NAS rather than Longhorn

If NAS-backed storage is not yet implemented in the repository, identify it as a prerequisite and design the smallest repository-native storage foundation needed before deploying the media stack.

Do not silently substitute node-local `hostPath` storage for shared media data.

### Consistent Container Paths

qBittorrent, Sonarr, and Radarr must mount the same shared filesystem at the same container path:

```text
/data
```

Recommended directory model:

```text
/data/
├── torrents/
│   ├── incomplete/
│   ├── movies/
│   └── tv/
└── media/
    ├── movies/
    └── tv/
```

Expected application paths:

```text
qBittorrent incomplete: /data/torrents/incomplete
qBittorrent movies:     /data/torrents/movies
qBittorrent television: /data/torrents/tv
Radarr root folder:      /data/media/movies
Sonarr root folder:      /data/media/tv
```

Validate that the backing filesystem permits hardlinks between download and library paths. Demonstrate this in the validation plan.

Do not use mismatched aliases such as `/downloads`, `/tv`, `/movies`, and `/media` for different containers when they refer to the same backing filesystem.

### UID, GID, and Permissions

Inspect the NAS export ownership, existing Kubernetes security conventions, and image behavior before choosing UID/GID values.

The plan must define:

- Runtime UID and GID
- `fsGroup` behavior
- Supplemental groups if needed
- NAS ownership and permission expectations
- Whether containers require an init container for permission preparation
- Whether the chosen images can run without root
- How file ownership remains consistent across qBittorrent, Sonarr, Radarr, and the media server

Do not recursively `chown` a large media library during every Pod startup.

## Workload and Controller Decisions

These applications normally run as one active instance because their local configuration and SQLite-style state are not designed for active-active replicas.

For each workload, choose and justify either:

- A single-replica Deployment with a `Recreate` strategy
- A single-replica StatefulSet
- The repository’s existing equivalent through its selected Helm chart

Avoid rolling-update behavior that can create two active instances competing for the same configuration volume.

The qBittorrent/Gluetun Pod must always schedule as one unit.

Define appropriate:

- Resource requests
- Resource limits where safe
- Startup probes
- Readiness probes
- Liveness probes
- Pod disruption behavior
- Graceful termination periods
- Update strategy
- Persistent volume retention behavior

Do not set artificially low memory or CPU limits that cause Sonarr or Radarr library scans and imports to fail.

## Helm and Manifest Strategy

First inspect whether the repository has already standardized on a reusable application chart such as the bjw-s app-template chart.

If an application chart is already established, use that exact chart family and current repository syntax.

If no reusable chart exists, compare these options in the plan:

1. A repository-approved generic app chart
2. Application-specific charts with acceptable maintenance and security characteristics
3. Direct Kubernetes manifests

Do not add six unrelated chart repositories without reviewing the operational cost.

Each selected image and chart must be pinned according to existing repository practice. Do not use floating tags such as `latest`.

## Proposed Repository Layout

The final layout must follow the repository’s existing conventions. Begin with this candidate and adjust it after reviewing current patterns:

```text
kubernetes/apps/media/
├── kustomization.yaml
├── namespace/
│   ├── app/
│   │   ├── kustomization.yaml
│   │   └── namespace.yaml
│   └── ks.yaml
├── storage/
│   ├── app/
│   │   ├── kustomization.yaml
│   │   ├── persistentvolumes.yaml
│   │   └── persistentvolumeclaims.yaml
│   └── ks.yaml
├── qbittorrent/
│   ├── app/
│   │   ├── helmrelease.yaml
│   │   ├── kustomization.yaml
│   │   ├── ocirepository.yaml
│   │   ├── protonvpn.sops.yaml
│   │   └── httproute.yaml
│   ├── config/
│   │   └── kustomization.yaml
│   ├── ks.yaml
│   └── README.md
├── prowlarr/
│   ├── app/
│   ├── ks.yaml
│   └── README.md
├── sonarr/
│   ├── app/
│   ├── ks.yaml
│   └── README.md
├── radarr/
│   ├── app/
│   ├── ks.yaml
│   └── README.md
└── seerr/
    ├── app/
    ├── ks.yaml
    └── README.md
```

This is not permission to force a new pattern. Replace it with the structure that best matches the current repository.

The category must be included by:

```text
kubernetes/apps/kustomization.yaml
```

and ultimately reconciled through the existing production Flux chain under:

```text
kubernetes/flux/clusters/prod/
```

## Namespace Decision

Prefer a shared `media` namespace unless the repository’s established isolation model strongly favors one namespace per application.

The plan must compare the practical effect on:

- Service discovery
- NetworkPolicy
- SOPS Secret scope
- Shared PVC access
- Gateway routing
- Operational clarity
- Blast radius
- Flux ownership

Record the final choice as an architecture decision.

## Gateway API, DNS, and TLS

Expose user interfaces only through the existing internal Envoy Gateway.

Expected internal hostnames should follow the repository’s actual DNS zone and naming conventions. Logical examples:

```text
seerr.<internal-domain>
sonarr.<internal-domain>
radarr.<internal-domain>
prowlarr.<internal-domain>
qbittorrent.<internal-domain>
```

Requirements:

- Seerr is the primary household request interface.
- Sonarr, Radarr, Prowlarr, and qBittorrent are administrative interfaces.
- No application in this stack is exposed through a public Gateway.
- No direct `LoadBalancer` Service should be added when the existing internal Gateway already provides LAN access.
- Use the repository’s established HTTPRoute parent reference, listener, hostname, certificate, and external-dns patterns.
- Do not expose Gluetun’s control API.
- Determine whether administrative interfaces need additional authentication or source-network restrictions beyond their native login pages.

The plan must state whether the existing wildcard or shared certificate covers the selected names and how DNS records will be generated.

## Network Policy and Security

Inspect current Cilium and policy conventions before adding policies.

At minimum, the plan must model these flows:

| Source | Destination | Purpose |
|---|---|---|
| Internal Gateway | Each web Service | LAN web access |
| Seerr | Sonarr and Radarr | Requests and availability |
| Prowlarr | Sonarr and Radarr | Application synchronization |
| Sonarr and Radarr | qBittorrent | Download-client API |
| Application Pods | DNS | Service discovery |
| qBittorrent/Gluetun Pod | ProtonVPN endpoints and internet | VPN and torrent traffic |
| Monitoring | Selected Services | Health and metrics |
| Admin clients | Administrative routes | Management access |

Do not accidentally permit the qBittorrent container to use the node’s normal WAN path.

Minimize privileges:

- Gluetun may receive only the capabilities and device access it actually needs.
- Validate whether `NET_ADMIN` plus `/dev/net/tun` is sufficient on Talos.
- Do not grant blanket privileged mode unless testing proves it is required and the plan explains why.
- Do not mount the container runtime socket.
- Do not use host networking.
- Do not expose host ports.
- Use a dedicated service account unless the repository intentionally uses the default account for comparable workloads.
- Disable service-account token automount when Kubernetes API access is unnecessary.

### Talos Device Validation

Confirm `/dev/net/tun` availability on every eligible NUC node.

If Gluetun requires a hostPath device mount, document:

- `hostPath` type
- container mount path
- eligible-node behavior
- scheduling implications
- failure behavior when the device is missing

Do not assume Docker-style `devices:` syntax applies to Kubernetes.

## Flux Dependency Model

Derive the exact dependency graph from the repository.

The architecture should generally account for:

```text
Cilium
  -> Longhorn and/or NAS storage integration
  -> Envoy Gateway and internal Gateway
  -> cert-manager and required certificates
  -> external-dns
  -> media namespace and storage
  -> application workloads
  -> HTTPRoutes
  -> Gatus monitoring
```

Application dependencies may be looser because Services can become available asynchronously, but the plan must ensure that:

- Required CRDs exist before custom resources.
- Storage classes and PVs exist before PVC-consuming workloads.
- SOPS decryption is configured before encrypted Secrets reconcile.
- Gateway resources exist before HTTPRoutes.
- Health checks do not create circular Flux dependencies.
- A missing optional application does not block unrelated foundation reconciliation.

List the exact `dependsOn` names that will be used in every new `ks.yaml`.

## Application Configuration Boundaries

### Seerr

Seerr is the main request interface, not the control plane for every application.

Configure it to connect to the media server plus the internal Sonarr and Radarr Services.

Document:

- Authentication model
- Default Sonarr server
- Default Radarr server
- Root folders
- Quality profiles
- Request approval rules
- Whether users may request 4K content
- Which settings remain manual after deployment

Do not imply that Seerr replaces the Sonarr, Radarr, Prowlarr, or qBittorrent administration interfaces.

### Prowlarr

Prowlarr owns indexer configuration and synchronizes indexers into Sonarr and Radarr.

Document:

- Application API-key handling
- Indexer credential handling
- Sync strategy
- Tags or categories
- Failure visibility
- Whether configuration is initially manual or declarative

Do not store indexer credentials in plaintext Git.

### Sonarr and Radarr

Document:

- Internal qBittorrent endpoint
- Download categories
- Completed-download handling
- Root folders
- Naming and quality-profile boundaries
- Hardlink behavior
- Permissions
- API-key handling
- Media server notification or scanning mechanism

### qBittorrent

Document:

- Internal Service port
- HTTPRoute port
- Web UI authentication
- Download directories
- Categories
- Queueing and seeding defaults
- ProtonVPN forwarded-port automation
- Health behavior
- How the application confirms it is using the VPN
- How an administrator accesses it without exposing it publicly

### Gluetun

Document:

- Provider and protocol
- Required environment variables
- Server-region and P2P constraints
- Port forwarding
- Firewall input ports
- Any permitted private or cluster subnets
- DNS behavior
- Health endpoint
- Control endpoint security
- Capability and device requirements
- Update and restart behavior

## Declarative Configuration Decision

The agent must explicitly decide which settings are:

1. Defined declaratively in Git
2. Stored in application PVC state
3. Entered manually during first-run setup
4. Backed up and restored
5. Derived from another service

Avoid pretending that all Servarr settings are conveniently declarative when the selected images or charts do not provide a reliable supported mechanism.

If post-deployment API configuration is proposed, explain:

- Idempotency
- Secret handling
- Reconciliation behavior
- Upgrade compatibility
- Failure recovery
- Whether a Kubernetes Job, Flux hook, or separate configuration controller is needed

Prefer a simple, supportable first deployment over brittle API automation.

## Backup and Recovery

Application configuration PVCs must participate in the repository’s Longhorn backup or snapshot strategy where appropriate.

Bulk downloads and finished media must not be copied into Longhorn backups.

The plan must define recovery for:

- Seerr configuration
- Sonarr database and configuration
- Radarr database and configuration
- Prowlarr database and configuration
- qBittorrent configuration
- SOPS-encrypted credentials
- NAS media and torrent data
- Recreated Pods on a different NUC
- Loss of one Longhorn replica
- Loss of the current ProtonVPN forwarded port

Add recovery instructions to either the application READMEs or the existing recovery documentation, following repository convention.

## Observability and Health

Integrate with existing monitoring without overengineering the first release.

At minimum, design Gatus checks for:

- Seerr web endpoint
- Sonarr web/API health
- Radarr web/API health
- Prowlarr web/API health
- qBittorrent Web UI/API
- A VPN status check that proves Gluetun reports a healthy tunnel

Consider, but do not automatically require:

- qBittorrent exporter
- Servarr Prometheus exporters
- Gluetun metrics
- Grafana dashboards
- Alerting on VPN disconnect
- Alerting on stalled download queues
- PVC utilization alerts

Never expose API keys in Gatus configuration or Prometheus labels.

## Validation and Acceptance Tests

The implementation is not complete until the following are demonstrated.

### Flux and Kubernetes

- All new Flux Kustomizations report Ready.
- All HelmReleases report Ready.
- All Pods are Running and Ready.
- No resources were created manually outside Git except approved bootstrap or validation operations.
- Reconciliation after deleting an application Pod restores the intended state.

### VPN Isolation

From the qBittorrent container or shared Pod network namespace:

- Public IP resolves to ProtonVPN, not the home WAN IP.
- DNS behavior matches the Gluetun design.
- The ProtonVPN forwarded port is active.
- qBittorrent is listening on the forwarded port.

From Sonarr, Radarr, Prowlarr, and Seerr:

- Public egress does not traverse the qBittorrent ProtonVPN tunnel unless explicitly designed otherwise.

Failure test:

1. Stop or break the Gluetun tunnel.
2. Confirm qBittorrent cannot reach the internet.
3. Confirm qBittorrent does not fall back to the node’s normal route.
4. Restore Gluetun.
5. Confirm the forwarded port is reacquired and reapplied.
6. Confirm qBittorrent resumes without manual port editing.

### Application Flow

- Seerr can communicate with Sonarr and Radarr.
- Prowlarr can synchronize with Sonarr and Radarr.
- Sonarr and Radarr can communicate with qBittorrent through its Kubernetes Service.
- A legal test download, such as a Linux distribution image, can be requested or submitted and completed.
- Completed-download handling imports the file into the expected library path.
- The media server can see the imported file.
- A hardlink test proves imports do not duplicate payload data when seeding continues.

Record a command showing source and destination inode or link-count evidence.

### Storage and Rescheduling

- Application configuration survives Pod deletion.
- The qBittorrent/Gluetun Pod can reschedule to another eligible NUC.
- Sonarr and Radarr can still access the same shared `/data` filesystem after rescheduling.
- No application requires a node-local path that was not documented.
- Longhorn backup or snapshot behavior is verified for configuration PVCs.
- NAS recovery responsibility is documented for bulk media.

### LAN Access

- All selected internal DNS names resolve.
- TLS is valid under the repository’s certificate design.
- HTTPRoutes attach to the intended internal Gateway.
- No route is attached to a public Gateway.
- Gluetun’s control interface is unreachable from normal LAN clients.
- Administrative UIs require authentication.

## Required Deliverables

The agent must produce:

1. `plans/media-stack-architecture-plan.md`
   - Repository findings
   - Architecture decisions
   - Exact dependency graph
   - Exact proposed file tree
   - Storage design
   - Networking design
   - Security design
   - Secrets design
   - Validation plan
   - Open questions or blockers

2. Kubernetes and Flux manifests under the repository’s established application structure.

3. SOPS-encrypted Secret manifests for sensitive values.

4. Application-level README files explaining:
   - Purpose
   - Dependencies
   - Internal endpoint
   - LAN endpoint
   - Storage
   - Secrets
   - Recovery
   - Validation
   - Common troubleshooting

5. Updates to relevant phase or platform documentation.

6. Gatus checks following the current repository pattern.

7. A final implementation report containing:
   - Files added and changed
   - Architecture deviations from this handoff
   - Validation commands run
   - Validation results
   - Remaining manual first-run settings
   - Risks and follow-up work

## Architecture Questions the Agent Must Resolve

Do not leave these implicit:

1. What NAS-backed Kubernetes storage mechanism will provide the shared `/data` filesystem?
2. Is the existing NAS integration already production-ready for this workload?
3. What exact StorageClass will back application configuration PVCs?
4. Will the stack use one `media` namespace or one namespace per application?
5. What generic or application-specific Helm chart will be used?
6. How will qBittorrent startup be gated until Gluetun is healthy?
7. What exact Gluetun privileges are required on Talos?
8. How will ProtonVPN’s forwarded port be applied and renewed?
9. What Pod and Service CIDRs, if any, must be permitted by the Gluetun firewall?
10. What internal DNS zone and certificate cover the application hostnames?
11. How will administrative routes be restricted?
12. How will API keys be created, stored, and rotated?
13. Which first-run settings remain manual?
14. How will application configuration be backed up and restored?
15. What media server consumes `/data/media`, and how is its library scan triggered?
16. What resource requests and limits fit the three NUC cluster?
17. How will VPN failure be monitored and alerted?
18. How will hardlink behavior be proven on the selected NAS filesystem?

## Constraints

- Use `homelab-talos`; do not use `homelab-playbook`.
- Use Kubernetes and Flux; do not use Docker Compose.
- Keep qBittorrent behind Gluetun and ProtonVPN.
- Do not tunnel the entire media namespace through ProtonVPN.
- Do not expose the stack publicly.
- Do not expose Gluetun’s control API.
- Do not commit plaintext secrets.
- Do not use `latest` image tags.
- Do not use node-local bulk-media storage without an explicit approved architecture decision.
- Do not store bulk media in Longhorn by default.
- Do not break existing Flux dependency chains.
- Do not bypass the existing internal Gateway, DNS, certificate, or SOPS patterns.
- Do not create multiple active Sonarr, Radarr, Prowlarr, Seerr, or qBittorrent replicas merely for apparent high availability.
- Do not claim completion without kill-switch, rescheduling, storage, and end-to-end download/import validation.

## Definition of Done

The media stack is complete when:

- It is fully represented in Git and reconciled by Flux.
- Seerr is the normal request interface.
- Sonarr and Radarr manage television and movies.
- Prowlarr manages indexer integration.
- qBittorrent shares a Pod network namespace with Gluetun.
- qBittorrent internet traffic fails closed through ProtonVPN.
- ProtonVPN port forwarding is automatically synchronized with qBittorrent.
- Configuration data persists on the approved Longhorn storage class.
- Downloads and media use the approved shared NAS-backed filesystem at a consistent `/data` mount.
- All selected UIs are available only through the internal Gateway and internal DNS.
- Secrets are SOPS encrypted.
- Gatus can detect application and VPN failures.
- A legal test download completes, imports, hardlinks, and becomes visible to the media server.
- The architecture, recovery steps, and remaining manual settings are documented.

## Primary Technical References

Use current documentation during implementation and record the exact versions consulted.

- Kubernetes Pods and shared network namespace:  
  https://kubernetes.io/docs/concepts/workloads/pods/

- Kubernetes sidecar containers:  
  https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/

- Kubernetes NetworkPolicy:  
  https://kubernetes.io/docs/concepts/services-networking/network-policies/

- Seerr documentation:  
  https://docs.seerr.dev/

- Seerr Sonarr and Radarr service configuration:  
  https://docs.seerr.dev/using-seerr/settings/services/

- Gluetun ProtonVPN configuration:  
  https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md

- Gluetun VPN port forwarding:  
  https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md

- Gluetun port-forwarding options:  
  https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/port-forwarding.md

- Gluetun control server:  
  https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/control-server.md

- bjw-s Helm charts, if consistent with repository policy:  
  https://github.com/bjw-s-labs/helm-charts
