set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]

# Validate the trackable Talhelper inputs without decrypting cluster identity.
source-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    talhelper validate talconfig talconfig.yaml
    [[ "$(sops filestatus talsecret.sops.yaml | yq -r '.encrypted')" == "true" ]]
    [[ "$(yq -r '.sops.age[0].recipient' talsecret.sops.yaml)" == "$(yq -r '.creation_rules[0].age' ../.sops.yaml)" ]]
    [[ "$(yq -r '.sops.encrypted_regex' talsecret.sops.yaml)" == '^(.*)$' ]]
    expected_extensions=$'siderolabs/intel-ucode\nsiderolabs/i915\nsiderolabs/iscsi-tools\nsiderolabs/util-linux-tools'
    actual_extensions="$(yq -r '.controlPlane.schematic.customization.systemExtensions.officialExtensions[]' talconfig.yaml)"
    [[ "$actual_extensions" == "$expected_extensions" ]]

# Decrypt the tracked identity in memory and render ignored machine configs.
generate: source-validate
    #!/usr/bin/env bash
    set -euo pipefail
    just repo secrets
    rm -rf ../clusterconfig
    talhelper genconfig \
      --config-file talconfig.yaml \
      --secret-file talsecret.sops.yaml \
      --out-dir ../clusterconfig \
      --no-gitignore
    just talos validate

# Validate rendered machine configs and the Phase 2 acceptance settings.
validate: source-validate
    #!/usr/bin/env bash
    set -euo pipefail
    expected_files=$'../clusterconfig/nuc1.yaml\n../clusterconfig/nuc2.yaml\n../clusterconfig/nuc3.yaml\n../clusterconfig/talosconfig'
    actual_files="$(find ../clusterconfig -maxdepth 1 -type f | sort)"
    [[ "$actual_files" == "$expected_files" ]] || {
      echo "Render exactly nuc1.yaml, nuc2.yaml, nuc3.yaml, and talosconfig first." >&2
      exit 1
    }

    expected_image='factory.talos.dev/metal-installer-secureboot/a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79:v1.13.6'
    for node in nuc1 nuc2 nuc3; do
      file="../clusterconfig/${node}.yaml"
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
      cp "../clusterconfig/${node}.yaml" "$tmpdir/${node}.yaml"
      yq ea -i '(. | select(.kind == "HostnameConfig") | .hostname) = "NODE"' "$tmpdir/${node}.yaml"
    done
    unique_hashes="$(for file in "$tmpdir"/*.yaml; do shasum -a 256 "$file" | awk '{print $1}'; done | sort -u | wc -l | tr -d ' ')"
    [[ "$unique_hashes" == '1' ]] || {
      echo "Rendered node configs differ in more than their hostname documents." >&2
      exit 1
    }
    echo "All Phase 2 rendered Talos configs passed validation."

# Phase 3 will enable per-node application after explicit safety checks.
apply node:
    @echo "Phase 3 prerequisite: talos apply is intentionally disabled (requested node: {{node}})." >&2
    @exit 1
