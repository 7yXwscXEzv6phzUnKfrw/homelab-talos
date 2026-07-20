# MetalLB

MetalLB chart `0.16.1` advertises LoadBalancer addresses on the LAN in L2 mode.
The only pool is `192.168.90.30-192.168.90.39`, `autoAssign` is disabled, and
the internal Gateway explicitly requests `192.168.90.30`. FRR and FRR-K8s are
disabled.

The router must exclude the entire pool from DHCP. Use
`just bootstrap foundation` for the guarded first reconciliation and
`just kube foundation-status` for inspection; see
[`docs/phase-7-foundation.md`](../../../../docs/phase-7-foundation.md).
