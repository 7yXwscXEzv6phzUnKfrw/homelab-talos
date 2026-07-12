# Repository and Workstation Recovery

## Source Recovery

Clone the private repository and install the toolchain from its lockfile:

```bash
brew install mise
mise trust
mise install --locked
mise exec -- just verify
```

The `manual-talos-v1.13.2` tag preserves the last Git state of the manual build.
The original SSDs are the physical rollback path and must remain labeled by node.

## Restore SOPS Access

Retrieve the password-manager item named `homelab-talos SOPS age key`. Load it
for the current shell without placing it in the repository:

```bash
export SOPS_AGE_KEY='AGE-SECRET-KEY-...'
mise exec -- just secrets
```

For longer operations, use an owner-readable file outside the repository:

```bash
export SOPS_AGE_KEY_FILE=/secure/path/homelab-talos-age.txt
mise exec -- just secrets
```

Only the public recipient is committed. A lost private key makes new repository
secrets unrecoverable; it does not affect the legacy encrypted secret, which uses
its older independent identity.

## Recreate Generated State

Phase 2 will define the exact Talhelper render command. Rendered machine configs,
talosconfig, and kubeconfig belong under ignored paths and can be recreated from
Git plus the repository age identity. Never recover them by committing plaintext
copies.

Cluster rebuild, etcd recovery, Cilium bootstrap, and Flux recovery procedures
will be added when those components are implemented and tested.
