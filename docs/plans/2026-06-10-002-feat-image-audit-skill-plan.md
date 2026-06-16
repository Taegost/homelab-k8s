---
type: feat
status: completed
created: 2026-06-10
origin: docs/plans/2026-06-10-001-feat-pre-commit-validation-scripts-plan.md
---

# feat: Image Audit Skill and Base-Image Knowledge Base

## Summary

Replace the ad-hoc Dockerfile audit step in CLAUDE.md research rules with a repeatable tool: a knowledge base doc mapping base images to securityContext requirements, and a skill script that cross-references it to produce concrete recommendations. The annotation-based approach for derived-image detection was considered and rejected — with only 2 nginx-derived images in the cluster, a KB is simpler and scales better than per-Deployment annotations.

## Problem Frame

The CLAUDE.md research rules mandate checking an image's Dockerfile for `USER`, port, entrypoint behavior, and capability needs before writing manifests. This is a manual, error-prone step — the Plane debugging session proved it gets skipped during rapid iteration. The planned `capability-check.sh` catches the result but not the root cause.

A knowledge base that accumulates known image patterns plus a structured audit script makes the research step repeatable. The operator (or Claude) runs the audit when adding a new Deployment; the script cross-references the KB and outputs a securityContext recommendation.

## Requirements

- **R1:** Create a base-image KB doc mapping image types to required capabilities, privilege-drop patterns, and gotchas
- **R2:** Create an image-audit script that takes an image identifier and cross-references the KB to output a securityContext recommendation
- **R3:** Integrate the audit script into the CLAUDE.md research workflow so it's the default path for new Deployments
- **R4:** The KB must cover all image types currently deployed in the cluster (nginx, RabbitMQ, Redis/Valkey, busybox, and the generic root-image case)

## Key Technical Decisions

### KTD-1: KB-driven pattern matching, not registry inspection

The audit script matches image names against KB pattern lists — it does NOT pull image layers or scrape container registries. Rationale:

- Registry inspection adds network dependency and is slow
- Many images don't expose their Dockerfile at a predictable URL
- The operator already knows (or can quickly check) what the image's runtime is

The script presents a decision tree: "What's the base image?" → "Does it drop from root to a non-root user?" → "What port does it listen on?" → outputs recommendation.

### KTD-2: KB doc lives at `docs/solutions/`, one file per image type

Following the `docs/solutions/` convention for institutional knowledge. Each entry is a standalone markdown file with a consistent structure: image patterns, required capabilities, privilege model, port conventions, gotchas. The audit script reads these as its source of truth.

### KTD-3: KB and script work for both human operators and Claude

The KB is readable standalone (`docs/solutions/base-images-nginx.md`). The audit script wraps it with interactive prompting for humans and can be called non-interactively by Claude (passing `--image <name>` and `--type <nginx|rabbitmq|...>` to skip prompts).

### KTD-4: KB covers explicit images AND derived images

nginx entry covers both explicit `nginx:` images and known derived images (`makeplane/plane-admin`, `makeplane/plane-frontend`). Each entry has an "Image patterns" field listing substrings to match. The audit script's `--image` flag checks against these patterns first before falling back to interactive mode.

## Scope Boundaries

### In Scope
- KB entries for nginx, RabbitMQ, Redis/Valkey, and the generic root-image case
- Audit script at `.claude/skills/homelab-image-audit/`
- CLAUDE.md research rules updated to reference the audit script

### Deferred to Follow-Up Work
- KB entries for additional image types as they are deployed (PostgreSQL, MySQL, MongoDB)
- Capability-check.sh alignment — ensure the KB and the pre-commit script agree on required capabilities
- Automated Dockerfile fetching for images hosted on GitHub (e.g., scrape `https://github.com/<org>/<repo>/blob/<tag>/Dockerfile`)
- **Auto-discover KB entries:** ~~The audit script hardcodes a TYPE_TO_KB map.~~ **RESOLVED** — `audit.sh` now auto-discovers KB entries via `_discover_kb()`, scanning `docs/solutions/` at startup. Adding a new image type is a single-file operation.
- **Valkey alias:** ~~`--type valkey` should map to the same KB as `--type redis`.~~ **RESOLVED** — `TYPE_ALIASES` maps `valkey` and `redis` to the canonical `redis-valkey` type. Both `--type redis` and `--type valkey` work.
- **KB as capability source of truth:** ~~`capability-check.sh` should read requirements from `docs/solutions/` instead of hardcoding them.~~ **RESOLVED** — Origin plan (001) U2 updated to reference KB-based capability lookup with auto-discovery.

### Outside Scope
- Modifying existing Deployments to add missing capabilities
- Registry-based layer inspection
- Automatic securityContext generation from audit output

## Implementation Units

### U1. Create base-image knowledge base entries

**Goal:** Document securityContext requirements for all image types in the cluster.

**Requirements:** R1, R4.

**Dependencies:** None.

**Files:**
- `docs/solutions/base-images-nginx.md` (create)
- `docs/solutions/base-images-rabbitmq.md` (create)
- `docs/solutions/base-images-redis-valkey.md` (create)
- `docs/solutions/base-images-root-generic.md` (create)

**Approach:** Each entry follows a consistent structure:

```markdown
# <Image Type> Security Context

## Image patterns
- `nginx:*`, `nginx:` (explicit)
- `makeplane/plane-admin`, `makeplane/plane-frontend` (derived, nginx-based)

## Required capabilities (when `drop: [ALL]`)
| Capability | Why |
|---|---|
| CHOWN | entrypoint chowns cache dirs to runtime user |
| SETGID | workers call setgid() to drop from root |
| SETUID | workers call setuid() to drop from root |

## Privilege model
Starts as root, drops to UID 101 (nginx user) via setgid/setuid in worker processes.
Without SETGID/SETUID, workers crash with "setgid(101) failed".

## Port
Defaults to 80 (privileged). Non-root or derived images may use 8080.

## Gotchas
- Derived images (makeplane/plane-*) don't name nginx in the image field
- If the entrypoint runs nginx workers as a fixed non-root user without setgid/setuid calls, capabilities are not needed (Leantime pattern)
```

Content sourced from the Plane debugging session (`docs/troubleshooting/troubleshooting-plane.md`), CLAUDE.md capability documentation, and existing Deployment securityContext comments.

**Patterns to follow:** The `docs/solutions/` convention (when established). Until then, stand-alone markdown with clear sections and concrete capability tables.

**Test scenarios:**
1. Read `base-images-nginx.md` — contains "Image patterns" section, required capabilities table (CHOWN, SETGID, SETUID), privilege model, port, gotchas
2. Read `base-images-rabbitmq.md` — contains required capabilities table (CHOWN, DAC_OVERRIDE, SETGID, SETUID) with rationale
3. Read `base-images-redis-valkey.md` — documents non-root (UID 999), no capabilities needed, gotcha about the Redis/Valkey rename
4. Read `base-images-root-generic.md` — covers privilege-drop entrypoint detection (gosu, su-exec, su, chroot) and WARN recommendation

**Verification:** Each KB entry covers all capability requirements documented in existing Deployment comments and troubleshooting docs. No entry contradicts another.

### U2. Create image-audit script

**Goal:** A script that, given an image name, cross-references the KB and outputs a securityContext recommendation.

**Requirements:** R2.

**Dependencies:** U1 (KB must exist before the script can reference it).

**Files:**
- `.claude/skills/homelab-image-audit/audit.sh` (create)
- `.claude/skills/homelab-image-audit/SKILL.md` (create)

**Approach:** Shell script with two modes:

**Interactive mode** (no flags, for human operators):
1. Prompt: "Image name?"
2. Check image name against KB pattern lists. If match found, present the matched type and skip to step 5.
3. Prompt: "Base image type? [nginx / rabbitmq / redis/valkey / postgres / mysql / mongodb / alpine / other]"
4. If "other," prompt: "Entrypoint behavior? [root-to-nonroot drop / fully non-root / runs as root]"
5. Cross-reference KB entry for the matched type
6. Output: recommended securityContext block (drop, add, runAsUser, runAsNonRoot, fsGroup if applicable)
7. Output: gotchas and port note

**Non-interactive mode** (`--image <name> --type <type>`, for Claude):
1. Check `--image` against KB pattern lists
2. Cross-reference `--type` KB entry
3. Output recommendation without prompts

The script does zero network I/O — it only reads local KB files.

**Patterns to follow:** The existing validation script conventions — `set -euo pipefail`, clear section headers, PASS/FAIL/WARN output format adapted for recommendations.

**Test scenarios:**
1. `audit.sh --image nginx:1.29-alpine --type nginx` → outputs capability table with CHOWN, SETGID, SETUID. Notes that official nginx listens on port 80 (privileged, needs NET_BIND_SERVICE if binding there), while derived/non-root images commonly remap to 8080 — cross-reference the Deployment's `containerPort` to determine which applies
2. `audit.sh --image makeplane/plane-admin:v1.3.1 --type nginx` → matches derived-image pattern, outputs same nginx recommendation
3. `audit.sh --image rabbitmq:3.13-management --type rabbitmq` → outputs CHOWN, DAC_OVERRIDE, SETGID, SETUID
4. `audit.sh --image redis:8-alpine --type redis` → outputs "No capabilities required. Runs as UID 999 (non-root). drop: [ALL] is safe."
5. Interactive mode: input `busybox:1.36`, select "other" → "runs as root" → outputs WARN about privilege-drop patterns
6. `audit.sh --image unknown-image:latest` (no KB match, no --type) → exits with guidance to run interactively or provide --type

### U3. Integrate into CLAUDE.md research workflow

**Goal:** Make the audit script the default path for securityContext research.

**Requirements:** R3.

**Dependencies:** U2 (script must exist).

**Files:**
- `CLAUDE.md` (modify) — update Research and correctness section

**Approach:** Add a bullet to the "Research container security context" rule: "When adding a new Deployment, run `.claude/skills/homelab-image-audit/audit.sh --image <image> --type <type>` before writing the securityContext. If the image type is unknown, run in interactive mode." Keep the existing Dockerfile research rule as the fallback for images not in the KB.

**Test scenarios:**
1. Read CLAUDE.md Research section — audit script referenced as primary path for securityContext determination
2. Read CLAUDE.md Research section — Dockerfile audit remains as fallback for unlisted images

## Risks & Dependencies

- **KB drift:** The KB must stay in sync with actual image behavior. If an image updates its entrypoint (e.g., nginx moves to fully non-root), the KB becomes outdated. Mitigation: KB entries cite the image version and Dockerfile URL where the information was sourced.
- **capability-check.sh alignment:** The KB and the planned `capability-check.sh` must agree on required capabilities. If they diverge, the audit recommends one set and pre-commit enforces another. Mitigation: U3 of this plan is to reference the audit script from research rules; a follow-up deferred item ensures KB and capability-check.sh stay in sync.
- **Limited coverage:** The KB starts with 4 image types (nginx, RabbitMQ, Redis/Valkey, root-generic). Images outside these types fall through to the existing manual research rules.

## Verification

1. Run `audit.sh --image nginx:1.29-alpine --type nginx` → matches CHOWN, SETGID, SETUID from KB
2. Run `audit.sh --image makeplane/plane-admin:v1.3.1 --type nginx` → derived-image pattern match, same output
3. Run `audit.sh` interactively with `redis:8-alpine` → correctly identifies as Redis/Valkey, recommends no capabilities
4. Read `docs/solutions/base-images-nginx.md` → covers all capabilities documented in `docs/troubleshooting/troubleshooting-plane.md`
5. Read CLAUDE.md → research rules reference audit script as primary path

## Sources & Research

Findings from repo-research-analyst and learnings-researcher (ce-plan Phase 1):

- Plane Deployment debugging documented in `docs/troubleshooting/troubleshooting-plane.md` lines 63-131 — nginx and RabbitMQ capability requirements
- Existing Deployment securityContext comments in `apps/plane/deployment-plane-admin.yaml`, `apps/plane/deployment-plane-web.yaml`, `apps/plane/deployment-rabbitmq.yaml`
- Redis/Valkey pattern: UID 999, `drop: [ALL]`, no added capabilities — confirmed across 5 Deployments
- Leantime fully non-root nginx pattern: `docs/plans/2026-06-10-001-feat-pre-commit-validation-scripts-plan.md` U2
- Only 2 nginx-derived images exist: `makeplane/plane-admin` and `makeplane/plane-frontend`
