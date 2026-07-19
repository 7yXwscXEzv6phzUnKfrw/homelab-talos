# Talos Bootstrap Repository Plan (Superseded)

## Status

- Original decision record: 2026-05
- Superseded by: [`talos-flux-platform-plan.md`](talos-flux-platform-plan.md)
- Historical implementation artifacts: removed after the fresh cluster completed
  Phase 5

## Original Objective

The original bootstrap effort established this repository as the source of truth
for Talos bootstrap material and introduced SOPS encryption for cluster identity.
It initially attempted to preserve the manually installed Talos identity and its
rendered configuration.

The later platform plan intentionally replaced that identity with a fresh
Talhelper-managed cluster. The old SSDs served as the physical rollback boundary
during the rebuild; their repository-side patches, rendered credentials, and
encrypted identity were retired once the new three-node cluster passed Talos,
etcd, Kubernetes, and Cilium acceptance.

## Decisions Retained

The current implementation keeps the useful principles from the original plan:

- Store private age identities outside Git in the password manager.
- Commit only encrypted Talos identity material.
- Keep rendered machine configs, talosconfigs, kubeconfigs, and decrypted
  secrets ignored.
- Use a dedicated full-document SOPS rule for the Talos secret bundle.
- Validate secret handling and generated configuration through repository Just
  workflows.
- Separate declarative source from local generated output.

## Current Implementation

- [`../talos/talconfig.yaml`](../talos/talconfig.yaml) is the cluster topology and
  Talhelper source.
- [`../talos/talsecret.sops.yaml`](../talos/talsecret.sops.yaml) is the active,
  fully encrypted Talos identity.
- `clusterconfig/` is the ignored render destination.
- [`../docs/sops.md`](../docs/sops.md) defines the active secret workflow.
- [`../docs/phase-2-talos.md`](../docs/phase-2-talos.md) records generation and
  validation evidence.
- [`../docs/phase-3-installation.md`](../docs/phase-3-installation.md) records the
  completed one-node-at-a-time installation.

Do not use commands or configuration from the initial manual installation to
rebuild or administer the current cluster.
