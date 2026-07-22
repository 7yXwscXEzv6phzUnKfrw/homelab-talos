#!/usr/bin/env bash
set -euo pipefail

# Fail if any staged *.sops.yaml file is not SOPS-encrypted. Inspects the STAGED
# blob from the git index (not the working tree), so partial staging cannot slip a
# plaintext secret through. Never prints file contents.

fail=0
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

while IFS= read -r -d '' file; do
  blob="$tmp_dir/staged.sops.yaml"
  if ! git show ":$file" >"$blob" 2>/dev/null; then
    echo "check-sops-encrypted: cannot read staged blob for $file" >&2
    fail=1
    continue
  fi
  if [[ "$(sops filestatus "$blob" 2>/dev/null | yq -r '.encrypted' 2>/dev/null)" != 'true' ]]; then
    echo "check-sops-encrypted: staged $file is NOT SOPS-encrypted; refusing to commit plaintext." >&2
    fail=1
  fi
done < <(git diff --cached --name-only -z --diff-filter=ACMR -- '*.sops.yaml' '*.sops.yml')

exit "$fail"
