# SOPS for Talos Secrets

This repo uses a dedicated SOPS age identity for Talos bootstrap secrets.
Only the public age recipient is committed in `.sops.yaml`; the private age key
must stay outside Git.

## Store the Private Key

Store the private key in a password manager as a secure note or password item named
`homelab-talos SOPS age key`.

The private key file should contain the age identity, not just the public
recipient. A valid key file includes a line beginning with:

```text
AGE-SECRET-KEY-
```

## Load the Key Locally

If copying the key from a password manager, paste it into `SOPS_AGE_KEY` for the
current shell:

```bash
export SOPS_AGE_KEY='AGE-SECRET-KEY-...'
```

Alternatively, use a temporary file when decrypting or regenerating Talos configs:

```bash
export SOPS_AGE_KEY_FILE=/path/to/talos-age-keys.txt
```

Alternatively, place the key in the default SOPS age location:

```bash
mkdir -p ~/.config/sops/age
chmod 700 ~/.config/sops/age
cp /path/to/talos-age-keys.txt ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

## Encrypt Talos Secrets

Derive secrets from the current manually installed controlplane config, encrypt
them, and remove the plaintext intermediate:

```bash
talosctl gen secrets \
  --from-controlplane-config clusters/nuc/talos/generated/controlplane.yaml \
  --output-file clusters/nuc/talos/secrets/talos-secrets.yaml

sops --encrypt \
  --filename-override clusters/nuc/talos/secrets/talos-secrets.sops.yaml \
  --output clusters/nuc/talos/secrets/talos-secrets.sops.yaml \
  clusters/nuc/talos/secrets/talos-secrets.yaml

rm clusters/nuc/talos/secrets/talos-secrets.yaml
```

## Decrypt for Regeneration

Decrypt only to a local temporary path:

```bash
SOPS_AGE_KEY='AGE-SECRET-KEY-...' \
  sops -d clusters/nuc/talos/secrets/talos-secrets.sops.yaml > /tmp/talos-secrets.yaml
```

Or use a key file:

```bash
SOPS_AGE_KEY_FILE=/path/to/talos-age-keys.txt \
  sops -d clusters/nuc/talos/secrets/talos-secrets.sops.yaml > /tmp/talos-secrets.yaml
```

Regenerate Talos configs with the locally installed `talosctl v1.13.2` flag:

```bash
talosctl gen config nuc-cluster https://192.168.90.20:6443 \
  --with-secrets /tmp/talos-secrets.yaml \
  --output clusters/nuc/talos/generated
```

Rendered Talos configs, kubeconfigs, talosconfigs, plaintext Talos secrets, and
age private keys must not be committed.
