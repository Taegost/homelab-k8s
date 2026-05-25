---
title: fix: Strengthen verification and research discipline for new app deployments
type: fix
status: active
date: 2026-05-25
---

# fix: Strengthen verification and research discipline for new app deployments

## Summary

Add verification checks and research rules to prevent the class of bugs discovered during the LibreChat deployment. Covers: NetworkPolicy cross-namespace verification, pre-implementation app config research discipline in CLAUDE.md, and troubleshooting entries for env var mismatches and CRD field format errors.

---

## Requirements

- R1. Verification script fails when NetworkPolicy `from.podSelector` is present without `namespaceSelector`, or when a policy has no `from` blocks
- R2. CLAUDE.md requires reading the app's actual source code (Dockerfile, config.py, example.yaml, Helm values) before writing manifests
- R3. Troubleshooting guide documents env var name mismatch pattern and CRD field format pattern

---

## Context

The LibreChat deployment exposed 12 bugs across 6 root cause classes. Four classes were already addressed during the deployment (sync-wave docs, secret template verification, securityContext checks, troubleshooting entries for lost+found and root images). Three classes remain unaddressed and are covered here.

### Relevant Code and Patterns

- `.claude/skills/homelab-validate/scripts/` — existing verification scripts
- `.claude/skills/homelab-validate/SKILL.md` — verification skill reference
- `CLAUDE.md` — project conventions and behavior instructions (Research and correctness section)
- `docs/troubleshooting.md` — cluster-level diagnostics

---

## Implementation Units

### U1. Add NetworkPolicy cross-namespace verification

**Goal:** Catch NetworkPolicy `from.podSelector` without `namespaceSelector` when the target pods are in a different namespace.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Create: `.claude/skills/homelab-validate/scripts/networkpolicy-check.sh`
- Modify: `.claude/skills/homelab-validate/SKILL.md`

**Approach:**
- Use `yaml.safe_load_all()` to parse NetworkPolicy files (same pattern as `yaml-validity.sh`)
- Two hard rules:
  1. Every `from` entry with `podSelector` MUST also have `namespaceSelector` — even if the target pods are in the same namespace. Explicit is safer than implicit.
  2. Every policy MUST have at least one `from` block — deny-all policies are not allowed.
- Both are hard failures (exit 1), not warnings. Same-namespace pod selectors with explicit `namespaceSelector` pass; omitting it is always wrong.
- Add to the homelab-validate SKILL.md as check #7

**Test scenarios:**
- Happy path: NetworkPolicy with `namespaceSelector` + `podSelector` in every `from` entry — passes
- Failure: NetworkPolicy with `podSelector` without `namespaceSelector` — fails
- Failure: NetworkPolicy with no `from` blocks (deny-all) — fails
- Edge case: NetworkPolicy with `ipBlock` only (no `podSelector`) — passes

**Verification:**
- Script runs without errors and correctly identifies the librechat NetworkPolicy (before fix) as needing review
- SKILL.md references the new check

---

### U2. Add app config research discipline to CLAUDE.md

**Goal:** Prevent env var name mismatches, config schema violations, probe path errors, and securityContext assumptions by requiring source-code-level research before writing manifests.

**Requirements:** R2

**Dependencies:** None

**Files:**
- Modify: `CLAUDE.md`

**Approach:**
- Add a complementary rule next to the existing "Research container security context per app" bullet: "Research app configuration per app" — never assume env var names, config schema fields, health probe paths, or default values. Follow the research order below; only proceed to the next tier if the current one is unclear or ambiguous.
- Tiered research order:
  1. Read the Dockerfile for USER, EXPOSE (port), WORKDIR, and ENV defaults
  2. Read the example config file (e.g., `librechat.example.yaml`) for schema field types, required fields, and defaults
  3. Read the Helm values.yaml or docker-compose.yml (when available) for probe paths, resource defaults, recommended config, and env var names
  4. Read the config source code (e.g., `config.py`, `config.js`) for env var names, default values, and feature flags — only when tiers 1-3 are unclear or silent
- Verify CRD field formats against the operator/CRD documentation or existing working examples in the repo before committing

**Test scenarios:**
- Test expectation: none — documentation only

**Verification:**
- CLAUDE.md "Research and correctness" section contains the new rule with enumerated checks

---

### U3. Add troubleshooting entries for env var mismatches and CRD format errors

**Goal:** Document the "wrong env var names" and "CRD field format wrong" bug patterns so future debugging is faster.

**Requirements:** R3

**Dependencies:** None

**Files:**
- Modify: `docs/troubleshooting.md`

**Approach:**
- Add an "Application Configuration" section covering:
  - **Wrong env var names:** Symptom: app connects with default credentials, "no such user" or "access denied." Root cause: app reads `POSTGRES_USER` but manifest set `DB_USER`. Fix: read the app's config source code or example config for exact env var names. Never assume `DB_*` prefix.
  - **CRD field format errors:** Symptom: operator rejects CRD with "required value" or "invalid type." Root cause: nested field structure doesn't match the CRD schema (e.g., `role: { name, db }` vs `name`/`db` at top level). Fix: check the operator's CRD documentation or existing working examples in the repo for the exact field format.
  - **Config schema violations at app startup:** Symptom: app logs ZodError/validation errors on config file. Root cause: config file values don't match the app's expected schema (wrong type, missing required fields). Fix: read the app's example config file and check field types — empty string is not the same as omitted, arrays may have min-length requirements.
- Add a "NetworkPolicy" section covering:
  - **Pod selector without namespace selector:** Symptom: "Bad Gateway" or "Connection refused" despite healthy pods and correct IngressRoute. Root cause: NetworkPolicy `from.podSelector` only matches pods in the same namespace. Fix: always add `namespaceSelector` to every `from` entry that uses `podSelector` — even if the target pods are in the same namespace. Explicit is safer than implicit.
  - **Deny-all policy blocks everything:** Symptom: all traffic denied. Root cause: NetworkPolicy with no `from` blocks is a deny-all. These are never warranted — remove the policy or add explicit `from` entries.

**Test scenarios:**
- Test expectation: none — documentation only

**Verification:**
- Troubleshooting guide contains the new sections with clear symptom→cause→fix chains

---

## System-Wide Impact

- **New verification script:** `networkpolicy-check.sh` — one file, no dependencies
- **CLAUDE.md:** expanded Research and correctness section — affects all future app deployments
- **Troubleshooting guide:** 5 new entries — no code changes
- **No changes to existing manifests or cluster state**

---

## Risks

| Risk | Mitigation |
|------|------------|
| Existing NetworkPolicies in the repo may not comply with new rules (e.g., ArgoCD policies in the monolithic manifest) | The script checks staged changes only — existing policies are grandfathered. The monolithic `apps/argocd/argocd.yaml` is auto-generated; exclude it or accept that it won't be modified in normal PRs |
| Research rules add overhead to simple deployments | Rules are tiered — Dockerfile + example config + Helm values cover most cases. Source code is tier 4, reserved for ambiguity |
