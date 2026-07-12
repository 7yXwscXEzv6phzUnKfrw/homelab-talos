# Talos Source Boundary

This directory is the declarative source for the NUC Talos cluster. Phase 2
established the Talhelper inputs and enabled local generation and validation;
applying a config remains disabled until Phase 3.

## Source and Generated State

The trackable sources are:

- `talconfig.yaml` for cluster topology, versions, nodes, and patch references
- `talsecret.sops.yaml` for the fully encrypted fresh Talos identity
- `patches/` for reviewed machine configuration fragments

Talhelper renders per-node machine configs into the ignored root
`clusterconfig/` directory. Rendered configs contain credentials and must never
be moved into a trackable path.

The files under `clusters/nuc/talos/` describe the superseded manual
installation. Do not copy its Talos version, Image Factory schematic, generated
configs, or cluster identity into this directory.

## Phase 2 Workflow

The developer workflow is:

```bash
just repo secrets
just talos generate
just talos validate
just repo verify
```

Generation is local and non-mutating. Applying a rendered config is a separate
Phase 3 operation through `just talos apply <node>` and must not be replaced with
an undocumented raw `talosctl apply-config` command.

`just talos generate` first verifies the loaded repository age identity, then
decrypts the Talos bundle only inside the Talhelper process. It replaces the
ignored `clusterconfig/` output and runs `just talos validate`. Validation checks
all three configs in strict metal mode and asserts the Phase 2 endpoint, network,
Secure Boot installer, CNI, kube-proxy, encryption, and volume decisions.

See the root [`README.md`](../README.md) for workstation setup and the canonical
[`plans/talos-flux-platform-plan.md`](../plans/talos-flux-platform-plan.md) for
machine configuration decisions and phase gates.
