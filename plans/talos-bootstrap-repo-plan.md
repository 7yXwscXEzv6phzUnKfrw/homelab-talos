# Talos Bootstrap Repo Plan

## Summary

Use `homelab-talos` as the source of truth for Talos bootstrap, encrypted Talos cluster identity, and future Flux bootstrap. Use the Flux GitOps repo as the source of truth for Kubernetes resources after Flux is installed.

Use a dedicated Talos SOPS age identity. Store the private key in a password manager, load it locally only when needed, and commit only the public age recipient plus encrypted Talos secret files.

## Key Changes

- Keep the repo model centered on `.sops.yaml`, `.gitignore`, `docs/nuc-cluster.md`, `docs/sops.md`, Talos patches, encrypted Talos secrets, and ignored `clusters/nuc/talos/generated/`.
- Add `docs/sops.md` documenting password manager storage, local key loading with `SOPS_AGE_KEY`, `SOPS_AGE_KEY_FILE`, or `~/.config/sops/age/keys.txt`, encryption, decryption, and plaintext cleanup.
- Add a dedicated Talos SOPS rule that full-file encrypts only Talos SOPS secret files:

```yaml
creation_rules:
  - path_regex: clusters/nuc/talos/secrets/.*\.sops\.ya?ml$
    age: <talos-age-public-recipient>
    encrypted_regex: '^(.*)$'
```

- Tighten `.gitignore` so generated files and plaintext secrets stay out of Git while encrypted SOPS files remain trackable:

```gitignore
clusters/**/talos/generated/
clusters/**/talos/_out/

clusters/**/talos/secrets/*.yaml
!clusters/**/talos/secrets/*.sops.yaml

**/talosconfig
**/kubeconfig
**/controlplane.yaml
**/worker.yaml
**/controlplane-final.yaml
**/nuc*-controlplane.yaml
```

## Secret And Regeneration Workflow

Preserve the existing manually installed cluster identity:

```bash
talosctl gen secrets \
  --from-controlplane-config clusters/nuc/talos/generated/controlplane.yaml \
  --output-file clusters/nuc/talos/secrets/talos-secrets.yaml
```

Encrypt and remove plaintext:

```bash
sops --encrypt \
  --output clusters/nuc/talos/secrets/talos-secrets.sops.yaml \
  clusters/nuc/talos/secrets/talos-secrets.yaml

rm clusters/nuc/talos/secrets/talos-secrets.yaml
```

Decrypt locally when regenerating configs:

```bash
SOPS_AGE_KEY_FILE=/path/to/talos-age-keys.txt \
  sops -d clusters/nuc/talos/secrets/talos-secrets.sops.yaml > /tmp/talos-secrets.yaml
```

Render configs using the locally installed `talosctl v1.13.2` flag, which is `--output`:

```bash
talosctl gen config nuc-cluster https://192.168.90.20:6443 \
  --with-secrets /tmp/talos-secrets.yaml \
  --output clusters/nuc/talos/generated
```

Apply common patches first, then host patches. Keep all rendered output under ignored `clusters/nuc/talos/generated/`.

Verify regenerated access before relying on it:

```bash
talosctl -n 192.168.90.10 -e 192.168.90.10 \
  --talosconfig clusters/nuc/talos/generated/talosconfig \
  get hostname
```

## Test Plan

- Verify `git status --ignored` shows `clusters/nuc/talos/generated/` ignored.
- Verify `.sops.yaml` contains only the Talos public recipient.
- Verify plaintext `clusters/**/talos/secrets/*.yaml` is ignored and `*.sops.yaml` is not ignored.
- Verify `sops -d clusters/nuc/talos/secrets/talos-secrets.sops.yaml` works only when the private key is loaded locally.
- Verify generated configs preserve the current cluster identity and no plaintext Talos secrets, age private keys, kubeconfigs, talosconfigs, or generated machine configs are tracked.

## Assumptions

- The current `clusters/nuc/talos/_out/controlplane.yaml` is from the manual install and represents the real cluster identity to preserve.
- Move `_out/` contents to `generated/` before deriving `talos-secrets.sops.yaml`.
- The implementation should use `--output` because the installed local `talosctl v1.13.2` does not expose `--output-dir`.
