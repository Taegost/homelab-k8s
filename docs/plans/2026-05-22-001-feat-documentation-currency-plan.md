---
title: "feat: Documentation currency pass"
type: feat
status: completed
date: 2026-05-22
origin: docs/brainstorms/documentation-currency.md
---

# feat: Documentation Currency Pass

## Summary

Six implementation units to close identified documentation drift: split the
project-level Claude instructions into a portable global file and a lean
project-scoped file committed back to git; complete the README deployed
applications table; archive the docker-traefik migration manifests with
context; remove the now-obsolete bootstrap Step 4 apply commands; and bump
Longhorn's `defaultReplicaCount` from 2 to 3.

---

## Problem Frame

See origin document `docs/brainstorms/documentation-currency.md` for the full
narrative. In brief: the third cluster node came online, the Docker→Kubernetes
migration completed, and `CLAUDE.md` was intentionally removed from git, but
the dependent documentation was never updated. A new session or external reader
gets a materially inaccurate picture of the cluster.

---

## Requirements

- R1. Create `~/.claude/CLAUDE.md` (global) with portable operator preferences
- R2. Create project `CLAUDE.md` (repo root, committed to git) with homelab-specific conventions
- R3. Cluster overview in project `CLAUDE.md` reflects 3-node state
- R4. "When third node comes online" removed; ArgoCD HA noted as still pending
- R5. `README.md` Deployed Applications table includes all currently deployed apps
- R6. `README.md` includes a MariaDB note alongside the existing PostgreSQL note
- R7. `archived/traefik/` contains the two docker-traefik manifests with archival headers
- R8. `archived/traefik/README.md` explains the migration artifact context
- R9. `bootstrap/README.md` Step 4 removes docker-traefik apply commands and references `archived/traefik/`
- R10. `apps/longhorn/values.yaml` `defaultReplicaCount` changed from `2` to `3`
- R11. Inline comment on `defaultReplicaCount` updated for 3-node cluster

---

## Scope Boundaries

- ArgoCD HA migration execution — documented as pending only, not performed here
- Longhorn existing-volume replica rebalancing — out-of-band operational step, not a GitOps change
- App READMEs for Firefly3, Leantime, n8n — documentation gap but not prior-state drift
- Content of `docs/argocd-ha-migration.md` — runbook is still valid, unchanged

### Deferred to Follow-Up Work

- Longhorn existing-volume replica increase: after R10 deploys, volumes created
  before the change remain at 2 replicas. Update each via Longhorn UI or kubectl.
- ArgoCD HA migration execution: follow `docs/argocd-ha-migration.md` when ready.

---

## Context & Research

### Relevant Code and Patterns

- `archived/README.md` — existing archive documentation pattern: what it is,
  why it was removed, why it's kept, and how to restore. Follow this structure
  for `archived/traefik/README.md`.
- `apps/longhorn/values.yaml` — `defaultReplicaCount` field and its comment block.
- `bootstrap/README.md` Step 4 — docker-traefik apply commands appear at the
  end of the Traefik bootstrap section after the main `helm install` block.
- docker-traefik source: recoverable via `git show 6f7fcdf^:apps/traefik/docker-traefik-forward.yaml`
  and `git show 6f7fcdf^:apps/traefik/docker-traefik-catchall.yaml` (commit `6f7fcdf` — "Traefik Migration: Phase 2") — both are
  well-commented in the original and serve as the source for the archive copies.

### Institutional Learnings

- None — `docs/solutions/` does not exist in this repo.

### External References

- None required — all changes are documentation, configuration, and file
  recovery from git history.

---

## Key Technical Decisions

- **CLAUDE.md split boundary (see origin: `docs/brainstorms/documentation-currency.md`):**
  Operator preferences that apply across any repo go global (communication rules,
  research discipline, response format, general security rules). Everything that
  presupposes the homelab-k8s context stays in the project file (cluster topology,
  app patterns, storage classes, IngressRoute conventions, Secrets workflow,
  k8s-specific research rules). Rule of thumb: if the instruction would be useful
  in a different repo, it's global.

- **Content preservation in plan:** The project `CLAUDE.md` content (R2–R4) must
  come from the current session's loaded instructions — the original file was
  deleted from git and no backup exists outside this session's loaded context.
  The split content is documented explicitly in U1 and U2 approach sections so
  it's preserved in this plan regardless of session state.

- **docker-traefik reconstruction:** Files are reconstructed from git history
  (`git show 6f7fcdf^:<path>`) rather than copied from the working tree (they
  were deleted). An archival header is added above the original file comments.

---

## Open Questions

### Resolved During Planning

- **Namespaces for missing README apps:** Confirmed via `apps/manifests/` scan.
  All destination namespaces match the app name. Firefly3 → `firefly3`,
  Leantime → `leantime`, n8n → `n8n`, Open WebUI → `open-webui`,
  LiteLLM → `litellm`, Mealie → `mealie`, SearXNG → `searxng`,
  AWS-DDNS → `aws-ddns`, DiceNinjaGaming WordPress → `wordpress-dng`.
- **Global `~/.claude/CLAUDE.md` exists?** No — file does not exist.
  U1 creates it from scratch.
- **`docs/solutions/` exists?** No — no institutional learnings to reference.

### Deferred to Implementation

- **Exact sentence-level split of Behavior Instructions:** Some lines in the
  current project instructions straddle the global/project boundary. Use the
  split principle in Key Technical Decisions and apply judgment per sentence.
  Both files should be read together with no duplication between them.

---

## Implementation Units

### U1. Create global ~/.claude/CLAUDE.md

**Goal:** Establish a portable operator-preferences file that applies to all
Claude Code sessions across any repo.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Create: `~/.claude/CLAUDE.md`

**Approach:**

The global file is the extracted operator-preferences portion of the deleted
project `CLAUDE.md`. Write the following content (sourced from the current
session's loaded project instructions):

*Communication rules:*
- Only render changed sections of documentation when updating existing docs —
  present the changed section with a placement annotation, not the full document
- When architecture changes, provide remediation steps to bring the existing
  environment in line, not just the file changes
- Ask, don't assume — when something is unclear, ask rather than guess
- Sequence before execute — think through architecture and dependencies fully
  before writing any config or code
- Only work on the phase explicitly requested — for phased work, do not create
  files for future phases until asked

*Research discipline:*
- Always check latest docs before writing any manifest, CRD, or Helm values —
  versions change and schemas evolve. Use web search to verify current release
  versions and field names.
- Research before suggesting — do not suggest a step and then contradict it
  later in the same response. Verify first.
- Research best practices first — check whether an established best practice
  exists before proposing a custom solution.
- Don't repeat failed steps — if something didn't work, think through what is
  actually different before proposing a next step.

*Values and secrets:*
- Private values stay private — hostnames, internal IPs, and domain-specific
  values are real values in manifests. Do not suggest placeholder values for
  things that are already configured.
- Treat placeholder values and real values as distinct concerns. Placeholder
  values appear only in secret templates (never in implemented manifests); real
  values are what's already deployed and should not be replaced with placeholders.
- Single source of truth — avoid situations where the same value exists in two
  places. Always identify the canonical location and reference it from there.
  This applies to versions in documentation: do not hardcode app or chart
  versions in runbooks or docs — reference the `image` tag or `targetRevision`
  in the manifest instead. Hardcoded versions drift the moment the manifest
  is updated.

*Security:*
- Never commit plaintext secrets — no exceptions.

*Response format:*
- All file references use repo-relative paths (e.g., `apps/foo/bar.yaml`),
  never absolute paths.
- `kubeseal` commands must always be written as a single line — never split
  with backslash continuations.
- Placeholder values in secret files must not contain dots or dashes — use
  underscores only (e.g., `your_api_key_here`). Dots and dashes break
  word-selection in editors and terminals.

**Test scenarios:**
Test expectation: none — configuration file, no behavioral change.

**Verification:**
- `cat ~/.claude/CLAUDE.md` shows the operator preferences file
- A new Claude Code session in a different repo applies the preferences
  without a project-level CLAUDE.md present

---

### U2. Create project CLAUDE.md

**Goal:** Restore homelab-specific project instructions to git, updated to
reflect the current 3-node cluster state, with ArgoCD HA noted as pending.

**Requirements:** R2, R3, R4

**Dependencies:** U1 — must know what moved to global before writing the project
file to avoid duplication.

**Files:**
- Create: `CLAUDE.md`

**Approach:**

The project file carries everything that presupposes homelab-k8s context.
Source all sections from the current session's loaded project instructions
with the following changes:

*Carry forward unchanged:*
- Read Before Acting section (all links still valid; add `docs/storage.md`
  reference for storage operations)
- Project Scope
- Core Stack table
- Repository Structure
- Comment Standards (the k8s-specific interpretation)
- GitOps Workflow
- Secrets
- Certificates
- IngressRoutes (including middleware reference table)
- External Services
- Traefik-Specific Notes
- Storage (including Longhorn, SMB CSI, NFS CSI, StorageClasses)
- Naming Conventions
- Helm-Based Apps / Manifest-Based Apps
- *arr Stack
- Authentik
- Shared PostgreSQL
- Shared MariaDB
- WordPress Sites
- Troubleshooting Reference

*Carry forward with changes:*

**Cluster Overview** — update as follows:
- Change node-count line to: `3 HA nodes (k3s; all nodes active as
  control-plane + worker)` — avoids transitional state language that
  becomes stale when topology changes; update the number, not the framing.
- Subnets, DNS, Secrets lines: unchanged
- Remove the entire "When the third node comes online" paragraph
- Add this note after the overview bullet list:
  > **ArgoCD HA migration is pending.** All nodes are active. Follow
  > `docs/argocd-ha-migration.md` to switch ArgoCD to the HA manifest.
  > Also increase the Longhorn replica count for existing volumes via the
  > Longhorn UI or kubectl — new volumes pick up the default automatically.

**Behavior Instructions — Research and correctness:** Keep the k8s-specific
guidance only (container security context research, non-root port assumption,
fsGroup). Remove the general research principles that moved to global
(always check latest docs, research before suggesting, don't repeat failed
steps, research best practices first).

**Behavior Instructions — Communication:** Remove this subsection entirely —
moved to `~/.claude/CLAUDE.md`.

**Behavior Instructions — Values and secrets:** Keep only the k8s/secrets-
workflow-specific items: the kubeseal command format, placeholder underscore
rule, and the two-secret pattern for PostgreSQL apps. Remove the general
principles (private values stay private, single source of truth, no hardcoded
versions) — moved to `~/.claude/CLAUDE.md`.

**Test scenarios:**
Test expectation: none — documentation file.

**Verification:**
- `git status` shows `CLAUDE.md` as a new untracked file
- File opens and reflects 3-node cluster state with no "third node pending"
  language
- New Claude Code session against this repo loads the project instructions
  and shows the updated cluster state

---

### U3. Update README.md deployed apps

**Goal:** Complete the Deployed Applications table and add a MariaDB note
alongside the existing PostgreSQL note.

**Requirements:** R5, R6

**Dependencies:** None

**Files:**
- Modify: `README.md`

**Approach:**

The current table lists Authentik, Manyfold, and arr-stack. Add the following
rows (match existing link-and-backtick formatting):

| Application | Purpose | Namespace |
|---|---|---|
| Open WebUI | Web chat interface for AI models (backed by LiteLLM) | `open-webui` |
| LiteLLM | LLM API proxy — OpenAI-compatible gateway to multiple providers | `litellm` |
| Mealie | Recipe manager and meal planner | `mealie` |
| n8n | Workflow automation | `n8n` |
| SearXNG | Privacy-respecting meta search engine | `searxng` |
| DiceNinjaGaming WordPress | WordPress site for the DiceNinjaGaming blog | `wordpress-dng` |
| Firefly III | Personal finance manager | `firefly3` |
| Leantime | Project management | `leantime` |
| AWS DDNS | Route53 dynamic DNS updater | `aws-ddns` |

Add links to each app name in the table following the same pattern as existing
rows (e.g., `[Open WebUI](https://openwebui.com/)`).

For R6 (MariaDB note): after the paragraph that mentions the CNPG PostgreSQL
cluster, add: "A shared [MariaDB](https://mariadb.org/) cluster (managed by
[mariadb-operator](https://github.com/mariadb-operator/mariadb-operator)) is
also available for apps that require MySQL-compatible storage. See
[docs/mariadb-runbooks.md](docs/mariadb-runbooks.md) for the workflow."

**Test scenarios:**
Test expectation: none — documentation update. Verification by inspection.

**Verification:**
- Table contains 12 rows (3 existing + 9 new)
- MariaDB note appears immediately after the PostgreSQL paragraph
- All app links resolve (spot-check 2-3)

---

### U4. Archive docker-traefik manifests

**Goal:** Preserve the Docker Traefik forwarding manifests in `archived/traefik/`
with archival context so they remain available as migration templates.

**Requirements:** R7, R8

**Dependencies:** None

**Files:**
- Create: `archived/traefik/docker-traefik-forward.yaml`
- Create: `archived/traefik/docker-traefik-catchall.yaml`
- Create: `archived/traefik/README.md`

**Approach:**

Reconstruct the two manifest files from git history:

```
git show 6f7fcdf^:apps/traefik/docker-traefik-forward.yaml
git show 6f7fcdf^:apps/traefik/docker-traefik-catchall.yaml
```

Prepend the following archival header above the original file comments
(retain all original comments beneath it):

```yaml
# ARCHIVED — Docker Traefik migration artifact
#
# Used temporarily during the Docker→Kubernetes Traefik migration
# (removed 2026-04, commit 6f7fcdf). Archived as a reference template
# for anyone performing the same migration.
#
# See archived/traefik/README.md for context.
# See docs/migration-traefik-docker.md for the full migration guide.
#
```

For `archived/traefik/README.md`, follow the pattern of `archived/README.md`:
- What these files are
- What role they played during the migration (catch-all forwarding to Docker
  Traefik while services were being migrated one by one)
- Why they were removed (migration complete — all services now have explicit
  IngressRoute resources)
- Why they are kept (template for anyone performing the same cutover)
- Reference to `docs/migration-traefik-docker.md` for the full guide
- Note that `6f7fcdf^` is the last commit containing the live versions

**Patterns to follow:**
- `archived/README.md` — documentation structure and voice

**Test scenarios:**
Test expectation: none — static archive files. Verification by inspection.

**Verification:**
- `ls archived/traefik/` shows three files
- Each yaml contains both the archival header and the original well-commented content
- `git diff --stat` shows three new files under `archived/traefik/`

---

### U5. Update bootstrap/README.md Step 4 and Step 5

**Goal:** Fix all stale paths and references in Step 4; remove obsolete
docker-traefik apply commands; update Step 5 ArgoCD HA note for 3-node reality.

**Requirements:** R9

**Dependencies:** U4 — `archived/traefik/` must exist before Step 4 references it.

**Files:**
- Modify: `bootstrap/README.md`

**Approach:**

*Step 4 — docker-traefik cleanup (R9):*

Remove the docker-traefik lines and their surrounding explanatory context:

```bash
kubectl apply -f apps/traefik/docker-traefik-forward.yaml
kubectl apply -f apps/traefik/docker-traefik-catchall.yaml
```

Replace the removed block with:

```
> **Docker→Kubernetes migration:** If you are cutting over from an existing
> Docker Traefik instance and need the catch-all forwarding pattern, see
> [`archived/traefik/`](../archived/traefik/) and
> [`docs/migration-traefik-docker.md`](../docs/migration-traefik-docker.md).
```

*Step 4 — fix stale `argocd-app.yaml` path:*

The `TRAEFIK_VERSION` extraction command references `apps/traefik/argocd-app.yaml`
which does not exist. Replace with the correct path:

```bash
# Before:
TRAEFIK_VERSION=$(grep -A1 "chart: traefik" apps/traefik/argocd-app.yaml | grep "targetRevision:" | awk '{print $2}')

# After:
TRAEFIK_VERSION=$(grep -A1 "chart: traefik" apps/manifests/traefik.yaml | grep "targetRevision:" | awk '{print $2}')
```

*Step 4 — fix stale cert and middleware paths:*

Certificates and middlewares have moved to subdirectories. Update all paths:

- `apps/traefik/middleware-*.yaml` → `apps/traefik/middlewares/middleware-*.yaml`
  (applies to: middleware-default-headers, middleware-internal-whitelist,
  middleware-default-whitelist, middleware-https-redirect, middleware-dashboard-auth)
- `apps/traefik/certificate-dng-home-wildcard.yaml` →
  `apps/traefik/certificates/certificate-dng-home-wildcard.yaml`
- `apps/traefik/certificate-dng-root-wildcard.yaml` →
  `apps/traefik/certificates/certificate-dng-root-wildcard.yaml`
- `apps/traefik/tlsstore.yaml`, `apps/traefik/dashboard-auth-sealedsecret.yaml`,
  and `apps/traefik/ingressroute-dashboard.yaml` remain at root — no change.

*Step 5 — update ArgoCD HA note:*

Step 5 currently says "Once a third node is available, follow the instructions
in docs/argocd-ha-migration.md to switch over." Replace with language that
makes node-count conditionality explicit for future operators:

```
> **ArgoCD HA (3-node clusters only):** HA mode requires 3+ nodes for Redis
> quorum. The third node is now active in this cluster. Follow
> [docs/argocd-ha-migration.md](../docs/argocd-ha-migration.md) when ready to
> switch ArgoCD to the HA manifest. On smaller clusters, skip this step.
```

**Test scenarios:**
Test expectation: none — documentation update.

**Verification:**
- `grep -n "docker-traefik" bootstrap/README.md` returns at most the new
  cross-reference line — not the kubectl apply commands
- `grep -n "argocd-app.yaml" bootstrap/README.md` returns no results
- `grep -n "apps/traefik/middleware-\|apps/traefik/certificate-" bootstrap/README.md`
  returns no results (all paths now reference subdirectories)
- Step 4 reads cleanly for a fresh bootstrap with no stale paths
- Step 5 ArgoCD note no longer conditions HA setup on node availability

---

### U6. Bump Longhorn defaultReplicaCount to 3

**Goal:** Align Longhorn's new-volume default with the 3-node cluster topology.

**Requirements:** R10, R11

**Dependencies:** None

**Files:**
- Modify: `apps/longhorn/values.yaml`

**Approach:**

*`defaultSettings.defaultReplicaCount`:*

Change `defaultReplicaCount: 2` to `defaultReplicaCount: 3`.

Update the inline comment: remove cluster-count language entirely (will drift
when topology changes). Replace with: "set to node count for full HA — one
replica per node; update when cluster topology changes. See
`persistence.defaultClassReplicaCount` below — keep these in sync." Retain the
existing notes that:
- Existing volumes do not gain a replica automatically — update via Longhorn UI
  or kubectl
- `replicaAutoBalance: best-effort` rebalances existing replicas across nodes
  but does not increase replica count

*`persistence.defaultClassReplicaCount`:*

Change `defaultClassReplicaCount: 2` to `defaultClassReplicaCount: 3`.

Update the inline comment: remove cluster-count language. Replace with: "set to
node count for full HA — must stay in sync with
`defaultSettings.defaultReplicaCount` above." The current "Keep in sync" note
confirms the coupling; both fields must match or PVCs created via the StorageClass
directly will provision with a different replica count than those hitting the
default settings path.

*`allowVolumeCreationWithDegradedAvailability`:*

Update the inline comment. Remove "Required for a 2-node cluster" language.
Replace with: "Safe to leave enabled permanently — only affects creation-time
replica placement checks. Harmless on any cluster where replica count ≤ node
count."

**Patterns to follow:**
- Existing `apps/longhorn/values.yaml` comment style — inline `#` prose
  explaining the "why" behind each non-default value

**Test scenarios:**
- Happy path: after ArgoCD syncs, a newly-created Longhorn PVC provisions
  with 3 replicas visible in the Longhorn UI
- Unchanged behavior: existing PVCs are unaffected by the values change
  (replica count does not change without explicit action)

**Verification:**
- `grep "defaultReplicaCount\|defaultClassReplicaCount" apps/longhorn/values.yaml`
  returns `3` for both fields
- Neither comment references "2-node cluster" or hardcoded counts
- ArgoCD shows `longhorn` application as `Synced` and `Healthy` after merge

---

## System-Wide Impact

- **CLAUDE.md in repo root:** ArgoCD only manages `apps/manifests/` targets —
  a `CLAUDE.md` in the repo root is invisible to ArgoCD. No cluster impact.
- **Longhorn replica count:** Affects new volume provisioning only. Existing
  PVCs retain their current replica count. The `replicaAutoBalance: best-effort`
  setting will redistribute existing replicas across nodes when topology changes
  but will not increase replica count.
- **Unchanged invariants:** All other `apps/longhorn/values.yaml` fields,
  ArgoCD sync behavior, and the recurring trim job (`apps/longhorn/recurringjob-daily-filesystem-trim.yaml`)
  are unaffected.

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| CLAUDE.md content split loses an important instruction | Split rules documented explicitly in U1/U2 approach sections; review both files against the split boundary before committing |
| Session ends before U1/U2 are executed, losing source material | The approach sections in U1 and U2 carry the full content explicitly — the plan is self-contained |
| Bootstrap README edit loses context a reader needs | Explanatory prose is preserved in `archived/traefik/README.md` and `docs/migration-traefik-docker.md`; cross-reference in Step 4 covers it |
| Longhorn replica increase causes scheduling pressure | Each replica lands on a distinct node by Longhorn's anti-affinity; 3 replicas on a 3-node cluster is the designed configuration |

---

## Sources & References

- **Origin document:** `docs/brainstorms/documentation-currency.md`
- docker-traefik source commit: `6f7fcdf^`
- Archive pattern reference: `archived/README.md`
- ArgoCD HA migration runbook: `docs/argocd-ha-migration.md`
- MariaDB runbook: `docs/mariadb-runbooks.md`
