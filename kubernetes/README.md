# Kubernetes Source Boundary

This directory will hold resources reconciled by Flux. Cilium bootstrap begins
in Phase 5 and the production Flux entrypoint begins in Phase 6. Until then, the
bootstrap recipes intentionally fail.

## Layout Rules

- Flux cluster entrypoints belong under `flux/clusters/prod/`.
- Components own their manifests and Helm configuration under `apps/`.
- Shared bases and overlays are deferred until the Pi staging cluster creates
  actual duplication.
- Rendered Helm output is validation material, not declarative source, and remains
  ignored.

Kubernetes Secret manifests use the `*.sops.yaml` suffix. SOPS encrypts only
their `data` and `stringData` fields so metadata remains reviewable by Flux. Load
and validate the repository identity before editing an encrypted manifest:

```bash
just repo secrets
mise exec -- sops kubernetes/path/to/secret.sops.yaml
just repo verify
```

There is not yet a Just recipe for interactive SOPS editing, so this is an
intentional direct use of a mise-pinned CLI. Never commit a decrypted Secret or
place the private age identity in this tree.

After Flux bootstrap, normal Kubernetes changes are made in Git and reconciled by
Flux. Direct `kubectl apply` is reserved for documented bootstrap or recovery
steps; it is not the steady-state deployment workflow.

See the root [`README.md`](../README.md) for workstation setup and
[`docs/sops.md`](../docs/sops.md) for the complete encryption policy.
