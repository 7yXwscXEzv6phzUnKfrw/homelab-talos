set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

# Install the exact tool versions and verify their presence.
tools:
    mise install --locked
    mise exec -- just repo versions

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

# Verify the external Pi-hole v6 HTTPS identity and write-capable app-session policy.
pihole-status:
    #!/usr/bin/env bash
    set -euo pipefail

    pihole_host='p1'
    pihole_ca='kubernetes/apps/networking/external-dns/app/pihole-ca.crt'
    temp_dir="$(mktemp -d /tmp/homelab-talos-pihole-status.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n cat /etc/pihole/tls_ca.crt' >"$temp_dir/remote-ca.crt"
    remote_domain="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n pihole-FTL --config webserver.domain')"
    remote_ports="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n pihole-FTL --config webserver.port')"
    remote_app_sudo="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n pihole-FTL --config webserver.api.app_sudo')"

    [[ "$remote_domain" == 'pi.hole' ]]
    rg -q '(^|,)443o?s($|,)' <<<"$remote_ports"
    [[ "$remote_app_sudo" == 'true' ]]
    [[ "$(dig +short @192.168.90.2 pi.hole A | sort -u)" == '192.168.90.2' ]]
    openssl verify -CAfile "$temp_dir/remote-ca.crt" "$temp_dir/remote-ca.crt" >/dev/null
    openssl x509 -in "$temp_dir/remote-ca.crt" -noout -checkend 2592000 >/dev/null
    [[ -f "$pihole_ca" ]]
    cmp -s "$pihole_ca" "$temp_dir/remote-ca.crt" || {
      echo 'The tracked Pi-hole CA differs from p1; run the guarded pihole-ca-refresh recipe.' >&2
      exit 1
    }
    curl --silent --show-error --fail-with-body --max-time 10 \
      --cacert "$pihole_ca" \
      --resolve 'pi.hole:443:192.168.90.2' \
      https://pi.hole/api/info/login >/dev/null

    fingerprint="$(openssl x509 -in "$pihole_ca" -noout -fingerprint -sha256 | cut -d= -f2)"
    echo "Pi-hole HTTPS passed: pi.hole resolves to 192.168.90.2, app_sudo=true, and tracked CA SHA256=$fingerprint."

# Refresh only the tracked public Pi-hole CA after a reviewed Pi-hole reinstall or CA rotation.
pihole-ca-refresh:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='refresh:pihole-ca:p1:pi.hole'
    pihole_host='p1'
    target='kubernetes/apps/networking/external-dns/app/pihole-ca.crt'
    temp_dir="$(mktemp -d /tmp/homelab-talos-pihole-ca-refresh.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    [[ "${PIHOLE_CA_REFRESH_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to replace the tracked Pi-hole trust anchor.' >&2
      echo "Set PIHOLE_CA_REFRESH_CONFIRM='$expected_confirmation' after verifying the p1 SSH host identity." >&2
      exit 1
    }

    remote_domain="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n pihole-FTL --config webserver.domain')"
    remote_ports="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n pihole-FTL --config webserver.port')"
    [[ "$remote_domain" == 'pi.hole' ]]
    rg -q '(^|,)443o?s($|,)' <<<"$remote_ports"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n cat /etc/pihole/tls_ca.crt' >"$temp_dir/pihole-ca.crt"
    ! rg -q 'PRIVATE KEY' "$temp_dir/pihole-ca.crt"
    openssl verify -CAfile "$temp_dir/pihole-ca.crt" "$temp_dir/pihole-ca.crt" >/dev/null
    openssl x509 -in "$temp_dir/pihole-ca.crt" -noout -checkend 2592000 >/dev/null
    openssl x509 -in "$temp_dir/pihole-ca.crt" -noout -text | rg -q 'CA:TRUE'

    new_fingerprint="$(openssl x509 -in "$temp_dir/pihole-ca.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
    if [[ -f "$target" ]] && cmp -s "$target" "$temp_dir/pihole-ca.crt"; then
      echo "Tracked Pi-hole CA already matches p1 at SHA256=$new_fingerprint."
      exit 0
    fi
    if [[ -f "$target" ]]; then
      old_fingerprint="$(openssl x509 -in "$target" -noout -fingerprint -sha256 | cut -d= -f2)"
      echo "Replacing tracked Pi-hole CA SHA256=$old_fingerprint with SHA256=$new_fingerprint."
    else
      echo "Installing tracked Pi-hole CA SHA256=$new_fingerprint."
    fi
    install -m 0644 "$temp_dir/pihole-ca.crt" "$target"
    echo 'Review the certificate diff and fingerprint before committing the trust-anchor rotation.'

# Validate Phase 7 provider credentials and write only SOPS-encrypted Secret manifests.
phase7-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:phase7:cloudflare-and-pihole:sops'
    cloudflare_target='kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml'
    pihole_target='kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml'
    pihole_ca='kubernetes/apps/networking/external-dns/app/pihole-ca.crt'
    pihole_api='https://pi.hole'
    temp_dir="$(mktemp -d /tmp/homelab-talos-phase7-secrets.XXXXXX)"
    pihole_sid=''
    pihole_record_cleanup_needed=false
    pihole_test_hostname="phase7-preflight-$$-${RANDOM}.lab.supermorphic.com"
    pihole_test_record="192.0.2.1 $pihole_test_hostname"
    pihole_test_url="$pihole_api/api/config/dns/hosts/192.0.2.1%20$pihole_test_hostname"
    pihole_curl=(
      curl --silent --show-error --fail-with-body --max-time 10
      --cacert "$pihole_ca"
      --resolve 'pi.hole:443:192.168.90.2'
    )
    cleanup_pihole_record() {
      [[ "$pihole_record_cleanup_needed" == 'true' && -n "$pihole_sid" ]] || return 0
      "${pihole_curl[@]}" \
        --request DELETE \
        --header "X-FTL-SID: $pihole_sid" \
        "$pihole_test_url" >/dev/null || return 1
      current_records="$("${pihole_curl[@]}" \
        --header "X-FTL-SID: $pihole_sid" \
        "$pihole_api/api/config/dns/hosts")" || return 1
      if yq -r '.config.dns.hosts[]?' - <<<"$current_records" | rg -Fxq -- "$pihole_test_record"; then
        return 1
      fi
      pihole_record_cleanup_needed=false
    }
    cleanup() {
      original_status=$?
      set +e
      cleanup_status=0
      if ! cleanup_pihole_record; then
        echo "Pi-hole cleanup failed; remove the temporary record '$pihole_test_record' before retrying." >&2
        cleanup_status=1
      fi
      if [[ -n "$pihole_sid" ]]; then
        "${pihole_curl[@]}" \
          --request DELETE \
          --header "X-FTL-SID: $pihole_sid" \
          "$pihole_api/api/auth" >/dev/null 2>&1 || \
          echo 'Warning: Pi-hole session logout failed; the short-lived session will expire.' >&2
      fi
      rm -rf -- "$temp_dir"
      if (( cleanup_status != 0 )); then
        return "$cleanup_status"
      fi
      return "$original_status"
    }
    trap cleanup EXIT
    umask 077

    just repo secrets
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || {
      echo 'Set CLOUDFLARE_API_TOKEN to the supermorphic.com-scoped cert-manager token.' >&2
      exit 1
    }
    [[ -n "${PIHOLE_PASSWORD:-}" ]] || {
      echo 'Set PIHOLE_PASSWORD to a dedicated Pi-hole v6 application password.' >&2
      exit 1
    }
    [[ "${PHASE7_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Phase 7 encrypted Secret manifests.' >&2
      echo "Set PHASE7_SECRETS_CONFIRM='$expected_confirmation' after reviewing both targets." >&2
      exit 1
    }

    [[ -f "$pihole_ca" ]]
    ! rg -q 'PRIVATE KEY' "$pihole_ca"
    openssl verify -CAfile "$pihole_ca" "$pihole_ca" >/dev/null
    openssl x509 -in "$pihole_ca" -noout -checkend 2592000 >/dev/null || {
      echo 'The tracked Pi-hole CA expires within 30 days.' >&2
      exit 1
    }
    "${pihole_curl[@]}" "$pihole_api/api/info/login" >/dev/null

    token_state="$(curl --silent --show-error --fail-with-body --max-time 10 \
      --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      https://api.cloudflare.com/client/v4/user/tokens/verify)"
    [[ "$(yq -r '.success and (.result.status == "active")' - <<<"$token_state")" == 'true' ]] || {
      echo 'Cloudflare rejected the API token or it is not active.' >&2
      exit 1
    }
    zone_state="$(curl --silent --show-error --fail-with-body --max-time 10 \
      --get \
      --data-urlencode 'name=supermorphic.com' \
      --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      https://api.cloudflare.com/client/v4/zones)"
    [[ "$(yq -r '.success and (.result | length == 1) and (.result[0].name == "supermorphic.com")' - <<<"$zone_state")" == 'true' ]] || {
      echo 'The Cloudflare token cannot read exactly the supermorphic.com zone.' >&2
      exit 1
    }

    export PIHOLE_PASSWORD
    yq -n -o=json '{"password": strenv(PIHOLE_PASSWORD)}' >"$temp_dir/pihole-auth.json"
    pihole_state="$("${pihole_curl[@]}" \
      --request POST \
      --header 'Content-Type: application/json' \
      --data-binary @"$temp_dir/pihole-auth.json" \
      "$pihole_api/api/auth")"
    [[ "$(yq -r '.session.valid' - <<<"$pihole_state")" == 'true' ]] || {
      echo 'Pi-hole v6 did not accept the application password.' >&2
      exit 1
    }
    pihole_sid="$(yq -r '.session.sid' - <<<"$pihole_state")"
    [[ -n "$pihole_sid" && "$pihole_sid" != 'null' ]]

    current_records="$("${pihole_curl[@]}" \
      --header "X-FTL-SID: $pihole_sid" \
      "$pihole_api/api/config/dns/hosts")"
    if yq -r '.config.dns.hosts[]?' - <<<"$current_records" | rg -Fxq -- "$pihole_test_record"; then
      echo "Refusing to overwrite the unexpected Pi-hole record '$pihole_test_record'." >&2
      exit 1
    fi
    pihole_record_cleanup_needed=true
    if ! "${pihole_curl[@]}" \
      --request PUT \
      --header "X-FTL-SID: $pihole_sid" \
      "$pihole_test_url" >/dev/null; then
      if current_records="$("${pihole_curl[@]}" \
        --header "X-FTL-SID: $pihole_sid" \
        "$pihole_api/api/config/dns/hosts")" && \
        ! yq -r '.config.dns.hosts[]?' - <<<"$current_records" | rg -Fxq -- "$pihole_test_record"; then
        pihole_record_cleanup_needed=false
      fi
      echo 'Pi-hole rejected the temporary DNS write; verify webserver.api.app_sudo=true.' >&2
      exit 1
    fi
    current_records="$("${pihole_curl[@]}" \
      --header "X-FTL-SID: $pihole_sid" \
      "$pihole_api/api/config/dns/hosts")"
    yq -r '.config.dns.hosts[]?' - <<<"$current_records" | rg -Fxq -- "$pihole_test_record" || {
      echo 'Pi-hole accepted the write request but did not return the temporary DNS record.' >&2
      exit 1
    }
    cleanup_pihole_record || {
      echo "Pi-hole did not remove the temporary record '$pihole_test_record'." >&2
      exit 1
    }

    export CLOUDFLARE_API_TOKEN
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "cloudflare-api-token" |
       .metadata.namespace = "cert-manager" |
       .type = "Opaque" |
       .stringData."api-token" = strenv(CLOUDFLARE_API_TOKEN)' \
      >"$temp_dir/cloudflare.yaml"
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "pihole-password" |
       .metadata.namespace = "external-dns" |
       .type = "Opaque" |
       .stringData.password = strenv(PIHOLE_PASSWORD)' \
      >"$temp_dir/pihole.yaml"

    sops --encrypt --filename-override "$cloudflare_target" \
      "$temp_dir/cloudflare.yaml" >"$temp_dir/cloudflare.sops.yaml"
    sops --encrypt --filename-override "$pihole_target" \
      "$temp_dir/pihole.yaml" >"$temp_dir/pihole.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/cloudflare.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(sops filestatus "$temp_dir/pihole.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/cloudflare.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/pihole.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$CLOUDFLARE_API_TOKEN" "$temp_dir/cloudflare.sops.yaml"
    ! rg -Fq -- "$PIHOLE_PASSWORD" "$temp_dir/pihole.sops.yaml"

    mv -- "$temp_dir/cloudflare.sops.yaml" "$cloudflare_target"
    mv -- "$temp_dir/pihole.sops.yaml" "$pihole_target"
    echo 'Phase 7 provider credentials passed Cloudflare validation and a trusted-HTTPS Pi-hole create/delete proof; only SOPS ciphertext was written.'

# Run repository and declarative Talos source validation.
verify: verify-files
    just talos source-validate
    just repo secret-scan
    @echo "Repository and Phase 2 Talos source checks passed."

# Fail unless running under bash >= 4. macOS /bin/bash 3.2 does not honor set -e
# for a failed bare [[ ]] or (( )) mid-recipe, so validation assertions would
# silently not gate. Recipes use #!/usr/bin/env bash, so a bash >= 4 earlier in
# PATH (for example brew install bash) is what makes the guards effective.
[private]
require-bash:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
      echo 'This repository requires bash >= 4 (for example: brew install bash).' >&2
      echo 'macOS /bin/bash 3.2 skips set -e for [[ ]] tests, so validation would not gate.' >&2
      exit 1
    }

# Verify ignore boundaries and SOPS policy.
verify-files: require-bash
    @git check-ignore -q clusterconfig/nuc1.yaml
    @git check-ignore -q talosconfig
    @git check-ignore -q kubeconfig
    @git check-ignore -q support-bundles/example.tar.gz
    @if git check-ignore -q talos/talconfig.yaml; then echo "talos/talconfig.yaml must be trackable" >&2; exit 1; fi
    @if git check-ignore -q talos/talsecret.sops.yaml; then echo "encrypted Talos secrets must be trackable" >&2; exit 1; fi
    @if git check-ignore -q kubernetes/apps/example/secret.sops.yaml; then echo "encrypted Kubernetes secrets must be trackable" >&2; exit 1; fi
    @test -f kubernetes/flux/clusters/prod/apps.yaml
    @test -f kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml
    @test -f kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml
    @test -f kubernetes/apps/networking/external-dns/app/pihole-ca.crt
    @test -f kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml
    @if git check-ignore -q kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml; then echo "the encrypted Flux canary must be trackable" >&2; exit 1; fi
    @if git check-ignore -q kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml; then echo "the encrypted Cloudflare token must be trackable" >&2; exit 1; fi
    @if git check-ignore -q kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml; then echo "the encrypted Pi-hole password must be trackable" >&2; exit 1; fi
    @test "$(yq -r '.creation_rules[0].encrypted_regex' .sops.yaml)" = '^(.*)$'
    @test "$(yq -r '.creation_rules[1].encrypted_regex' .sops.yaml)" = '^(data|stringData)$'
    @test "$(yq -r '[.creation_rules[].age | test("^age1")] | all' .sops.yaml)" = true
    @test "$(sops filestatus kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml | yq -r '.encrypted')" = true
    @test "$(sops filestatus kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml | yq -r '.encrypted')" = true
    @test "$(sops filestatus kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml | yq -r '.encrypted')" = true
    @if rg -q 'PRIVATE KEY' kubernetes/apps/networking/external-dns/app/pihole-ca.crt; then echo "Pi-hole CA source must not contain a private key" >&2; exit 1; fi

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
