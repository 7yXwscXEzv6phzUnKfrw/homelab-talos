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

    [[ "$(yq ea -r 'select(.kind == "Kustomization") | .metadata.name' "$temp_dir/apps.yaml" | sort)" == $'cilium\nflux-canary' ]]
    [[ -z "$(rg 'apiVersion: .+/(v1beta1|v1beta2|v2beta1|v2beta2)' kubernetes --glob '*.yaml' || true)" ]]

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
flux-verify: flux-validate
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
