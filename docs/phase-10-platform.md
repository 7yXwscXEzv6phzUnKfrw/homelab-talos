# Phase 10: Greenfield Platform Applications

## Status

**In progress.** Applications are added one at a time, each as a Flux HelmRelease
(or focused native manifests) reimplemented from the legacy `homelab-gitops`
requirements — never by copying rendered YAML, KSOPS resources, PVCs, or data.

| App | State |
|---|---|
| kube-prometheus-stack (Prometheus + Alertmanager + Grafana + exporters) | **Complete (2026-07-22)** |
| Gatus | pending |
| Homepage | pending |
| Trivy Operator | pending |

## Delivery pattern (every app)

`kubernetes/apps/<domain>/<app>/` with staged `ks.yaml` (`suspend: true`) →
`app/` (HelmRelease/HelmRepository/namespace/values, plus any SOPS secret the
workload needs at start) → `config/` (routes and post-install CRs, `dependsOn`
the app). Guarded workflow: `just repo <app>-secrets` (if secrets) →
`just kube <app>-validate` → commit/push → `just bootstrap <app>` → `just kube
<app>-verify` → durable `suspend: false` flip.

**Exposure:** Gateway API `HTTPRoute` on the `internal` gateway
(`sectionName: https`, wildcard host `*.lab.supermorphic.com`, existing
`wildcard-lab-supermorphic-com-tls`), with `external-dns.k8s.io/audience: internal`
so ExternalDNS publishes the record to Pi-hole. **The app namespace MUST carry
`gateway.supermorphic.com/access: internal`** — the gateway's https listener
allows routes only from namespaces with that label. Envoy Gateway does not
re-evaluate existing routes when a namespace's labels change later, so create the
namespace with the label from the start (see the kube-prometheus-stack note).

## kube-prometheus-stack

`kubernetes/apps/monitoring/kube-prometheus-stack/`, chart `87.19.0` from
`prometheus-community`, namespace `monitoring` (privileged + gateway-access
label). Two Kustomizations: `kube-prometheus-stack` (app, `dependsOn`
cilium + longhorn) → `kube-prometheus-stack-config` (HTTPRoutes, `dependsOn`
the app + internal-gateway).

### Right-sizing (raised from the Raspberry-Pi-5 constraints)

The legacy Pi build was constrained silently through retention/storage caps and
disabled rules, not memory limits. For the 32 GB/node Talos cluster:

| Setting | Pi-5 legacy | This cluster |
|---|---|---|
| Prometheus retention | 7d | 30d |
| Prometheus retentionSize | 8GiB | 45GiB |
| Prometheus PVC | 20Gi | 50Gi longhorn |
| Prometheus resources | none | req 500m/2Gi, limit 4Gi |
| Grafana persistence | off (ephemeral) | on, 10Gi longhorn |
| Grafana resources | 300m/400Mi limit | req 100m/256Mi, limit 512Mi |
| Alertmanager PVC | 1Gi | 5Gi longhorn |
| defaultRules | trimmed | all on except the Talos-unscrapable groups |
| operator / KSM / node-exporter | none | modest req + limits |

### Talos-specific component handling

Cilium replaces kube-proxy, and Talos binds controller-manager/scheduler/etcd
metrics to localhost, so `kubeProxy`, `kubeControllerManager`, `kubeScheduler`,
and `kubeEtcd` scrape targets are disabled along with their `defaultRules` groups
to avoid false "down" alerts. `serviceMonitorSelectorNilUsesHelmValues: false`
(and the pod/rule/probe/scrapeConfig equivalents) let Prometheus scrape every
monitor in the cluster, not only chart-labeled ones.

### Exposure and credentials

Three internal HTTPRoutes: `grafana` / `prometheus` / `alertmanager`
`.lab.supermorphic.com`. The Grafana admin credential is the SOPS-encrypted
`grafana-admin-secret` written by the guarded `just repo monitoring-secrets`
(env `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`, ≥12 chars,
`MONITORING_SECRETS_CONFIRM`) — never copied from the legacy repo.

### Alerting

Alertmanager is the alerting backbone (the enabled Prometheus rules route to it;
Grafana's own unified alerting is left unused). It ships with the chart's default
(null) route, so **alerts evaluate but do not notify** until a real receiver
(ntfy/email/Slack) is wired — a later follow-up.

### Rollout

```bash
export MONITORING_BOOTSTRAP_CONFIRM='bootstrap:phase10:monitoring:kube-prometheus-stack'
mise exec -- just bootstrap monitoring
```

### Acceptance evidence (2026-07-22)

`just kube monitoring-verify` passed: both Kustomizations and the HelmRelease
Ready, ≥3 PVCs Bound on Longhorn, all three HTTPRoutes Accepted, and all three
UIs reachable with trusted HTTPS through the internal gateway
(Grafana `/api/health` → `database: ok`); `foundation-verify` still green.

### Lesson: internal-gateway namespace label

The first rollout created the `monitoring` namespace without
`gateway.supermorphic.com/access: internal`; the HTTPRoutes were rejected. Adding
the label later did not help because Envoy Gateway does not re-evaluate existing
routes on a namespace label change — a one-time
`kubectl -n envoy-gateway-system rollout restart deploy/envoy-gateway` cleared its
cache. The label is now in the namespace manifest and asserted by
`monitoring-validate`, so future apps avoid this.
