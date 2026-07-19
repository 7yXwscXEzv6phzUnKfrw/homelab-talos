# Homelab Talos Platform

This private repository is the source of truth for the three-node NUC Talos
cluster and its Flux-managed Kubernetes platform. The cluster is being rebuilt
from scratch on new NVMe drives; the old manual Talos layout remains only as a
reference and rollback record.

The canonical design and rollout order are in
[`plans/talos-flux-platform-plan.md`](plans/talos-flux-platform-plan.md). Start
there before enabling a new phase. Physical preflight evidence is in
[`docs/phase-0-preflight.md`](docs/phase-0-preflight.md).

## Physical KVM Note

When connecting the KVM's HDMI and USB cables, `nuc1` and `nuc3` can use their
rear USB-A ports normally. The rear USB-A port on `nuc2` does not provide working
keyboard and mouse access. For `nuc2`, connect the KVM's USB-A cable through a
USB-A-to-USB-C adapter and use the rear USB-C port instead.

## Prerequisites

- macOS with Homebrew and Git
- Access to this private repository
- The password-manager item `homelab-talos SOPS age key` when working with secrets
- Network access to GitHub and upstream release registries when installing tools

No Kubernetes, Talos, Helm, Flux, or SOPS CLI should be installed manually for
this repository. Mise installs the versions declared in `.mise.toml` and verified
by `mise.lock`.

## First Clone

Install mise, review and trust the repository configuration, install the locked
tools, and validate the checkout:

```bash
brew install mise
mise trust
mise install --locked
mise exec -- just repo verify
```

`mise install --locked` is required on the first clone because `just` is itself a
mise-managed tool. After that bootstrap, use Just for repository workflows.

## Shell Setup

Choose one command style for each shell session.

Activate mise, then call Just directly:

```bash
eval "$(mise activate zsh)"
just repo verify
```

Or leave the shell unchanged and execute Just inside the mise environment:

```bash
mise exec -- just repo verify
```

Run `just` or `mise exec -- just` to list the command namespaces. Run a namespace
without a recipe, such as `just talos`, to list its workflows.

## Mise Versus Just

Mise owns tool installation, exact version selection, and the execution
environment. Just is the sole operational task runner; mise tasks are not used.

| Action | Command |
|---|---|
| Bootstrap tools on a new clone | `mise install --locked` |
| Refresh already-bootstrapped tools | `just repo tools` |
| Inspect active tool versions | `just repo versions` or `mise ls --current` |
| Diagnose mise itself | `mise doctor` |
| Run a repository workflow | `just <namespace> <recipe>` |
| Run an ad hoc pinned CLI for investigation | `mise exec -- <tool> ...` |

Prefer a Just recipe whenever one exists. Direct `talosctl`, `kubectl`, `helm`,
`flux`, or `sops` commands are for investigation, recovery documentation, or
developing a new guarded recipe.

## Just Command Reference

The namespace commands are also the built-in command index:

| Command | Purpose |
|---|---|
| `just` | List all top-level namespaces |
| `just repo` | List repository workflows |
| `just talos` | List Talos workflows |
| `just bootstrap` | List staged bootstrap workflows |
| `just kube` | List Kubernetes rendering, validation, and live-status workflows |

All currently defined recipes are listed below. Recipes marked internal are
normally invoked as dependencies of the operator-facing workflow, but remain
available for focused developer validation.

| Recipe | Purpose | Availability |
|---|---|---|
| `just repo tools` | Install locked tools and print versions | Available |
| `just repo versions` | Print the active tool versions | Available |
| `just repo secrets` | Confirm the loaded age identity matches this repository | Available |
| `just repo verify` | Check policy, Talos sources, and tracked content for secrets | Available |
| `just repo verify-files` | Check ignore boundaries and SOPS policy | Available; internal validation |
| `just repo secret-scan` | Run the repository secret scans directly | Available |
| `just talos generate` | Render and validate machine configs with Talhelper | Available |
| `just talos validate` | Strictly validate rendered Talos configs and Phase 2 policy | Available |
| `just talos source-validate` | Validate trackable Talhelper inputs without decrypting identity | Available; internal validation |
| `just talos apply <node>` | Guard, dry-run, and apply one node's machine config | Enabled in Phase 3; destructive after confirmation |
| `just bootstrap preflight` | Verify all three installed NUCs and refuse if etcd is initialized | Enabled in Phase 4; read-only |
| `just bootstrap talos` | Guard and bootstrap etcd exactly once on nuc1 | Enabled in Phase 4; destructive after confirmation |
| `just bootstrap status [node]` | Print read-only etcd membership, service, discovery, and recent logs; optionally select one node | Enabled in Phase 4; diagnostic |
| `just bootstrap retry-join <node>` | Guard and reboot a failed nuc2/nuc3 etcd join without re-bootstrap | Enabled in Phase 4; mutating after confirmation |
| `just bootstrap verify` | Verify the pre-Cilium etcd/Kubernetes/Talos gate and refresh ignored kubeconfig | Historical Phase 4 gate; do not use after Cilium |
| `just kube cilium-render` | Render the pinned Cilium OCI chart to standard output | Enabled in Phase 5; read-only |
| `just kube cilium-validate` | Validate Cilium sources, values, and the Helm render | Enabled in Phase 5; read-only |
| `just kube cilium-status` | Print Helm, node, pod, and Cilium status | Enabled in Phase 5; read-only |
| `just kube cilium-diagnostics` | Print Talos diagnostics from all cluster nodes | Enabled in Phase 5; read-only |
| `just kube cilium-postflight` | Verify Talos diagnostics and etcd health | Enabled in Phase 5; read-only |
| `just kube cilium-verify` | Run the Phase 5 gate and temporary connectivity tests | Enabled in Phase 5; creates and removes test resources |
| `just bootstrap cilium` | Guard and install or reconcile Cilium `1.19.6` | Enabled in Phase 5; mutating after confirmation |
| `just bootstrap flux` | Bootstrap Flux against this repository | Disabled until Phase 6 |

Recipes for future phases currently fail with a phase-prerequisite message. That
failure is intentional and prevents a documented interface from becoming an
accidental cluster mutation.

The Phase 3 apply procedure, including its exact serial-bound confirmation, is
documented in [`talos/README.md`](talos/README.md) and the installation evidence
is recorded in [`docs/phase-3-installation.md`](docs/phase-3-installation.md).
The Cilium ownership boundary, exact confirmation, connectivity test, and Phase 5
evidence are documented in
[`docs/phase-5-cilium.md`](docs/phase-5-cilium.md).

## Daily Cluster Health Check

From the repository root, run these two read-only checks:

```bash
mise exec -- just kube cilium-status
mise exec -- just kube cilium-postflight
```

If the mise environment is already activated, omit `mise exec --`. A healthy
result shows:

- Helm release `cilium` deployed at `1.19.6`.
- `nuc1`, `nuc2`, and `nuc3` in Kubernetes `Ready` state.
- Three ready Cilium agents, two ready operators, and one ready Hubble Relay.
- Cilium and Hubble reporting `OK` without crash loops or an unexpected restart
  increase.
- No temporary `cilium-test*` namespaces.
- No Talos diagnostics on any node.
- Three etcd members and no etcd alarms.

If either command fails, use the read-only checks in this order:

```bash
# Focused Talos diagnostic resources from every node
mise exec -- just kube cilium-diagnostics

# Etcd membership, Talos service state, discovery, and recent logs
mise exec -- just bootstrap status

# Limit the detailed output to one node when the failure is localized
mise exec -- just bootstrap status nuc1
```

Run the full functional network suite after a networking change or when the
status checks cannot explain a connectivity problem:

```bash
mise exec -- just kube cilium-verify
```

The full verifier takes approximately 15–20 minutes. It creates temporary test
workloads, exercises DNS, services, policy, FQDN, L7, pod, node, and cross-node
traffic, and removes the test resources afterward. `just kube cilium-validate`
and `just repo verify` validate local declarative sources; they do not establish
live cluster health.

Do not use `just bootstrap verify` as a routine check after Cilium is installed.
It is the historical Phase 4 pre-CNI gate and intentionally expects all nodes to
be `NotReady`. Do not use `just bootstrap cilium` as a status command because it
is an installation/reconciliation workflow with a guarded mutation path.

## Secret Access

Retrieve `homelab-talos SOPS age key` from the password manager and expose it to
the current shell. Do not create the key file inside this repository.

For a short session:

```bash
export SOPS_AGE_KEY='AGE-SECRET-KEY-...'
just repo secrets
```

For repeated operations, use an owner-readable file outside the repository:

```bash
export SOPS_AGE_KEY_FILE=/secure/path/homelab-talos-age.txt
just repo secrets
```

`just repo secrets` derives the public recipient and rejects the wrong identity. See
[`docs/sops.md`](docs/sops.md) for encryption policy and
[`docs/recovery.md`](docs/recovery.md) for restoring access.

## Normal Change Workflow

1. Confirm the current phase and its prerequisites in the canonical plan.
2. Run `just repo tools` after pulling a change to `.mise.toml` or `mise.lock`.
3. Load the SOPS identity only when the change requires encrypted material.
4. Edit declarative source files, never generated output.
5. Run the phase-specific generation or validation recipe when it is available.
6. Run `just repo verify` before reviewing or committing the change.
7. Inspect `git status` and confirm no generated config, decrypted secret,
   kubeconfig, talosconfig, or private key is trackable.

Do not bypass a disabled recipe with a raw cluster-changing command. Enable and
test the guarded recipe as part of the phase that owns that operation.

## Updating Tool Versions

Tool upgrades are deliberate repository changes:

1. Edit the version in `.mise.toml`.
2. Run `mise install` to install the new version.
3. Run `mise lock` to refresh cross-platform URLs, checksums, and provenance.
4. Run `just repo versions` and `just repo verify`.
5. Review and commit `.mise.toml` and `mise.lock` together.

Use `mise install --locked` when consuming the repository. Use unlocked
`mise install` only while intentionally changing the tool definition and lockfile.

## Repository Boundaries

- `talos/` holds declarative Talhelper inputs beginning in Phase 2.
- `.just/` holds repository and cross-domain bootstrap command modules.
- `talos/mod.just` and `kubernetes/mod.just` colocate domain commands with their
  declarative sources; the root `.justfile` only declares namespaces.
- `clusterconfig/` holds ignored rendered Talos machine configs.
- `kubernetes/` holds Flux sources beginning in Phase 5.
- `docs/` holds inventory, recovery, secret handling, and phase evidence.
- `plans/` holds architectural decisions and phased acceptance gates.

Generated configs, kubeconfigs, talosconfigs, decrypted secrets, Helm output,
support bundles, and age private identities must remain outside Git. The private
repository does not weaken this rule.

## Current Phase

Phase 5 is complete: Cilium `1.19.6` was installed through the guarded Just
workflow from the canonical future-Flux values, all three NUCs are Ready, and
DNS, policy, service, cross-node, Hubble, Talos, and etcd acceptance gates pass.
Flux does not own the release yet; that adoption remains Phase 6. See
[`docs/phase-3-installation.md`](docs/phase-3-installation.md) for installation
evidence and [`docs/phase-4-bootstrap.md`](docs/phase-4-bootstrap.md) for the
bootstrap interface and recovery record. Phase 5 ownership, commands, and live
evidence are in [`docs/phase-5-cilium.md`](docs/phase-5-cilium.md).
