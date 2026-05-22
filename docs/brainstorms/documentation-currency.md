---
date: 2026-05-22
topic: documentation-currency
---

# Documentation Currency

## Summary

A comprehensive documentation pass to close the gap between the live cluster and what's
written. Six discrete changes: split the project instructions into a lean project-scoped
`CLAUDE.md` (back in git) and a portable global `~/.claude/CLAUDE.md`; update the README
deployed apps table; remove obsolete docker-traefik bootstrap steps; and bump Longhorn's
`defaultReplicaCount` to 3 with an updated comment.

---

## Problem Frame

The third cluster node came online and the Docker→Kubernetes migration completed, but the
documentation did not catch up. The project-level `CLAUDE.md` was intentionally removed
from git; cluster state references (node count, migration status) in several files are now
stale; the README's deployed applications table is missing roughly ten apps added since it
was last touched; and the bootstrap guide still tells a new operator to apply forwarding
files that no longer exist. A new session or external reader gets an inaccurate picture of
the cluster.

---

## Requirements

**CLAUDE.md split**

- R1. Create `~/.claude/CLAUDE.md` (global) containing operator preferences that apply
  across all repos: communication style (caveman-mode aside), comment standards
  ("future Mike at 2am"), research-before-acting discipline, general security rules
  (no plaintext secrets), response style preferences (no trailing summaries,
  repo-relative paths, terse).
- R2. Create `CLAUDE.md` at the repo root (committed to git) containing
  homelab-k8s-specific conventions only: cluster overview, repo structure, app
  deployment conventions, storage classes, IngressRoute patterns, Sealed Secrets
  workflow, GitOps rules, Traefik-specific notes, comment standards for this repo.
- R3. Update the cluster overview in the new project `CLAUDE.md` to reflect the
  current 3-node state: remove "currently 2 nodes active; third node pending" and
  replace with "3-node HA (all nodes active)".
- R4. Remove the "When the third node comes online" paragraph from the project
  `CLAUDE.md` cluster overview. Replace with a note that the third node is live
  and the ArgoCD HA migration (`docs/argocd-ha-migration.md`) is still pending.

**README.md deployed apps**

- R5. Update the Deployed Applications table in `README.md` to include all currently
  deployed apps. Missing entries: Open WebUI, LiteLLM, Mealie, n8n, SearXNG,
  DiceNinjaGaming WordPress (`wordpress-dng`), Firefly3, Leantime. Each entry needs
  app name, purpose, and namespace.
- R6. Add a note in `README.md` that a shared MariaDB cluster (mariadb-operator)
  is available alongside CNPG PostgreSQL, following the same per-app database
  pattern. This mirrors the existing PostgreSQL note in the Deployed Applications
  section.

**Bootstrap guide**

- R7. Create `archived/traefik/` and move (or recreate) the two deprecated migration
  manifests there: `docker-traefik-forward.yaml` and `docker-traefik-catchall.yaml`.
  Add a header comment to each file explaining it is a migration artifact — used
  temporarily during the Docker→Kubernetes Traefik cutover and archived for reference
  once the migration was complete.
- R8. Update `archived/traefik/README.md` (create it) explaining the contents: what
  these files did during the migration period, when they were removed, and why they
  are kept for reference (anyone performing the same Docker→Kubernetes migration can
  use them as a template).
- R9. Update `bootstrap/README.md` Step 4 (Traefik): remove the `kubectl apply` lines
  for the two forwarding files. Replace with a brief note pointing readers doing a
  Docker→Kubernetes migration to `archived/traefik/` and `docs/migration-traefik-docker.md`
  for the forwarding pattern.

**Longhorn values**

- R10. Update `apps/longhorn/values.yaml`: change `defaultReplicaCount` from `2`
  to `3`.
- R11. Update the inline comment on `defaultReplicaCount` to remove the "matches
  the current 2-node cluster" language and replace with a note that reflects the
  3-node cluster. Retain the existing note that existing volumes do not gain a
  third replica automatically and must be updated via Longhorn UI or kubectl.

---

## Success Criteria

- A new Claude Code session opened against this repo loads accurate project
  instructions from `CLAUDE.md` without needing to rely on session-cached
  content from a deleted file.
- An operator reading `README.md` gets a complete picture of what's deployed.
- A new operator following `bootstrap/README.md` Step 4 does not attempt to apply
  files that no longer exist in `apps/traefik/`, and can find the migration
  artifacts in `archived/traefik/` if they need them.
- `apps/longhorn/values.yaml` reflects 3-replica intent for new volumes on the
  3-node cluster, with comments that explain the remaining manual step for existing
  volumes.

---

## Scope Boundaries

- ArgoCD HA migration execution is out of scope — operational change documented
  as pending, not performed here.
- Longhorn existing-volume replica rebalancing (via UI or kubectl) is out of scope
  — out-of-band operational step, not a GitOps change.
- Creating new app READMEs (Firefly3, Leantime, n8n, etc.) is out of scope —
  documentation gap but not identified drift from a previously-existing state.
- Content of `docs/argocd-ha-migration.md` is unchanged — the runbook is still
  valid; only the project instructions need to stop treating it as a future event.

---

## Key Decisions

- **CLAUDE.md returns to git (leaner):** Keeping project instructions only in project
  settings means a fresh session or new contributor has no grounding. Returning it
  to git with homelab-specific content only solves this without bloating it with
  portable operator preferences that belong globally.
- **Global CLAUDE.md gets operator preferences:** Communication style, comment
  standards, and security rules are portable. Moving them to `~/.claude/CLAUDE.md`
  means they apply to all repos without repetition.
- **ArgoCD HA documented as pending, not done:** Third node is live but the
  migration hasn't been executed. Documentation should reflect reality — the node
  is available, the migration is a known next step.

---

## Dependencies / Assumptions

- The current session's project instructions (loaded from the now-deleted
  `CLAUDE.md`) are the authoritative source for the content split in R1–R4.
- Third node is confirmed online (user-stated).
- Docker Traefik migration is confirmed complete (user-stated; forwarding files
  already removed from the repo).
- ArgoCD HA migration has not been performed — confirmed by absence of
  `redis-ha` references in `apps/argocd/argocd.yaml`.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R5][Needs research] Confirm namespace for each missing app by scanning
  `apps/manifests/<app>.yaml` — most are obvious but Firefly3 and Leantime should
  be verified.
- [Affects R1][User decision] Any operator preferences beyond those named in R1
  that should move to the global CLAUDE.md vs stay project-specific? Review the
  full content of the current project instructions during planning.
