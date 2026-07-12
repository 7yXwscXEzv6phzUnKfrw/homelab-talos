set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

# Install the exact tool versions and verify their presence.
tools:
    mise install --locked
    mise exec -- just versions

# Print the tool versions used by this repository.
versions:
    @talosctl version --client --short
    @talhelper --version
    @kubectl version --client
    @helm version --short
    @flux --version
    @cilium version --client
    @kustomize version
    @sops --version
    @age --version
    @yq --version
    @just --version
    @gh --version | head -n 1
    @gitleaks version

# Verify that the loaded private age identity matches this repository.
secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    expected="$(yq -r '.creation_rules[0].age' .sops.yaml)"
    if [[ -n "${SOPS_AGE_KEY_FILE:-}" ]]; then
      actual="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
    elif [[ -n "${SOPS_AGE_KEY:-}" ]]; then
      key_file="$(mktemp "${TMPDIR:-/tmp}/homelab-talos-age.XXXXXX")"
      trap 'rm -f "$key_file"' EXIT
      chmod 600 "$key_file"
      printf '%s\n' "$SOPS_AGE_KEY" > "$key_file"
      actual="$(age-keygen -y "$key_file")"
    else
      echo "Set SOPS_AGE_KEY or SOPS_AGE_KEY_FILE." >&2
      exit 1
    fi
    [[ "$actual" == "$expected" ]] || {
      echo "Loaded age identity does not match $expected." >&2
      exit 1
    }
    echo "Loaded age identity matches $expected."

# Run repository and declarative Talos source validation.
verify: verify-files talos-source-validate secret-scan
    @echo "Repository and Phase 2 Talos source checks passed."

# Verify ignore boundaries and SOPS policy.
verify-files:
    @git check-ignore -q clusterconfig/nuc1.yaml
    @git check-ignore -q talosconfig
    @git check-ignore -q kubeconfig
    @git check-ignore -q support-bundles/example.tar.gz
    @if git check-ignore -q talos/talconfig.yaml; then echo "talos/talconfig.yaml must be trackable" >&2; exit 1; fi
    @if git check-ignore -q talos/talsecret.sops.yaml; then echo "encrypted Talos secrets must be trackable" >&2; exit 1; fi
    @if git check-ignore -q kubernetes/apps/example/secret.sops.yaml; then echo "encrypted Kubernetes secrets must be trackable" >&2; exit 1; fi
    @test "$(yq -r '.creation_rules[0].encrypted_regex' .sops.yaml)" = '^(.*)$'
    @test "$(yq -r '.creation_rules[1].encrypted_regex' .sops.yaml)" = '^(data|stringData)$'
    @test "$(yq -r '[.creation_rules[].age | test("^age1")] | all' .sops.yaml)" = true

# Validate the trackable Talhelper inputs without decrypting cluster identity.
talos-source-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    talhelper validate talconfig talos/talconfig.yaml
    [[ "$(sops filestatus talos/talsecret.sops.yaml | yq -r '.encrypted')" == "true" ]]
    [[ "$(yq -r '.sops.age[0].recipient' talos/talsecret.sops.yaml)" == "$(yq -r '.creation_rules[0].age' .sops.yaml)" ]]
    [[ "$(yq -r '.sops.encrypted_regex' talos/talsecret.sops.yaml)" == '^(.*)$' ]]
    expected_extensions=$'siderolabs/intel-ucode\nsiderolabs/i915\nsiderolabs/iscsi-tools\nsiderolabs/util-linux-tools'
    actual_extensions="$(yq -r '.controlPlane.schematic.customization.systemExtensions.officialExtensions[]' talos/talconfig.yaml)"
    [[ "$actual_extensions" == "$expected_extensions" ]]

# Scan Git history and all currently trackable files without printing secrets.
secret-scan:
    #!/usr/bin/env bash
    set -euo pipefail
    if git ls-files --cached --others --exclude-standard -z \
      | xargs -0 rg -l 'AGE-SECRET-KEY-1[0-9A-Z]{20,}' >/dev/null 2>&1; then
      echo "An age private key exists in a trackable file." >&2
      exit 1
    fi
    gitleaks git --redact --no-banner .
    git diff --no-ext-diff HEAD | gitleaks stdin --redact --no-banner
    untracked="$(git ls-files --others --exclude-standard)"
    if [[ -n "$untracked" ]]; then
      while IFS= read -r file; do printf '\nFILE: %s\n' "$file"; cat "$file"; done <<< "$untracked" \
        | gitleaks stdin --redact --no-banner
    fi

# Decrypt the tracked identity in memory and render ignored machine configs.
talos-generate: talos-source-validate
    #!/usr/bin/env bash
    set -euo pipefail
    just secrets
    rm -rf clusterconfig
    (
      cd talos
      talhelper genconfig \
        --config-file talconfig.yaml \
        --secret-file talsecret.sops.yaml \
        --out-dir ../clusterconfig \
        --no-gitignore
    )
    just talos-validate

# Validate rendered machine configs and the Phase 2 acceptance settings.
talos-validate: talos-source-validate
    #!/usr/bin/env bash
    set -euo pipefail
    expected_files=$'clusterconfig/nuc1.yaml\nclusterconfig/nuc2.yaml\nclusterconfig/nuc3.yaml\nclusterconfig/talosconfig'
    actual_files="$(find clusterconfig -maxdepth 1 -type f | sort)"
    [[ "$actual_files" == "$expected_files" ]] || {
      echo "Render exactly nuc1.yaml, nuc2.yaml, nuc3.yaml, and talosconfig first." >&2
      exit 1
    }

    expected_image='factory.talos.dev/metal-installer-secureboot/a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79:v1.13.6'
    for node in nuc1 nuc2 nuc3; do
      file="clusterconfig/${node}.yaml"
      talosctl validate --config "$file" --mode metal --strict

      [[ "$(yq -r 'select(has("machine")) | .version' "$file")" == 'v1alpha1' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.type' "$file")" == 'controlplane' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.install.disk' "$file")" == '/dev/nvme0n1' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.install.wipe' "$file")" == 'true' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.install.image' "$file")" == "$expected_image" ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.kubelet.image' "$file")" == 'ghcr.io/siderolabs/kubelet:v1.35.6' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.features.kubePrism.enabled' "$file")" == 'true' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.features.kubePrism.port' "$file")" == '7445' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.features.hostDNS.enabled' "$file")" == 'true' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.features.hostDNS.forwardKubeDNSToHost' "$file")" == 'true' ]]
      [[ "$(yq -r 'select(has("machine")) | .cluster.controlPlane.endpoint' "$file")" == 'https://192.168.90.20:6443' ]]
      [[ "$(yq -r 'select(has("machine")) | .cluster.proxy.disabled' "$file")" == 'true' ]]
      [[ "$(yq -r 'select(has("machine")) | .cluster.allowSchedulingOnControlPlanes' "$file")" == 'true' ]]

      [[ "$(yq ea -r 'select(.kind == "HostnameConfig") | .hostname' "$file")" == "$node" ]]
      [[ "$(yq ea -r 'select(.kind == "DHCPv4Config") | .name' "$file")" == 'enp88s0' ]]
      [[ "$(yq ea -r 'select(.kind == "Layer2VIPConfig") | [.name, .link] | join(" ")' "$file")" == '192.168.90.20 enp88s0' ]]
      [[ -z "$(yq ea -r 'select(.kind == "KubeFlannelCNIConfig") | .kind' "$file")" ]]

      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "STATE") | .encryption.provider' "$file")" == 'luks2' ]]
      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "STATE") | .encryption.keys[0].slot' "$file")" == '0' ]]
      [[ "$(yq ea -o=json -I=0 'select(.kind == "VolumeConfig") | select(.name == "STATE") | .encryption.keys[0].tpm.options.pcrs' "$file")" == '[7]' ]]
      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "STATE") | .encryption.keys[0].tpm.checkSecurebootStatusOnEnroll' "$file")" == 'true' ]]

      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "EPHEMERAL") | .provisioning.maxSize' "$file")" == '150GiB' ]]
      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "EPHEMERAL") | .encryption.provider' "$file")" == 'luks2' ]]
      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "EPHEMERAL") | .encryption.keys[0].slot' "$file")" == '0' ]]
      [[ "$(yq ea -o=json -I=0 'select(.kind == "VolumeConfig") | select(.name == "EPHEMERAL") | .encryption.keys[0].tpm.options.pcrs' "$file")" == '[7]' ]]
      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "EPHEMERAL") | .encryption.keys[0].tpm.checkSecurebootStatusOnEnroll' "$file")" == 'true' ]]
      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "EPHEMERAL") | .encryption.keys[0].lockToState' "$file")" == 'true' ]]

      [[ "$(yq ea -r 'select(.kind == "UserVolumeConfig") | select(.name == "longhorn") | .provisioning.diskSelector.match' "$file")" == 'system_disk' ]]
      [[ "$(yq ea -r 'select(.kind == "UserVolumeConfig") | select(.name == "longhorn") | .provisioning.minSize' "$file")" == '700GiB' ]]
      [[ "$(yq ea -r 'select(.kind == "UserVolumeConfig") | select(.name == "longhorn") | .provisioning.grow' "$file")" == 'true' ]]
      [[ "$(yq ea -r 'select(.kind == "UserVolumeConfig") | select(.name == "longhorn") | .filesystem.type' "$file")" == 'xfs' ]]
      [[ "$(yq ea -r 'select(.kind == "UserVolumeConfig") | select(.name == "longhorn") | .encryption' "$file")" == 'null' ]]
    done

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    for node in nuc1 nuc2 nuc3; do
      cp "clusterconfig/${node}.yaml" "$tmpdir/${node}.yaml"
      yq ea -i '(. | select(.kind == "HostnameConfig") | .hostname) = "NODE"' "$tmpdir/${node}.yaml"
    done
    unique_hashes="$(for file in "$tmpdir"/*.yaml; do shasum -a 256 "$file" | awk '{print $1}'; done | sort -u | wc -l | tr -d ' ')"
    [[ "$unique_hashes" == '1' ]] || {
      echo "Rendered node configs differ in more than their hostname documents." >&2
      exit 1
    }
    echo "All Phase 2 rendered Talos configs passed validation."

# Phase 3 will enable per-node application after explicit safety checks.
talos-apply node:
    @echo "Phase 3 prerequisite: talos-apply is intentionally disabled (requested node: {{node}})." >&2
    @exit 1

# Phase 4 will enable initial etcd bootstrap.
talos-bootstrap:
    @echo "Phase 4 prerequisite: Talos bootstrap is intentionally disabled." >&2
    @exit 1

# Phase 5 will enable Cilium bootstrap.
cilium-bootstrap:
    @echo "Phase 5 prerequisite: Cilium bootstrap is intentionally disabled." >&2
    @exit 1

# Phase 6 will enable Flux bootstrap.
flux-bootstrap:
    @echo "Phase 6 prerequisite: Flux bootstrap is intentionally disabled." >&2
    @exit 1
