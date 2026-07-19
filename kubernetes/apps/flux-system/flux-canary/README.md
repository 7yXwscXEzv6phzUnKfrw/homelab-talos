# Flux Canary

This noncritical Secret is the permanent reconciliation and SOPS decryption
canary for the production cluster. Its encrypted Git source contains the marker
`ready`; only Flux with the matching `flux-system/sops-age` identity can create
the live plaintext value.

The canary Kustomization depends on Cilium so it cannot report Ready before the
network ownership handoff succeeds. Use `just kube flux-canary-test` for the
guarded delete-and-recreate test. Do not delete it directly or replace it with a
plaintext manifest.
