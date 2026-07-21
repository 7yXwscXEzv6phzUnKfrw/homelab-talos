# MetalLB

MetalLB chart `0.16.1` advertises LoadBalancer addresses on the LAN in L2 mode.
The only pool is `192.168.90.30-192.168.90.39`, `autoAssign` is disabled, and
the internal Gateway explicitly requests `192.168.90.30`. FRR and FRR-K8s are
disabled.

The router must exclude the entire pool from DHCP. Use
`just bootstrap foundation` for the guarded first reconciliation and
`just kube foundation-status` for inspection; see
[`docs/phase-7-foundation.md`](../../../../docs/phase-7-foundation.md).

All three nodes are schedulable control planes, so the Talos machine config
deletes `node.kubernetes.io/exclude-from-external-load-balancers` from
`machine.nodeLabels` (see `talos/patches/machine.yaml`). Talos adds and
reconciles that label on control-plane nodes, and MetalLB honors it: if every
node carries it, MetalLB reports "no available nodes" and never announces the
Gateway IP. Removing it only at the Kubernetes layer (`kubectl label`) does not
persist because Talos re-applies it from the machine config, so the fix must
live in the Talos config and be applied with `just talos apply`.
