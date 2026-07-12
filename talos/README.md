# Talos Source Boundary

This directory will become the declarative source for the NUC Talos cluster in
Phase 2. Until that phase is implemented, the Talos generation and validation
recipes intentionally fail.

## Source and Generated State

Phase 2 will add these trackable sources:

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

After Phase 2 enables its recipes, the developer workflow will be:

```bash
just secrets
just talos-generate
just talos-validate
just verify
```

Generation is local and non-mutating. Applying a rendered config is a separate
Phase 3 operation through `just talos-apply <node>` and must not be replaced with
an undocumented raw `talosctl apply-config` command.

See the root [`README.md`](../README.md) for workstation setup and the canonical
[`plans/talos-flux-platform-plan.md`](../plans/talos-flux-platform-plan.md) for
machine configuration decisions and phase gates.
