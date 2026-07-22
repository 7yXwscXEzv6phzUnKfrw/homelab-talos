# homelab-talos PR, Pre-Commit, and CI Implementation Plan

## Purpose

Introduce a pull-request-based workflow and an enforceable, cluster-independent CI gate for the private `homelab-talos` repository before Phase 12 introduces Renovate.

The repository currently deploys from `main` through Flux. Because changes merged to `main` can affect the live Kubernetes cluster, `main` must be treated as the production deployment boundary rather than as a working branch.

This plan adds:

- Feature-branch and pull-request workflow for normal changes
- Local pre-commit checks for fast developer feedback
- A single `just ci` contract shared by local and GitHub Actions execution
- GitHub Actions validation before merge
- Kubernetes schema validation with kubeconform
- SOPS plaintext protection and gitleaks scanning
- Main-branch protection or ruleset configuration
- Renovate readiness without implementing Renovate yet

## Evaluation and Repo-Specific Refinements (2026-07-22)

**Verdict: this plan aligns with how the repository should evolve — adopt it.** A
repo audit confirms the design fits: `just`-centric CI matches the pure
module-dispatcher `.justfile`; the cluster-independent + secret-free CI boundary is
achievable (`just repo verify` and every `kube *-validate` are CI-safe — no
kubeconfig, no age key; `sops filestatus` reads ciphertext metadata only; the
`*-verify` recipes are correctly excluded); and the Phase 7 version-de-duplication
addresses a real, present duplication (~12 literals), not a hypothetical one.

Fold these audit-grounded refinements into the phases noted:

1. **`just ci` uses `just repo verify` + `talos source-validate`, NOT `talos
   validate`.** `talos validate` needs pre-rendered `clusterconfig/*.yaml`
   (gitignored, needs the age key) → not CI-runnable; `talos source-validate`
   (talhelper + sops metadata) is CI-safe. (Phases 1, 9)
2. **`just ci` placement:** add a top-level `ci` recipe to the root `.justfile`
   (today a pure `mod` dispatcher with no recipes) so it aggregates across the
   `repo` and `kube` modules. (Phase 9)
3. **`require-bash` needs no CI shim** — it checks `BASH_VERSINFO >= 4` (not a
   Homebrew path) and passes on ubuntu-latest. (Phases 1, 10)
4. **kubeconform Kubernetes version = `1.35.6`,** derived from `.mise.toml`
   `kubectl` or `talconfig.yaml` kubelet image, not a fresh literal. (Phase 6)
5. **Phase 7 concrete targets:** literals to make manifest-derived (both the
   `== '<v>'` asserts and the `helm template --version <v>` calls): cilium `1.19.6`,
   cert-manager `v1.21.0`, metallb `0.16.1`, envoy-gateway `v1.8.2`, external-dns
   `1.21.1` (foundation vars/asserts/helm in `kubernetes/mod.just`); longhorn
   `1.12.0`, kube-prometheus-stack `87.19.0`, gatus `1.5.0`, trivy-operator `0.34.0`,
   homepage image `v1.13.2`; talos installer `v1.13.6` + kubelet `v1.35.6`
   (`talos/mod.just`); `flux_version 2.9.2` duplicates `.mise.toml`.
6. **Structural brittleness (same class, not Renovate):** the `flux-validate` exact
   Kustomization-name set (`kubernetes/mod.just`) and the `foundation-validate`
   dependency-name sets must be hand-edited whenever an app is added — this broke
   repeatedly. Make them derive from the built manifests (list/sort) or relax to a
   superset check. (Phase 7 sub-item)
7. **`just ci` is network-dependent, not offline** (helm pulls public charts,
   kubeconform pulls schemas). Keep "cluster-independent / no-secret"; do not call it
   offline. (already stated — keep)

## Target Operating Model

```text
feature/fix branch
        |
        v
local pre-commit checks
        |
        v
pull request to main
        |
        v
GitHub Actions: just ci
        |
        v
squash merge
        |
        v
Flux reconciles main
```

Normal changes must no longer be committed directly to `main`.

Direct commits or rule bypasses are reserved for emergency recovery and must not be used as the routine workflow.

## Key Decisions

1. **Adopt pull requests now.**
   Renovate must enter a repository where PR validation has already been exercised through human-created PRs.

2. **Add GitHub Actions now.**
   CI is a real pre-merge gate once normal development moves to pull requests. Do not defer the workflow until Phase 12.

3. **Use both pre-commit and CI.**
   Pre-commit provides fast local feedback. GitHub Actions is the authoritative and reproducible gate.

4. **Keep validation logic in `just`.**
   GitHub Actions must remain a thin launcher. Do not duplicate shell logic or validation rules in workflow YAML.

5. **Keep CI cluster-independent and secret-free.**
   Required PR checks must not need a kubeconfig, Talos configuration, SOPS age private key, cluster connectivity, or live infrastructure.

6. **Use exact tool versions.**
   Do not use `latest`, floating tags, or duplicate version sources.

7. **Do not enable Renovate automerge initially.**
   Renovate will be introduced later after the PR and CI process is proven stable.

## Scope

### In Scope

- `.pre-commit-config.yaml`
- `.yamllint`
- `scripts/check-sops-encrypted.sh`
- kubeconform validation recipe
- `.mise.toml` and `mise.lock`
- `just repo hooks`
- `just repo lint`
- `just ci`
- `.github/workflows/ci.yml`
- README and platform-plan documentation
- Main branch ruleset or protection documentation
- Removal of unrelated operational health checks from required PR CI
- Refactoring version assertions that will conflict with Renovate

### Out of Scope

- Renovate installation or configuration
- Renovate onboarding PR
- Renovate automerge
- Live cluster verification in GitHub Actions
- Uploading kubeconfig, Talos credentials, SOPS age keys, or other cluster secrets to GitHub
- Automatic Flux reconciliation testing against the live cluster
- Replacing existing local `*-verify`, `*-status`, `*-preflight`, or diagnostic recipes

## Safety and Implementation Guardrails

The implementation agent must follow these constraints:

- Do not push directly to `main`.
- Create a dedicated branch, preferably `feat/pr-ci-quality-gates`.
- Do not modify live Kubernetes resources unless required for validation compatibility.
- Do not decrypt or print committed SOPS secrets.
- Do not add cluster credentials or repository secrets to GitHub Actions.
- Do not make CI dependent on the operator's local machine.
- Do not remove existing validation recipes.
- Do not silently weaken existing validation to make CI pass.
- Do not use `continue-on-error` for required checks.
- Do not mark yamllint as warning-only by swallowing its exit code. If rules are intentionally advisory, encode that behavior explicitly and document it; required CI must have deterministic pass/fail semantics.
- Do not use floating GitHub Action tags in the final workflow. Pin actions to full commit SHAs and add comments showing the corresponding release tag.
- Do not use `<latest>` or equivalent floating values in `.mise.toml`.
- Preserve the repository's `mise` plus `just` command interface.

## Phase 1: Baseline and Audit

Before editing files, inspect the repository and record the current state.

### Tasks

1. Confirm the current branch is not `main` before making changes.
2. Pull the latest `origin/main`.
3. Create the implementation branch.
4. Run the existing repository validation commands and record failures that predate this change.
5. Inventory all recipes that are candidates for `just ci`.
6. Classify each candidate recipe as:
   - Cluster-independent and secret-free
   - Requires network access but not cluster access
   - Requires kubeconfig or live cluster
   - Requires SOPS age private key or decrypted secrets
   - Operational health check unrelated to a proposed change
7. Inspect whether any existing `*-validate` recipe reads:
   - `$KUBECONFIG`
   - `talosconfig`
   - the age private key
   - live HTTP endpoints
   - `kubectl`, `talosctl`, or cluster APIs
8. Identify all duplicated version assertions in:
   - `.mise.toml`
   - `mise.lock`
   - HelmRelease resources
   - OCIRepository resources
   - Kustomizations
   - `.just` files

### Expected Baseline Commands

Adapt names to the actual repository interface:

```bash
mise install
just repo verify
just kube cilium-validate
just kube flux-validate
just kube foundation-validate
just kube storage-validate
just kube monitoring-validate
just kube gatus-validate
just repo secret-scan
```

Do not proceed by hiding existing failures. Document any pre-existing failure separately from implementation regressions.

## Phase 2: Add and Pin Tooling

### Files

- `.mise.toml`
- `mise.lock`

### Tasks

1. Add exact versions for:
   - `pre-commit`
   - `kubeconform`
2. Use the repository's supported mise backend for each tool.
3. Regenerate or update `mise.lock`.
4. Verify a clean environment can install every tool with the repository's standard command.
5. Confirm CI can run mise in locked mode or an equivalent reproducible mode.

### Requirements

- Versions must be exact.
- `mise.lock` must be committed.
- Tool versions must not be duplicated in the GitHub Actions workflow.
- The workflow must install versions from repository-controlled mise configuration.

### Acceptance Criteria

```bash
mise install
mise exec -- pre-commit --version
mise exec -- kubeconform -v
```

All commands succeed from a fresh shell.

## Phase 3: Add Pre-Commit Configuration

### File

- `.pre-commit-config.yaml`

### Required Hooks

Use pinned revisions and include at least:

- `check-added-large-files`
- `check-merge-conflict`
- `check-case-conflict`
- `end-of-file-fixer`
- `trailing-whitespace`
- `mixed-line-ending`
- `check-yaml` with multiple-document support
- `check-json`
- `yamllint`
- local staged-diff gitleaks hook
- local staged SOPS-encryption guard

### Important Corrections

#### Do not exclude `.sops.yaml` from YAML syntax validation

The top-level `sops:` mapping is valid YAML. `check-yaml` should validate encrypted SOPS documents for syntax errors.

Only add an exclusion if a concrete repository file demonstrates an incompatibility, and document the exact reason.

#### Gitleaks must scan staged content

Use the existing proven repository invocation where possible, but ensure the local hook evaluates the staged diff rather than the unstaged working tree.

A suitable pattern is:

```yaml
- id: gitleaks-staged
  name: gitleaks staged changes
  entry: bash -c 'git diff --cached --no-ext-diff --binary | gitleaks stdin --redact --no-banner'
  language: system
  pass_filenames: false
```

Validate the exact gitleaks arguments against the version pinned by mise.

#### Hooks that modify files are local convenience checks

`end-of-file-fixer`, `trailing-whitespace`, and similar hooks may modify files. This is acceptable locally. In CI, `pre-commit run --all-files` must fail if modifications would be required, making uncommitted formatting corrections visible.

## Phase 4: Add Yamllint Configuration

### File

- `.yamllint`

### Starting Configuration

Use a Kubernetes-friendly configuration, then run it against the full repository and adjust only when existing repository conventions justify the change.

Suggested baseline:

```yaml
extends: default

rules:
  document-start: disable
  trailing-spaces: disable
  indentation:
    indent-sequences: consistent
  line-length:
    max: 160
  comments:
    min-spaces-from-content: 1
```

### Requirements

- Avoid broad disablement of syntax or structural rules merely to obtain a green run.
- Fix legitimate lint errors in the repository where reasonable.
- Document any relaxed rule and why Kubernetes, Helm values, SOPS, or the current repository style requires it.
- Required CI must use deterministic exit behavior.

## Phase 5: Implement the Staged SOPS Encryption Guard

### File

- `scripts/check-sops-encrypted.sh`

### Purpose

Prevent a plaintext file named `*.sops.yaml` from being committed.

### Critical Requirement

The script must inspect the **staged Git index content**, not the working-tree copy. Partial staging can otherwise allow the hook to validate different content than the content being committed.

### Required Behavior

1. Enumerate staged added, copied, modified, or renamed files matching `*.sops.yaml`.
2. Ignore deleted files.
3. For each file:
   - Read the staged blob with `git show ":$file"`.
   - Write it to a secure temporary file.
   - Run `sops filestatus` against the temporary file.
   - Use `yq` to assert `.encrypted == true`.
4. Do not print file contents.
5. Report only the affected path and a clear error.
6. Clean temporary files through a trap.
7. Handle spaces in filenames safely.
8. Exit nonzero if any staged SOPS file is not encrypted.

### Suggested Script Structure

```bash
#!/usr/bin/env bash
set -euo pipefail

# Enumerate staged ACMR paths with NUL delimiters.
# Materialize each staged blob to a temporary file.
# Assert sops filestatus reports encrypted=true.
# Never print secret contents.
```

Do not copy a working-tree-only implementation into the final version.

## Phase 6: Add Kubeconform Validation

### Likely File

- `kubernetes/mod.just`

### Objective

Render the committed Kubernetes configuration and validate it against Kubernetes and CRD schemas without accessing the live cluster.

### Required Corrections to the Original Proposal

#### Set an explicit Kubernetes version

Kubeconform must not use its default schema version. Pass the Kubernetes version matching the cluster or derive it from a single authoritative repository value.

Example:

```bash
-kubernetes-version 1.35.6
```

Prefer deriving this value from an existing cluster-version declaration rather than creating another hardcoded copy.

#### Do not remove all Secret resources

Do not use:

```bash
yq ea 'select(.kind != "Secret")'
```

Instead, preserve Secret resources and remove only SOPS metadata before schema validation where required:

```bash
yq ea 'del(.sops)' rendered.yaml
```

Confirm encrypted scalar values remain acceptable to the relevant Secret schema.

#### Control missing CRD schemas

Initial adoption may use `-ignore-missing-schemas`, but unlimited skipping must not become the permanent state.

Implement one of these approaches, in preference order:

1. Add authoritative schema locations until all expected CRDs validate.
2. Capture skipped GVKs and compare them to a committed allowlist.
3. Fail when a new, unexpected skipped GVK appears.

At minimum, print and review skipped resources in CI output.

### Schema Sources

Use:

- Kubernetes default schemas
- A maintained CRD schema catalog
- Existing repository schema sources such as `k8s-schemas.home-operations.com` where appropriate
- Project-specific schemas when required and trustworthy

Do not rely on only one third-party CRD catalog if known repository resources are absent from it.

### Network Classification

This validation is cluster-independent but not necessarily offline because schemas may be downloaded over HTTPS. Documentation must call the gate:

- `cluster-independent`
- `no-cluster, no-secret`

Do not call it fully offline unless schemas are vendored or guaranteed by a local cache.

### Suggested Recipe Shape

```just
kubeconform:
    #!/usr/bin/env bash
    set -euo pipefail

    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' EXIT

    kustomize build kubernetes/apps > "$tmp/rendered.yaml"
    yq ea 'del(.sops)' "$tmp/rendered.yaml" > "$tmp/validated-input.yaml"

    kubeconform \
      -strict \
      -summary \
      -kubernetes-version "${KUBERNETES_VERSION}" \
      -schema-location default \
      -schema-location '<approved CRD schema location>' \
      "$tmp/validated-input.yaml"
```

Adapt rendering to the actual repository structure. If `kustomize build kubernetes/apps` does not build every desired resource, enumerate all intended roots explicitly.

## Phase 7: Refactor Version Assertions Before Renovate

### Problem

Versions are duplicated between manifests and hardcoded validation guards. Renovate may update HelmRelease or OCIRepository manifests while leaving `.just` assertions unchanged, causing false CI failures.

### Tasks

Refactor validation guards such as:

- `cilium_version`
- `cert_manager_version`
- `metallb_version`
- `envoy_gateway_version`
- `external_dns_chart_version`

The preferred model is:

1. The manifest is the source of truth.
2. Validation reads the version from the manifest with `yq`.
3. Assertions validate consistency between related resources without restating the literal version.

Use a Renovate custom regex manager only when a value genuinely cannot be derived from the manifest.

### Acceptance Criteria

- Updating a HelmRelease version in one authoritative manifest does not require manually editing a duplicate literal in `.just` files.
- Existing validation still detects disagreement between related resources.

## Phase 8: Add Repository Commands

### Likely File

- `.just/repository.just`

### Add

```text
just repo hooks
just repo lint
```

### Behavior

#### `just repo hooks`

- Runs `pre-commit install`.
- Is idempotent.
- Uses the mise-managed executable.

#### `just repo lint`

- Runs `pre-commit run --all-files`.
- Returns nonzero when hooks fail or modify files.
- Does not silently restage changes.

### Preserve Existing Commands

Do not redefine the semantic meaning of an existing aggregate such as `just repo verify` unless repository documentation explicitly supports the change.

## Phase 9: Create the `just ci` Contract

### Location

Use the root `.justfile` or `.just/repository.just`, whichever matches current command organization.

### Purpose

`just ci` is the single authoritative command run:

- locally before opening or merging a PR
- by GitHub Actions on pull requests
- by GitHub Actions after pushes to `main`

### Candidate Structure

```just
ci:
    just repo lint
    just repo secret-scan
    just kube kubeconform
    just kube cilium-validate
    just kube flux-validate
    just kube foundation-validate
    just kube storage-validate
    just kube monitoring-validate
    just kube gatus-validate
```

### Required Audit

Before including each recipe, prove that it does not require:

- kubeconfig
- age private key
- decrypted secret values
- Talos API access
- Kubernetes API access
- DNS or HTTP access to the live homelab
- local machine-specific paths

Drop or split any recipe that violates these constraints.

### Operational Checks Must Be Separate

Remove certificate expiry and similar time-based operational checks from required PR CI when failure is unrelated to the proposed change.

For example, move the Pi-hole CA remaining-lifetime check to a separate command:

```text
just operational-checks
```

That command may later run on a schedule or locally, but it must not block unrelated Renovate PRs.

### Naming

Use `cluster-independent CI` or `no-cluster, no-secret CI` in documentation. Do not describe the gate as offline unless remote schema and dependency access has been eliminated.

## Phase 10: Add GitHub Actions Workflow

### File

- `.github/workflows/ci.yml`

### Required Triggers

```yaml
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  workflow_dispatch:
```

The `push` trigger catches emergency bypasses and validates the exact merged commit consumed by Flux.

### Required Workflow Properties

- `permissions: contents: read`
- Full action SHA pinning
- Concurrency cancellation for superseded PR runs
- Reasonable timeout
- No secrets
- No kubeconfig
- No SOPS age key
- No cluster access
- Tool installation through repository mise configuration
- One logical execution command: `just ci`

### Checkout Depth

The current deep gitleaks scan is described as scanning history. `actions/checkout` defaults to a shallow checkout, so configure:

```yaml
with:
  fetch-depth: 0
```

If full-history scanning becomes too expensive, explicitly redesign the required CI scan to cover the PR range and current tree, then move the full-history scan to a scheduled workflow. Do not claim a full-history scan while using a shallow checkout.

### Workflow Skeleton

Use full action commit SHAs in the implementation. The placeholders below are structural only.

```yaml
name: CI

on:
  pull_request:
    branches:
      - main
  push:
    branches:
      - main
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    name: ci
    runs-on: ubuntu-latest
    timeout-minutes: 20

    steps:
      - name: Check out repository
        uses: actions/checkout@<FULL_COMMIT_SHA> # corresponding release tag
        with:
          fetch-depth: 0

      - name: Install mise and repository tools
        uses: jdx/mise-action@<FULL_COMMIT_SHA> # corresponding release tag
        with:
          install: true
          cache: true

      - name: Run cluster-independent validation
        run: mise exec -- just ci
```

Verify the exact mise action inputs against its pinned release before committing.

### Optional Enhancements

Add only when justified:

- Cache kubeconform schemas or mise downloads
- Upload sanitized validation logs on failure
- A scheduled operational-health workflow separate from required PR CI

Do not add excessive matrix jobs to a single-operator homelab repository without a demonstrated need.

## Phase 11: Branch Protection or Ruleset

Configure `main` after the CI workflow has completed at least one successful PR run and the status-check name is known.

### Recommended Rules

- Require a pull request before merging.
- Require zero approving reviews for a single-operator repository.
- Require the `ci` status check.
- Require branches to be up to date before merging only if it does not create unnecessary churn; otherwise rely on GitHub's merge-queue or latest-base validation behavior if available.
- Require linear history.
- Use squash merge as the default merge method.
- Block force pushes.
- Block branch deletion.
- Permit administrator bypass only for emergency recovery.

If the account tier cannot enforce rules on a private repository, document the voluntary workflow and revisit enforcement when the repository plan supports it.

## Phase 11B: AI-Agent Operating Rules (AGENTS.md + CLAUDE.md)

No agent-instruction file exists in the repo today, which is why AI agents default
to committing directly to `main`. Add agent operating rules using the industry
"canonical + thin adapter" pattern — not two full copies that will drift.

### Files

- **`AGENTS.md` (repo root) — canonical, vendor-neutral instruction set.** All real
  rules live here (read by Codex, Cursor, Copilot, Aider, Jules, and others).
- **`CLAUDE.md` (repo root) — thin adapter.** First line `@AGENTS.md` (Claude Code
  imports the referenced file), then only Claude-Code-specific behavior:

  ```markdown
  @AGENTS.md

  ## Claude Code specifics
  - Use plan mode before cross-cutting or multi-phase changes.
  - Use read-only Explore subagents for repo-wide analysis.
  - Stay within this repository unless explicitly directed otherwise.
  ```

- **Optional nested adapters** (defer unless useful for a single-operator repo):
  `kubernetes/CLAUDE.md` = `@AGENTS.md`, plus a `kubernetes/AGENTS.md` capturing the
  app-scaffold pattern (`apps/<domain>/<app>/{ks.yaml,app/,config/}` → staged
  `suspend: true` → guarded `bootstrap` → durable `suspend: false` flip).

### Instruction is not enforcement

These files only *influence* agents; they are **not** a security or policy
boundary. Every guidance rule must have real enforcement elsewhere in this plan:

| Guidance (AGENTS.md) | Enforcement |
|---|---|
| Run `just ci` before completing | CI fails the PR (Phase 10) |
| Never push to `main` | Branch protection / ruleset (Phase 11) |
| Never commit plaintext secrets | pre-commit staged-SOPS guard + gitleaks (Phases 3, 5) + CI |
| Don't hand-edit `clusterconfig/` | `.gitignore` + talhelper generation flow |

### Canonical `AGENTS.md` content

- **Repo purpose:** manages a Talos + Flux GitOps cluster; **Git/`main` is the
  source of truth and the Flux deployment boundary.**
- **Workflow:** branch (`feat/…`/`fix/…`) → change → `just ci` → `gh pr create` →
  squash-merge after the `ci` check passes. **Never commit or push to `main`
  directly**; emergency bypass is exceptional and must be followed by `just ci` on
  `main` (push trigger).
- **Interface:** everything via `mise exec -- just …`. All cluster mutations AND
  health checks are guarded `just` recipes — never raw `kubectl`/`talosctl`/`helm`/
  `flux` against the cluster. Cluster-mutating `bootstrap …` recipes need `*_CONFIRM`
  and are operator-run; agents stage source and hand off.
- **Secrets:** SOPS-encrypted; the age private key is the operator's only. Never
  handle the key, decrypt or rewrite `*.sops.yaml`, print secret values, or copy
  legacy ciphertext — recreate under the repo age key via the guarded `*-secrets`
  recipes.
- **Talos:** don't hand-edit generated `clusterconfig/*.yaml`; change via
  `talconfig.yaml` + the generation flow; preserve Talos/Kubernetes/Cilium version
  compatibility.
- **Flux:** follow the existing `apps/<domain>/<app>` layout and HelmRelease/
  Kustomization/OCIRepository patterns; preserve `dependsOn` ordering; don't suspend
  resources unless authorized.
- **Completion criteria:** review the diff, run applicable validation, and report
  which commands ran versus were skipped and why.

Keep detailed *procedures* out of these files — those belong in `just` recipes and
`docs/`. The files carry rules and pointers only. Reinforce the pattern with a
Claude feedback memory (AGENTS.md-canonical + CLAUDE.md-adapter; PR workflow; never
commit to `main`).

## Phase 12: Documentation Updates

### Files

- `README.md`
- `plans/talos-flux-platform-plan.md`
- Any command-interface or contribution documentation

### Document the New Workflow

Include:

```bash
git switch main
git pull --ff-only
git switch -c feat/<short-description>

# make changes
just repo lint
just ci

git add ...
git commit -m "..."
git push -u origin HEAD

gh pr create
```

Document that:

- Normal work occurs on branches.
- Pull requests are required before changes reach `main`.
- `main` is the Flux deployment boundary.
- `just repo lint` is local fast feedback.
- `just ci` is the authoritative cluster-independent validation contract.
- Cluster-dependent checks remain local/operator-only.
- Emergency bypasses are exceptional and must be followed by validation on `main`.
- AI agents follow the same workflow via `AGENTS.md` / `CLAUDE.md` (Phase 11B); the
  README points humans and agents to those files.

### Update Phase 12 Renovate Notes

Record that Phase 12 will:

- Install and authorize the hosted Renovate GitHub App for the selected private repository, or deploy self-hosted Renovate.
- Add Renovate configuration and onboarding.
- Enable the Dependency Dashboard.
- Enable managers for Flux, Helm, mise, pre-commit, and GitHub Actions as applicable.
- Start with low PR concurrency.
- Require manual review for major updates.
- Keep automerge disabled during initial rollout.
- Use the already-established `ci` required status check.

Do not state that a separate private-only Renovate app is required unless that is verified for the selected installation path.

## Phase 13: Verification

### Local Positive Tests

1. Install tools from a clean environment.
2. Install pre-commit hooks.
3. Run all hooks against all files.
4. Run kubeconform against the full rendered application tree.
5. Run every recipe included in `just ci` without:
   - kubeconfig
   - Talos configuration
   - SOPS age key
   - cluster network access
6. Run `just ci` successfully end to end.

Expected commands:

```bash
mise install
just repo hooks
just repo lint
just ci
```

### Negative Tests

Make each temporary change, confirm the expected failure, then revert it.

1. Introduce invalid YAML indentation.
   - Expected: yamllint or YAML syntax hook fails.

2. Add an invalid field or API version to a Deployment.
   - Expected: kubeconform fails.

3. Stage a plaintext `test.sops.yaml`.
   - Expected: staged SOPS guard fails without printing contents.

4. Stage a fake credential matching a gitleaks rule.
   - Expected: staged gitleaks hook fails.

5. Partially stage an encrypted SOPS file while leaving a different working-tree copy.
   - Expected: the hook evaluates the staged version, proving index-based behavior.

6. Introduce an unapproved unknown CRD kind.
   - Expected: kubeconform missing-schema policy reports or fails it according to the committed allowlist behavior.

7. Add trailing whitespace and omit EOF newline.
   - Expected: local hook modifies the file; CI fails until the correction is committed.

8. Run `just ci` with kubeconfig and SOPS age variables unset.
   - Expected: success.

### GitHub Actions Tests

1. Push the implementation branch.
2. Open a PR to `main`.
3. Confirm `ci` runs automatically.
4. Confirm the workflow uses no repository secrets.
5. Confirm the gitleaks history scan has full history if that behavior is retained.
6. Confirm a deliberate validation failure blocks the PR.
7. Revert the deliberate failure and confirm the PR becomes mergeable.
8. Squash merge the PR.
9. Confirm the `push` workflow validates the resulting `main` commit.
10. Confirm Flux sees only the merged `main` commit, not intermediate branch commits.

## Phase 14: Pull Request Structure

Prefer one implementation PR if the changes remain reviewable. If the diff becomes too large, split into these ordered PRs:

1. **PR 1: Tooling and local hooks**
   - mise pins
   - pre-commit
   - yamllint
   - staged gitleaks
   - staged SOPS guard

2. **PR 2: Kubeconform and version-source refactoring**
   - kubeconform recipe
   - explicit Kubernetes version
   - CRD schema policy
   - Secret validation behavior
   - duplicate version removal

3. **PR 3: CI contract and GitHub Actions**
   - `just ci`
   - operational-check separation
   - workflow YAML
   - docs
   - ruleset instructions

Each PR must leave the repository in a usable state.

## Definition of Done

The implementation is complete only when all conditions are met:

- Normal changes use feature branches and pull requests.
- `main` is not used as a working branch.
- Pre-commit hooks provide fast local feedback.
- The SOPS hook validates staged content, not the working tree.
- Exact versions of pre-commit and kubeconform are pinned through mise.
- `mise.lock` is updated and committed.
- Kubeconform uses an explicit Kubernetes version.
- Secret resources are structurally validated rather than completely discarded.
- Missing CRD schemas are controlled, visible, and preferably allowlisted.
- Duplicate version assertions that would conflict with Renovate are removed or derived from manifests.
- `just ci` succeeds without cluster credentials or decryption keys.
- Time-based operational health checks do not block unrelated PRs.
- GitHub Actions runs on PRs, pushes to `main`, and manual dispatch.
- GitHub Actions contains no duplicated validation logic.
- GitHub Actions are pinned to full commit SHAs.
- Full-history gitleaks behavior uses a full checkout, or the documentation accurately describes a narrower scan.
- A required `ci` check protects `main` where the GitHub plan supports enforcement.
- The implementation is merged through its own pull request.
- Phase 12 documentation introduces Renovate into this established PR workflow rather than creating the workflow at that time.
- `AGENTS.md` (canonical) and `CLAUDE.md` (`@AGENTS.md` adapter) exist at the repo root and state the no-direct-`main`, `just ci`, and PR rules.
- Every agent-guidance rule has a corresponding enforcement mechanism (CI, branch protection, hooks, or `.gitignore`); the agent files carry no duplicated full instruction copies.

## Agent Completion Report

At the end of implementation, provide a concise report containing:

1. Branch name and PR URL.
2. Files added and modified.
3. Exact pinned versions added.
4. Recipes included in `just ci`.
5. Recipes excluded from CI and why.
6. Current expected or allowlisted missing CRD schemas.
7. Results of all positive and negative tests.
8. GitHub Actions run URL and result.
9. Main-branch rules configured or any account-tier limitation preventing enforcement.
10. Remaining work deferred to Phase 12.
