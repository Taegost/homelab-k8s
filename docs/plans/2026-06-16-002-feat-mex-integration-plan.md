---
type: feat
status: completed
created: 2026-06-16
origin: docs/brainstorms/2026-06-16-mex-integration-requirements.md
---

# feat: Integrate mex for Persistent Agent Memory

## Summary

Migrate from the monolithic 752-line `CLAUDE.md` + ad-hoc `.claude/projects/.../memory/`
system to [mex](https://github.com/theDakshJaitly/mex) — a structured markdown
scaffold with routing, drift detection, and systematic memory. Uses
`mex setup --mode agent-memory` for operational environment framing.

## Problem Frame

See origin: `docs/brainstorms/2026-06-16-mex-integration-requirements.md`

Every session loads the full 752-line CLAUDE.md regardless of task. The memory
system is ad-hoc files with no routing or drift detection.

## Requirements

All requirements defined in the origin document (R1–R8). Summary:

- **R1:** mex scaffold setup with `--mode agent-memory`
- **R2:** CLAUDE.md content migrated into .mex/context/ files
- **R3:** Non-negotiables in the thin CLAUDE.md anchor
- **R4:** Memory system replaced by mex
- **R5:** User-facing docs stay in place
- **R6:** AI planning artifacts stay in docs/
- **R7:** Pre-commit hooks coexist with mex drift checkers
- **R8:** Python scripts relocated from scripts/ to .claude/skills/

## Key Technical Decisions

### KTD-1: Let mex handle the content mapping

mex's `setup --mode agent-memory` creates empty scaffold files and generates an
AI population prompt. The AI reads the preserved CLAUDE.md and populates the
context files using mex's own logic and framing. We verify after, rather than
manually mapping 752 lines into 5 context files.

**Rationale:** mex's agent-memory mode has nuanced semantics for each context
file (e.g., architecture.md maps to "services, machines, containers, automations"
not software architecture). Manual mapping would fight mex's framing.

### KTD-2: CLAUDE.md is skipped, not overwritten

mex's actual behavior (verified in source code) is to skip existing CLAUDE.md
with "already exists — skipped (delete it first to replace)". The dry-run
message "Would overwrite" is misleading. We do NOT delete CLAUDE.md before
setup. Instead:

1. Run `mex setup --mode agent-memory` — it creates the .mex/ scaffold and
   skips CLAUDE.md
2. The preserved CLAUDE.md stays as the active anchor during migration
3. After migration is verified, we replace CLAUDE.md with the thin mex anchor

### KTD-3: Preserve CLAUDE.md as CLAUDE.md.pre-mex

Before any setup, copy CLAUDE.md to CLAUDE.md.pre-mex with an extraction
annotation. This is the source material for the AI population prompt and a
rollback point if migration fails.

### KTD-4: Drift checker scope

mex has 11 drift checkers. Several are npm-focused (checkCommands,
checkDependencies, checkScriptCoverage) and won't fire on this Kubernetes repo.
The relevant checkers are: checkPaths, checkEdges, checkIndexSync,
checkStaleness, checkCrossFile, checkToolConfigSync, checkTodoFixme,
checkBrokenLinks. We accept this and note it as a known limitation.

### KTD-5: ROUTER.md references user-facing docs

After mex populates the context files, we configure ROUTER.md to reference
user-facing docs (docs/, bootstrap/, README.md) for operational tasks. Agents
load these on demand via the router, not by default.

## Implementation Units

### U8. Relocate Python scripts from scripts/

**Goal:** Move AI maintenance scripts to an AI-owned location before the
mex migration, so the repo is clean when the scaffold is created.

**Requirements:** R8

**Dependencies:** None

**Note:** The origin doc marks R8 as "a separate cleanup, not part of the mex
migration itself." This unit executes first for convenience — it's a small,
low-risk change that cleans up the repo before the scaffold is created. If
preferred, it can be extracted to a separate plan/PR.

**Files:**
- `.claude/skills/homelab-validate/scripts/audit-manifest-naming.py` (move from scripts/)
- `.claude/skills/homelab-validate/scripts/check-sync-waves.py` (move from scripts/)
- `.claude/skills/homelab-validate/scripts/update-filename-refs.py` (move from scripts/)
- `scripts/README.md` (modify — remove Python script docs)
- `.claude/skills/homelab-validate/SKILL.md` (modify — add moved scripts if relevant)

**Approach:**

1. Move the 3 .py files to `.claude/skills/homelab-validate/scripts/`
2. Update usage examples in each script's docstring to reflect the new path
3. Update scripts/README.md to remove Python script documentation (keep
   longhorn-pvc-report.sh and wp-migration.yaml docs)
4. Update any references to the old paths (grep for the filenames across the repo)
5. Verify the scripts still work from the new location

**Verification:** `grep -rn 'scripts/audit-manifest-naming\|scripts/check-sync-waves\|scripts/update-filename-refs' .` returns zero results outside `docs/plans/` (historical plan references are expected and do not need updating).

### U1. Preserve CLAUDE.md and run mex dry-run

**Goal:** Create a rollback point and preview what mex would do.

**Requirements:** R1, R3

**Dependencies:** None

**Files:**
- `CLAUDE.md.pre-mex` (create — copy of current CLAUDE.md)
- `CLAUDE.md` (unchanged — stays as active anchor during migration)

**Approach:**

1. Copy CLAUDE.md to CLAUDE.md.pre-mex
2. Add extraction annotation at the top of CLAUDE.md.pre-mex:
   ```
   <!-- PRESERVED FOR MEX MIGRATION — this file is the source material
        for populating .mex/context/ files. Delete after migration is verified. -->
   ```
3. Run `npx mex-agent setup --mode agent-memory --dry-run` to preview
4. Verify the dry-run output: confirm it would create the 13 scaffold files
   and skip CLAUDE.md

**Test expectation:** none — this is a preservation and preview step.

### U2. Run mex setup

**Goal:** Create the .mex/ scaffold with agent-memory templates.

**Requirements:** R1

**Dependencies:** U1

**Files:**
- `.mex/config.json` (create)
- `.mex/AGENTS.md` (create)
- `.mex/ROUTER.md` (create)
- `.mex/HEARTBEAT.md` (create)
- `.mex/SETUP.md` (create)
- `.mex/SYNC.md` (create)
- `.mex/context/architecture.md` (create)
- `.mex/context/stack.md` (create)
- `.mex/context/conventions.md` (create)
- `.mex/context/decisions.md` (create)
- `.mex/context/setup.md` (create)
- `.mex/patterns/README.md` (create)
- `.mex/patterns/INDEX.md` (create)

**Approach:**

1. Run `npx mex-agent setup --mode agent-memory`
2. When prompted for AI tool, select Claude Code (option 1). The command is
   interactive — it halts at "Which AI tool do you use?" waiting for input.
3. mex creates the .mex/ scaffold and skips CLAUDE.md (it already exists)
4. mex generates a population prompt — save it for U3
5. Verify all 12 .md scaffold files were created (plus `.mex/config.json`
   which mex creates silently — it won't appear in the dry-run output)
6. Review created files — add any local-only artifacts to .gitignore if
   mex generates files that shouldn't be committed (e.g., cache files)

**Test expectation:** none — scaffold creation is mex's responsibility.

### U3. Populate .mex/context/ files from CLAUDE.md

**Goal:** Migrate the 752-line CLAUDE.md content into mex's modular context files.

**Requirements:** R2

**Dependencies:** U2

**Files:**
- `.mex/context/architecture.md` (modify — populate from CLAUDE.md)
- `.mex/context/stack.md` (modify — populate from CLAUDE.md)
- `.mex/context/conventions.md` (modify — populate from CLAUDE.md)
- `.mex/context/decisions.md` (modify — populate from CLAUDE.md)
- `.mex/context/setup.md` (modify — populate from CLAUDE.md)

**Approach:**

Use mex's population prompt (generated in U2) as guidance. The AI reads
CLAUDE.md.pre-mex and the memory files from `~/.claude/projects/-home-taegost--ws-homelab-k8s/memory/`
and populates each context file using mex's agent-memory framing:

Memory file mapping:

| Memory file | Destination |
|---|---|
| `feedback-rename-discipline.md` | `.mex/context/conventions.md` |
| `feedback-sync-waves.md` | `.mex/context/conventions.md` |
| `feedback-security-context-audit.md` | `.mex/context/conventions.md` |
| `feedback-walkthrough-discipline.md` | `.mex/context/conventions.md` |
| `gitops-no-kubectl-apply.md` | `.mex/context/conventions.md` |
| `project-librechat-networkpolicy-hardening.md` | `.mex/context/stack.md` |

CLAUDE.md.pre-mex section mapping:

- `architecture.md` → cluster overview, core stack, node topology, networking,
  storage architecture
- `stack.md` → per-app patterns (arr-stack, Authentik, WordPress, PostgreSQL,
  MariaDB, MongoDB), container images, Helm charts
- `conventions.md` → naming conventions, comment standards, sync wave reference,
  secrets workflow, IngressRoute rules, storage patterns, pre-commit verification
- `decisions.md` → key technical decisions (MetalLB vs kube-vip, Traefik vs
  NGINX, Sealed Secrets vs ESO, local-path vs Longhorn rationale, certificate
  namespace strategy)
- `setup.md` → prerequisites, bootstrap order, repository structure, how to add
  new apps

After population, verify no content was lost by comparing against CLAUDE.md.pre-mex.

**Verification:** Every section of CLAUDE.md.pre-mex appears in at least one
.mex/context/ file. Every memory file's content appears in the appropriate
.mex/context/ file (per the mapping table above). No content is silently dropped.

### U4. Configure the thin CLAUDE.md anchor

**Goal:** Replace the 752-line CLAUDE.md with a thin anchor containing
non-negotiables and the ROUTER.md pointer.

**Requirements:** R3

**Dependencies:** U3 (content must be in .mex/context/ before we replace the anchor)

**Files:**
- `CLAUDE.md` (replace — thin anchor)

**Approach:**

Replace CLAUDE.md with a thin anchor (~30 lines) containing:

1. Non-negotiables (visible in every session):
   - "Never commit plaintext secrets — no exceptions"
   - Bypass rules: `HOMELAB_ALLOW_LATEST` and `HOMELAB_ALLOW_MAIN` are for the
     human operator only, Claude must never set them
   - "Claude must NEVER use `git commit --amend`"
   - Pre-commit hook setup: `ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit`
2. ROUTER.md pointer: "At the start of every session, read `.mex/ROUTER.md`
   before doing anything else. Its routing table entries are mandatory
   pre-action reads — before implementing any change, load the relevant
   context file."
3. Link to CLAUDE.md.pre-mex for reference during transition

**Verification:** The anchor is under 40 lines. All non-negotiables from the
original CLAUDE.md are present. The ROUTER.md pointer is correct.

**Rollback:** If agent behavior degrades after replacing CLAUDE.md (missed
conventions, broken manifests, safety rules not loaded), restore the original
by copying CLAUDE.md.pre-mex back to CLAUDE.md and committing. This is a
single commit. Verify pre-commit hooks still pass after rollback. The .mex/
scaffold can remain — it's harmless if unused.

### U5. Configure ROUTER.md to reference user-facing docs

**Goal:** ROUTER.md directs agents to load user-facing docs on demand for
operational tasks.

**Requirements:** R5

**Dependencies:** U3

**Files:**
- `.mex/ROUTER.md` (modify)

**Approach:**

Add routing table entries that reference user-facing docs:

| Task type | File to load |
|---|---|
| Deploying a new app with Postgres | `docs/postgres-runbooks.md` |
| Deploying a new app with MariaDB | `docs/mariadb-runbooks.md` |
| Deploying a new app with MongoDB | `docs/mongodb-runbooks.md` |
| Sealed secrets workflow | `docs/sealed-secrets.md` |
| Cluster recovery or node loss | `docs/disaster-recovery.md` |
| DNS or networking issues | `docs/troubleshooting.md` |
| Storage utilisation or trim jobs | `docs/storage.md` |
| n8n HA migration (S3, queue mode) | `docs/n8n-ha-migration.md` |
| ArgoCD HA migration | `docs/argocd-ha-migration.md` |
| External service routing | `apps/traefik/external/README.md` |
| Bootstrap from scratch | `bootstrap/README.md` |
| Pre-commit validation scripts | `.claude/skills/homelab-validate/SKILL.md` |
| Image security context audit | `.claude/skills/homelab-image-audit/SKILL.md` |
| Planning artifacts | `docs/plans/`, `docs/brainstorms/` |

**Verification:** Each routing entry points to an existing file. Agents can
navigate from ROUTER.md to the correct doc for any operational task.

### U6. Seed decisions log and clean up memory references

**Goal:** Seed `.mex/events/decisions.jsonl` with key decisions. The old
memory files in `~/.claude/` remain untouched — they are global Claude Code
config, not repo-scoped, and can be cleaned up manually after migration is
verified.

**Requirements:** R4

**Dependencies:** U3

**Files:**
- `.mex/events/decisions.jsonl` (create — seed with key decisions)

**Approach:**

The `.claude/projects/.../memory/` files live in `~/.claude/` (global Claude
Code config, outside the repo). Their content is already available to the AI
via the system prompt and was absorbed into .mex/context/ files during U3's
population step. No explicit file copy is needed.

1. Create `.mex/events/` directory if it doesn't exist
2. Seed `decisions.jsonl` with key decisions from the brainstorm session
   (mex integration approach, CLAUDE.md migration strategy)
3. The old memory files in `~/.claude/projects/.../memory/` remain untouched —
   they are global Claude Code config, not repo-scoped. They can be cleaned up
   manually after the migration is verified.

**Verification:** `.mex/events/decisions.jsonl` exists and has at least one
entry. Run `mex check` after creating events/ to confirm the new directory
doesn't cause drift warnings — if it does, add events/ to ROUTER.md.

### U7. Run mex check and fix drift

**Goal:** Validate the scaffold achieves ≥80/100 on first run.

**Requirements:** Origin success criteria #1 (mex check ≥80/100)

**Dependencies:** U3, U4, U5, U6

**Files:**
- `.mex/` files (modify — fix any drift issues found)

**Approach:**

1. Run `npx mex-agent check` and capture the scored report
2. Fix errors (−10 each): broken paths, dead edges, cross-file conflicts
3. Fix warnings (−3 each): stale files, index sync, TODO/FIXME markers
4. Re-run `mex check` until score is ≥80/100
5. Note any npm-focused checkers that produce no output (expected — no
   package.json in this repo)

**Verification:** `mex check` reports ≥80/100.

---

## Risks & Dependencies

- **mex npm package availability** — `npx mex-agent setup` requires the `mex-agent`
  npm package. If the registry is unavailable, setup fails. Mitigation: `npm install -g mex-agent` as fallback.
- **Population prompt quality** — mex's AI population prompt drives the context
  file filling. If the prompt doesn't produce good output, manual intervention
  is needed. Mitigation: verify each context file against CLAUDE.md.pre-mex.
- **Drift checker relevance** — 3 of 11 drift checkers are npm-focused and
  won't fire. This is acceptable for a Kubernetes repo but means some drift
  categories (undocumented scripts, dependency version mismatches) aren't caught.
- **CLAUDE.md anchor size** — the thin anchor must be under ~40 lines to achieve
  the context bloat reduction goal. If non-negotiables grow, the anchor bloats.
- **mex checkPaths false positives** — mex's `checkPaths` checker extracts
  backtick-wrapped strings and tries to resolve them as file paths. In a
  Kubernetes manifests repo, backticks wrap config values, annotation keys, IP
  addresses, and example filenames — none of which are file paths. This produces
  ~18 false-positive errors on every `mex check` run. This is a mex bug, not a
  documentation problem. The score reads 0/100 but the scaffold is correct.
  Upstream issue should be filed at https://github.com/theDakshJaitly/mex.

## Verification

1. `mex check` reports ≥80/100
2. Agent sessions load only relevant context — after migration, start a new
   session and verify the agent reads ROUTER.md and loads the correct context
   file for the task (not the full 752-line CLAUDE.md)
3. No content lost from original CLAUDE.md (compare against CLAUDE.md.pre-mex)
4. Pre-commit hooks continue to pass
5. Python scripts work from new location

## Deferred / Open Questions

From origin document:
- **mex setup --dry-run behavior** — verified: it shows "Would overwrite CLAUDE.md"
  but actual behavior is to skip. Not a blocker.
- **agent-memory mode specifics** — verified: uses agent-memory templates for
  AGENTS.md, ROUTER.md, HEARTBEAT.md; skips codebase scanner; uses operational
  framing. Not a blocker.
- **Context file size limits** — no explicit limits found in mex source. Large
  files (200+ lines) are acceptable as long as they're well-structured.
- **Migration tooling** — none exists. The AI population prompt is the migration
  mechanism. Not a blocker.

Deferred to later:
- Agent interoperability (Copilot, Cursor config files)
- `mex watch` (post-commit hook for ongoing monitoring)
- `mex sync` integration into the development workflow
- Moving superpowers/ directory
- Deleting CLAUDE.md.pre-mex after verification period
