---
name: mex-integration
type: feat
status: draft
created: 2026-06-16
---

# Requirements: Integrate mex for Persistent Agent Memory

## Problem

The 752-line `CLAUDE.md` is loaded in full every session regardless of the
current task. Most sessions only need a subset — editing a Deployment doesn't
need the WordPress conventions, and working on docs doesn't need the arr-stack
patterns. This wastes context window, burns tokens, and risks agents ignoring
relevant guidance because it's buried in noise.

The existing `.claude/projects/.../memory/` system is ad-hoc — individual
markdown files with no routing, no drift detection, and no systematic structure.

## What We're Building

Migration from the current monolithic CLAUDE.md + ad-hoc memory system to
[mex](https://github.com/theDakshJaitly/mex) — a structured markdown scaffold
with a CLI that provides routing, drift detection, and systematic memory.

## Actors

- **Primary:** Claude Code agent (reads the scaffold every session)
- **Secondary:** Mike (the operator — benefits from structured decisions log
  and drift reports)
- **Tertiary:** Other AI tools (Copilot, Cursor) — mex generates config files
  for each from one source of truth

## Key Flows

### F1. Session startup
Agent reads the thin CLAUDE.md anchor (non-negotiables + ROUTER.md pointer).
ROUTER.md directs the agent to load only the context files relevant to the
current task. Agent narrates what it loads.

### F2. After meaningful work (GROW step)
Agent updates .mex/context/ files with what changed, creates or updates
.mex/patterns/ for recurring tasks, logs decisions to events/decisions.jsonl,
and bumps last_updated timestamps.

### F3. Drift detection
`mex check` runs 11 drift checkers against the scaffold — path validity,
staleness, broken links, index sync, etc. Produces a scored report. `mex sync`
generates targeted prompts for AI to fix only stale components.

### F4. Pre-commit validation (existing, unchanged)
The existing 11-check pre-commit hook suite continues to validate manifest
correctness (sync waves, YAML validity, capabilities, etc.). No overlap with
mex's drift checkers.

## Requirements

### R1: mex scaffold setup
Run `mex setup --mode agent-memory` (or `--dry-run` first) to create the
.mex/ scaffold. Preserve the existing CLAUDE.md by copying it to
`CLAUDE.md.pre-mex` with an extraction annotation before setup overwrites it.

### R2: CLAUDE.md migration
The 752-line CLAUDE.md content is split into mex's context files:
- `context/architecture.md` — cluster overview, core stack, node topology
- `context/conventions.md` — naming conventions, comment standards, sync waves,
  secrets workflow, IngressRoute rules, storage patterns
- `context/decisions.md` — key technical decisions (MetalLB vs kube-vip,
  Traefik vs NGINX, Sealed Secrets vs ESO, local-path vs Longhorn rationale)
- `context/setup.md` — prerequisites, bootstrap order, repository structure
- `context/stack.md` — per-app patterns (arr-stack, Authentik, WordPress,
  PostgreSQL, MariaDB, MongoDB)

Exact mapping deferred to planning phase.

### R3: Non-negotiables in the thin anchor
The thin CLAUDE.md anchor must include these rules (visible in every session
regardless of routing):
- "Never commit plaintext secrets — no exceptions"
- Bypass rules: `HOMELAB_ALLOW_LATEST` and `HOMELAB_ALLOW_MAIN` are for the
  human operator only, Claude must never set them
- "Claude must NEVER use `git commit --amend`"
- Pre-commit hook reference (one-time setup command)
- ROUTER.md pointer

### R4: Memory system replacement
The `.claude/projects/.../memory/` system is replaced by mex's memory model:
- `events/decisions.jsonl` — append-only decision log
- `context/` files — structured project knowledge
- `patterns/` files — reusable task guides

Existing memory file content is migrated into appropriate mex locations.
The `.claude/projects/.../memory/MEMORY.md` index is no longer needed.

### R5: User-facing docs stay in place
These directories are user-facing documentation and must NOT be moved into .mex/:
- `docs/` (runbooks, troubleshooting, storage, migration guides)
- `bootstrap/`
- `README.md`

mex's ROUTER.md references these files where relevant. Agents load them on
demand via the router, not by default.

### R6: AI planning artifacts stay in docs/
These directories are created by the Compound Engineering plugin and stay in
docs/ to avoid modifying the CE skill:
- `docs/brainstorms/`
- `docs/plans/`

mex's ROUTER.md references them. The `docs/solutions/` knowledge base (base-image
security context entries) stays in place — it's used by the image audit skill.

The `docs/superpowers/` directory can be evaluated — it only contains the
MongoDB design doc and may not provide ongoing value.

### R7: Pre-commit hooks coexist with mex drift checkers
The existing 11-check pre-commit hook suite continues unchanged. mex's drift
checkers validate documentation accuracy; the hooks validate manifest
correctness. No overlap, both run.

`mex heartbeat` can be added as a lightweight health check on a schedule.

### R8: Script relocation (separate cleanup)
The `.py` scripts in `scripts/` (audit-manifest-naming.py, check-sync-waves.py,
update-filename-refs.py) are AI maintenance scripts, not user-facing tools.
They should be moved to `.claude/skills/homelab-validate/scripts/` (or a
similar AI-owned location). The `scripts/README.md` is updated accordingly.

This is a separate cleanup, not part of the mex migration itself.

## Scope Boundaries

### In Scope
- Running `mex setup --dry-run` to preview the scaffold
- Preserving CLAUDE.md before setup
- Running `mex setup --mode agent-memory`
- Migrating CLAUDE.md content into .mex/context/ files
- Migrating .claude/memory/ content into mex
- Configuring ROUTER.md to reference user-facing docs
- Running `mex check` to validate the scaffold
- Adding `mex heartbeat` to the workflow

### Deferred for Later
- Agent interoperability (Copilot, Cursor config files) — can add anytime
- `mex watch` (post-commit hook for ongoing monitoring) — add after migration
  is stable
- `mex sync` integration into the development workflow — add after drift
  patterns are understood
- Moving superpowers/ — evaluate after mex is working

### Outside Scope
- Modifying the Compound Engineering plugin (brainstorms/ plans/ locations)
- Modifying pre-commit hooks (they work fine as-is)
- Building custom mex plugins or extending the CLI

## Success Criteria

1. `mex check` reports ≥80/100 on first run after migration
2. Agent sessions load only relevant context (measured by token usage reduction)
3. No content is lost from the original CLAUDE.md during migration
4. Pre-commit hooks continue to pass on all existing manifests
5. The ROUTER.md correctly routes to user-facing docs for operational tasks

## Dependencies / Assumptions

- Node.js ≥ 20 is available (v24.15.0 confirmed)
- npm is available (v11.12.1 confirmed)
- The `.mex/` directory will be committed to git (it's the persistent memory)
- mex's CLAUDE.md template can be customized to include our non-negotiables
- The CE plugin's brainstorms/ and plans/ paths are configurable or we accept
  them in docs/

## Outstanding Questions

1. **mex setup --dry-run behavior** — does it show what would happen to an
   existing CLAUDE.md? We need to verify before running actual setup.
2. **agent-memory mode specifics** — what does `--mode agent-memory` add beyond
   the default setup? The README mentions HEARTBEAT.md and templates but
   details are sparse.
3. **Context file size limits** — does mex have recommendations for how large
   each context file should be? Our conventions alone could be 200+ lines.
4. **Migration tooling** — does mex provide any tooling for migrating existing
   CLAUDE.md content, or is this entirely manual?
