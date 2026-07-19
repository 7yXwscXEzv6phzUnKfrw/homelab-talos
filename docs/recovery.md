# Repository and Workstation Recovery

## Source Recovery

Clone the private repository and install the toolchain from its lockfile:

```bash
brew install mise
mise trust
mise install --locked
mise exec -- just repo verify
```

The `manual-talos-v1.13.2` tag preserves the historical Git state of the manual
build. Its artifacts are not present on the current branch. The original SSDs
are the physical rollback path and must remain labeled by node.

## Restore SOPS Access

Retrieve the password-manager item named `homelab-talos SOPS age key`. Load it
for the current shell without placing it in the repository:

```bash
export SOPS_AGE_KEY='AGE-SECRET-KEY-...'
mise exec -- just repo secrets
```

For longer operations, use an owner-readable file outside the repository:

```bash
export SOPS_AGE_KEY_FILE=/secure/path/homelab-talos-age.txt
mise exec -- just repo secrets
```

Only the active public recipient is committed on the current branch. A lost
private key makes current repository secrets unrecoverable. Any deliberate
recovery from the historical rollback tag requires the separate identity that
encrypted that historical state.

## Recreate Generated State

Rendered machine configs and talosconfig can be recreated from Git plus the
repository age identity:

```bash
mise exec -- just talos generate
```

The recipe verifies the age identity, renders `clusterconfig/nuc1.yaml` through
`nuc3.yaml` and `clusterconfig/talosconfig`, then performs strict metal-mode and
policy validation. These outputs and the later kubeconfig remain ignored. Never
recover them by committing plaintext copies.

Phase-specific rebuild and recovery evidence is maintained under `docs/`. Flux
recovery procedures will be added when Flux is implemented and tested.
