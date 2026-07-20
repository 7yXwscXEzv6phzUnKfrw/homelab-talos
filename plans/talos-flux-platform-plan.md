# Plan: Fresh Talos and Flux Platform Rebuild

## Status

- Revision date: 2026-07-19
- Status: Approved for implementation
- First milestone: Talos, Cilium, Flux, and the internal platform foundation
- Later milestones: storage, applications, media, lifecycle automation, and staging

This document is the canonical implementation plan for rebuilding the three-node
Intel NUC Talos cluster on the new NVMe drives. It replaces the earlier draft that
treated the work as a migration from the manually generated Talos cluster.

## Summary

Rebuild instead of migrating. The current Kubernetes cluster has no workloads or
persistent data worth preserving, so the NVMe replacement is a clean boundary for
a new Talos identity, declarative talhelper configuration, a new SOPS identity,
and the private `7yXwscXEzv6phzUnKfrw/homelab-talos` monorepo.

Keep the sound architectural choices from the earlier plan:

- Three uniform Intel NUC 11 machines as schedulable control-plane nodes
- Talhelper and SOPS for reproducible Talos configuration
- Cilium with kube-proxy replacement
- Flux for Kubernetes reconciliation
- MetalLB and Envoy Gateway for internal ingress
- Longhorn for replicated block storage
- NFS from the UNAS Pro for bulk media and downloads

The work is divided into gated phases. Phases 0 through 8 form the foundation
milestone. No Longhorn, greenfield platform application, or media deployment
starts until the foundation passes its acceptance and soak tests.

## Locked Decisions

| Decision | Choice |
|---|---|
| Repository | Private `7yXwscXEzv6phzUnKfrw/homelab-talos` monorepo |
| Cluster | `nuc-cluster` |
| Nodes | `nuc1`, `nuc2`, `nuc3` |
| Node addresses | `192.168.90.10-12` via DHCP reservations |
| Kubernetes API VIP | `192.168.90.20` |
| Internal Gateway IP | `192.168.90.30` |
| Talos | `v1.13.6` |
| Kubernetes | `v1.35.6` |
| Talhelper | `v3.1.13` |
| Cilium | `v1.19.6` |
| Flux | `v2.9.2` |
| MetalLB chart | `0.16.1` |
| Envoy Gateway | `v1.8.2` |
| ExternalDNS | `v0.21.0` |
| cert-manager | `v1.21.0` |
| Talos identity | Generate fresh |
| SOPS identity | Generate a new repository-specific age identity |
| Disk encryption | TPM encryption for STATE and EPHEMERAL only |
| Longhorn storage | Dedicated unencrypted Talos user volume |
| Exposure | Internal ingress and Pi-hole DNS only |
| Target DNS | Separate internal Pi-hole and public Cloudflare ExternalDNS controllers |
| Pi 5 role | Preserve existing k3s cluster; convert to Flux-managed staging later |
| Initial upgrades | Manual; evaluate tuppr after a successful manual cycle |

Kubernetes `v1.35.6` is intentional. Stable Envoy Gateway `v1.8.2` supports
Kubernetes through `v1.35`; Kubernetes `v1.36` is deferred until a stable Envoy
Gateway release supports it.

## Context and Decision History

The repository began as a record of a manual Talos installation. Three Intel NUC
11 machines were installed with Talos `v1.13.2`, Secure Boot keys were enrolled,
hostnames and the API VIP were applied with patches, and the resulting Talos
cluster identity was encrypted with SOPS. Kubernetes was stood up only far enough
to prove that the machines could form a cluster. No CNI, workloads, or persistent
application data now need to survive the NVMe replacement.

The earlier design discussion had a broader goal: replace the existing
ArgoCD-on-k3s production environment with a production-quality Talos platform,
reuse the useful application knowledge in `homelab-gitops`, and add a media stack
backed by the UNAS Pro at `192.168.0.3`. That direction remains valid. What changed
is the path: because the NUC cluster is empty and every system disk is being
replaced, preserving the original Talos PKI and migrating etcd would add risk
without preserving anything useful.

This plan therefore treats the old installation as a successful hardware and
Secure Boot proof of concept, not as a production cluster to migrate. The old
SSDs remain the rollback mechanism while the new drives receive a clean,
reproducible installation.

## Architectural Rationale

### Hybrid Design: onedr0p Patterns Without Adopting the Template Wholesale

Three approaches were evaluated:

1. Adopt `onedr0p/cluster-template` wholesale.
2. Build every convention and bootstrap mechanism from scratch.
3. Keep this repository and selectively adopt proven HomeOps patterns.

The wholesale template approach provides a strong reference implementation, but
it also brings its author's repository layout, bootstrap assumptions, providers,
secret workflow, naming conventions, and release cadence. Treating that entire
template as an upstream product would make local requirements harder to see and
would turn future template divergence into maintenance work. The original plan
also predated the decision to discard the old cluster, so preserving every old
file is no longer important; preserving ownership of the design still is.

The pure DIY approach would avoid inherited conventions but would require
re-solving common problems such as Talos rendering, Flux dependency ordering,
SOPS bootstrap, chart layout, and dependency updates. Those problems have little
homelab-specific value.

The chosen hybrid approach uses the template and `onedr0p/home-ops` as pattern
libraries, not as code generators or permanent upstream dependencies. Adopt:

- Talhelper for declarative Talos inputs
- Flux `Kustomization` and `HelmRelease` dependency patterns
- App-local `ks.yaml` and `app/` organization where it improves navigation
- Mise for reproducible workstation tools
- Renovate after the platform has a known-good baseline
- A staged bootstrap boundary between Talos, Cilium, Flux, and applications

Do not inherit components merely for ecosystem parity. Every controller in this
plan must solve a local requirement and have a documented recovery path.

### Legacy GitOps Review: Preserve Intent, Not Artifacts

The existing `homelab-gitops` repository was reviewed after the HomeOps pattern
review. It remains useful as an operational-requirements inventory, not as a
deployment source for this greenfield cluster. Retain the domain and Cloudflare
DNS-01 conventions, Longhorn backup intent, monitoring sizing history, Gatus
endpoint inventory, Homepage content, Trivy resource constraints, standard
application labels, and configuration-triggered rollout behavior.

Do not copy ArgoCD Applications or ApplicationSets, implicit recursive directory
discovery, sync-wave annotations, KSOPS generators, Reflector configuration,
blanket Secret data drift ignores, Traefik resources, rendered Helm output,
Kompose output, legacy ciphertext, PVCs, or application data. Secrets are
recreated from their authoritative sources and encrypted for this repository's
SOPS identity.

The old static-manifest workaround addressed admission-controller and CRD
readiness ordering, not a lack of Git webhook support in ArgoCD. Flux is still
the better fit because `HelmRelease` owns a Helm lifecycle and Flux
`Kustomization` resources express readiness dependencies directly. Controller
CRDs and deployments must become Ready before dependent custom resources are
reconciled.

Application packaging is Helm-first, not Helm-only. Infrastructure controllers
and applications with maintained charts use `HelmRelease`. Small applications
without a trustworthy chart use focused native resources. Rendered third-party
chart output is validation material only and is never committed.

Gatus is the single declarative synthetic-monitoring system. Uptime Kuma is not
part of the new platform because its legacy deployment was generated rather than
declaratively maintained and its role is already covered by Gatus.

### One Private Monorepo

Talos configuration, cluster bootstrap, and Kubernetes GitOps resources belong in
one private repository because they describe one platform and often change
together. A schematic change can require a Talos version change, Cilium values can
depend on Talos KubePrism settings, and Gateway or storage changes can require
machine extensions. Atomic commits make those relationships reviewable.

Splitting Talos and Kubernetes into separate repositories would create an
artificial release boundary without separate teams or access policies to justify
it. Privacy is not a substitute for encryption, so credentials remain encrypted
even though GitHub access is restricted.

### Why Talhelper Instead of Raw `talosctl gen config`

Raw `talosctl gen config` is appropriate for a one-time cluster, but the generated
machine files contain both policy and secrets and are unsuitable as the primary
Git source. The current repository demonstrates the cost: the meaningful state is
distributed across an ignored generated control-plane file, common patches,
hostname documents, an encrypted secret extraction, and prose describing the
order in which they were combined.

Talhelper adds substantial value here:

- A reviewable `talconfig.yaml` becomes the source of cluster topology, versions,
  nodes, schematics, patches, and volume policy.
- `talsecret.sops.yaml` keeps cluster identity separate and encrypted.
- Per-node configs are rendered consistently instead of being copied and edited.
- SOPS decryption and Talos config validation are part of one render workflow.
- Image Factory URLs and installer references derive from the same declared
  schematic, reducing ISO/installer mismatch risk.
- A fresh clone plus the age key can reproduce the ignored machine configs.

Talhelper is deliberately not treated as a cluster lifecycle controller. Talos
still installs, bootstraps, upgrades, and diagnoses the nodes. Talhelper's benefit
is reproducible configuration generation, not abstraction away from Talos. See
the [Talhelper overview](https://budimanjojo.github.io/talhelper/latest/).

### Three Uniform, Schedulable NUC Control Planes

A split design with Raspberry Pi 5 control planes and NUC workers was evaluated
and rejected. It would move etcd and the Kubernetes API onto the less trusted and
less uniform hardware, give up the NUC Secure Boot and TPM posture for the most
sensitive services, and introduce a permanent arm64/amd64 compatibility burden.
The available memory gained by isolating the NUC control planes would be small at
this scale, while etcd benefits directly from the NUC NVMe latency.

Using all three NUCs as schedulable control planes provides:

- An odd three-member etcd quorum
- One amd64 image and extension schematic
- One firmware and Talos upgrade path
- Secure Boot and TPM protection on every control-plane member
- All compute capacity available to workloads
- Straightforward one-node-at-a-time maintenance

The tradeoff is that application resource pressure shares hardware with etcd and
the API server. This is addressed with resource requests and limits, Longhorn
capacity isolation, monitoring, and conservative workload rollout. Blanket use of
`system-cluster-critical` is rejected because it can make third-party workloads
compete with genuine control-plane services during memory pressure.

### The Pi 5s Become a Separate Staging Cluster

The three Pi 5 machines already have a healthy k3s installation, 1 TB Samsung 970
Pro NVMes, 8 GB RAM, and k3s configured with Traefik and ServiceLB disabled. They
should not be wiped or joined to the Talos production cluster.

Their future role is a Flux-managed staging cluster that reuses k3s while replacing
ArgoCD and Traefik with Flux and Envoy Gateway. This provides a useful place to
test Helm values, Kustomize composition, SOPS decryption, HTTPRoutes, and chart
updates before production. Arm64 staging also exposes multi-architecture image
problems early.

It does not test Talos upgrades, Secure Boot, x86 GPU behavior, or NUC-specific
storage performance. Those remain production procedures exercised one NUC at a
time. The staging cluster will run a reduced platform and will not host Plex, the
download stack, or other workloads whose resource profile makes staging
unrepresentative.

Pi-hole is separate infrastructure managed by `homelab-playbook`; the Pi 5
staging nodes are not being repurposed as the production DNS server. This
distinction avoids coupling production name resolution to the staging cluster.

### Fresh Talos Identity, Secure Boot, and TPM Encryption

The old PKI proved the original cluster, but there are no clients, workloads, or
etcd data that require its identity. Generating fresh secrets removes ambiguity
between the old disks and new cluster and makes the new talhelper/SOPS workflow
the only supported recovery source.

Secure Boot continues to protect the boot chain, while TPM-sealed LUKS2 keys
protect STATE and EPHEMERAL at rest. STATE holds machine configuration and node
credentials; EPHEMERAL holds etcd, images, logs, and runtime data. The Longhorn
volume remains unencrypted to simplify node and replica recovery; sensitive
application values remain encrypted at the application layer. The old SSDs stay
untouched until the new cluster passes its soak gate.

### Why Cilium

Talos can run the simpler default Flannel CNI, but the target platform needs more
than basic pod networking. Cilium provides one coherent implementation for pod
networking, network policy, service load balancing, kube-proxy replacement, and
Hubble observability. It is actively documented for Talos and uses the local
KubePrism endpoint at `localhost:7445`, avoiding a dependency on the external API
VIP for each node's CNI control traffic. See the
[Cilium Talos Helm guide](https://docs.cilium.io/en/stable/installation/k8s-install-helm/).

Kube-proxy replacement reduces duplicate service-routing machinery and aligns
with the modern Talos/HomeOps patterns being adopted. Hubble gives immediate
visibility into policy and connectivity failures without introducing a separate
service mesh.

The cost is a more sophisticated CNI and a bootstrap dependency: Kubernetes
cannot become Ready and Flux cannot run until Cilium is installed. The plan makes
that dependency explicit by installing Cilium from a tracked values file before
Flux, then having Flux adopt the same Helm release.

### Why MetalLB Instead of Cilium L2 Announcements

Cilium can allocate and announce LoadBalancer addresses, which would remove one
controller. Its L2 announcement feature is still documented as beta in Cilium
`1.19`, has per-service lease traffic, and has limitations such as incompatibility
with `externalTrafficPolicy: Local`. MetalLB L2 is already understood in this
environment, where a static L2 pool (previously `192.168.90.100-110` in
`homelab-gitops`, now consolidated to `192.168.90.30-39`) is proven.

Keeping MetalLB separates CNI failure diagnosis from LAN address advertisement
and favors operational maturity over minimizing the controller count. Cilium LB
IPAM/L2 can be reconsidered when the feature is stable and there is a measurable
benefit. See the [Cilium L2 limitations](https://docs.cilium.io/en/stable/network/l2-announcements/).

### Why Envoy Gateway Instead of Familiar Traefik

Traefik is familiar and already represented throughout `homelab-gitops`; keeping
it would minimize initial manifest conversion. Envoy Gateway was nevertheless an
explicit design choice because it centers the Kubernetes Gateway API rather than
Traefik-specific `IngressRoute`, middleware, and TLS CRDs. Gateway API separates
Gateway ownership from application routes, provides portable `HTTPRoute`
resources, and offers a clearer long-term boundary between platform and app
configuration.

The re-authoring cost is real: any useful Traefik route or middleware behavior
must be reviewed and expressed with portable Gateway API resources, and
operational familiarity must be rebuilt. The staged echo deployment exists
specifically to prove TLS, routing, DNS, and failure behavior before greenfield
applications are added.

Envoy Gateway `v1.8.2` is selected because it is a stable patch release. Its published
compatibility matrix supports Kubernetes through `v1.35`, which is why the plan
uses Kubernetes `v1.35.6` instead of Talos's newer default. See the
[Envoy Gateway compatibility matrix](https://gateway.envoyproxy.io/news/releases/matrix/).

### DNS: Separate Internal and Public ExternalDNS Controllers

The target architecture uses two ExternalDNS controllers because internal and
public DNS have different providers, credentials, zones, and exposure policies:

- `external-dns-internal` watches only routes annotated with
  `external-dns.k8s.io/audience=internal`, limits itself to
  `lab.supermorphic.com`, and writes LAN records to Pi-hole.
- `external-dns-public` watches only explicitly public routes, writes to
  Cloudflare, and must exclude `lab.supermorphic.com`.

This separation prevents an internal route from being published publicly because
of a broad domain or provider configuration. It also allows the Cloudflare
controller to use a narrowly scoped token unrelated to Pi-hole credentials.

Only the internal controller is installed in the foundation milestone because no
public Gateway or public application exists yet. The second Cloudflare controller
remains the documented target and is added with the future public Gateway. This
is a sequencing change, not a rejection of the two-controller design.

The old draft proposed a third-party Pi-hole webhook. ExternalDNS now includes a
native Pi-hole v6 provider, so the extra webhook is unnecessary. Pi-hole cannot
store ExternalDNS TXT ownership records, hence the deliberate `registry=noop` and
`policy=upsert-only` settings protect manually managed records. See the
[ExternalDNS Pi-hole guide](https://kubernetes-sigs.github.io/external-dns/latest/docs/tutorials/pihole/).

Cloudflare still participates on day one through cert-manager DNS-01. That token
proves control of the domain for the internal wildcard certificate without
publishing internal service addresses to public DNS.

### Why Flux Replaces ArgoCD

The existing k3s environment uses ArgoCD, but the new platform adopts Flux because
its source, Helm, and Kustomize controllers map cleanly to the desired monorepo and
dependency-ordered platform layers. Flux can decrypt SOPS secrets natively during
Kustomization reconciliation and represents Helm installations as reviewable
`HelmRelease` resources. ArgoCD does support Git webhooks; the legacy failure mode
was admission-webhook and CRD readiness combined with template-only Helm
ownership, not repository notification delivery.

Running both systems would create competing ownership and duplicate operational
surfaces. ArgoCD resources are therefore reference material only. Flux is
bootstrapped after Cilium, then becomes the sole Kubernetes reconciler.

### Why SOPS with age

SOPS keeps encrypted values in the same declarative workflow as the resources
that consume them. Age provides a small key format with no external service
dependency, and both the public and private identities can be stored in the
existing password-manager practice. Flux can decrypt SOPS documents directly,
while talhelper can consume an encrypted Talos secret bundle.

Alternatives were considered:

- Plain Kubernetes Secrets are unacceptable because base64 is not encryption.
- Sealed Secrets ties ciphertext to an in-cluster controller key and complicates
  recovery when rebuilding the cluster that holds the decryption key.
- External Secrets plus 1Password or another backend is attractive at larger
  scale but introduces an external API, another controller, and bootstrap
  credentials before there is a demonstrated need.
- Reflector copies Secrets between namespaces but expands secret distribution and
  does not solve authoritative secret storage.

The chosen model uses one new repository-specific age identity, stores the private
key outside Git, bootstraps it into `flux-system` out of band, and deploys each
secret directly to its consuming namespace. External Secrets can be reconsidered
when secret rotation or multi-cluster distribution becomes painful enough to
justify the additional service.

### Why Longhorn Plus NFS Instead of One Storage System

The workloads have two different storage profiles. Databases, application
configuration, and small stateful services need Kubernetes-managed block volumes
with node failure tolerance. Media and downloads need large shared filesystems
whose data already belongs on the UNAS Pro.

Longhorn is retained for block storage because it is already understood in the
existing GitOps configuration, supports amd64 and Talos with the iSCSI and
util-linux extensions, provides visible replica health and rebuild behavior, and
can back up to the existing UNAS CIFS share. Two replicas tolerate one node loss
while avoiding the three-times capacity cost of a replica on every node. CIFS
backups remain mandatory because replicas are availability, not backup.

Rook/Ceph was not chosen because three single-disk converged nodes offer limited
failure-domain diversity while adding substantially more memory, networking, and
recovery complexity. Plain local-path storage is simpler but provides no replica
failover. Putting every PVC directly on NFS would make the NAS a synchronous
dependency for latency-sensitive application state.

Longhorn receives a dedicated Talos user volume at `/var/mnt/longhorn` rather
than sharing EPHEMERAL. Capacity isolation prevents a replica rebuild or runaway
volume from consuming the filesystem that holds etcd, logs, and container images.
The UNAS NFS CSI driver is used separately for `/media` and `/downloads`, avoiding
wasteful Longhorn replication of large replaceable or externally protected files.
See the [Longhorn installation requirements](https://longhorn.io/docs/1.12.0/deploy/install/).

### Why Lifecycle Automation Is Deferred

Renovate is useful immediately after the baseline is stable because it makes
available updates visible as reviewable pull requests. Automatic merge is
disabled until compatibility and rollback behavior are established.

Tuppr is a younger community controller that can orchestrate Talos and Kubernetes
upgrades, but automation should encode a procedure already understood by the
operator. The plan therefore requires one successful manual Talos upgrade and one
manual Kubernetes upgrade, including rollback and declared-version
synchronization, before tuppr is considered. If adopted, control-plane
parallelism remains one to preserve etcd quorum and simplify fault diagnosis.

## Target Repository Structure

```text
.just/
  repository.just
  bootstrap.just
talos/
  mod.just
  talconfig.yaml
  talsecret.sops.yaml
  patches/
clusterconfig/                         # generated and ignored
kubernetes/
  mod.just
  flux/clusters/prod/
    apps.yaml
  apps/flux-system/flux-canary/
    ks.yaml
    app/
      kustomization.yaml
      secret.sops.yaml
  apps/kube-system/cilium/
    README.md
    ks.yaml
    app/
      kustomization.yaml
      ocirepository.yaml
      helmrelease.yaml
      values.yaml
  apps/networking/metallb/
  apps/networking/envoy-gateway/
  apps/networking/external-dns/
  apps/security/cert-manager/
  apps/testing/echo/
docs/
plans/
.mise.toml
.sops.yaml
.justfile
```

Do not create base/overlay directories for every application before a second
cluster exists. Add shared bases only when the Pi staging cluster is implemented
and actual duplication needs to be removed.

Every application owns its Flux entrypoint, chart source, Helm release or focused
native resources, first-party configuration, routing, monitoring, and local
documentation under `kubernetes/apps/<namespace>/<app>/`. Directories do not
become deployable merely by existing; a parent Flux Kustomization must include
each application explicitly.

## Command Interface

### Tooling Responsibilities

- Mise pins and installs repository-local CLI versions and defines the non-secret
  environment variables required by those tools. Mise tasks are not used as the
  operational command interface.
- Just is the sole task runner. The root `.justfile` is a small parent dispatcher
  that declares grouped modules; domain modules expose generation, validation,
  installation, bootstrap, and verification workflows using the tools provided
  by Mise.
- Just modules, not textual imports, provide command namespaces and keep module
  variables, settings, working directories, and recipes within their operational
  domain.
- `just repo tools` is a convenience wrapper around `mise install`.
- Secrets and machine-specific values are not stored in `.mise.toml`. Recipes
  require them from the operator environment or password manager and fail when
  they are absent.

Module ownership is:

- `repo`, sourced from `.just/repository.just`: workstation tools, version
  reporting, SOPS identity checks, repository policy, secret scanning, and the
  aggregate non-mutating verification workflow.
- `talos`, sourced from `talos/mod.just`: Talhelper source validation, rendering,
  rendered-config validation, per-node configuration, image operations, and
  later Talos lifecycle commands.
- `bootstrap`, sourced from `.just/bootstrap.just`: explicitly ordered workflows
  that cross Talos and Kubernetes boundaries, including etcd, Cilium, and Flux
  bootstrap. It composes domain commands but does not own their low-level logic.
- `kube`, sourced from `kubernetes/mod.just`: Kubernetes rendering,
  reconciliation, diagnostics, and day-two operations after those workflows
  exist.

The namespaced operator interface is:

```text
just repo tools
just repo versions
just repo secrets
just repo verify
just repo secret-scan
just talos source-validate
just talos generate
just talos validate
just talos apply <node>
just bootstrap talos
just bootstrap cilium
just bootstrap flux
```

Running `just` lists the modules, and running a module without a recipe, such as
`just talos`, lists that module's available commands. The module files repeat the
Just settings they require because settings are module-local. Paths colocated
with a module are resolved relative to that module; repository-wide paths use the
root Justfile directory explicitly.

Flat compatibility commands and aliases are intentionally not retained. This is
an early single-operator rebuild, so one documented namespaced interface is less
ambiguous than maintaining two command vocabularies. Documentation and phase
evidence must be updated atomically with the module migration.

Generated `clusterconfig`, talosconfig, kubeconfig, decrypted secrets, and age
private keys must remain ignored. The command recipes must fail when prerequisites
or required environment variables are missing rather than silently using defaults.

### Just Module Migration Gate

Completed on 2026-07-12. The root dispatcher and four namespaced modules are in
place, flat commands were removed, documentation uses the namespaced interface,
and all repository-only acceptance checks below passed.

Complete this repository-only migration before Phase 3 enables any machine
configuration command:

1. Reduce the root `.justfile` to shared settings and grouped `repo`, `talos`,
   `bootstrap`, and `kube` module declarations. Do not add compatibility aliases.
2. Move the existing tool, secret, policy, and scanning recipes into
   `.just/repository.just`.
3. Move Talhelper generation and validation into `talos/mod.just`, taking
   advantage of its Talos-relative working directory without weakening any
   prerequisite or rendered-policy assertion.
4. Move the disabled etcd, Cilium, and Flux bootstrap boundaries into
   `.just/bootstrap.just`; keep them disabled until their owning implementation
   phases.
5. Create `kubernetes/mod.just` as the namespace for later Kubernetes operations;
   do not add speculative recipes merely to populate the module.
6. Update the root README, Talos README, SOPS and recovery documentation, and
   phase evidence to use only the namespaced commands.
7. Verify `just`, each module listing, `just repo verify`, `just talos validate`,
   formatting with `just --fmt --check`, failure behavior without the SOPS
   identity, and the continued disablement of future cluster-changing workflows.

## Phase 0: Preserve and Preflight

Implementation evidence and the remaining physical checklist are maintained in
[`docs/phase-0-preflight.md`](../docs/phase-0-preflight.md). Phase 0 is in progress;
the live inventory and rollback tag are complete, while `nuc1`, BIOS, new-drive,
new-config, and USB checks remain open.

### Objectives

- Preserve a physical and Git rollback path.
- Confirm all hardware and network assumptions before changing a node.
- Prepare every artifact required for installation before shutting down Talos.

### Work

1. Record the current node MAC addresses, DHCP reservations, BIOS versions,
   Secure Boot state, TPM availability, NIC name, old disk model, and old serial.
2. Confirm the new Samsung NVMes report their expected capacity and current stable
   firmware before Talos seals encryption keys to the TPM.
3. Tag the current Git state as `manual-talos-v1.13.2` after ensuring the tag does
   not include plaintext generated credentials.
4. Retain the old generated files locally only as short-term reference. They are
   not inputs to the fresh cluster and must remain ignored.
5. Build and validate the new repository structure, talhelper configuration,
   Image Factory schematic, generated machine configs, and Secure Boot USB.
6. Test that the USB reaches Talos maintenance mode without applying a config or
   modifying a disk.

### Exit Gate

- All three machine configs pass local validation.
- The Image Factory ISO and installer use the same version and schematic.
- DHCP reservations still map each MAC to the documented address.
- The USB reaches maintenance mode with Secure Boot enabled.
- The old SSDs have a documented labeling and rollback procedure.

## Phase 1: Rebuild the Repository

Implementation evidence is recorded in
[`docs/phase-1-repository.md`](../docs/phase-1-repository.md). Phase 1 completed on
2026-07-12. Mise provides the locked CLI environment, Just provides the guarded
operator interface, the new repository age identity is stored outside Git, and
no cluster-changing command ran.

### Work

1. Replace the raw `talosctl gen config` layout with the target structure above.
2. Add `.mise.toml` pins for talosctl, talhelper, kubectl, Helm, Flux, Cilium CLI,
   Kustomize, SOPS, age, yq, just, and GitHub CLI.
3. Add path-specific SOPS rules:
   - Fully encrypt `talos/talsecret.sops.yaml`.
   - Encrypt only `data` and `stringData` in Kubernetes Secret manifests.
4. Generate a new age identity and store its public and private portions in the
   password manager. Only the public recipient belongs in Git.
5. Add ignore rules for `clusterconfig`, talosconfig, kubeconfig, temporary secret
   files, Helm output, support bundles, and local tool caches.
6. Add the `.justfile`, cluster documentation, recovery notes, and validation
   commands.
7. Treat `homelab-gitops` as reference material only. Do not copy ArgoCD,
   Traefik, KSOPS generators, or rendered Helm chart manifests.

### Exit Gate

- `mise install` provides the pinned tools.
- Secret scanning finds no age private key or plaintext Talos/Kubernetes secret.
- Generated paths are ignored while declarative source files remain trackable.
- A fresh clone can install the locked tools and validate that a loaded
  password-manager identity matches the committed public recipient.
- Phase 2 will prove that a fresh clone plus the password-manager identity renders
  identical machine configs after the Talhelper sources exist.

## Phase 2: Define Talos with Talhelper

Implementation evidence is recorded in
[`docs/phase-2-talos.md`](../docs/phase-2-talos.md). Phase 2 completed on
2026-07-12. The fresh Talos identity is encrypted, all three machine configs
render reproducibly into ignored output, and strict metal-mode validation passes.

### Machine Configuration

- Configure all three nodes as control planes and explicitly set
  `allowSchedulingOnControlPlanes: true`.
- Preserve DHCP on `enp88s0`; the existing router reservations remain the source
  of the stable node addresses.
- Configure the Kubernetes API endpoint as `https://192.168.90.20:6443`.
- Configure the Talos VIP `192.168.90.20` on `enp88s0`.
- Enable KubePrism on `localhost:7445` and host DNS caching.
- Set `cniConfig` to none and disable kube-proxy because Cilium replaces it.
- Install to `/dev/nvme0n1` with wipe enabled.

### Image Factory Schematic

Include these current system extensions:

- `siderolabs/intel-ucode` for CPU microcode
- `siderolabs/i915` for Intel GPU firmware and kernel modules
- `siderolabs/iscsi-tools` for future Longhorn support
- `siderolabs/util-linux-tools` for future Longhorn prerequisites

The ISO and machine-config installer must reference the same Secure Boot
schematic and Talos `v1.13.6`.

### Disk Layout and Encryption

1. Configure STATE as LUKS2 with a TPM key, signed PCR policy binding, and a check
   that Secure Boot is enabled when the TPM key is enrolled.
2. Configure EPHEMERAL as LUKS2 with a TPM key, signed PCR policy binding, and
   `lockToState: true`.
3. Cap EPHEMERAL at `150GiB` so Talos images, logs, container data, and etcd cannot
   consume the entire NVMe.
4. Provision an XFS `UserVolumeConfig` named `longhorn` on the system NVMe with a
   minimum size of `700GiB`, growth into remaining free space, and mount path
   `/var/mnt/longhorn`.
5. Leave the Longhorn user volume unencrypted as selected. Future Longhorn data
   protection comes from replication, backups, and application-level secrets.

### Secrets and Rendering

1. Generate a fresh Talos secret bundle with talhelper.
2. Encrypt it immediately as `talos/talsecret.sops.yaml`.
3. Render all three machine configs into ignored `clusterconfig/`.
4. Validate each rendered config with `talosctl validate --mode metal`.
5. Compare the rendered configs and confirm that only hostname and node-specific
   network identity differ.

### Exit Gate

- Every rendered config is valid for metal mode.
- The expected Talos, Kubernetes, schematic, disk, VIP, CNI, and encryption
  settings appear in all three configs.
- No tracked file contains a Talos certificate, token, private key, or kubeconfig.

## Phase 3: Replace and Install the NVMes

### Shutdown and Rollback

1. Gracefully shut down each old NUC through its direct Talos API endpoint.
2. Label each removed SSD with its hostname and removal date.
3. Do not wipe or reuse an old SSD until the new foundation passes its soak test.
4. Replace all three drives. A rolling etcd migration is unnecessary because the
   old cluster contains no workloads or required persistent state.

### Installation

1. Boot each NUC from the new Secure Boot USB into maintenance mode.
2. Before applying config, inspect disks through the insecure Talos API and verify
   the Samsung model, serial, size, and `/dev/nvme0n1` target.
3. Apply the matching generated config with `talosctl apply-config --insecure`.
4. Allow Talos to wipe the new disk, install, and reboot from NVMe.
5. Repeat for all three nodes without running `talosctl bootstrap` yet.

### Exit Gate

- Every node boots from its new NVMe without the USB.
- Each node answers at its reserved IP and reports its expected hostname.
- Secure Boot is enabled and the expected extensions are active.
- STATE, EPHEMERAL, and the Longhorn user volume exist with expected sizes.

### Rollback

If a node cannot install or boot and the problem cannot be corrected safely,
power it down and reinstall its labeled old SSD. Do not mix old and new nodes into
one etcd cluster because the rebuild uses a fresh Talos identity.

## Phase 4: Bootstrap Talos and Kubernetes

### Work

1. Configure the generated talosconfig with all three node endpoints.
2. Run `talosctl bootstrap` exactly once against `nuc1` at `192.168.90.10`.
3. Wait for `nuc2` and `nuc3` to join etcd and verify exactly three members.
4. Check etcd status, alarms, leader election, and member health.
5. Retrieve kubeconfig from a control-plane node.
6. Expect Kubernetes nodes to remain `NotReady` until Cilium is installed.
7. Verify time synchronization, Talos services, API VIP reachability, encryption
   status, mount status, and `/var/mnt/longhorn` capacity.

### Exit Gate

- Talos reports three healthy control-plane nodes.
- Etcd has exactly three healthy members and no alarms.
- Kubernetes API is reachable through `192.168.90.20:6443`.
- Kubeconfig and talosconfig work from the operator workstation.

## Phase 5: Bootstrap Cilium

Implementation and live acceptance evidence are recorded in
[`docs/phase-5-cilium.md`](../docs/phase-5-cilium.md).

### Configuration

Keep one canonical values file under the future Flux Cilium application. Use the
same file for the initial Helm install and subsequent Flux reconciliation.

Configure:

- Kubernetes IPAM
- `kubeProxyReplacement: true`
- `k8sServiceHost: localhost`
- `k8sServicePort: 7445`
- Talos host cgroup configuration
- Two Cilium operator replicas
- Hubble relay enabled
- Hubble UI disabled until the observability phase
- Default tunnel routing for the initial deployment
- Default Cilium VLAN filtering; do not configure `bpf.vlanBypass` without a
  documented cluster requirement for a tagged VLAN

### Work

1. Install Cilium `v1.19.6` with the guarded `just bootstrap cilium` workflow and
   the tracked values.
2. Wait for Cilium agents and operators.
3. Confirm kube-proxy was not deployed.
4. Run `cilium status --wait` and the guarded connectivity suite. Keep all
   functional tests enabled; exclude only the aggregate unexpected-drop counter
   when upstream non-cluster VLAN broadcasts are independently confirmed.
5. Verify Kubernetes DNS and cross-node pod traffic.

### Exit Gate

- All three Kubernetes nodes are `Ready` and schedulable.
- Cilium reports healthy agents and operators.
- Connectivity and DNS tests pass across nodes.
- No kube-proxy workload exists.

## Phase 6: Publish and Bootstrap Flux

### Completion State (2026-07-19)

Phase 6 is complete against the existing private personal repository
`7yXwscXEzv6phzUnKfrw/homelab-talos`. Flux `2.9.2`, the production app root,
encrypted permanent canary, staged Cilium adoption protections, and all guarded
Just workflows are live. The read-only Git source, SOPS decryption, canary drift
repair, Cilium ownership, connectivity suite, Talos diagnostics, and etcd exit
gates passed. Exact evidence is recorded in `docs/phase-6-flux.md`.

### Work

1. Use the existing private `7yXwscXEzv6phzUnKfrw/homelab-talos` GitHub repository.
2. Confirm `origin`, `main`, and generated-credential exclusions through the
   repository checks.
3. Bootstrap Flux `2.9.2` at `kubernetes/flux/clusters/prod` with a unique
   read-only deploy key and one-minute Git polling.
4. Create `flux-system/sops-age` through `just bootstrap flux-sops` from the
   password-manager private key; never give the key to GitHub or the bootstrap PAT.
5. Configure Flux Kustomizations with SOPS decryption and explicit dependencies.
6. Add a Flux HelmRelease matching the existing Cilium release name, namespace,
   chart version, and values so Flux adopts it without a disruptive reconfiguration.
7. Keep infrastructure sources and application definitions declarative; do not
   commit rendered vendor charts.
8. Keep Cilium suspended and prune-protected on first reconciliation, then use
   `just bootstrap flux-adopt-cilium` to bound the one-time ownership and
   certificate-material replacement, verify every workload returns Ready with
   zero restarts, and prove a repeated adoption causes no further rollout before
   committing the permanent unsuspend.
9. Retain the SOPS-encrypted `flux-canary` Secret and prove guarded deletion is
   repaired by its dependent Kustomization.

### Exit Gate

- Flux sources, Helm releases, and Kustomizations report `Ready`.
- Flux can decrypt a test SOPS Secret.
- Flux reconciles Cilium without restarting or reconfiguring it unexpectedly.
- Deleting a noncritical test resource causes Flux to recreate it.

## Phase 7: Internal Platform Foundation

Implementation, operator commands, security boundaries, and acceptance evidence
are recorded in
[`docs/phase-7-foundation.md`](../docs/phase-7-foundation.md).

### Reconciliation Order

1. cert-manager
2. MetalLB
3. Envoy Gateway and matching Gateway API CRDs
4. Internal Gateway configuration
5. ExternalDNS for Pi-hole
6. Echo acceptance workload

### cert-manager

- Install cert-manager `v1.21.0`, which supports Kubernetes `v1.35`.
- Create a least-privilege Cloudflare API token limited to DNS edits for
  `supermorphic.com`.
- Store the token in a SOPS-encrypted Secret in the consuming namespace.
- Validate ACME using Let's Encrypt staging before creating the production issuer.
- Issue a production wildcard certificate for `*.lab.supermorphic.com` in the
  internal Gateway namespace.

### MetalLB and Envoy Gateway

- Install MetalLB in L2 mode with pool `192.168.90.30-192.168.90.39`.
- Reserve `192.168.90.30` for one internal Envoy Gateway.
- Install stable Envoy Gateway `v1.8.2`.
- Configure one HTTPS listener using the wildcard certificate.
- Allow application namespaces to attach HTTPRoutes through an explicit
  `allowedRoutes` policy.
- Do not create a public Gateway during this milestone.

### Internal DNS

- Verify the existing DNS server at `192.168.90.2` is running Pi-hole v6 and its
  API is reachable as `https://pi.hole` from the cluster using the tracked public
  Pi-hole CA. Never skip TLS verification.
- Use ExternalDNS's native Pi-hole provider rather than a third-party webhook.
- Configure `source=gateway-httproute`, Pi-hole API version 6, `registry=noop`,
  `policy=upsert-only`, and domain filter `lab.supermorphic.com`.
- Require the annotation `external-dns.k8s.io/audience=internal` before a route is
  published.

### Acceptance Workload

- Deploy a small echo service in the testing namespace.
- Create an HTTPRoute for `echo.lab.supermorphic.com` with the internal DNS
  audience annotation.
- Verify Pi-hole publishes `192.168.90.30` and HTTPS presents the wildcard
  certificate.

### Exit Gate

- MetalLB assigns the intended IP without conflict.
- Gateway is `Programmed` and its listener is accepted.
- The wildcard certificate is `Ready` using the production issuer.
- Pi-hole resolves the echo hostname to `192.168.90.30`.
- HTTPS returns the echo response with a trusted certificate.

## Phase 8: Foundation Soak and Recovery

### Failure Tests

1. Reboot one NUC at a time.
2. Require TPM auto-unlock, etcd recovery, Kubernetes readiness, Cilium health,
   Flux reconciliation, DNS resolution, and Gateway reachability before moving to
   the next node.
3. Confirm MetalLB moves the internal Gateway announcement when its announcing
   node is unavailable.
4. Restart Flux controllers and verify reconciliation resumes.
5. Remove and recreate the echo workload through Git to validate the full path.

### Soak Gate

Run the foundation for at least 24 hours with:

- No etcd alarms or unexpected member changes
- No repeated controller crash loops
- No certificate issuance or renewal errors
- No Pi-hole record churn
- No recurring Cilium connectivity or endpoint regeneration failures
- No TPM unlock or volume mount failures after reboot

Record final versions, schematic ID, extension list, disk layout, encryption
status, recovery commands, and support-bundle procedure. Only after this gate may
the old SSDs be wiped or reused.

## Phase 9: Storage

1. Install a stable Longhorn `1.12.x` release verified against the chosen Talos
   and Kubernetes versions.
2. Point Longhorn's default data path to `/var/mnt/longhorn`.
3. Use two replicas and enforce node-level replica anti-affinity.
4. Configure the UNAS CIFS backup target and SOPS-encrypted credentials.
5. Add recurring snapshots and backups, then prove restoration into a new PVC.
6. Install NFS CSI and define separate StorageClasses for `/media` and
   `/downloads` on the UNAS Pro.
7. Test one PVC on Longhorn and each NFS StorageClass before adding applications.

### Exit Gate

- Longhorn nodes, disks, engines, and replicas are healthy.
- A replica rebuild succeeds after a single-node reboot.
- A Longhorn backup can be restored.
- Both NFS classes support the expected read/write behavior.

## Phase 10: Greenfield Platform Applications

- Add applications one at a time as Flux HelmReleases or focused native
  manifests.
- Use useful legacy configuration as requirements, then author Gateway API
  HTTPRoutes and other resources for the new platform.
- Do not deploy ArgoCD; Flux is the sole reconciler.
- Do not copy generated Helm YAML, KSOPS resources, PVCs, or application data
  from `homelab-gitops`.
- Recreate secrets from authoritative sources and encrypt them with the new SOPS
  key instead of mechanically copying ciphertext from the old repository.
- Validate DNS, TLS, storage, health probes, and rollback for each application
  before moving to the next.

Suggested order:

1. kube-prometheus-stack and Grafana
2. Gatus
3. Homepage
4. Trivy Operator if resource use is acceptable

## Phase 11: Media Platform

1. Verify the `i915` extension exposes `/dev/dri/renderD128` on all appropriate
   NUCs.
2. Deploy the Intel device plugin and validate GPU resource discovery.
3. Create the media namespace and NFS-backed media/download PVCs.
4. Deploy Gluetun and the selected download client in one pod/network namespace.
5. Deploy Prowlarr, Sonarr, Radarr, Jellyseerr, and Plex.
6. Store application configuration on Longhorn and bulk media/downloads on NFS.
7. Prove VPN egress, download/import flow, atomic media moves, and Plex hardware
   transcoding before declaring the phase complete.
8. Keep Plex LAN-only; public streaming exposure remains deferred.

## Phase 12: Operations and Lifecycle

- Add Renovate in PR-only mode with dependency grouping and no automatic merge.
- Perform one manual Talos patch upgrade, one node at a time, and verify rollback.
- Perform one manual Kubernetes upgrade with `talosctl upgrade-k8s --dry-run`
  followed by the real upgrade.
- Synchronize declared Talos/Kubernetes versions after the live upgrade to prevent
  configuration drift.
- Evaluate tuppr only after the manual procedures are documented and successful.
- If adopted, set tuppr control-plane parallelism to one and require health checks
  for etcd, nodes, Cilium, and critical workloads.

## Phase 13: Deferred Expansion

Create separate plans for:

- Converting the Pi 5 k3s cluster from ArgoCD/Traefik to Flux/Envoy staging
- Introducing shared bases or overlays after the second cluster exists
- A public Envoy Gateway and Cloudflare ExternalDNS
- External Plex access using direct routing rather than Cloudflare proxying
- Replacing SOPS-distributed workload credentials with External Secrets if the
  operational benefit justifies another controller

## Superseded Decisions

This plan intentionally rejects or defers these earlier choices:

- Preserving the old Talos PKI: unnecessary for an empty cluster
- Kubernetes `v1.36`: deferred until stable Envoy Gateway support exists
- `i915-ucode`: replaced by the current `siderolabs/i915` extension
- Longhorn on shared EPHEMERAL: replaced by a capacity-isolated user volume
- Third-party Pi-hole webhook: replaced by native Pi-hole v6 support
- Internal and public Gateways on day one: internal only until an actual need exists
- Reflector: secrets are deployed directly to consuming namespaces
- Blanket critical priority classes: retain vendor defaults unless testing proves
  a specific override is required
- Immediate tuppr adoption: manual upgrade proficiency comes first
- Base/overlay directories for every app: deferred until staging creates real reuse
- One all-encompassing rollout: replaced by explicit phase gates and rollback points

## Reference Sources

- Talos support matrix and v1.13 documentation: https://docs.siderolabs.com/talos/v1.13
- Talos Image Factory: https://factory.talos.dev
- Talhelper documentation: https://budimanjojo.github.io/talhelper/latest/
- Cilium Talos Helm installation: https://docs.cilium.io/en/stable/installation/k8s-install-helm/
- Cilium Kubernetes compatibility: https://docs.cilium.io/en/stable/network/kubernetes/compatibility/
- Envoy Gateway compatibility matrix: https://gateway.envoyproxy.io/news/releases/matrix/
- ExternalDNS Pi-hole guide: https://kubernetes-sigs.github.io/external-dns/latest/docs/tutorials/pihole/
- Longhorn documentation: https://longhorn.io/docs/
