set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

# Phase 4 will enable initial etcd bootstrap.
talos:
    @echo "Phase 4 prerequisite: bootstrap talos is intentionally disabled." >&2
    @exit 1

# Phase 5 will enable Cilium bootstrap.
cilium:
    @echo "Phase 5 prerequisite: bootstrap cilium is intentionally disabled." >&2
    @exit 1

# Phase 6 will enable Flux bootstrap.
flux:
    @echo "Phase 6 prerequisite: bootstrap flux is intentionally disabled." >&2
    @exit 1
