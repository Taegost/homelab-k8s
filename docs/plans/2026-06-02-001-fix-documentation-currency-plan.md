# Documentation Remediation Plan

Based on audit `docs/audit-documentation-currency-2026-06-02.md` (41 findings,
9 HIGH, 8 MEDIUM, 24 LOW).

## Phase 1: Critical Accuracy Fixes (HIGH severity)

### U1. Add missing deployed apps to README.md

**File:** `README.md`

Add two rows to the Deployed Applications table:

| Application | Purpose | Namespace |
|---|---|---|
| [LibreChat](https://www.librechat.ai/) | Unified AI chat interface — MongoDB, Meilisearch, Redis, RAG API | `librechat` |
| [WordPress (taegost.com)](https://wordpress.org/) | Mike's professional portfolio and blog | `wordpress-taegost` |

### U2. Fix StorageClass documentation across README.md and CLAUDE.md

**Problem:** Neither doc covers all 4 StorageClasses. README mentions `nfs-backups` + `nfs-multimedia`; CLAUDE.md mentions `smb-backups` + `nfs-multimedia` + `longhorn`.

**Fix — README.md:** Replace the NFS Storage section (lines ~250-285) with a table covering all 4:

| StorageClass | Backend | Access | Use |
|---|---|---|---|
| `longhorn` | Longhorn replicated block | RWO/RWX | App config and data |
| `smb-backups` | Unraid Backups (SMB) | RWX | Application backup volumes |
| `nfs-backups` | Unraid Backups (NFS) | RWX | Alternative backup path |
| `smb-multimedia` | Unraid Multimedia (SMB) | RWX | Media library — shared across *arr stack apps |

**Fix — CLAUDE.md:** Add `nfs-backups` StorageClass entry to the StorageClasses section.

### U3. Update CLAUDE.md Repository Structure tree

**File:** `CLAUDE.md`

Add to the ASCII tree:
```
│   ├── librechat/                # LibreChat AI chat — MongoDB, Meilisearch, Redis, RAG API
│   ├── percona-mongodb/          # MongoDB cluster CRD + sealed secrets
│   ├── percona-mongodb-operator/ # Percona MongoDB operator Helm values
│   ├── wordpress-taegost/        # Mike's portfolio/blog (taegost.com)
```

Add to the `docs/` listing:
```
│   ├── mongodb-runbooks.md       # New app + migration workflows for MongoDB
│   ├── brainstorms/              # Requirements and brainstorming documents
│   ├── plans/                    # Implementation plans
```

### U4. Fix Open WebUI README OIDC redirect URI

**File:** `apps/open-webui/README.md`

Line 174 says `authorization-code/callback` but line 97 says `oauth/oidc/callback`.
**Need user confirmation** on which is correct. Once confirmed, fix the wrong one.

### U5. Update STRATEGY.md

**File:** `STRATEGY.md`

- Update `last_updated: 2026-06-02`
- Mark "Documentation currency" track as `**[COMPLETE]**` — the doc-currency pass deployed 2026-05-22
- Mark "Personal portfolio WordPress" track as `**[COMPLETE]**` — wordpress-taegost deployed
- Add new track: "LibreChat hardening" (ongoing — monitor MongoDB performance, pgvector RAG)
- Add new track: "Documentation maintenance" (recurring — keep docs in sync with cluster)

---

## Phase 2: Plan Document Lifecycle (HIGH/MEDIUM)

### U6. Mark completed plans

**Files:**
- `docs/plans/2026-05-22-002-feat-wordpress-taegost-plan.md`
- `docs/plans/2026-05-23-001-feat-librechat-deployment-plan.md`

Change `status: active` → `status: completed` in frontmatter.

### U7. Verify and close deployment-verification-gaps plan

**File:** `docs/plans/2026-05-25-001-fix-deployment-verification-gaps-plan.md`

Verify:
- NetworkPolicy check script exists at `.claude/skills/homelab-validate/scripts/networkpolicy-check.sh`
- CLAUDE.md contains the tiered research rules (confirmed: yes, they're in "Research and correctness")
- Troubleshooting entries added to `docs/troubleshooting.md`

If all three are done, mark `status: completed`. If not, leave active but note remaining work.

---

## Phase 3: Cross-Reference Fixes (MEDIUM)

### U8. Fix postgres-runbooks.md file path reference

**File:** `docs/postgres-runbooks.md`

Line 71: `apps/postgres/cluster.yaml` → `apps/postgres/cluster-postgres.yaml`

### U9. Fix postgres-runbooks.md hardcoded version

**File:** `docs/postgres-runbooks.md`

Line 14: `Postgres version: 18.3` → `Postgres version: see image tag in apps/postgres/cluster-postgres.yaml`

### U10. Fix argocd-ha-migration.md hardcoded ArgoCD version

**File:** `docs/argocd-ha-migration.md`

Line 38: Replace `v3.3.7` with a note to extract the version from the current manifest:
```
ARGOCD_VERSION=$(grep -A1 "chart: argo-cd" apps/manifests/argocd.yaml | grep "targetRevision:" | awk '{print $2}')
```

---

## Phase 4: Format Consistency (LOW — batch fix)

These are low-severity formatting/clarity issues. Batch them in a single commit.

### U11. Misc cleanups

- `docs/sealed-secrets.md` line 28: note that `v0.36.6` is a reference example, not a pinned requirement
- Verify `archived/nodelocaldns/` directory still exists (referenced by `archived/README.md`)
- Verify `bootstrap/kube-vip/` directory still exists (referenced by `docs/disaster-recovery.md`)

---

## Sequencing

Phase 1 (U1-U5) has no cross-dependencies — all can be done in a single commit.
Phase 2 (U6-U7) is independent — separate commit.
Phase 3 (U8-U10) is independent — separate commit.
Phase 4 (U11) is cleanup — single commit.

Recommended: single PR with 4 commits, or one combined commit if preferred.

---

## Open Questions (need user input before implementing)

1. **Open WebUI OIDC callback URL** — which is correct?
   - `https://open-webui.diceninjagaming.com/oauth/oidc/callback` (from Phase 2 setup)
   - `https://open-webui.diceninjagaming.com/authorization-code/callback` (from Troubleshooting)

2. **`nfs-backups` vs `smb-backups`** — both StorageClasses exist. Are both intentionally kept, or is one legacy? If `nfs-backups` is legacy, should it be documented as deprecated?

3. **ArgoCD HA migration** — is this still planned? The docs say "pending." If it's been indefinitely deferred, update the language.

4. **Plan lifecycle** — should completed plans be moved to an `archived/` directory, or just marked `status: completed` in place?

5. **STRATEGY.md new tracks** — the proposed "LibreChat hardening" and "Documentation maintenance" tracks in U5 — do these match your actual priorities?
