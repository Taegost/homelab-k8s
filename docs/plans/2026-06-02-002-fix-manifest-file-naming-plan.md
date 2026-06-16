---
title: "fix: Rename manifest files to match documented naming conventions"
type: fix
status: completed
date: 2026-06-02
---

## Summary

Create a Python audit script, then use it to verify 16 naming convention
violations across 8 app directories before renaming them to match the
`<kind>-<resource-name>.yaml` and `sealedsecret-<name>.yaml` conventions
documented in CLAUDE.md. Update all filename references in manifests,
runbooks, bootstrap docs, and CLAUDE.md itself. Remove the stale
`smb-multimedia` StorageClass section from CLAUDE.md.

## Problem Frame

CLAUDE.md documents a naming convention for all Kubernetes manifests:
`<kind>-<resource-name>.yaml` (e.g., `deployment-mealie.yaml`,
`ingressroute-bazarr.yaml`). An audit found 16 files that violate this
convention. Common violation patterns:

- **Missing resource name** — `deployment.yaml` instead of
  `deployment-<app>.yaml` (7 files across arr-stack, open-webui)
- **Missing resource name** — `ingressroute.yaml` instead of
  `ingressroute-<app>.yaml` (argocd, longhorn)
- **Kind shorthand or abbreviation** — `argocd-cmd-params-cm.yaml` uses `cm`
  for ConfigMap; `cluster-mongodb.yaml` uses `cluster` for CRD kind
  `PerconaServerMongoDB`
- **Suffix form** — `dashboard-auth-sealedsecret.yaml` has the prefix after
  the name instead of before it (`sealedsecret-dashboard-auth.yaml`)
- **Missing resource name** — `namespace.yaml`, `tlsstore.yaml`,
  `ipaddresspool.yaml`, `l2advertisement.yaml`

Additionally, `smb-multimedia` is documented as a StorageClass in CLAUDE.md
but the corresponding file was never created — the multimedia share uses a
static PV with `storageClassName: ""` instead.

Excluded from scope: multi-resource install manifests
(`apps/argocd/argocd.yaml`, `apps/cert-manager/cert-manager.yaml`,
`apps/metallb/metallb.yaml`,
`apps/sealed-secrets/sealed-secrets-controller.yaml`), Helm `values.yaml`
files, ArgoCD Application manifests in `apps/manifests/` (which follow a
separate "named after the app directory" convention), and external route
files in `apps/traefik/external/` (which follow the `<service-name>.yaml`
convention). Only the general `<kind>-<resource-name>.yaml` and
`sealedsecret-<name>.yaml` conventions are being enforced.

## Requirements

- R1. Every committed single-resource Kubernetes manifest under `apps/`
  follows the `<kind>-<resource-name>.yaml` convention.
- R2. Every committed SealedSecret file follows the `sealedsecret-<name>.yaml`
  convention.
- R3. All filename references in manifests, runbooks, bootstrap docs, skills,
  and CLAUDE.md are updated to match the renamed files.
- R4. CLAUDE.md no longer references the non-existent `smb-multimedia`
  StorageClass.
- R5. No application behavior, resource names, or Kubernetes object metadata
  changes — this is a filename-only change.
- R6. ArgoCD continues to sync all applications without errors after the
  renames.

## Key Technical Decisions

- **Full CRD kind for MongoDB, not shorthand.**
  `cluster-mongodb.yaml` → `perconaservermongodb-mongodb.yaml`.
  The convention is `<kind>-<resource-name>.yaml`; the CRD kind is
  `PerconaServerMongoDB`. Using `cluster` as shorthand is inconsistent with
  the convention even though `cluster-postgres.yaml` uses `Cluster` (which
  happens to be CNPG's actual `kind` value). Decision: use the exact CRD kind,
  lowercased.
- **Rename only; no resource content changes.**
  All `metadata.name`, `spec.selector`, and other Kubernetes object fields
  stay identical. Only the filename changes. ArgoCD syncs directories, not
  individual filenames, so this is safe.
- **Historical plans and design specs are not updated.**
  Completed plans in `docs/plans/`, `docs/superpowers/plans/`, and
  `docs/superpowers/specs/` are historical records of what was true at plan
  time. They are not updated. Active docs (runbooks, bootstrap, skills,
  CLAUDE.md) are updated.

## Scope Boundaries

### In scope
- Python audit/verification script (`scripts/audit-manifest-naming.py`)
- 16 file renames across 8 app directories
- ~20 reference updates in active documentation and manifest comments
- Removal of stale `smb-multimedia` StorageClass section from CLAUDE.md
- `deployment.yaml` → `deployment-<app-name>.yaml` template update in CLAUDE.md
- Pre-commit sync wave verification

### Deferred to Follow-Up Work
- `docs/plans/`, `docs/superpowers/plans/`, and `docs/superpowers/specs/`
  historical references — these are snapshots of past planning and design
  artifacts and intentionally not updated

## Implementation Units

### U1. Write Python naming convention audit/verification script

**Goal:** Create a single Python script that scans all committed YAML
manifests and reports files violating the `<kind>-<resource-name>.yaml` and
`sealedsecret-<name>.yaml` conventions. The script is run twice: before
renames (expects 16 violations) and after renames (expects zero).

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- `scripts/audit-manifest-naming.py` — new file

**Approach:** The script reads each YAML file, extracts `kind` and
`metadata.name`, lowercases both, and checks that the filename matches
`<lowercased-kind>-<metadata.name>.yaml`. For SealedSecrets, it checks the
`sealedsecret-<name>.yaml` convention specifically (since the resource kind
inside a SealedSecret is `SealedSecret`, not `sealedsecret`).

Known exclusions built into the script:
- Multi-resource install manifests: `apps/argocd/argocd.yaml`,
  `apps/cert-manager/cert-manager.yaml`,
  `apps/metallb/metallb.yaml`,
  `apps/sealed-secrets/sealed-secrets-controller.yaml`
- Helm `values.yaml` files and Helm-generated templates
- ArgoCD Application manifests in `apps/manifests/` (separate "named after
  app directory" convention)
- External route files in `apps/traefik/external/` (separate
  `<service-name>.yaml` convention)

Output: one line per violation with old path → expected new path, plus a
summary count. Exit code 0 when zero violations, non-zero when violations
found.

**Test scenarios:**
- Run against current repo: expect 16 violations listed with correct
  old→new paths.
- Run against a single already-conforming file (e.g.,
  `apps/mealie/deployment-mealie.yaml`): expect zero violations.
- Run against a multi-resource install manifest: expect it to be skipped
  (not flagged).
- Run after all renames complete: expect zero violations, exit code 0.

**Verification:** Run `python3 scripts/audit-manifest-naming.py` and confirm
16 violations listed, each with the correct expected new filename matching
the table in U2.

---

### U2. Rename non-conforming manifest files

**Goal:** Rename all 16 files to match `<kind>-<resource-name>.yaml` or
`sealedsecret-<name>.yaml`.

**Requirements:** R1, R2, R5, R6

**Dependencies:** U1 (verify violations before touching files)

**Files:**

| Old path | New path |
|---|---|
| `apps/argocd/argocd-cmd-params-cm.yaml` | `apps/argocd/configmap-argocd-cmd-params-cm.yaml` |
| `apps/argocd/ingressroute.yaml` | `apps/argocd/ingressroute-argocd.yaml` |
| `apps/arr-stack/bazarr/deployment.yaml` | `apps/arr-stack/bazarr/deployment-bazarr.yaml` |
| `apps/arr-stack/neutarr/deployment.yaml` | `apps/arr-stack/neutarr/deployment-neutarr.yaml` |
| `apps/arr-stack/prowlarr/deployment.yaml` | `apps/arr-stack/prowlarr/deployment-prowlarr.yaml` |
| `apps/arr-stack/radarr/deployment.yaml` | `apps/arr-stack/radarr/deployment-radarr.yaml` |
| `apps/arr-stack/sonarr/deployment.yaml` | `apps/arr-stack/sonarr/deployment-sonarr.yaml` |
| `apps/arr-stack/whisparr/deployment.yaml` | `apps/arr-stack/whisparr/deployment-whisparr.yaml` |
| `apps/aws-ddns/namespace.yaml` | `apps/aws-ddns/namespace-aws-ddns.yaml` |
| `apps/longhorn/ingressroute.yaml` | `apps/longhorn/ingressroute-longhorn.yaml` |
| `apps/metallb/ipaddresspool.yaml` | `apps/metallb/ipaddresspool-default-pool.yaml` |
| `apps/metallb/l2advertisement.yaml` | `apps/metallb/l2advertisement-default-pool-l2.yaml` |
| `apps/open-webui/deployment.yaml` | `apps/open-webui/deployment-open-webui.yaml` |
| `apps/percona-mongodb/cluster-mongodb.yaml` | `apps/percona-mongodb/perconaservermongodb-mongodb.yaml` |
| `apps/traefik/dashboard-auth-sealedsecret.yaml` | `apps/traefik/sealedsecret-dashboard-auth.yaml` |
| `apps/traefik/tlsstore.yaml` | `apps/traefik/tlsstore-default.yaml` |

**Approach:** Use `git mv` for each rename to preserve git history. Group by
directory to minimize churn. The ArgoCD Application manifest for each app
points at the directory path, not individual files, so ArgoCD will pick up
the renamed files on next sync without intervention.

**Patterns to follow:** Existing well-named files in each directory (e.g.,
`apps/arr-stack/bazarr/service-bazarr.yaml` follows the convention; the
`deployment.yaml` rename mirrors that pattern).

**Test scenarios:**
- Verify each renamed file is tracked by git (not lost).
- Verify ArgoCD Application manifests still point at valid directory paths
  (the path does not change, only filenames within it).
- Verify each renamed file's `kind` and `metadata.name` are unchanged by
  inspecting `git diff --cached`.
- Run `python3 scripts/audit-manifest-naming.py` — expect zero violations.

**Verification:** Run the U1 Python script. Exit code 0 = all violations resolved.

---

### U3. Update filename references in ArgoCD manifests and app comments

**Goal:** Update all filename references in `apps/manifests/` and inline
comments within renamed files to match the new filenames.

**Requirements:** R3

**Dependencies:** U2 (rename files first so references point at real paths)

**Files:**

- `apps/manifests/argocd.yaml:26` — update comment:
  `argocd-cmd-params-cm.yaml` → `configmap-argocd-cmd-params-cm.yaml`
- `apps/manifests/metallb.yaml:6-7` — update comments:
  `ipaddresspool.yaml` → `ipaddresspool-default-pool.yaml`,
  `l2advertisement.yaml` → `l2advertisement-default-pool-l2.yaml`
- `apps/manifests/percona-mongodb.yaml:7` — update comment:
  `cluster-mongodb.yaml` → `perconaservermongodb-mongodb.yaml`
- `apps/traefik/sealedsecret-dashboard-auth.yaml` (renamed from
  `dashboard-auth-sealedsecret.yaml`) — update self-referencing comment
  on line 9 with the new filename
- `apps/traefik/certificates/certificate-dng-root-wildcard.yaml:14` —
  update comment: `tlsstore.yaml` → `tlsstore-default.yaml`
- `apps/longhorn/values.yaml:57` — update comment:
  `ingressroute.yaml` → `ingressroute-longhorn.yaml`
- `apps/traefik/values.yaml:110` — update comment:
  `ipaddresspool.yaml` → `ipaddresspool-default-pool.yaml`
- `apps/arr-stack/neutarr/ingressroute-neutarr.yaml:12` — update comment:
  `deployment.yaml` → `deployment-neutarr.yaml`

**Approach:** Each reference is a comment-only change. No Kubernetes resource
content changes. Comments that reference the old filename as a ConfigMap name
(e.g., `name: argocd-cmd-params-cm`) are NOT changed — those are Kubernetes
resource names, not filenames.

**Patterns to follow:** Existing comment style in each file — match the
surrounding prose.

**Test scenarios:**
- Verify each updated comment line references the new filename.
- Verify no Kubernetes resource `metadata.name` was accidentally changed.
- Grep for each old filename across `apps/` — should return zero results in
  active manifests. (The old names may still appear in the install manifest
  `apps/argocd/argocd.yaml` as Kubernetes resource names, which is correct.)

**Verification:** `grep` for each old filename across `apps/` — should return
zero results in active manifests.

---

### U4. Update filename references in bootstrap, runbooks, and docs

**Goal:** Update all filename references in living documentation so readers
can find the renamed files.

**Requirements:** R3

**Dependencies:** U2 (rename files first)

**Files:**

- `bootstrap/README.md` — 7 references:
  - L177: `apps/metallb/ipaddresspool.yaml` → `apps/metallb/ipaddresspool-default-pool.yaml`
  - L178: `apps/metallb/l2advertisement.yaml` → `apps/metallb/l2advertisement-default-pool-l2.yaml`
  - L196, L217: `apps/traefik/dashboard-auth-sealedsecret.yaml` → `apps/traefik/sealedsecret-dashboard-auth.yaml`
  - L228: `apps/traefik/tlsstore.yaml` → `apps/traefik/tlsstore-default.yaml`
  - L274, L275: `apps/argocd/argocd-cmd-params-cm.yaml` → `apps/argocd/configmap-argocd-cmd-params-cm.yaml`
  - L276: `apps/argocd/ingressroute.yaml` → `apps/argocd/ingressroute-argocd.yaml`
- `docs/mongodb-runbooks.md` — all references to
  `apps/percona-mongodb/cluster-mongodb.yaml` → `apps/percona-mongodb/perconaservermongodb-mongodb.yaml`
  (lines 3, 21, 37, 125, 202, 260)
- `docs/troubleshooting.md` — 4 references to
  `apps/percona-mongodb/cluster-mongodb.yaml` (lines 329, 331, 362, 363)
- `docs/migration-traefik-docker.md:52` —
  `apps/metallb/ipaddresspool.yaml` → `apps/metallb/ipaddresspool-default-pool.yaml`
- `docs/migration-traefik-docker.md:158` — update template comment:
  `# Template: apps/<app-name>/ingressroute.yaml` →
  `# Template: apps/<app-name>/ingressroute-<app-name>.yaml`
- `.claude/skills/homelab-scaffold/SKILL.md:83` —
  `cluster-mongodb.yaml` → `perconaservermongodb-mongodb.yaml`
- `docs/audit-documentation-currency-2026-06-02.md:120` — update reference
  to match new filename

**Approach:** Each reference is a path update in prose or command examples.
Use exact string replacement — old path → new path. For `docs/mongodb-runbooks.md`
which has many references, use `sed` or equivalent to replace all occurrences
at once.

**Patterns to follow:** Existing documentation style in each file.

**Test scenarios:**
- Grep for each old filename across `docs/`, `bootstrap/`, `.claude/skills/` —
  should return zero results (except historical plans in `docs/plans/`,
  `docs/superpowers/plans/`, and `docs/superpowers/specs/` which are
  intentionally excluded).
- Verify markdown links and inline code references still render correctly.
- Spot-check 2-3 updated files to confirm the new paths are correct.

**Verification:**
```bash
grep -rn "cluster-mongodb.yaml\|dashboard-auth-sealedsecret\|argocd-cmd-params-cm.yaml" \
  bootstrap/ docs/ .claude/skills/ \
  | grep -v "docs/plans/" \
  | grep -v "docs/superpowers/plans/" \
  | grep -v "docs/superpowers/specs/"
# Should return zero results.
```

---

### U5. Remove stale `smb-multimedia` StorageClass section from CLAUDE.md

**Goal:** Remove the `smb-multimedia` StorageClass documentation since the
file was never created — the multimedia share uses a static PV with
`storageClassName: ""` instead. Also update the arr-stack structure template
to reflect the renamed `deployment.yaml` files.

**Requirements:** R3, R4

**Dependencies:** None (independent of file renames)

**Files:**
- `CLAUDE.md` — remove lines 467–471 (the `**\`smb-multimedia\`**` section)
  and line 523 (the `/multimedia` bullet referencing `smb-multimedia`).
  Also update line 513: `deployment.yaml` → `deployment-<app-name>.yaml`
  in the arr-stack structure template to match the renamed files.

**Approach:** Delete the `smb-multimedia` StorageClass section entirely.
The `smb-backups` section above it remains unchanged. The `/multimedia`
bullet in the arr-stack structure section (line 523) also references
`smb-multimedia` — update it to describe the static PV instead.

Line 523 currently reads:
```
- `/multimedia` — SMB PVC (`smb-multimedia` StorageClass, full share root)
```
Replace with:
```
- `/multimedia` — static PV + PVC binding (`persistentvolume-arr-stack-multimedia.yaml` and `persistentvolumeclaim-multimedia.yaml`)
```

**Patterns to follow:** Existing CLAUDE.md StorageClass documentation style
for `smb-backups` and `nfs-backups`.

**Test scenarios:**
- Verify `grep -i "smb-multimedia" CLAUDE.md` returns zero results.
- Verify the StorageClasses section still documents `longhorn`, `smb-backups`,
  and `nfs-backups` correctly.
- Verify the arr-stack structure section still documents all three volume
  mounts (`/config`, `/backups`, `/multimedia`).
- Verify the arr-stack structure template now shows
  `deployment-<app-name>.yaml` instead of `deployment.yaml`.

**Verification:** Read the updated CLAUDE.md StorageClasses section and
confirm the three remaining StorageClasses are documented accurately.

---

### U6. Pre-commit sync wave verification

**Goal:** Confirm no sync wave annotations are needed on renamed files and
validate the commit is clean.

**Requirements:** R6

**Dependencies:** U2–U5 (run after all changes are staged)

**Files:** All staged files

**Approach:** Run the mandatory pre-commit verification from CLAUDE.md.
File renames do not add or remove sync wave annotations — this is a
filename-only change with no new resources. The check confirms no
annotations were accidentally introduced. Also run the U1 Python script
one final time to confirm zero violations.

**Test scenarios:**
- All staged files pass sync wave verification.
- Git status shows only the expected renames and reference updates.
- No new files were accidentally created.
- `python3 scripts/audit-manifest-naming.py` exits 0.

**Verification:**
```bash
# List resources without sync-wave annotations in staged changes:
git diff --cached --name-only | xargs grep -L "sync-wave" 2>/dev/null
# All hits should be either:
#   - Resources at wave 0 that correctly omit the annotation, or
#   - Documentation files where the annotation is not applicable
```
