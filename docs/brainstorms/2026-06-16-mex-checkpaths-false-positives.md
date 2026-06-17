---
name: mex-checkpaths-false-positives
type: fix
status: active
created: 2026-06-16
---

# Problem: mex checkPaths Produces 18 False Positives on Correct Scaffold

## Context

We integrated [mex](https://github.com/theDakshJaitly/mex) (v0.6.1) into the
homelab-k8s repo as a persistent agent memory system. The integration is
complete — `.mex/` scaffold created, 5 context files populated from the
original 752-line CLAUDE.md, ROUTER.md configured with routing table,
decisions log seeded.

The problem: `mex check` returns **0/100** on a correct scaffold because the
`checkPaths` drift checker extracts backtick-wrapped strings from markdown and
tries to resolve them as file paths. In a Kubernetes manifests repo, many
backtick-wrapped strings are config values, annotation keys, IP addresses, and
example filenames — not file paths.

## The Checker's Logic

From mex source code (`src/checkers/checkPaths.ts`):

1. Reads all `.mex/` markdown files
2. Extracts backtick-wrapped strings using regex: `` /`([^`]+)`/g ``
3. For each extracted string, tries to resolve it as a path:
   - Check if it exists at project root
   - Check if it exists at scaffold root (`.mex/`)
   - Check if it exists with `.mex/` prefix
   - Check if it matches a glob pattern
4. If none resolve → `MISSING_PATH` error (−10 points each)
5. For pattern files or placeholder words ("example", "foo") → warning (−3)

The checker has no heuristic for "this is not a path" — every backtick-wrapped
string is treated as a potential path.

## Evidence: Full Error Output

```
Drift score: 0/100 — 18 errors, 7 warnings, 0 info
12 files checked

ERROR

.mex/context/stack.md
  ✗ MISSING_PATH:80 csi.kubeletRootDir: /var/lib/kubelet

.mex/context/setup.md
  ✗ MISSING_PATH:180 csi.kubeletRootDir: /var/lib/kubelet
  ✗ MISSING_PATH:180 sudo ls /var/lib/kubelet/plugins_registry/
  ✗ MISSING_PATH:182 argocd.argoproj.io/sync-wave

.mex/context/decisions.md
  ✗ MISSING_PATH:31 192.168.5.0/24
  ✗ MISSING_PATH:38 forwardedHeaders.trustedIPs: 10.0.0.0/8
  ✗ MISSING_PATH:50 csi.kubeletRootDir: /var/lib/kubelet

.mex/context/conventions.md
  ✗ MISSING_PATH:24 clusterissuer-dng-prod.yaml
  ✗ MISSING_PATH:27 secret-basic-auth.yaml
  ✗ MISSING_PATH:28 unraid.yaml
  ✗ MISSING_PATH:30 secret-basic-auth.yaml
  ✗ MISSING_PATH:55 argocd.argoproj.io/sync-wave
  ✗ MISSING_PATH:152 .yaml
  ✗ MISSING_PATH:152 .yml
  ✗ MISSING_PATH:163-173 (11 script short names — fixed by prefixing full paths)

.mex/context/architecture.md
  ✗ MISSING_PATH:23 apps/manifests/*.yaml
  ✗ MISSING_PATH:48 forwardedHeaders.trustedIPs: 10.0.0.0/8
  ✗ MISSING_PATH:53 csi.kubeletRootDir: /var/lib/kubelet

.mex/SETUP.md
  ✗ MISSING_PATH:227 .mex/sync.sh

WARNING

.mex/patterns/INDEX.md
  ⚠ BROKEN_LINK: filename.md (×3)
  ⚠ BROKEN_LINK: add-api-client.md
  ⚠ BROKEN_LINK: debug-pipeline.md
  ⚠ BROKEN_LINK: crud-operations.md (×2)
```

## Categories of False Positives

### 1. Kubernetes config values (7 errors)

Strings like `csi.kubeletRootDir: /var/lib/kubelet` appear in backticks as
configuration examples. The checker extracts `/var/lib/kubelet` (or the whole
string) and tries to resolve it as a path.

**Files affected:** stack.md, setup.md, decisions.md, architecture.md

**Examples:**
- `csi.kubeletRootDir: /var/lib/kubelet` — Longhorn Helm values
- `forwardedHeaders.trustedIPs: 10.0.0.0/8` — Traefik config
- `sudo ls /var/lib/kubelet/plugins_registry/` — troubleshooting command

### 2. Kubernetes annotation keys (2 errors)

`argocd.argoproj.io/sync-wave` looks like a path to the checker (it has
slashes). It's an ArgoCD annotation key, not a file.

**Files affected:** conventions.md, setup.md

### 3. IP addresses and subnets (2 errors)

`192.168.5.0/24` and `10.0.0.0/8` are network notation. The checker sees
them as paths.

**Files affected:** decisions.md, architecture.md

### 4. Example filenames in naming convention table (3 errors)

The naming convention table in conventions.md uses example filenames to show
the convention:

```
| ClusterIssuers | `clusterissuer-<domain>-<env>.yaml` | `clusterissuer-dng-prod.yaml` |
| Kubernetes manifests | `<kind>-<name>.yaml` | `secret-basic-auth.yaml` |
| External route files | `<service>.yaml` | `unraid.yaml` |
```

These examples exist as real files in the repo (e.g.,
`apps/cert-manager/clusterissuer-dng-prod.yaml`) but not at the repo root
where the checker looks.

**File affected:** conventions.md

### 5. File extensions and glob patterns (3 errors)

- `.yaml` and `.yml` — mentioned in prose about file extensions
- `apps/manifests/*.yaml` — a glob pattern, not a specific file

**Files affected:** conventions.md, architecture.md

### 6. Template placeholder (1 error + 7 warnings)

- `.mex/sync.sh` — referenced in mex's own SETUP.md template but doesn't exist
- `filename.md`, `add-api-client.md`, etc. — placeholder links in
  patterns/INDEX.md template

These are mex's own template issues, not our content.

## Why This Matters

The drift checker and score are a core part of mex's value proposition. A
checker that returns 0/100 on a correct scaffold:

1. **Trains users to ignore the checker** — if the score is always wrong,
   nobody checks it
2. **Makes real drift invisible** — if a context file goes stale, the score
   doesn't change (already 0)
3. **Undermines trust in the tool** — "mex says everything is broken" is worse
   than "mex says nothing is wrong"

## The Deeper Problem: Backticks ≠ Paths

The checker's core assumption — that backtick-wrapped strings are file paths —
is wrong for general markdown usage. Backticks are inline code formatting. They
are used for:

- File paths (`src/auth.ts`) — the only case the checker handles correctly
- Config values (`csi.kubeletRootDir: /var/lib/kubelet`)
- Commands (`sudo ls /var/lib/`)
- Annotation keys (`argocd.argoproj.io/sync-wave`)
- IP addresses (`192.168.5.0/24`)
- Example filenames (`clusterissuer-dng-prod.yaml`)
- Emphasis and technical terms (`drop: [ALL]`, `this is important`)

The mex templates themselves are empty skeletons — no backtick-wrapped content
to trigger false positives. The tool was built for code repos where backtick
strings typically ARE file paths. Nobody has tested it on infrastructure repos
or general documentation where backticks serve many other purposes.

This affects any mex user who writes documentation with inline code formatting
that isn't file paths — not just Kubernetes repos.

## Options for Resolution

### Option A: File upstream issue, wait for fix

File at https://github.com/theDakshJaitly/mex describing the false positive
pattern. Ask for:
- Skip strings that look like IPs (`\d+\.\d+\.\d+\.\d+`)
- Skip strings that look like annotation keys (`\w+\.\w+/\w+`)
- Skip strings that contain `=` or `:` (config values)
- Skip strings that are file extensions (`.yaml`, `.yml`)
- Skip strings in code fences (already done) — extend to skip strings that
  look like shell commands (`sudo`, `ls`, `grep`)

**Pro:** Correct fix, benefits all mex users.
**Con:** Depends on maintainer response. May take weeks.

### Option B: Accept checker is broken, use mex for routing only

Use mex for the scaffold (context files, ROUTER.md, decisions log) but ignore
`mex check` entirely. Rely on existing pre-commit hooks for validation.

**Pro:** No work needed. Scaffold still has value.
**Con:** Loses drift detection — the primary reason we chose mex over a simpler
approach.

### Option C: Fork mex and fix the checker locally

Fork the mex repo, fix checkPaths to be smarter about what constitutes a path,
use the forked version.

**Pro:** Immediate fix, full control.
**Con:** Maintenance burden. Need to track upstream changes.

### Option D: Restructure content to avoid backticks around non-paths

Replace backticks with plain text or code fences for config values, IPs, and
annotation keys. This reduces false positives but hurts readability.

**Pro:** Works with current mex version.
**Con:** Changes documentation style to work around a tool bug. Wrong fix.

### Option E: Use a simpler approach without mex

If drift detection was the primary motivation and it's broken, reconsider
whether mex is the right tool. A ROUTER.md + context files without the mex
CLI gives the same routing and modular context benefits without the broken
checker.

**Pro:** No dependency on a buggy tool.
**Con:** Loses the structured scaffold format, decisions log, and future mex
features.

## Current State

- **Branch:** `feat/mex-integration` (9 commits, not yet pushed)
- **Plan:** `docs/plans/2026-06-16-002-feat-mex-integration-plan.md` (completed)
- **CLAUDE.md:** 19-line thin anchor (replaced 752-line original)
- **CLAUDE.md.pre-mex:** Preserved as rollback point
- **Context files:** 5 files, 627 lines total, populated from CLAUDE.md + memory
- **ROUTER.md:** 14 routing entries for user-facing docs
- **decisions.jsonl:** 5 migration decisions logged
- **mex check score:** 0/100 (18 false positive errors, 7 template warnings)

## Decision Needed

Which option (A–E) to pursue. This decision affects whether the mex
integration ships as-is, gets modified, or gets reverted.
