# Kubernetes Source Boundary

This directory will hold resources reconciled by Flux. Cilium bootstrap begins
in Phase 5 and the production Flux entrypoint begins in Phase 6. Until then, the
bootstrap recipes intentionally fail.

## Layout Rules

- Flux cluster entrypoints belong under `flux/clusters/prod/`.
- Components own their manifests, chart source, Helm configuration, first-party
  configuration, routing, monitoring, and local documentation under
  `apps/<namespace>/<app>/`.
- Each application has an explicit `ks.yaml` entrypoint and an `app/` directory.
  A directory is not deployed merely because it exists; a parent Flux
  Kustomization must include it.
- Shared bases and overlays are deferred until the Pi staging cluster creates
  actual duplication.
- Rendered Helm output is validation material, not declarative source, and remains
  ignored.

Use a `HelmRelease` for infrastructure controllers and applications with a
healthy maintained chart. Use focused native Deployments, Services, HTTPRoutes,
PVCs, and related resources when no trustworthy chart exists. Do not commit the
output of `helm template`, Kompose, or another third-party generator as the
declarative source.

Flux dependencies replace implicit directory ordering and numeric sync waves.
Split controllers from the custom resources that depend on them, then use
`dependsOn`, readiness waiting, and health checks. Examples include cert-manager
before issuers, MetalLB before address-pool resources, Envoy Gateway before
Gateways and HTTPRoutes, and Longhorn before PVC consumers.

## Cilium Bootstrap Boundary

Cilium is the only Kubernetes component installed before Flux because the nodes
cannot become Ready and Flux cannot run without a CNI. Its app-local package is
tracked under `apps/kube-system/cilium/` before it is reconciled by Flux:

```text
cilium/
├── README.md
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml
    ├── helmrelease.yaml
    └── values.yaml
```

`values.yaml` is the single configuration source. `just bootstrap cilium` passes
it to Helm during Phase 5. In Phase 6, the app Kustomization publishes the same
file as a watched ConfigMap and the HelmRelease adopts the existing `cilium`
release in `kube-system`. Do not apply `ks.yaml`, `ocirepository.yaml`, or
`helmrelease.yaml` manually before Flux is installed.

All supported Cilium workflows are Just recipes:

| Command | Behavior |
|---|---|
| `just kube cilium-render` | Render the pinned OCI chart to standard output without writing tracked YAML |
| `just kube cilium-validate` | Validate the app package, canonical values, and rendered chart |
| `just kube cilium-status` | Print read-only Helm, node, pod, and Cilium status |
| `just kube cilium-diagnostics` | Print read-only Talos diagnostics from all cluster nodes |
| `just kube cilium-postflight` | Verify Talos diagnostics and etcd health after connectivity tests |
| `just kube cilium-verify` | Run the live Phase 5 gate and temporary connectivity workloads |
| `just bootstrap cilium` | Guard and install or reconcile the bootstrap Helm release |

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
