set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

cilium_chart := "oci://quay.io/cilium/charts/cilium"
cilium_version := "1.19.6"
cilium_values := "kubernetes/apps/kube-system/cilium/app/values.yaml"
cilium_app := "kubernetes/apps/kube-system/cilium/app"
kubeconfig := "kubeconfig"
flux_version := "2.9.2"
flux_path := "kubernetes/flux/clusters/prod"
github_owner := "7yXwscXEzv6phzUnKfrw"
github_repository := "homelab-talos"
cert_manager_chart := "oci://quay.io/jetstack/charts/cert-manager"
cert_manager_version := "v1.21.0"
metallb_repository := "https://metallb.github.io/metallb"
metallb_version := "0.16.1"
envoy_gateway_chart := "oci://docker.io/envoyproxy/gateway-helm"
envoy_gateway_version := "v1.8.2"
external_dns_repository := "https://kubernetes-sigs.github.io/external-dns"
external_dns_chart_version := "1.21.1"

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

    kubeconfig='{{kubeconfig}}'
    just kube cilium-diagnostics

    terminating_test_namespaces="$(kubectl --kubeconfig "$kubeconfig" get namespaces --output json | \
      yq -r '.items[] | select(.metadata.name | test("^cilium-test")) | select(.metadata.deletionTimestamp != null) | .metadata.name')"
    while IFS= read -r namespace; do
      [[ -n "$namespace" ]] || continue
      kubectl --kubeconfig "$kubeconfig" wait \
        --for=delete "namespace/$namespace" \
        --timeout=2m
    done <<<"$terminating_test_namespaces"

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

# Fail unless running under bash >= 4; macOS /bin/bash 3.2 does not honor set -e
# for a failed bare [[ ]] mid-recipe, so these acceptance assertions would not gate.
[private]
require-bash:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
      echo 'This repository requires bash >= 4 (for example: brew install bash).' >&2
      echo 'macOS /bin/bash 3.2 skips set -e for [[ ]] tests, so validation would not gate.' >&2
      exit 1
    }

# Verify the complete live Phase 5 Cilium acceptance gate.
cilium-verify: require-bash
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

    cleanup
    just kube cilium-postflight

    trap - EXIT
    rm -rf -- "$diagnostic_dir"
    echo 'Phase 5 verification passed: Cilium 1.19.6, three Ready nodes, healthy DNS, Hubble, connectivity, Talos, and etcd.'

# Validate the complete local Phase 6 source and pinned OCI render without mutating the cluster.
flux-validate:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_flux='{{flux_version}}'
    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    temp_dir="$(mktemp -d /tmp/homelab-talos-flux-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for file in \
      '{{flux_path}}/apps.yaml' \
      'kubernetes/apps/kustomization.yaml' \
      'kubernetes/apps/flux-system/kustomization.yaml' \
      'kubernetes/apps/flux-system/flux-canary/ks.yaml' \
      'kubernetes/apps/flux-system/flux-canary/app/kustomization.yaml' \
      'kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml' \
      'kubernetes/apps/kube-system/kustomization.yaml' \
      'kubernetes/apps/kube-system/cilium/ks.yaml'; do
      [[ -f "$file" ]] || {
        echo "Missing required Flux source: $file" >&2
        exit 1
      }
    done

    [[ "$(flux version --client | awk '{print $2}' | sed 's/^v//')" == "$expected_flux" ]]
    [[ "$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .encrypted_regex' .sops.yaml)" == '^(data|stringData)$' ]]
    [[ "$expected_recipient" == age1* ]]

    canary='kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml'
    [[ "$(sops filestatus "$canary" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$canary" | sort -u)" == "$expected_recipient" ]]
    [[ "$(yq -r '.kind' "$canary")" == 'Secret' ]]
    [[ "$(yq -r '.metadata.name' "$canary")" == 'flux-canary' ]]
    [[ "$(yq -r '.stringData.marker' "$canary")" != 'ready' ]]

    root='{{flux_path}}/apps.yaml'
    [[ "$(yq -r '.metadata.name' "$root")" == 'cluster-apps' ]]
    [[ "$(yq -r '.spec.path' "$root")" == './kubernetes/apps' ]]
    [[ "$(yq -r '.spec.sourceRef.name' "$root")" == 'flux-system' ]]
    [[ "$(yq -r '.spec.deletionPolicy' "$root")" == 'Orphan' ]]

    cilium='kubernetes/apps/kube-system/cilium/ks.yaml'
    [[ "$(yq -r '.metadata.annotations."kustomize.toolkit.fluxcd.io/prune"' "$cilium")" == 'disabled' ]]
    [[ "$(yq -r '.spec.deletionPolicy' "$cilium")" == 'Orphan' ]]
    [[ "$(yq -r '.spec.decryption.provider' "$cilium")" == 'sops' ]]
    [[ "$(yq -r '.spec.decryption.secretRef.name' "$cilium")" == 'sops-age' ]]
    cilium_suspend="$(yq -r '.spec.suspend // false' "$cilium")"
    [[ "$cilium_suspend" == 'true' || "$cilium_suspend" == 'false' ]]
    [[ "$(yq -r '.metadata.annotations."kustomize.toolkit.fluxcd.io/prune"' kubernetes/apps/kube-system/cilium/app/helmrelease.yaml)" == 'disabled' ]]

    canary_ks='kubernetes/apps/flux-system/flux-canary/ks.yaml'
    [[ "$(yq -r '.spec.dependsOn[0].name' "$canary_ks")" == 'cilium' ]]
    [[ "$(yq -r '.spec.decryption.provider' "$canary_ks")" == 'sops' ]]
    [[ "$(yq -r '.spec.decryption.secretRef.name' "$canary_ks")" == 'sops-age' ]]

    kustomize build kubernetes/apps >"$temp_dir/apps.yaml"
    kustomize build kubernetes/apps/kube-system >"$temp_dir/kube-system.yaml"
    kustomize build kubernetes/apps/flux-system >"$temp_dir/flux-system.yaml"
    kustomize build kubernetes/apps/kube-system/cilium/app >"$temp_dir/cilium.yaml"
    kustomize build kubernetes/apps/flux-system/flux-canary/app >"$temp_dir/canary.yaml"

    [[ "$(yq ea -r '[select(.kind == "Kustomization") | .metadata.name] | .[]' "$temp_dir/apps.yaml" | sort -u)" == $'cert-manager\ncert-manager-config\ncilium\necho\nenvoy-gateway\nexternal-dns-internal\nflux-canary\ngatus\ninternal-gateway\nkube-prometheus-stack\nkube-prometheus-stack-config\nlonghorn\nlonghorn-config\nmetallb\nmetallb-config\nwildcard-certificate' ]]
    [[ -z "$(rg '^apiVersion: (apps|extensions)/v1beta|^apiVersion: (networking.k8s.io|policy)/v1beta1' kubernetes --glob '*.yaml' || true)" ]]

    just kube cilium-validate
    echo "Flux $expected_flux source, SOPS canary, dependency graph, and Cilium adoption guards passed validation."

# Check the live cluster and Git publication boundary before GitHub bootstrap.
flux-preflight: flux-validate
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='{{github_owner}}'
    repository='{{github_repository}}'
    expected_origin="https://github.com/${owner}/${repository}.git"

    [[ -f "$kubeconfig" ]] || {
      echo 'Missing ignored kubeconfig; run just bootstrap verify only if it must be refreshed.' >&2
      exit 1
    }
    [[ "$(git branch --show-current)" == 'main' ]] || {
      echo 'Refusing Flux bootstrap: the checked-out branch is not main.' >&2
      exit 1
    }
    [[ -z "$(git status --porcelain)" ]] || {
      echo 'Refusing Flux bootstrap: commit and push the reviewed Phase 6 sources first.' >&2
      exit 1
    }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]] || {
      echo "Refusing Flux bootstrap: origin must be $expected_origin." >&2
      exit 1
    }
    remote_head="$(git ls-remote --exit-code origin refs/heads/main | awk '{print $1}')"
    [[ "$remote_head" == "$(git rev-parse HEAD)" ]] || {
      echo 'Refusing Flux bootstrap: local HEAD and origin/main differ.' >&2
      exit 1
    }
    [[ "$(kubectl --kubeconfig "$kubeconfig" config view --minify --output jsonpath='{.clusters[0].cluster.server}')" == 'https://192.168.90.20:6443' ]]

    just kube cilium-status
    just kube cilium-postflight
    flux check --pre --kubeconfig "$kubeconfig"

    if ! kubectl --kubeconfig "$kubeconfig" --namespace flux-system get deployment source-controller >/dev/null 2>&1; then
      [[ "$(yq -r '.spec.suspend' kubernetes/apps/kube-system/cilium/ks.yaml)" == 'true' ]] || {
        echo 'Refusing first bootstrap: Cilium must begin suspended for staged adoption.' >&2
        exit 1
      }
    fi

    echo 'Flux preflight passed: Git is published, Cilium is healthy, and Kubernetes is compatible.'

# Print the read-only Flux reconciliation and controller state.
flux-status:
    #!/usr/bin/env bash
    set -u

    kubeconfig='{{kubeconfig}}'
    status=0
    [[ -f "$kubeconfig" ]] || {
      echo 'Missing ignored kubeconfig.' >&2
      exit 1
    }

    echo '=== Flux installation ==='
    flux check --kubeconfig "$kubeconfig" || status=1
    echo '=== Git sources ==='
    flux get sources git --all-namespaces --kubeconfig "$kubeconfig" || status=1
    echo '=== OCI sources ==='
    flux get sources oci --all-namespaces --kubeconfig "$kubeconfig" || status=1
    echo '=== Kustomizations ==='
    flux get kustomizations --all-namespaces --show-source --kubeconfig "$kubeconfig" || status=1
    echo '=== Helm releases ==='
    flux get helmreleases --all-namespaces --kubeconfig "$kubeconfig" || status=1
    echo '=== Flux workloads ==='
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system get deployments,pods --output wide || status=1
    exit "$status"

# Verify final Phase 6 ownership, source, SOPS, canary, and Cilium health.
flux-verify: flux-validate require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    expected_url='ssh://git@ssh.github.com:443/{{github_owner}}/{{github_repository}}'
    temp_key="$(mktemp /tmp/homelab-talos-flux-age.XXXXXX)"
    trap 'rm -f -- "$temp_key"' EXIT

    flux check --kubeconfig "$kubeconfig"
    for deployment in source-controller kustomize-controller helm-controller notification-controller; do
      available="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get deployment "$deployment" --output jsonpath='{.status.availableReplicas}')"
      [[ "$available" == '1' ]] || {
        echo "$deployment does not have exactly one available replica." >&2
        exit 1
      }
    done

    source_json="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get gitrepository flux-system --output json)"
    [[ "$(yq -r '.spec.url' - <<<"$source_json")" == "$expected_url" ]]
    [[ "$(yq -r '.spec.ref.branch' - <<<"$source_json")" == 'main' ]]
    [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$source_json")" == 'True' ]]
    remote_head="$(git ls-remote --exit-code origin refs/heads/main | awk '{print $1}')"
    artifact_revision="$(yq -r '.status.artifact.revision' - <<<"$source_json")"
    [[ "$artifact_revision" == *"$remote_head" ]] || {
      echo "Flux artifact $artifact_revision has not reconciled origin/main at $remote_head." >&2
      exit 1
    }

    for name in flux-system cluster-apps cilium flux-canary; do
      kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
        --for=condition=Ready "kustomization/$name" --timeout=10m
      state="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output json)"
      [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$state")" == 'True' ]] || {
        echo "Flux Kustomization $name is not Ready." >&2
        exit 1
      }
      [[ "$(yq -r '.spec.suspend // false' - <<<"$state")" == 'false' ]]
    done

    kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret sops-age \
      --output jsonpath='{.data.age\.agekey}' | base64 --decode >"$temp_key"
    chmod 600 "$temp_key"
    [[ "$(age-keygen -y "$temp_key")" == "$expected_recipient" ]]
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret flux-canary --output jsonpath='{.data.marker}' | base64 --decode)" == 'ready' ]]

    source_secret_keys="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret flux-system --output json | yq -r '.data | keys | .[]' | sort)"
    [[ "$source_secret_keys" == $'identity\nidentity.pub\nknown_hosts' ]] || {
      echo "Unexpected Flux source credential fields: $source_secret_keys" >&2
      exit 1
    }

    cilium_source="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get ocirepository cilium --output json)"
    [[ "$(yq -r '.spec.ref.tag' - <<<"$cilium_source")" == '{{cilium_version}}' ]]
    [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$cilium_source")" == 'True' ]]
    cilium_release="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get helmrelease cilium --output json)"
    [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$cilium_release")" == 'True' ]]
    [[ "$(yq -r '.spec.releaseName' - <<<"$cilium_release")" == 'cilium' ]]

    just kube cilium-postflight
    echo 'Phase 6 verification passed: Flux, SSH source auth, SOPS, canary reconciliation, and Cilium ownership are healthy.'

# Validate the complete local Phase 7 graph, encrypted providers, and pinned chart renders.
foundation-validate:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    cloudflare_secret='kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml'
    pihole_secret='kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml'
    pihole_ca='kubernetes/apps/networking/external-dns/app/pihole-ca.crt'
    temp_dir="$(mktemp -d /tmp/homelab-talos-foundation-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for file in \
      'kubernetes/apps/security/cert-manager/ks.yaml' \
      'kubernetes/apps/security/cert-manager/app/ocirepository.yaml' \
      'kubernetes/apps/security/cert-manager/app/helmrelease.yaml' \
      'kubernetes/apps/security/cert-manager/app/values.yaml' \
      'kubernetes/apps/security/cert-manager/config/clusterissuers.yaml' \
      'kubernetes/apps/security/cert-manager/config/staging-certificate.yaml' \
      'kubernetes/apps/security/cert-manager/certificate/certificate.yaml' \
      'kubernetes/apps/networking/metallb/ks.yaml' \
      'kubernetes/apps/networking/metallb/app/helmrelease.yaml' \
      'kubernetes/apps/networking/metallb/app/values.yaml' \
      'kubernetes/apps/networking/metallb/config/address-pool.yaml' \
      'kubernetes/apps/networking/envoy-gateway/ks.yaml' \
      'kubernetes/apps/networking/envoy-gateway/app/ocirepository.yaml' \
      'kubernetes/apps/networking/envoy-gateway/app/helmrelease.yaml' \
      'kubernetes/apps/networking/envoy-gateway/app/values.yaml' \
      'kubernetes/apps/networking/internal-gateway/ks.yaml' \
      'kubernetes/apps/networking/internal-gateway/app/envoyproxy.yaml' \
      'kubernetes/apps/networking/internal-gateway/app/gateway.yaml' \
      'kubernetes/apps/networking/external-dns/ks.yaml' \
      'kubernetes/apps/networking/external-dns/app/helmrelease.yaml' \
      'kubernetes/apps/networking/external-dns/app/kustomization.yaml' \
      "$pihole_ca" \
      'kubernetes/apps/networking/external-dns/app/values.yaml' \
      'kubernetes/apps/testing/echo/ks.yaml' \
      'kubernetes/apps/testing/echo/app/deployment.yaml' \
      'kubernetes/apps/testing/echo/app/httproute.yaml' \
      "$cloudflare_secret" \
      "$pihole_secret"; do
      [[ -f "$file" ]] || {
        echo "Missing required Phase 7 source: $file" >&2
        echo 'Run just repo phase7-secrets if a provider Secret is missing.' >&2
        exit 1
      }
    done

    for secret in "$cloudflare_secret" "$pihole_secret"; do
      [[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
      [[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
      [[ "$(yq -r '.kind' "$secret")" == 'Secret' ]]
    done
    [[ "$(yq -r '.metadata.name' "$cloudflare_secret")" == 'cloudflare-api-token' ]]
    [[ "$(yq -r '.metadata.namespace' "$cloudflare_secret")" == 'cert-manager' ]]
    [[ "$(yq -r '.metadata.name' "$pihole_secret")" == 'pihole-password' ]]
    [[ "$(yq -r '.metadata.namespace' "$pihole_secret")" == 'external-dns' ]]
    ! rg -q 'PRIVATE KEY' "$pihole_ca"
    openssl verify -CAfile "$pihole_ca" "$pihole_ca" >/dev/null
    openssl x509 -in "$pihole_ca" -noout -checkend 2592000 >/dev/null

    phase7_sources=(
      kubernetes/apps/security/cert-manager/ks.yaml
      kubernetes/apps/networking/metallb/ks.yaml
      kubernetes/apps/networking/envoy-gateway/ks.yaml
      kubernetes/apps/networking/internal-gateway/ks.yaml
      kubernetes/apps/networking/external-dns/ks.yaml
      kubernetes/apps/testing/echo/ks.yaml
    )
    suspend_states="$(yq ea -r '[select(.kind == "Kustomization") | (.spec.suspend // false)] | .[]' "${phase7_sources[@]}" | sort -u)"
    [[ "$suspend_states" == 'true' || "$suspend_states" == 'false' ]] || {
      echo 'Every Phase 7 Kustomization must be staged together: all suspended or all active.' >&2
      exit 1
    }

    [[ "$(yq -r '.spec.ref.tag' kubernetes/apps/security/cert-manager/app/ocirepository.yaml)" == '{{cert_manager_version}}' ]]
    [[ "$(yq -r '.spec.url' kubernetes/apps/security/cert-manager/app/ocirepository.yaml)" == '{{cert_manager_chart}}' ]]
    [[ "$(yq -r '.spec.chart.spec.version' kubernetes/apps/networking/metallb/app/helmrelease.yaml)" == '{{metallb_version}}' ]]
    [[ "$(yq -r '.spec.ref.tag' kubernetes/apps/networking/envoy-gateway/app/ocirepository.yaml)" == '{{envoy_gateway_version}}' ]]
    [[ "$(yq -r '.spec.url' kubernetes/apps/networking/envoy-gateway/app/ocirepository.yaml)" == '{{envoy_gateway_chart}}' ]]
    [[ "$(yq -r '.spec.chart.spec.version' kubernetes/apps/networking/external-dns/app/helmrelease.yaml)" == '{{external_dns_chart_version}}' ]]

    cert_ks='kubernetes/apps/security/cert-manager/ks.yaml'
    [[ "$(yq ea -r 'select(.metadata.name == "cert-manager") | .spec.dependsOn[].name' "$cert_ks")" == 'cilium' ]]
    [[ "$(yq ea -r 'select(.metadata.name == "cert-manager-config") | .spec.dependsOn[].name' "$cert_ks")" == 'cert-manager' ]]
    [[ "$(yq ea -r 'select(.metadata.name == "wildcard-certificate") | .spec.dependsOn[].name' "$cert_ks")" == 'cert-manager-config' ]]
    [[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/networking/metallb/ks.yaml | head -n 1)" == 'cilium' ]]
    [[ "$(yq ea -r 'select(.metadata.name == "metallb-config") | .spec.dependsOn[].name' kubernetes/apps/networking/metallb/ks.yaml)" == 'metallb' ]]
    [[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/networking/envoy-gateway/ks.yaml)" == 'cilium' ]]
    [[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/networking/internal-gateway/ks.yaml | sort)" == $'envoy-gateway\nmetallb-config\nwildcard-certificate' ]]
    [[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/networking/external-dns/ks.yaml)" == 'internal-gateway' ]]
    [[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/testing/echo/ks.yaml)" == 'external-dns-internal' ]]

    metallb_values='kubernetes/apps/networking/metallb/app/values.yaml'
    [[ "$(yq -r '.frrk8s.enabled' "$metallb_values")" == 'false' ]]
    [[ "$(yq -r '.speaker.frr.enabled' "$metallb_values")" == 'false' ]]
    pool='kubernetes/apps/networking/metallb/config/address-pool.yaml'
    [[ "$(yq ea -r 'select(.kind == "IPAddressPool") | .spec.addresses[0]' "$pool")" == '192.168.90.30-192.168.90.39' ]]
    [[ "$(yq ea -r 'select(.kind == "IPAddressPool") | .spec.autoAssign' "$pool")" == 'false' ]]

    gateway='kubernetes/apps/networking/internal-gateway/app/gateway.yaml'
    [[ "$(yq ea -r 'select(.kind == "Gateway") | .spec.listeners[0].hostname' "$gateway")" == '*.lab.supermorphic.com' ]]
    [[ "$(yq ea -r 'select(.kind == "Gateway") | .spec.listeners[0].port' "$gateway")" == '443' ]]
    [[ "$(yq ea -r 'select(.kind == "Gateway") | .spec.listeners[0].tls.certificateRefs[0].name' "$gateway")" == 'wildcard-lab-supermorphic-com-tls' ]]
    proxy='kubernetes/apps/networking/internal-gateway/app/envoyproxy.yaml'
    [[ "$(yq -r '.spec.provider.kubernetes.envoyDeployment.replicas' "$proxy")" == '2' ]]
    [[ "$(yq -r '.spec.provider.kubernetes.envoyService.annotations."metallb.io/loadBalancerIPs"' "$proxy")" == '192.168.90.30' ]]
    [[ "$(yq -r '.spec.provider.kubernetes.envoyService.externalTrafficPolicy' "$proxy")" == 'Local' ]]

    dns_values='kubernetes/apps/networking/external-dns/app/values.yaml'
    [[ "$(yq -r '.provider.name' "$dns_values")" == 'pihole' ]]
    [[ "$(yq -r '.registry' "$dns_values")" == 'noop' ]]
    [[ "$(yq -r '.policy' "$dns_values")" == 'upsert-only' ]]
    [[ "$(yq -r '.sources | join(" ")' "$dns_values")" == 'gateway-httproute' ]]
    [[ "$(yq -r '.domainFilters | join(" ")' "$dns_values")" == 'lab.supermorphic.com' ]]
    [[ "$(yq -r '.annotationFilter' "$dns_values")" == 'external-dns.k8s.io/audience=internal' ]]
    [[ "$(yq -r '.gatewayNamespace' "$dns_values")" == 'networking' ]]
    [[ "$(yq -r '.extraArgs."gateway-name"' "$dns_values")" == 'internal' ]]
    [[ "$(yq -r '.extraArgs."pihole-api-version"' "$dns_values")" == '6' ]]
    [[ "$(yq -r '.extraArgs."pihole-server"' "$dns_values")" == 'https://pi.hole' ]]
    [[ "$(yq -r '.extraArgs."pihole-tls-skip-verify" // ""' "$dns_values")" == '' ]]
    [[ "$(yq -r '.env[] | select(.name == "SSL_CERT_FILE") | .value' "$dns_values")" == '/etc/ssl/pihole/tls_ca.crt' ]]
    [[ "$(yq -r '.extraVolumes[] | select(.name == "pihole-ca") | .configMap.name' "$dns_values")" == 'pihole-ca' ]]
    [[ "$(yq -r '.extraVolumeMounts[] | select(.name == "pihole-ca") | [.mountPath, .readOnly] | join(" ")' "$dns_values")" == '/etc/ssl/pihole true' ]]
    [[ "$(yq -r '.configMapGenerator[] | select(.name == "pihole-ca") | [.namespace, .files[]] | join(" ")' kubernetes/apps/networking/external-dns/app/kustomization.yaml)" == 'external-dns tls_ca.crt=pihole-ca.crt' ]]

    for directory in \
      kubernetes/apps \
      kubernetes/apps/security/cert-manager/app \
      kubernetes/apps/security/cert-manager/config \
      kubernetes/apps/security/cert-manager/certificate \
      kubernetes/apps/networking/metallb/app \
      kubernetes/apps/networking/metallb/config \
      kubernetes/apps/networking/envoy-gateway/app \
      kubernetes/apps/networking/internal-gateway/app \
      kubernetes/apps/networking/external-dns/app \
      kubernetes/apps/testing/echo/app; do
      kustomize build "$directory" >"$temp_dir/$(tr '/' '-' <<<"$directory").yaml"
    done

    printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repositories.yaml"
    export HELM_REPOSITORY_CONFIG="$temp_dir/repositories.yaml"
    export HELM_REPOSITORY_CACHE="$temp_dir/repository-cache"
    helm template cert-manager '{{cert_manager_chart}}' \
      --version '{{cert_manager_version}}' \
      --namespace cert-manager \
      --values kubernetes/apps/security/cert-manager/app/values.yaml >"$temp_dir/cert-manager.yaml"
    helm template metallb metallb \
      --repo '{{metallb_repository}}' \
      --version '{{metallb_version}}' \
      --namespace metallb-system \
      --values "$metallb_values" >"$temp_dir/metallb.yaml"
    helm template envoy-gateway '{{envoy_gateway_chart}}' \
      --version '{{envoy_gateway_version}}' \
      --namespace envoy-gateway-system \
      --include-crds \
      --values kubernetes/apps/networking/envoy-gateway/app/values.yaml >"$temp_dir/envoy-gateway.yaml"
    helm template external-dns-internal external-dns \
      --repo '{{external_dns_repository}}' \
      --version '{{external_dns_chart_version}}' \
      --namespace external-dns \
      --values "$dns_values" >"$temp_dir/external-dns.yaml"

    rg -q '^kind: Deployment$' "$temp_dir/cert-manager.yaml"
    rg -q '^  name: cert-manager$' "$temp_dir/cert-manager.yaml"
    rg -q '^kind: DaemonSet$' "$temp_dir/metallb.yaml"
    rg -q '^  name: metallb-speaker$' "$temp_dir/metallb.yaml"
    ! rg -q '^  name: .*frr' "$temp_dir/metallb.yaml"
    rg -q '^  name: envoy-gateway$' "$temp_dir/envoy-gateway.yaml"
    rg -q '^  name: gatewayclasses.gateway.networking.k8s.io$' "$temp_dir/envoy-gateway.yaml"
    rg -q '^  name: gateways.gateway.networking.k8s.io$' "$temp_dir/envoy-gateway.yaml"
    rg -q '^  name: httproutes.gateway.networking.k8s.io$' "$temp_dir/envoy-gateway.yaml"
    rg -q '^  name: envoyproxies.gateway.envoyproxy.io$' "$temp_dir/envoy-gateway.yaml"
    rg -q -- '--source=gateway-httproute' "$temp_dir/external-dns.yaml"
    rg -q -- '--provider=pihole' "$temp_dir/external-dns.yaml"
    rg -q -- '--annotation-filter=external-dns.k8s.io/audience=internal' "$temp_dir/external-dns.yaml"
    rg -q -- '--gateway-name=internal' "$temp_dir/external-dns.yaml"
    rg -q -- '--pihole-server=https://pi.hole' "$temp_dir/external-dns.yaml"
    ! rg -q -- '--pihole-tls-skip-verify' "$temp_dir/external-dns.yaml"
    [[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "external-dns-internal") | .spec.template.spec.containers[] | select(.name == "external-dns") | .env[] | select(.name == "SSL_CERT_FILE") | .value' "$temp_dir/external-dns.yaml")" == '/etc/ssl/pihole/tls_ca.crt' ]]
    [[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "external-dns-internal") | .spec.template.spec.volumes[] | select(.name == "pihole-ca") | .configMap.name' "$temp_dir/external-dns.yaml")" == 'pihole-ca' ]]
    [[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "external-dns-internal") | .spec.template.spec.containers[] | select(.name == "external-dns") | .volumeMounts[] | select(.name == "pihole-ca") | [.mountPath, .readOnly] | join(" ")' "$temp_dir/external-dns.yaml")" == '/etc/ssl/pihole true' ]]

    echo 'Phase 7 source, SOPS provider Secrets, dependency graph, policy, and pinned Helm renders passed validation.'

# Print the read-only Phase 7 controller, certificate, address, Gateway, DNS, and echo state.
foundation-status:
    #!/usr/bin/env bash
    set -u

    kubeconfig='{{kubeconfig}}'
    status=0
    [[ -f "$kubeconfig" ]] || {
      echo 'Missing ignored kubeconfig.' >&2
      exit 1
    }

    echo '=== Phase 7 Flux Kustomizations ==='
    flux get kustomizations --namespace flux-system --show-source --kubeconfig "$kubeconfig" | rg 'NAME|cert-manager|wildcard-certificate|metallb|envoy-gateway|internal-gateway|external-dns-internal|echo' || status=1
    echo '=== Phase 7 Helm sources and releases ==='
    flux get sources oci --all-namespaces --kubeconfig "$kubeconfig" || status=1
    flux get sources helm --all-namespaces --kubeconfig "$kubeconfig" || status=1
    flux get helmreleases --all-namespaces --kubeconfig "$kubeconfig" || status=1
    echo '=== Certificates ==='
    kubectl --kubeconfig "$kubeconfig" get clusterissuers,certificates --all-namespaces || status=1
    echo '=== MetalLB ==='
    kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get pods,ipaddresspools,l2advertisements --output wide || status=1
    echo '=== Internal Gateway ==='
    kubectl --kubeconfig "$kubeconfig" --namespace networking get gateways,envoyproxies,services,pods --output wide || status=1
    echo '=== ExternalDNS and echo ==='
    kubectl --kubeconfig "$kubeconfig" --namespace external-dns get deployments,pods --output wide || status=1
    kubectl --kubeconfig "$kubeconfig" --namespace testing get deployments,pods,services,httproutes --output wide || status=1
    echo '=== Pi-hole resolution ==='
    dig +short @192.168.90.2 echo.lab.supermorphic.com A || status=1
    exit "$status"

# Verify the complete live Phase 7 internal foundation acceptance gate.
foundation-verify: foundation-validate require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    phase7_names=(cert-manager cert-manager-config wildcard-certificate metallb metallb-config envoy-gateway internal-gateway external-dns-internal echo)
    [[ -f "$kubeconfig" ]] || {
      echo 'Missing ignored kubeconfig.' >&2
      exit 1
    }

    just kube flux-verify
    for name in "${phase7_names[@]}"; do
      kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
        --for=condition=Ready "kustomization/$name" --timeout=15m
      state="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output json)"
      [[ "$(yq -r '.spec.suspend // false' - <<<"$state")" == 'false' ]]
      [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$state")" == 'True' ]]
    done

    for deployment in cert-manager cert-manager-webhook cert-manager-cainjector; do
      kubectl --kubeconfig "$kubeconfig" --namespace cert-manager rollout status "deployment/$deployment" --timeout=10m
      replicas="$(kubectl --kubeconfig "$kubeconfig" --namespace cert-manager get deployment "$deployment" --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
      [[ "$replicas" == '2 2' ]]
    done
    for issuer in letsencrypt-staging letsencrypt-production; do
      kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready "clusterissuer/$issuer" --timeout=10m
    done
    for certificate in wildcard-lab-supermorphic-com-staging wildcard-lab-supermorphic-com; do
      kubectl --kubeconfig "$kubeconfig" --namespace networking wait --for=condition=Ready "certificate/$certificate" --timeout=15m
    done

    controller="$(kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get deployment metallb-controller --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
    [[ "$controller" == '1 1' ]]
    speaker="$(kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get daemonset metallb-speaker --output json | yq -r '[.status.desiredNumberScheduled, .status.numberReady, (.status.numberUnavailable // 0)] | join(" ")')"
    [[ "$speaker" == '3 3 0' ]]
    pool="$(kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get ipaddresspool internal --output json)"
    [[ "$(yq -r '.spec.addresses | join(" ")' - <<<"$pool")" == '192.168.90.30-192.168.90.39' ]]
    [[ "$(yq -r '.spec.autoAssign' - <<<"$pool")" == 'false' ]]
    ! kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get daemonset frr-k8s-daemon >/dev/null 2>&1

    gateway_class="$(kubectl --kubeconfig "$kubeconfig" get gatewayclass internal --output json)"
    [[ "$(yq -r '[.status.conditions[] | select(.type == "Accepted") | .status][0]' - <<<"$gateway_class")" == 'True' ]]
    gateway="$(kubectl --kubeconfig "$kubeconfig" --namespace networking get gateway internal --output json)"
    [[ "$(yq -r '[.status.conditions[] | select(.type == "Programmed") | .status][0]' - <<<"$gateway")" == 'True' ]]
    [[ "$(yq -r '.status.addresses[].value' - <<<"$gateway" | sort -u)" == '192.168.90.30' ]]
    [[ "$(yq -r '.status.listeners[] | select(.name == "https") | [.conditions[] | select(.type == "Accepted") | .status][0]' - <<<"$gateway")" == 'True' ]]

    envoy_services="$(kubectl --kubeconfig "$kubeconfig" --namespace envoy-gateway-system get services --output json)"
    envoy_service="$(yq -r '.items[] | select(.spec.type == "LoadBalancer" and (.status.loadBalancer.ingress[]?.ip == "192.168.90.30")) | .metadata.name' - <<<"$envoy_services")"
    [[ -n "$envoy_service" && "$(wc -l <<<"$envoy_service" | tr -d ' ')" == '1' ]]
    envoy_deployments="$(kubectl --kubeconfig "$kubeconfig" --namespace envoy-gateway-system get deployments --output json)"
    envoy_ready="$(yq -r '.items[] | select(.metadata.labels."gateway.envoyproxy.io/owning-gateway-name" == "internal") | [.spec.replicas, (.status.availableReplicas // 0)] | join(" ")' - <<<"$envoy_deployments")"
    [[ "$envoy_ready" == '2 2' ]]

    kubectl --kubeconfig "$kubeconfig" --namespace external-dns rollout status deployment/external-dns-internal --timeout=10m
    dns_deployment="$(kubectl --kubeconfig "$kubeconfig" --namespace external-dns get deployment external-dns-internal --output json)"
    dns_args="$(yq -r '.spec.template.spec.containers[0].args[]' - <<<"$dns_deployment")"
    for argument in \
      '--source=gateway-httproute' \
      '--provider=pihole' \
      '--registry=noop' \
      '--policy=upsert-only' \
      '--domain-filter=lab.supermorphic.com' \
      '--annotation-filter=external-dns.k8s.io/audience=internal' \
      '--gateway-name=internal' \
      '--pihole-api-version=6' \
      '--pihole-server=https://pi.hole'; do
      rg -Fx -- "$argument" <<<"$dns_args"
    done
    ! rg -Fx -- '--pihole-tls-skip-verify' <<<"$dns_args"
    [[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "external-dns") | .env[] | select(.name == "SSL_CERT_FILE") | .value' - <<<"$dns_deployment")" == '/etc/ssl/pihole/tls_ca.crt' ]]
    [[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "pihole-ca") | .configMap.name' - <<<"$dns_deployment")" == 'pihole-ca' ]]
    [[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "external-dns") | .volumeMounts[] | select(.name == "pihole-ca") | [.mountPath, .readOnly] | join(" ")' - <<<"$dns_deployment")" == '/etc/ssl/pihole true' ]]
    live_pihole_ca="$(kubectl --kubeconfig "$kubeconfig" --namespace external-dns get configmap pihole-ca --output jsonpath='{.data.tls_ca\.crt}')"
    [[ "$live_pihole_ca" == "$(<kubernetes/apps/networking/external-dns/app/pihole-ca.crt)" ]]

    kubectl --kubeconfig "$kubeconfig" --namespace testing rollout status deployment/echo --timeout=10m
    echo_replicas="$(kubectl --kubeconfig "$kubeconfig" --namespace testing get deployment echo --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
    [[ "$echo_replicas" == '2 2' ]]
    route="$(kubectl --kubeconfig "$kubeconfig" --namespace testing get httproute echo --output json)"
    [[ "$(yq -r '[.status.parents[].conditions[] | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]
    [[ "$(yq -r '[.status.parents[].conditions[] | select(.type == "ResolvedRefs") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]

    dns_answer=''
    for attempt in {1..30}; do
      dns_answer="$(dig +short @192.168.90.2 echo.lab.supermorphic.com A | sort -u)"
      [[ "$dns_answer" == '192.168.90.30' ]] && break
      sleep 10
    done
    [[ "$dns_answer" == '192.168.90.30' ]] || {
      echo "Pi-hole returned '$dns_answer' instead of 192.168.90.30." >&2
      exit 1
    }
    response="$(curl --silent --show-error --fail --max-time 15 \
      --resolve echo.lab.supermorphic.com:443:192.168.90.30 \
      https://echo.lab.supermorphic.com/)"
    [[ -n "$response" ]]

    just kube cilium-postflight
    echo 'Phase 7 verification passed: certificates, MetalLB, Envoy Gateway, Pi-hole DNS, trusted HTTPS, echo, Talos, and etcd are healthy.'

# Restart the flux-system controllers and prove reconciliation resumes.
flux-restart: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    expected_confirmation='restart:flux-system:controllers'
    [[ -f "$kubeconfig" ]] || {
      echo 'Missing ignored kubeconfig.' >&2
      exit 1
    }

    flux check --kubeconfig "$kubeconfig"

    [[ "${FLUX_RESTART_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to restart the Flux controllers.' >&2
      echo "Set FLUX_RESTART_CONFIRM='$expected_confirmation' and rerun." >&2
      exit 1
    }

    controllers="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get deployments \
      --selector app.kubernetes.io/part-of=flux --output name)"
    [[ -n "$controllers" ]] || {
      echo 'Refusing restart: no Flux controller deployments found.' >&2
      exit 1
    }
    echo 'Restarting Flux controllers:'
    printf '  %s\n' $controllers
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system rollout restart $controllers
    while IFS= read -r deployment; do
      kubectl --kubeconfig "$kubeconfig" --namespace flux-system rollout status "$deployment" --timeout=5m
    done <<<"$controllers"

    flux check --kubeconfig "$kubeconfig"
    flux reconcile kustomization cluster-apps \
      --namespace flux-system \
      --with-source \
      --kubeconfig "$kubeconfig" \
      --timeout 10m

    just kube flux-verify
    echo 'Flux controllers restarted; controllers are healthy and reconciliation resumed.'

# Delete only the permanent canary and prove Flux recreates it from encrypted Git source.
flux-canary-test: flux-verify
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    expected_confirmation='recreate:flux-system:flux-canary'
    [[ "${FLUX_CANARY_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to delete the Flux reconciliation canary.' >&2
      echo "Set FLUX_CANARY_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    canary_json="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret flux-canary --output json)"
    [[ "$(yq -r '.metadata.labels."app.kubernetes.io/component"' - <<<"$canary_json")" == 'reconciliation-canary' ]] || {
      echo 'Refusing canary test: flux-system/flux-canary does not carry the required safety label.' >&2
      exit 1
    }
    old_uid="$(yq -r '.metadata.uid' - <<<"$canary_json")"
    [[ -n "$old_uid" ]]
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system delete secret flux-canary \
      --wait=true
    flux reconcile kustomization flux-canary \
      --namespace flux-system \
      --with-source \
      --kubeconfig "$kubeconfig" \
      --timeout 5m
    new_uid="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret flux-canary --output jsonpath='{.metadata.uid}')"
    [[ -n "$new_uid" && "$new_uid" != "$old_uid" ]]
    just kube flux-verify
    echo 'Flux canary recreation passed with a new Secret UID.'

# Validate the Phase 9 storage source: files, encrypted CIFS Secret, dependency
# graph, staged-suspend uniformity, key values, wiring, and the pinned Longhorn render.
storage-validate: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/storage/longhorn'
    ks="$base/ks.yaml"
    secret="$base/config/nas-credentials.sops.yaml"
    values="$base/app/values.yaml"
    hr="$base/app/helmrelease.yaml"
    repo="$base/app/helmrepository.yaml"
    jobs="$base/config/recurring-jobs.yaml"
    backuptarget="$base/config/backup-target.yaml"
    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    temp_dir="$(mktemp -d /tmp/homelab-talos-storage-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for f in "$ks" "$secret" "$values" "$hr" "$repo" "$jobs" "$backuptarget" \
      "$base/app/namespace.yaml" "$base/app/kustomization.yaml" \
      "$base/config/kustomization.yaml" kubernetes/apps/storage/kustomization.yaml; do
      [[ -f "$f" ]] || {
        echo "Missing Phase 9 storage source: $f" >&2
        echo 'Run just repo storage-secrets if the CIFS Secret is missing.' >&2
        exit 1
      }
    done

    rg -qx '  - ./storage' kubernetes/apps/kustomization.yaml || {
      echo 'Refusing: ./storage is not wired into kubernetes/apps/kustomization.yaml.' >&2
      exit 1
    }

    [[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
    [[ "$(yq -r '.kind' "$secret")" == 'Secret' ]]
    [[ "$(yq -r '.metadata.name' "$secret")" == 'nas-credentials' ]]
    [[ "$(yq -r '.metadata.namespace' "$secret")" == 'longhorn-system' ]]

    suspend_states="$(yq ea -r '[select(.kind == "Kustomization") | (.spec.suspend // false)] | .[]' "$ks" | sort -u)"
    [[ "$suspend_states" == 'true' || "$suspend_states" == 'false' ]] || {
      echo 'Both storage Kustomizations must be staged together: all suspended or all active.' >&2
      exit 1
    }

    [[ "$(yq ea -r 'select(.metadata.name == "longhorn") | .spec.dependsOn[].name' "$ks")" == 'cilium' ]]
    [[ "$(yq ea -r 'select(.metadata.name == "longhorn-config") | .spec.dependsOn[].name' "$ks")" == 'longhorn' ]]

    [[ "$(yq -r '.spec.chart.spec.version' "$hr")" == '1.12.0' ]]
    [[ "$(yq -r '.spec.url' "$repo")" == 'https://charts.longhorn.io' ]]
    [[ "$(yq -r '.defaultSettings.defaultDataPath' "$values")" == '/var/mnt/longhorn' ]]
    [[ "$(yq -r '.defaultSettings.replicaSoftAntiAffinity' "$values")" == 'false' ]]
    [[ "$(yq -r '.persistence.defaultClassReplicaCount' "$values")" == '2' ]]
    [[ "$(yq -r '.kind' "$backuptarget")" == 'BackupTarget' ]]
    [[ "$(yq -r '.metadata.name' "$backuptarget")" == 'default' ]]
    [[ "$(yq -r '.spec.backupTargetURL' "$backuptarget")" == 'cifs://192.168.0.3/Longhorn' ]]
    [[ "$(yq -r '.spec.credentialSecret' "$backuptarget")" == 'nas-credentials' ]]
    [[ "$(yq ea -r '[select(.kind == "RecurringJob") | .spec.task] | .[]' "$jobs" | sort | tr '\n' ' ')" == 'backup snapshot ' ]]

    kustomize build "$base/app" >/dev/null
    kustomize build "$base/config" >/dev/null

    printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
    HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
      helm template longhorn longhorn --repo https://charts.longhorn.io --version 1.12.0 --namespace longhorn-system --values "$values" >"$temp_dir/longhorn.yaml"
    rg -q '^  name: longhorn-manager$' "$temp_dir/longhorn.yaml"

    echo 'Phase 9 storage source, encrypted CIFS Secret, dependency graph, values, and pinned Longhorn render passed validation.'

# Verify the live Longhorn acceptance gate: controllers, node disks, default
# StorageClass, backup target, recurring jobs, and a two-replica test PVC.
storage-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    ns='longhorn-system'
    tpvc='storage-verify-test'
    tmp="$(mktemp -d /tmp/homelab-talos-storage-verify.XXXXXX)"
    cleanup() {
      kubectl --kubeconfig "$kubeconfig" --namespace "$ns" delete pvc "$tpvc" --ignore-not-found --wait=false >/dev/null 2>&1 || true
      rm -rf -- "$tmp"
    }
    trap cleanup EXIT

    for n in longhorn longhorn-config; do
      [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$n" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
        echo "Storage Kustomization $n is not Ready." >&2
        exit 1
      }
    done

    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status daemonset/longhorn-manager --timeout=5m

    nodes_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get nodes.longhorn.io --output json)"
    [[ "$(yq -r '.items | length' - <<<"$nodes_json")" == '3' ]] || { echo 'Expected three Longhorn nodes.' >&2; exit 1; }
    ready="$(yq -r '[.items[] | [.status.conditions[] | select(.type == "Ready") | .status][0]] | unique | join(" ")' - <<<"$nodes_json")"
    [[ "$ready" == 'True' ]] || { echo "Longhorn nodes are not all Ready ($ready)." >&2; exit 1; }
    disk_paths="$(yq -r '[.items[].spec.disks[].path] | unique | join(" ")' - <<<"$nodes_json")"
    [[ "$disk_paths" == '/var/mnt/longhorn' ]] || { echo "Longhorn disk path(s) '$disk_paths', expected /var/mnt/longhorn." >&2; exit 1; }

    sc="$(kubectl --kubeconfig "$kubeconfig" get storageclass longhorn --output json)"
    [[ "$(yq -r '.metadata.annotations."storageclass.kubernetes.io/is-default-class"' - <<<"$sc")" == 'true' ]] || { echo 'longhorn is not the default StorageClass.' >&2; exit 1; }
    [[ "$(yq -r '.parameters.numberOfReplicas' - <<<"$sc")" == '2' ]] || { echo 'longhorn StorageClass is not 2 replicas.' >&2; exit 1; }

    # The CIFS mount + first poll are eventually consistent, so retry (~4 min).
    bt_available=false
    for _ in {1..24}; do
      if [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get backuptargets.longhorn.io default --output jsonpath='{.status.available}' 2>/dev/null)" == 'true' ]]; then
        bt_available=true
        break
      fi
      sleep 10
    done
    [[ "$bt_available" == 'true' ]] || {
      bt_msg="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get backuptargets.longhorn.io default --output jsonpath='{.status.conditions[?(@.type=="Unavailable")].message}' 2>/dev/null)"
      echo "Longhorn backup target is not available after retries: ${bt_msg:-unknown}." >&2
      echo 'Check the CIFS share, the nas-credentials Secret, and whether the Talos nodes can mount CIFS (cifs kernel module).' >&2
      exit 1
    }
    for j in daily-snapshot daily-backup; do
      kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get recurringjobs.longhorn.io "$j" >/dev/null
    done

    export tpvc ns
    yq -n \
      '.apiVersion = "v1" |
       .kind = "PersistentVolumeClaim" |
       .metadata.name = strenv(tpvc) |
       .metadata.namespace = strenv(ns) |
       .spec.accessModes = ["ReadWriteOnce"] |
       .spec.storageClassName = "longhorn" |
       .spec.resources.requests.storage = "1Gi"' >"$tmp/pvc.yaml"
    kubectl --kubeconfig "$kubeconfig" apply --filename "$tmp/pvc.yaml" >/dev/null
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$tpvc" --timeout=3m
    vol="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pvc "$tpvc" --output jsonpath='{.spec.volumeName}')"
    replica_nodes=0
    for _ in {1..24}; do
      replica_nodes="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get replicas.longhorn.io --selector "longhornvolume=$vol" --output json 2>/dev/null | yq -r '[.items[].spec.nodeID] | unique | length')"
      [[ "$replica_nodes" == '2' ]] && break
      sleep 5
    done
    [[ "$replica_nodes" == '2' ]] || { echo "Test volume replicas span $replica_nodes nodes; expected 2 (hard anti-affinity)." >&2; exit 1; }

    just kube foundation-verify
    echo 'Phase 9 storage acceptance passed: Longhorn healthy on three nodes (disks at /var/mnt/longhorn), default two-replica StorageClass, backup target available, recurring jobs present, and a test PVC bound with replicas on two distinct nodes.'

# Validate the Phase 10 monitoring source: files, encrypted Grafana Secret,
# dependency graph, staged-suspend uniformity, key values, wiring, HTTPRoutes,
# and the pinned kube-prometheus-stack render.
monitoring-validate: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/monitoring/kube-prometheus-stack'
    ks="$base/ks.yaml"
    secret="$base/app/grafana-admin.sops.yaml"
    values="$base/app/values.yaml"
    hr="$base/app/helmrelease.yaml"
    repo="$base/app/helmrepository.yaml"
    routes="$base/config/httproutes.yaml"
    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    temp_dir="$(mktemp -d /tmp/homelab-talos-monitoring-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for f in "$ks" "$secret" "$values" "$hr" "$repo" "$routes" \
      "$base/app/namespace.yaml" "$base/app/kustomization.yaml" \
      "$base/config/kustomization.yaml" kubernetes/apps/monitoring/kustomization.yaml; do
      [[ -f "$f" ]] || {
        echo "Missing Phase 10 monitoring source: $f" >&2
        echo 'Run just repo monitoring-secrets if the Grafana Secret is missing.' >&2
        exit 1
      }
    done

    rg -qx '  - ./monitoring' kubernetes/apps/kustomization.yaml || {
      echo 'Refusing: ./monitoring is not wired into kubernetes/apps/kustomization.yaml.' >&2
      exit 1
    }

    [[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
    [[ "$(yq -r '.kind' "$secret")" == 'Secret' ]]
    [[ "$(yq -r '.metadata.name' "$secret")" == 'grafana-admin-secret' ]]
    [[ "$(yq -r '.metadata.namespace' "$secret")" == 'monitoring' ]]

    suspend_states="$(yq ea -r '[select(.kind == "Kustomization") | (.spec.suspend // false)] | .[]' "$ks" | sort -u)"
    [[ "$suspend_states" == 'true' || "$suspend_states" == 'false' ]] || {
      echo 'Both monitoring Kustomizations must be staged together: all suspended or all active.' >&2
      exit 1
    }

    [[ "$(yq ea -r 'select(.metadata.name == "kube-prometheus-stack") | [.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,longhorn' ]]
    [[ "$(yq ea -r 'select(.metadata.name == "kube-prometheus-stack-config") | [.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,kube-prometheus-stack' ]]

    [[ "$(yq -r '.spec.chart.spec.version' "$hr")" == '87.19.0' ]]
    [[ "$(yq -r '.spec.url' "$repo")" == 'https://prometheus-community.github.io/helm-charts' ]]
    [[ "$(yq -r '.prometheus.prometheusSpec.retention' "$values")" == '30d' ]]
    [[ "$(yq -r '.prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage' "$values")" == '50Gi' ]]
    [[ "$(yq -r '.grafana.persistence.enabled' "$values")" == 'true' ]]
    for c in kubeProxy kubeControllerManager kubeScheduler kubeEtcd; do
      [[ "$(yq -r ".${c}.enabled" "$values")" == 'false' ]]
    done
    [[ "$(yq ea -r '[select(.kind == "HTTPRoute") | .spec.hostnames[0]] | sort | join(" ")' "$routes")" == 'alertmanager.lab.supermorphic.com grafana.lab.supermorphic.com prometheus.lab.supermorphic.com' ]]
    [[ "$(yq ea -r '[select(.kind == "HTTPRoute") | .spec.parentRefs[].name] | unique | .[]' "$routes")" == 'internal' ]]
    [[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$base/app/namespace.yaml")" == 'internal' ]]

    kustomize build "$base/app" >/dev/null
    kustomize build "$base/config" >/dev/null

    printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
    HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
      helm template kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 87.19.0 --namespace monitoring --values "$values" >"$temp_dir/kps.yaml"
    render_kinds="$(yq ea -r '[select(.kind == "Prometheus" or .kind == "Alertmanager") | .kind] | .[]' "$temp_dir/kps.yaml" | sort -u | tr '\n' ' ')"
    [[ "$render_kinds" == 'Alertmanager Prometheus ' ]]

    echo 'Phase 10 monitoring source, encrypted Grafana Secret, dependency graph, values, HTTPRoutes, and pinned kube-prometheus-stack render passed validation.'

# Verify the live monitoring stack: HelmRelease + workloads healthy, PVCs bound
# on Longhorn, HTTPRoutes accepted, all three UIs reachable with trusted HTTPS
# through the internal gateway, and the foundation still green.
monitoring-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    ns='monitoring'
    gateway_ip='192.168.90.30'

    for k in kube-prometheus-stack kube-prometheus-stack-config; do
      [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$k" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
        echo "Monitoring Kustomization $k is not Ready." >&2
        exit 1
      }
    done
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease kube-prometheus-stack --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
      echo 'kube-prometheus-stack HelmRelease is not Ready.' >&2
      exit 1
    }

    pvc_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pvc --output json)"
    [[ "$(yq -r '[.items[] | select(.status.phase == "Bound")] | length' - <<<"$pvc_json")" -ge 3 ]] || { echo 'Expected at least three bound PVCs in monitoring.' >&2; exit 1; }
    [[ "$(yq -r '[.items[].status.phase] | unique | join(" ")' - <<<"$pvc_json")" == 'Bound' ]] || { echo 'Not all monitoring PVCs are Bound.' >&2; exit 1; }

    for r in grafana prometheus alertmanager; do
      accepted=false
      for _ in {1..18}; do
        route="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute "$r" --output json 2>/dev/null)"
        if [[ "$(yq -r '[.status.parents[].conditions[]? | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]; then
          accepted=true
          break
        fi
        sleep 5
      done
      [[ "$accepted" == 'true' ]] || {
        echo "HTTPRoute $r is not Accepted; confirm the monitoring namespace carries gateway.supermorphic.com/access=internal and that Envoy Gateway has re-listed it." >&2
        exit 1
      }
    done

    dns_answer=''
    for _ in {1..30}; do
      dns_answer="$(dig +short @192.168.90.2 grafana.lab.supermorphic.com A | sort -u)"
      [[ "$dns_answer" == "$gateway_ip" ]] && break
      sleep 10
    done
    [[ "$dns_answer" == "$gateway_ip" ]] || { echo "Pi-hole returned '$dns_answer' for grafana, not $gateway_ip." >&2; exit 1; }
    for host in prometheus alertmanager; do
      [[ "$(dig +short @192.168.90.2 "$host.lab.supermorphic.com" A | sort -u)" == "$gateway_ip" ]] || { echo "Pi-hole has no $gateway_ip record for $host." >&2; exit 1; }
    done

    health="$(curl --silent --show-error --fail --max-time 15 --resolve "grafana.lab.supermorphic.com:443:$gateway_ip" https://grafana.lab.supermorphic.com/api/health)"
    [[ "$(yq -r '.database' - <<<"$health")" == 'ok' ]] || { echo "Grafana /api/health not ok: $health" >&2; exit 1; }
    curl --silent --show-error --fail --max-time 15 --resolve "prometheus.lab.supermorphic.com:443:$gateway_ip" https://prometheus.lab.supermorphic.com/-/healthy >/dev/null
    curl --silent --show-error --fail --max-time 15 --resolve "alertmanager.lab.supermorphic.com:443:$gateway_ip" https://alertmanager.lab.supermorphic.com/-/healthy >/dev/null

    just kube foundation-verify
    echo 'Phase 10 monitoring acceptance passed: kube-prometheus-stack Ready (Prometheus, Alertmanager, Grafana, exporters), PVCs bound on Longhorn, HTTPRoutes accepted, and all three UIs reachable with trusted HTTPS through the internal gateway.'

# Validate the Phase 10 Gatus source: files, wiring, namespace gateway label,
# staged suspend, key values, HTTPRoute, and the pinned chart render.
gatus-validate: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/monitoring/gatus'
    ks="$base/ks.yaml"
    values="$base/app/values.yaml"
    hr="$base/app/helmrelease.yaml"
    repo="$base/app/helmrepository.yaml"
    route="$base/app/httproute.yaml"
    ns="$base/app/namespace.yaml"
    temp_dir="$(mktemp -d /tmp/homelab-talos-gatus-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for f in "$ks" "$values" "$hr" "$repo" "$route" "$ns" "$base/app/kustomization.yaml"; do
      [[ -f "$f" ]] || { echo "Missing Phase 10 Gatus source: $f" >&2; exit 1; }
    done
    rg -qx '  - ./gatus/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
      echo 'Refusing: ./gatus/ks.yaml is not listed in kubernetes/apps/monitoring/kustomization.yaml.' >&2
      exit 1
    }

    suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
    [[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
    [[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]]
    [[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,internal-gateway,longhorn' ]]
    [[ "$(yq -r '.spec.chart.spec.version' "$hr")" == '1.5.0' ]]
    [[ "$(yq -r '.spec.url' "$repo")" == 'https://twin.github.io/helm-charts' ]]
    [[ "$(yq -r '.persistence.enabled' "$values")" == 'true' ]]
    [[ "$(yq -r '.persistence.storageClassName' "$values")" == 'longhorn' ]]
    [[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'gatus.lab.supermorphic.com' ]]
    [[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]

    kustomize build "$base/app" >/dev/null
    printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
    HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
      helm template gatus gatus --repo https://twin.github.io/helm-charts --version 1.5.0 --namespace gatus --values "$values" >/dev/null

    echo 'Phase 10 Gatus source, wiring, namespace label, values, HTTPRoute, and pinned chart render passed validation.'

# Verify the live Gatus app: Kustomization + HelmRelease Ready, PVC bound,
# HTTPRoute accepted, the dashboard reachable via HTTPS, and foundation green.
gatus-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    ns='gatus'
    gateway_ip='192.168.90.30'

    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization gatus --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Gatus Kustomization is not Ready.' >&2; exit 1; }
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease gatus --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Gatus HelmRelease is not Ready.' >&2; exit 1; }
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pvc gatus --output jsonpath='{.status.phase}' 2>/dev/null)" == 'Bound' ]] || { echo 'Gatus PVC is not Bound.' >&2; exit 1; }

    accepted=false
    for _ in {1..18}; do
      route="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute gatus --output json 2>/dev/null)"
      if [[ "$(yq -r '[.status.parents[].conditions[]? | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]; then accepted=true; break; fi
      sleep 5
    done
    [[ "$accepted" == 'true' ]] || { echo 'Gatus HTTPRoute is not Accepted.' >&2; exit 1; }

    dns_answer=''
    for _ in {1..30}; do
      dns_answer="$(dig +short @192.168.90.2 gatus.lab.supermorphic.com A | sort -u)"
      [[ "$dns_answer" == "$gateway_ip" ]] && break
      sleep 10
    done
    [[ "$dns_answer" == "$gateway_ip" ]] || { echo "Pi-hole returned '$dns_answer' for gatus, not $gateway_ip." >&2; exit 1; }
    curl --silent --show-error --fail --max-time 15 --resolve "gatus.lab.supermorphic.com:443:$gateway_ip" https://gatus.lab.supermorphic.com/health >/dev/null

    just kube foundation-verify
    echo 'Phase 10 Gatus acceptance passed: Kustomization and HelmRelease Ready, PVC bound on Longhorn, HTTPRoute accepted, and the dashboard reachable with trusted HTTPS at gatus.lab.supermorphic.com.'
