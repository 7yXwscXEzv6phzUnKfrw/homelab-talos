# SOPS Secret Handling

This repository uses a dedicated age identity for the fresh Talos and Flux
platform. Only its public recipient is committed. The private identity stays in
the password-manager item `homelab-talos SOPS age key`.

The legacy encrypted secret under `clusters/nuc/talos/` retains its old recipient
and identity. It is not an input to the rebuild.

## Load the Repository Identity

Load the private identity for one shell:

```bash
export SOPS_AGE_KEY='AGE-SECRET-KEY-...'
mise exec -- just secrets
```

Alternatively, point SOPS at an owner-readable file outside the repository:

```bash
export SOPS_AGE_KEY_FILE=/secure/path/homelab-talos-age.txt
mise exec -- just secrets
```

The check derives the public recipient and rejects an identity that does not
match the first rule in `.sops.yaml`.

## Encryption Policy

- `talos/talsecret.sops.yaml` is encrypted as a complete document because every
  field is cluster identity material.
- `kubernetes/**/*.sops.yaml` encrypts only `data` and `stringData`, leaving
  Secret metadata reviewable.
- Plaintext secrets, decrypted files, kubeconfigs, talosconfigs, and private age
  identities must never be committed.

Phase 2 will document Talhelper secret generation and encryption after the new
Talos source is defined. Flux decryption configuration arrives with Flux
bootstrap, not during Phase 1.
