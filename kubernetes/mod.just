set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

cilium_chart := "oci://quay.io/cilium/charts/cilium"
cilium_version := "1.19.6"
cilium_values := "kubernetes/apps/kube-system/cilium/app/values.yaml"
cilium_app := "kubernetes/apps/kube-system/cilium/app"
kubeconfig := "kubeconfig"

# Render the pinned Cilium chart to standard output without writing generated YAML.
cilium-render:
    @helm template cilium {{cilium_chart}} \
      --version {{cilium_version}} \
      --namespace kube-system \
      --values {{cilium_values}}

# Validate the app-local Cilium source and pinned Helm render.
cilium-validate:
    #!/usr/bin/env bash
    set -euo pipefail

    app_dir='{{cilium_app}}'
    values_file='{{cilium_values}}'
    chart='{{cilium_chart}}'
    version='{{cilium_version}}'
    temp_dir="$(mktemp -d /tmp/homelab-talos-cilium-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for file in \
      "$app_dir/kustomization.yaml" \
      "$app_dir/ocirepository.yaml" \
      "$app_dir/helmrelease.yaml" \
      "$values_file" \
      'kubernetes/apps/kube-system/cilium/ks.yaml'; do
      [[ -f "$file" ]] || {
        echo "Missing required Cilium source: $file" >&2
        exit 1
      }
    done

    [[ "$(yq -r '.spec.ref.tag' "$app_dir/ocirepository.yaml")" == "$version" ]]
    [[ "$(yq -r '.spec.url' "$app_dir/ocirepository.yaml")" == "$chart" ]]
    [[ "$(yq -r '.spec.releaseName' "$app_dir/helmrelease.yaml")" == 'cilium' ]]
    [[ "$(yq -r '.spec.targetNamespace' "$app_dir/helmrelease.yaml")" == 'kube-system' ]]
    [[ "$(yq -r '.spec.storageNamespace' "$app_dir/helmrelease.yaml")" == 'kube-system' ]]
    [[ "$(yq -r '.spec.valuesFrom[0].name' "$app_dir/helmrelease.yaml")" == 'cilium-values' ]]
    [[ "$(yq -r '.spec.valuesFrom[0].valuesKey' "$app_dir/helmrelease.yaml")" == 'values.yaml' ]]

    [[ "$(yq -r '.cluster.name' "$values_file")" == 'nuc-cluster' ]]
    [[ "$(yq -r '.cluster.id' "$values_file")" == '1' ]]
    [[ "$(yq -r '.ipam.mode' "$values_file")" == 'kubernetes' ]]
    [[ "$(yq -r '.kubeProxyReplacement' "$values_file")" == 'true' ]]
    [[ "$(yq -r '.k8sServiceHost' "$values_file")" == 'localhost' ]]
    [[ "$(yq -r '.k8sServicePort' "$values_file")" == '7445' ]]
    [[ "$(yq -r '.cgroup.autoMount.enabled' "$values_file")" == 'false' ]]
    [[ "$(yq -r '.cgroup.hostRoot' "$values_file")" == '/sys/fs/cgroup' ]]
    [[ "$(yq -r '.routingMode' "$values_file")" == 'tunnel' ]]
    [[ "$(yq -r '.tunnelProtocol' "$values_file")" == 'vxlan' ]]
    [[ "$(yq -r '.bpf.masquerade' "$values_file")" == 'false' ]]
    [[ "$(yq -r '.operator.replicas' "$values_file")" == '2' ]]
    [[ "$(yq -r '.hubble.relay.enabled' "$values_file")" == 'true' ]]
    [[ "$(yq -r '.hubble.ui.enabled' "$values_file")" == 'false' ]]
    [[ "$(yq -r '.envoy.enabled' "$values_file")" == 'false' ]]
    [[ "$(yq -r '.gatewayAPI.enabled' "$values_file")" == 'false' ]]
    [[ "$(yq -r '.l2announcements.enabled' "$values_file")" == 'false' ]]
    [[ "$(yq -r '.bgpControlPlane.enabled' "$values_file")" == 'false' ]]
    ! yq -r '.securityContext.capabilities.ciliumAgent[]' "$values_file" | rg -qx 'SYS_MODULE'

    kustomize build "$app_dir" >"$temp_dir/kustomization.yaml"
    [[ "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "cilium-values") | .metadata.labels."reconcile.fluxcd.io/watch"' "$temp_dir/kustomization.yaml")" == 'Enabled' ]]
    [[ -n "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "cilium-values") | .data."values.yaml"' "$temp_dir/kustomization.yaml")" ]]

    helm template cilium "$chart" \
      --version "$version" \
      --namespace kube-system \
      --values "$values_file" >"$temp_dir/rendered.yaml"

    [[ -n "$(yq ea -r 'select(.kind == "DaemonSet" and .metadata.name == "cilium") | .metadata.name' "$temp_dir/rendered.yaml")" ]]
    [[ -n "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "cilium-operator") | .metadata.name' "$temp_dir/rendered.yaml")" ]]
    [[ -n "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "hubble-relay") | .metadata.name' "$temp_dir/rendered.yaml")" ]]
    [[ -z "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "hubble-ui") | .metadata.name' "$temp_dir/rendered.yaml")" ]]
    [[ -z "$(yq ea -r 'select(.kind == "DaemonSet" and .metadata.name == "cilium-envoy") | .metadata.name' "$temp_dir/rendered.yaml")" ]]

    echo "Cilium $version app sources and Helm render passed validation."

# Print read-only live Cilium and Kubernetes status.
cilium-status:
    #!/usr/bin/env bash
    set -u

    kubeconfig='{{kubeconfig}}'
    [[ -f "$kubeconfig" ]] || {
      echo "Missing ignored kubeconfig; run just bootstrap verify." >&2
      exit 1
    }

    status=0
    echo '=== Helm release ==='
    helm status cilium --namespace kube-system --kubeconfig "$kubeconfig" || status=1
    echo '=== Kubernetes nodes ==='
    kubectl --kubeconfig "$kubeconfig" get nodes --output wide || status=1
    echo '=== Cilium workloads ==='
    kubectl --kubeconfig "$kubeconfig" --namespace kube-system get pods \
      --selector app.kubernetes.io/part-of=cilium --output wide || status=1
    echo '=== Cilium status ==='
    cilium status --kubeconfig "$kubeconfig" --namespace kube-system || status=1
    exit "$status"

# Print read-only Talos diagnostics from every cluster node.
cilium-diagnostics:
    #!/usr/bin/env bash
    set -u

    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    status=0
    for node_ip in 192.168.90.10 192.168.90.11 192.168.90.12; do
      echo "=== Talos diagnostics: $node_ip ==="
      diagnostics="$(talosctl get diagnostics \
        --nodes "$node_ip" \
        --endpoints "$nodes_csv" \
        --talosconfig clusterconfig/talosconfig \
        --output json)" || {
        status=1
        continue
      }
      if [[ -n "$diagnostics" ]]; then
        printf '%s\n' "$diagnostics"
        status=1
      else
        echo 'None'
      fi
    done
    exit "$status"

# Verify Talos diagnostics and etcd after Cilium connectivity workloads finish.
cilium-postflight:
    #!/usr/bin/env bash
    set -euo pipefail

    just kube cilium-diagnostics

    kubeconfig='{{kubeconfig}}'
    remaining_test_namespaces="$(kubectl --kubeconfig "$kubeconfig" get namespaces --output json | \
      yq -r '.items[].metadata.name | select(test("^cilium-test"))')"
    [[ -z "$remaining_test_namespaces" ]] || {
      echo "Cilium test namespaces remain: $remaining_test_namespaces" >&2
      exit 1
    }

    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    etcd_status="$(talosctl etcd status \
      --nodes "$nodes_csv" \
      --endpoints "$nodes_csv" \
      --talosconfig clusterconfig/talosconfig)"
    printf '%s\n' "$etcd_status"
    [[ "$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$etcd_status")" == '3' ]]

    alarm_status="$(talosctl etcd alarm list \
      --nodes "$nodes_csv" \
      --endpoints "$nodes_csv" \
      --talosconfig clusterconfig/talosconfig)"
    printf '%s\n' "$alarm_status"
    [[ "$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$alarm_status")" == '0' ]]

    echo 'Cilium postflight passed: test resources removed, no Talos diagnostics, three etcd members, and no etcd alarms.'

# Verify the complete live Phase 5 Cilium acceptance gate.
cilium-verify:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    values_file='{{cilium_values}}'
    expected_names=$'nuc1\nnuc2\nnuc3'
    diagnostic_dir="$(mktemp -d /tmp/homelab-talos-cilium-test.XXXXXX)"
    cleanup() {
      cilium connectivity test \
        --kubeconfig "$kubeconfig" \
        --test-namespace cilium-test \
        --cleanup >/dev/null 2>&1 || true
    }
    trap cleanup EXIT

    [[ -f "$kubeconfig" ]] || {
      echo "Missing ignored kubeconfig; run just bootstrap verify." >&2
      exit 1
    }
    api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify --output jsonpath='{.clusters[0].cluster.server}')"
    [[ "$api_server" == 'https://192.168.90.20:6443' ]]

    release_json="$(helm list --namespace kube-system --kubeconfig "$kubeconfig" --output json)"
    [[ "$(yq -r '.[] | select(.name == "cilium") | .status' - <<<"$release_json")" == 'deployed' ]]
    [[ "$(yq -r '.[] | select(.name == "cilium") | .chart' - <<<"$release_json")" == 'cilium-1.19.6' ]]

    helm get values cilium \
      --namespace kube-system \
      --kubeconfig "$kubeconfig" \
      --output yaml >"$diagnostic_dir/live-values.yaml"
    yq -o=json -I=0 'sort_keys(..)' "$values_file" >"$diagnostic_dir/expected-values.json"
    yq -o=json -I=0 'sort_keys(..)' "$diagnostic_dir/live-values.yaml" >"$diagnostic_dir/normalized-live-values.json"
    cmp -s "$diagnostic_dir/expected-values.json" "$diagnostic_dir/normalized-live-values.json" || {
      echo "Live Cilium Helm values differ from $values_file." >&2
      diff -u "$diagnostic_dir/expected-values.json" "$diagnostic_dir/normalized-live-values.json" || true
      exit 1
    }

    nodes_json="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json)"
    node_names="$(yq -r '.items[].metadata.name' - <<<"$nodes_json" | sort)"
    [[ "$node_names" == "$expected_names" ]]
    node_states="$(yq -r '.items[] | .metadata.name + " " + ([.status.conditions[] | select(.type == "Ready") | .status][0]) + " " + ((.spec.unschedulable // false) | tostring)' - <<<"$nodes_json" | sort)"
    [[ "$node_states" == $'nuc1 True false\nnuc2 True false\nnuc3 True false' ]]
    forbidden_taints="$(yq -r '.items[] | .metadata.name as $name | (.spec.taints // [])[] | select(.effect == "NoSchedule" or .effect == "NoExecute") | $name + " " + .key' - <<<"$nodes_json")"
    [[ -z "$forbidden_taints" ]]

    daemonset_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset cilium --output json)"
    [[ "$(yq -r '[.status.desiredNumberScheduled, .status.numberReady, (.status.numberUnavailable // 0)] | join(" ")' - <<<"$daemonset_json")" == '3 3 0' ]]
    operator_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment cilium-operator --output json)"
    [[ "$(yq -r '[.spec.replicas, .status.availableReplicas] | join(" ")' - <<<"$operator_json")" == '2 2' ]]
    relay_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment hubble-relay --output json)"
    [[ "$(yq -r '[.spec.replicas, .status.availableReplicas] | join(" ")' - <<<"$relay_json")" == '1 1' ]]
    coredns_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment coredns --output json)"
    [[ "$(yq -r '.status.availableReplicas // 0' - <<<"$coredns_json")" -ge 1 ]]

    ! kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset kube-proxy >/dev/null 2>&1
    ! kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment hubble-ui >/dev/null 2>&1
    ! kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset cilium-envoy >/dev/null 2>&1

    cilium status \
      --kubeconfig "$kubeconfig" \
      --namespace kube-system \
      --wait \
      --wait-duration 10m

    cilium_status_json="$(cilium status \
      --kubeconfig "$kubeconfig" \
      --namespace kube-system \
      --output json)"
    [[ "$(yq -r '.pod_state."hubble-relay" | [.Desired, .Ready, .Available, .Unavailable] | join(" ")' - <<<"$cilium_status_json")" == '1 1 1 0' ]]
    [[ "$(yq -r '[.cilium_status[].hubble.state] | unique | join(" ")' - <<<"$cilium_status_json")" == 'Ok' ]]
    [[ "$(yq -r '.errors."hubble-relay"."hubble-relay" | ((.Errors | length) + (.Warnings | length))' - <<<"$cilium_status_json")" == '0' ]]

    cleanup
    echo "Connectivity-test diagnostics, if required, will remain in $diagnostic_dir."
    if ! cilium connectivity test \
      --kubeconfig "$kubeconfig" \
      --namespace kube-system \
      --test-namespace cilium-test \
      --namespace-labels pod-security.kubernetes.io/enforce=privileged \
      --ip-families ipv4 \
      --hubble=false \
      --flow-validation disabled \
      --test '!no-unexpected-packet-drops' \
      --timeout 45m \
      --sysdump-output-filename "$diagnostic_dir/cilium-sysdump-<ts>"; then
      cilium sysdump \
        --kubeconfig "$kubeconfig" \
        --namespace kube-system \
        --output-filename "$diagnostic_dir/cilium-sysdump-<ts>" || true
      exit 1
    fi

    just kube cilium-postflight

    cleanup
    trap - EXIT
    rm -rf -- "$diagnostic_dir"
    echo 'Phase 5 verification passed: Cilium 1.19.6, three Ready nodes, healthy DNS, Hubble, connectivity, Talos, and etcd.'
