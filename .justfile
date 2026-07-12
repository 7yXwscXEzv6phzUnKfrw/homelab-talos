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

# Run repository-only Phase 1 validation.
verify: verify-files secret-scan
    @echo "Phase 1 repository checks passed."

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

# Phase 2 will enable Talhelper rendering after its source files exist.
talos-generate:
    @echo "Phase 2 prerequisite: talos/talconfig.yaml and talos/talsecret.sops.yaml are not defined yet." >&2
    @exit 1

# Phase 2 will enable local machine-config validation.
talos-validate:
    @echo "Phase 2 prerequisite: rendered machine configs do not exist yet." >&2
    @exit 1

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
