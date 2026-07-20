# Envoy Gateway

Envoy Gateway `v1.8.2` owns the Kubernetes Gateway API controller. It watches
only namespaces labeled `gateway.supermorphic.com/access=internal`. The separate
`internal-gateway` package creates the GatewayClass, shared HTTPS Gateway, and
two-replica Envoy data plane at `192.168.90.30`.

Applications attach portable HTTPRoutes from explicitly labeled namespaces.
They do not receive the wildcard TLS private key. Use the Phase 7 Just workflows
documented in [`docs/phase-7-foundation.md`](../../../../docs/phase-7-foundation.md).
