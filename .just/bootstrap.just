set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

# Verify all Phase 4 prerequisites and refuse if etcd is already initialized.
preflight:
    #!/usr/bin/env bash
    set -euo pipefail

    talosconfig='clusterconfig/talosconfig'
    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    expected_endpoints=$'192.168.90.10\n192.168.90.11\n192.168.90.12'
    actual_endpoints="$(yq -r '.context as $context | .contexts[$context].endpoints[]' "$talosconfig" | sort)"
    [[ "$actual_endpoints" == "$expected_endpoints" ]] || {
      echo "Refusing to bootstrap: talosconfig must contain exactly the three NUC endpoints." >&2
      exit 1
    }

    just talos validate

    for node_spec in 'nuc1:192.168.90.10' 'nuc2:192.168.90.11' 'nuc3:192.168.90.12'; do
      node="${node_spec%%:*}"
      node_ip="${node_spec#*:}"
      common=(--nodes "$node_ip" --endpoints "$node_ip" --talosconfig "$talosconfig" --output yaml)

      talosctl version --nodes "$node_ip" --endpoints "$node_ip" --talosconfig "$talosconfig" >/dev/null

      hostname_state="$(talosctl get hostname "${common[@]}")"
      [[ "$(yq -r '.spec.hostname' - <<<"$hostname_state")" == "$node" ]]

      boot_state="$(talosctl get bootedentries "${common[@]}")"
      [[ "$(yq -r '.spec.bootedEntry' - <<<"$boot_state")" == 'talos-v1.13.6.efi' ]]

      security_state="$(talosctl get securitystate "${common[@]}")"
      [[ "$(yq -r '.spec.secureBoot' - <<<"$security_state")" == 'true' ]]
      [[ "$(yq -r '.spec.bootedWithUKI' - <<<"$security_state")" == 'true' ]]
      [[ "$(yq -r '.spec.moduleSignatureEnforced' - <<<"$security_state")" == 'true' ]]

      disk_state="$(talosctl get disks "${common[@]}")"
      [[ "$(yq ea -r 'select(.spec.dev_path == "/dev/nvme0n1") | .spec.model' - <<<"$disk_state")" == 'Samsung SSD 990 PRO 1TB' ]]
      [[ "$(yq ea -r 'select(.spec.dev_path == "/dev/nvme0n1") | .spec.size' - <<<"$disk_state")" == '1000204886016' ]]
      [[ -z "$(yq ea -r 'select(.spec.transport == "usb") | .spec.dev_path' - <<<"$disk_state")" ]]

      volume_state="$(talosctl get volumestatuses "${common[@]}")"
      [[ "$(yq ea -r 'select(.metadata.id == "STATE") | .spec.phase' - <<<"$volume_state")" == 'ready' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "STATE") | .spec.encryptionProvider' - <<<"$volume_state")" == 'luks2' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "STATE") | .spec.size' - <<<"$volume_state")" == '104857600' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "EPHEMERAL") | .spec.phase' - <<<"$volume_state")" == 'ready' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "EPHEMERAL") | .spec.encryptionProvider' - <<<"$volume_state")" == 'luks2' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "EPHEMERAL") | .spec.size' - <<<"$volume_state")" == '161061273600' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.phase' - <<<"$volume_state")" == 'ready' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.size' - <<<"$volume_state")" == '836832854016' ]]

      time_state="$(talosctl get timestatus "${common[@]}")"
      [[ "$(yq -r '.spec.synced' - <<<"$time_state")" == 'true' ]]

      mount_state="$(talosctl get mountstatuses.block.talos.dev "${common[@]}")"
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.target' - <<<"$mount_state")" == '/var/mnt/longhorn' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.filesystem' - <<<"$mount_state")" == 'xfs' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.detached' - <<<"$mount_state")" == 'false' ]]

      extension_state="$(talosctl get extensions "${common[@]}")"
      extension_names="$(yq ea -r '.spec.metadata.name' - <<<"$extension_state")"
      for extension in intel-ucode i915 iscsi-tools util-linux-tools; do
        rg -qx "$extension" <<<"$extension_names"
      done

      service_state="$(talosctl get services "${common[@]}")"
      for service in apid containerd cri kubelet machined; do
        [[ "$(yq ea -r 'select(.metadata.id == "'"$service"'") | .spec.running' - <<<"$service_state")" == 'true' ]]
        [[ "$(yq ea -r 'select(.metadata.id == "'"$service"'") | .spec.healthy' - <<<"$service_state")" == 'true' ]]
      done

      diagnostics="$(talosctl get diagnostics \
        --nodes "$node_ip" \
        --endpoints "$node_ip" \
        --talosconfig "$talosconfig" \
        --output json)"
      [[ -z "$diagnostics" ]] || {
        echo "Refusing to bootstrap: Talos diagnostics exist on $node." >&2
        exit 1
      }
    done

    existing_members="$(talosctl get etcdmembers \
      --nodes 192.168.90.10 \
      --endpoints 192.168.90.10 \
      --talosconfig "$talosconfig" \
      --output yaml)"
    if [[ -n "$existing_members" ]]; then
      echo 'Refusing to bootstrap: etcd member resources already exist.' >&2
      exit 1
    fi

    echo 'Phase 4 preflight passed on nuc1, nuc2, and nuc3; etcd is not initialized.'

# Bootstrap etcd exactly once on nuc1 after the full guarded preflight.
talos: preflight
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='bootstrap:nuc1:192.168.90.10'
    [[ "${TALOS_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to bootstrap etcd.' >&2
      echo "Set TALOS_BOOTSTRAP_CONFIRM='$expected_confirmation' and rerun after reviewing the preflight." >&2
      exit 1
    }

    echo 'Bootstrapping etcd exactly once on nuc1 (192.168.90.10).'
    talosctl bootstrap \
      --nodes 192.168.90.10 \
      --endpoints 192.168.90.10 \
      --talosconfig clusterconfig/talosconfig

# Print read-only etcd membership, service, discovery, and recent-log status.
status node='all':
    #!/usr/bin/env bash
    set -euo pipefail

    talosconfig='clusterconfig/talosconfig'
    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    requested_node='{{node}}'
    case "$requested_node" in
      all|nuc1|nuc2|nuc3) ;;
      *)
        echo 'Node must be one of: all, nuc1, nuc2, nuc3.' >&2
        exit 1
        ;;
    esac

    echo '=== etcd membership from nuc1 ==='
    talosctl etcd members \
      --nodes 192.168.90.10 \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig"

    for node_spec in 'nuc1:192.168.90.10' 'nuc2:192.168.90.11' 'nuc3:192.168.90.12'; do
      node="${node_spec%%:*}"
      node_ip="${node_spec#*:}"
      [[ "$requested_node" == 'all' || "$requested_node" == "$node" ]] || continue
      echo "=== $node etcd service ==="
      talosctl service etcd \
        --nodes "$node_ip" \
        --endpoints "$nodes_csv" \
        --talosconfig "$talosconfig"

      echo "=== $node cluster discovery ==="
      talosctl get members \
        --nodes "$node_ip" \
        --endpoints "$nodes_csv" \
        --talosconfig "$talosconfig"

      echo "=== $node recent etcd log ==="
      if ! talosctl logs etcd \
        --nodes "$node_ip" \
        --endpoints "$nodes_csv" \
        --talosconfig "$talosconfig" \
        --tail 80; then
        echo "$node etcd log is not available."
      fi
    done

# Retry one failed non-bootstrap etcd join after guarded live-state checks.
retry-join node:
    #!/usr/bin/env bash
    set -euo pipefail

    node='{{node}}'
    case "$node" in
      nuc2) node_ip='192.168.90.11' ;;
      nuc3) node_ip='192.168.90.12' ;;
      *)
        echo 'Join retry is allowed only for nuc2 or nuc3; never nuc1.' >&2
        exit 1
        ;;
    esac

    talosconfig='clusterconfig/talosconfig'
    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'

    member_table="$(talosctl etcd members \
      --nodes 192.168.90.10 \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig")"
    member_names="$(awk 'NR > 1 && NF {print $3}' <<<"$member_table")"
    if rg -qx "$node" <<<"$member_names"; then
      echo "Refusing join retry: $node is already an etcd member." >&2
      exit 1
    fi

    service_status="$(talosctl service etcd \
      --nodes "$node_ip" \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig")"
    etcd_state="$(awk '$1 == "STATE" {print $2}' <<<"$service_status")"
    [[ "$etcd_state" == 'Failed' ]] || {
      echo "Refusing join retry: $node etcd state is $etcd_state, not Failed." >&2
      exit 1
    }

    discovery_state="$(talosctl get members \
      --nodes "$node_ip" \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig")"
    discovery_names="$(awk 'NR > 1 && NF {print $4}' <<<"$discovery_state" | sort)"
    [[ "$discovery_names" == $'nuc1\nnuc2\nnuc3' ]] || {
      echo "Refusing join retry: $node does not discover exactly nuc1, nuc2, and nuc3." >&2
      exit 1
    }

    expected_confirmation="retry-etcd-reboot:${node}:${node_ip}"
    [[ "${TALOS_ETCD_RETRY_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing to reboot $node for the failed etcd join." >&2
      echo "Set TALOS_ETCD_RETRY_CONFIRM='$expected_confirmation' and rerun after reviewing status." >&2
      exit 1
    }

    echo "Rebooting only $node to rerun Talos' normal etcd join lifecycle."
    talosctl reboot \
      --nodes "$node_ip" \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig" \
      --wait=false

# Verify the Phase 4 cluster and refresh the ignored workstation kubeconfig.
verify:
    #!/usr/bin/env bash
    set -euo pipefail

    talosconfig='clusterconfig/talosconfig'
    kubeconfig='kubeconfig'
    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    expected_names=$'nuc1\nnuc2\nnuc3'
    expected_endpoints=$'192.168.90.10\n192.168.90.11\n192.168.90.12'
    actual_endpoints="$(yq -r '.context as $context | .contexts[$context].endpoints[]' "$talosconfig" | sort)"
    [[ "$actual_endpoints" == "$expected_endpoints" ]]

    members=''
    member_count=0
    for attempt in {1..60}; do
      if members="$(talosctl etcd members \
        --nodes 192.168.90.10 \
        --endpoints "$nodes_csv" \
        --talosconfig "$talosconfig" 2>/dev/null)"; then
        member_count="$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$members")"
        [[ "$member_count" == '3' ]] && break
      fi
      sleep 5
    done
    [[ "$member_count" == '3' ]] || {
      echo "Expected three etcd members, found $member_count." >&2
      exit 1
    }
    member_names="$(awk 'NR > 1 && NF {print $3}' <<<"$members" | sort)"
    [[ "$member_names" == "$expected_names" ]]

    etcd_status="$(talosctl etcd status \
      --nodes "$nodes_csv" \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig")"
    printf '%s\n' "$etcd_status"
    status_rows="$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$etcd_status")"
    [[ "$status_rows" == '3' ]]
    member_ids="$(awk 'BEGIN {FS="[[:space:]][[:space:]]+"} NR > 1 {print $2}' <<<"$etcd_status" | sort -u)"
    leader_ids="$(awk 'BEGIN {FS="[[:space:]][[:space:]]+"} NR > 1 {print $5}' <<<"$etcd_status" | sort -u)"
    leader_count="$(awk 'NF {count++} END {print count + 0}' <<<"$leader_ids")"
    [[ "$leader_count" == '1' ]] && rg -qx "$leader_ids" <<<"$member_ids" || {
      echo 'Expected one elected leader ID belonging to the three etcd members.' >&2
      exit 1
    }

    alarm_status="$(talosctl etcd alarm list \
      --nodes "$nodes_csv" \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig")"
    printf '%s\n' "$alarm_status"
    alarm_rows="$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$alarm_status")"
    [[ "$alarm_rows" == '0' ]] || {
      echo "Expected no etcd alarms, found $alarm_rows." >&2
      exit 1
    }

    talosctl kubeconfig "$kubeconfig" \
      --nodes 192.168.90.10 \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig" \
      --merge=false \
      --force >/dev/null
    chmod 600 "$kubeconfig"

    api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify --output jsonpath='{.clusters[0].cluster.server}')"
    [[ "$api_server" == 'https://192.168.90.20:6443' ]]

    nodes_json=''
    node_count=0
    for attempt in {1..60}; do
      if nodes_json="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json 2>/dev/null)"; then
        node_count="$(yq -r '.items | length' - <<<"$nodes_json")"
        [[ "$node_count" == '3' ]] && break
      fi
      sleep 5
    done
    [[ "$node_count" == '3' ]]
    actual_names="$(yq -r '.items[].metadata.name' - <<<"$nodes_json" | sort)"
    [[ "$actual_names" == "$expected_names" ]]
    control_plane_count="$(yq -r '[.items[] | select(.metadata.labels | has("node-role.kubernetes.io/control-plane"))] | length' - <<<"$nodes_json")"
    [[ "$control_plane_count" == '3' ]]
    ready_states="$(yq -r '.items[].status.conditions[] | select(.type == "Ready") | .status' - <<<"$nodes_json" | sort)"
    [[ "$ready_states" == $'False\nFalse\nFalse' ]] || {
      echo 'Expected all Kubernetes nodes to remain NotReady before Cilium.' >&2
      exit 1
    }

    for node_spec in 'nuc1:192.168.90.10' 'nuc2:192.168.90.11' 'nuc3:192.168.90.12'; do
      node="${node_spec%%:*}"
      node_ip="${node_spec#*:}"
      common=(--nodes "$node_ip" --endpoints "$nodes_csv" --talosconfig "$talosconfig" --output yaml)

      hostname_state="$(talosctl get hostname "${common[@]}")"
      [[ "$(yq -r '.spec.hostname' - <<<"$hostname_state")" == "$node" ]]

      time_state="$(talosctl get timestatus "${common[@]}")"
      [[ "$(yq -r '.spec.synced' - <<<"$time_state")" == 'true' ]]

      security_state="$(talosctl get securitystate "${common[@]}")"
      [[ "$(yq -r '.spec.secureBoot' - <<<"$security_state")" == 'true' ]]
      [[ "$(yq -r '.spec.bootedWithUKI' - <<<"$security_state")" == 'true' ]]

      service_state="$(talosctl get services "${common[@]}")"
      for service in apid containerd cri etcd kubelet machined; do
        [[ "$(yq ea -r 'select(.metadata.id == "'"$service"'") | .spec.running' - <<<"$service_state")" == 'true' ]]
        [[ "$(yq ea -r 'select(.metadata.id == "'"$service"'") | .spec.healthy' - <<<"$service_state")" == 'true' ]]
      done

      volume_state="$(talosctl get volumestatuses "${common[@]}")"
      [[ "$(yq ea -r 'select(.metadata.id == "STATE") | [.spec.phase, .spec.encryptionProvider, .spec.size] | join(" ")' - <<<"$volume_state")" == 'ready luks2 104857600' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "EPHEMERAL") | [.spec.phase, .spec.encryptionProvider, .spec.size] | join(" ")' - <<<"$volume_state")" == 'ready luks2 161061273600' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | [.spec.phase, .spec.filesystem, .spec.size] | join(" ")' - <<<"$volume_state")" == 'ready xfs 836832854016' ]]

      mount_state="$(talosctl get mountstatuses.block.talos.dev "${common[@]}")"
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | [.spec.target, .spec.filesystem, .spec.readOnly, .spec.detached] | join(" ")' - <<<"$mount_state")" == '/var/mnt/longhorn xfs false false' ]]

      diagnostics="$(talosctl get diagnostics \
        --nodes "$node_ip" \
        --endpoints "$nodes_csv" \
        --talosconfig "$talosconfig" \
        --output json)"
      [[ -z "$diagnostics" ]] || {
        echo "Talos diagnostics exist on $node." >&2
        exit 1
      }
    done

    echo 'Phase 4 verification passed: three-member etcd, one leader, no alarms, VIP API, and three expected NotReady nodes.'

# Install or reconcile Cilium from the canonical app-local values after guarded preflight.
cilium:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    values_file='kubernetes/apps/kube-system/cilium/app/values.yaml'
    chart='oci://quay.io/cilium/charts/cilium'
    version='1.19.6'
    expected_confirmation='bootstrap:cilium:1.19.6:kube-system'
    expected_names=$'nuc1\nnuc2\nnuc3'

    just kube cilium-validate
    just talos validate

    [[ -f "$kubeconfig" ]] || {
      echo 'Missing ignored kubeconfig; run just bootstrap verify.' >&2
      exit 1
    }
    api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify --output jsonpath='{.clusters[0].cluster.server}')"
    [[ "$api_server" == 'https://192.168.90.20:6443' ]] || {
      echo "Refusing Cilium bootstrap: kubeconfig targets $api_server." >&2
      exit 1
    }

    node_names="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json | yq -r '.items[].metadata.name' | sort)"
    [[ "$node_names" == "$expected_names" ]] || {
      echo 'Refusing Cilium bootstrap: expected exactly nuc1, nuc2, and nuc3.' >&2
      exit 1
    }

    ! kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset kube-proxy >/dev/null 2>&1 || {
      echo 'Refusing Cilium bootstrap: kube-proxy exists.' >&2
      exit 1
    }

    competing_cni="$(kubectl --kubeconfig "$kubeconfig" get daemonsets --all-namespaces --output name | rg '(calico-node|kube-flannel|weave-net|canal|antrea-agent)' || true)"
    [[ -z "$competing_cni" ]] || {
      echo "Refusing Cilium bootstrap: a competing CNI exists: $competing_cni" >&2
      exit 1
    }

    if kubectl --kubeconfig "$kubeconfig" api-resources \
      --api-group helm.toolkit.fluxcd.io \
      --no-headers 2>/dev/null | rg -q '^helmreleases'; then
      flux_cilium="$(kubectl --kubeconfig "$kubeconfig" get helmreleases.helm.toolkit.fluxcd.io \
        --all-namespaces \
        --output custom-columns=NAME:.metadata.name \
        --no-headers 2>/dev/null | rg -x 'cilium' || true)"
      [[ -z "$flux_cilium" ]] || {
        echo 'Refusing bootstrap ownership: Flux already manages Cilium.' >&2
        exit 1
      }
    fi

    release_exists=false
    if helm status cilium --namespace kube-system --kubeconfig "$kubeconfig" >/dev/null 2>&1; then
      release_exists=true
      release_json="$(helm list --namespace kube-system --kubeconfig "$kubeconfig" --output json)"
      release_chart="$(yq -r '.[] | select(.name == "cilium") | .chart' - <<<"$release_json")"
      [[ "$release_chart" == 'cilium-1.19.6' ]] || {
        echo "Refusing Cilium bootstrap: existing release uses $release_chart." >&2
        exit 1
      }

      temp_dir="$(mktemp -d /tmp/homelab-talos-cilium-bootstrap.XXXXXX)"
      trap 'rm -rf -- "$temp_dir"' EXIT
      helm get values cilium \
        --namespace kube-system \
        --kubeconfig "$kubeconfig" \
        --output yaml >"$temp_dir/live-values.yaml"
      yq -o=json -I=0 'sort_keys(..)' "$values_file" >"$temp_dir/expected-values.json"
      yq -o=json -I=0 'sort_keys(..)' "$temp_dir/live-values.yaml" >"$temp_dir/normalized-live-values.json"
      if cmp -s "$temp_dir/expected-values.json" "$temp_dir/normalized-live-values.json"; then
        echo 'Cilium already matches the canonical chart and values; skipping Helm mutation.'
        just kube cilium-verify
        exit 0
      fi
    else
      unmanaged_cilium=''
      for resource in daemonset/cilium deployment/cilium-operator deployment/hubble-relay; do
        existing_resource="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get \
          "$resource" \
          --ignore-not-found \
          --output name)"
        if [[ -n "$existing_resource" ]]; then
          unmanaged_cilium+="${unmanaged_cilium:+ }$existing_resource"
        fi
      done
      [[ -z "$unmanaged_cilium" ]] || {
        echo "Refusing Cilium bootstrap: Cilium resources exist without the expected Helm release: $unmanaged_cilium" >&2
        exit 1
      }
      just bootstrap verify
    fi

    [[ "${CILIUM_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to install or reconcile Cilium.' >&2
      echo "Set CILIUM_BOOTSTRAP_CONFIRM='$expected_confirmation' and rerun after reviewing preflight." >&2
      exit 1
    }

    if [[ "$release_exists" == 'true' ]]; then
      echo 'Reconciling the existing bootstrap Cilium release from canonical values.'
    else
      echo 'Installing the bootstrap Cilium release from canonical values.'
    fi
    helm upgrade --install cilium "$chart" \
      --version "$version" \
      --namespace kube-system \
      --kubeconfig "$kubeconfig" \
      --values "$values_file" \
      --reset-values \
      --cleanup-on-fail \
      --rollback-on-failure \
      --wait=watcher \
      --wait-for-jobs \
      --timeout 10m \
      --history-max 5

    just kube cilium-verify

# Phase 6 will enable Flux bootstrap.
flux:
    @echo "Phase 6 prerequisite: bootstrap flux is intentionally disabled." >&2
    @exit 1
