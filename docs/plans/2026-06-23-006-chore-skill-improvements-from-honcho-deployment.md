---
title: "chore: Skill improvements from Honcho deployment session"
type: chore
status: pending
date: 2026-06-23
---

# Skill Improvements from Honcho Deployment Session

## Summary

The Honcho deployment session (`feat/honcho-deployment`) exposed 8 friction
points across the ce-doc-review, ce-work, verify-implementation, and
ce-compound skills. The user caught 2 issues that doc-review missed (Valkey
auth pattern, LiteLLM URL), verify-implementation flagged 2 false positives
(missing SealedSecret templates that are manual-operator artifacts), and
ce-work failed pre-commit validation on probe timeouts it could have caught
proactively.

This plan documents each finding with root cause analysis and proposed fixes.
Improvements are ordered by impact-to-effort ratio.

---

## Finding 1: ce-work doesn't cross-check plans against repo conventions

**Skill:** ce-work
**Severity:** High (caused user intervention during doc-review walk-through)
**Effort:** Low

### What happened

The plan specified Valkey with `--requirepass` and a password embedded in the
ConfigMap's `CACHE_URL`. The repo convention (established by plane's Valkey
deployment at `apps/plane/deployment-valkey.yaml`) is no auth on Valkey — rely
on NetworkPolicy namespace isolation instead. ce-work implemented the plan as
written. The user had to catch the contradiction during the doc-review
walk-through.

### Root cause

ce-work's Phase 1 says "Treat the plan as a decision artifact" and "Do not
edit the plan body during execution." It has no step to cross-check the plan
against `docs/solutions/` for established patterns before implementing. The
plan is treated as authoritative even when it contradicts documented
conventions.

### Proposed fix

Add a step to ce-work's Phase 1 (after "Read Plan and Clarify", before
"Setup Environment"):

1. Extract resource types from the plan (Deployments, Services, ConfigMaps,
   NetworkPolicies, etc.)
2. For each resource type, grep `docs/solutions/` for relevant patterns
   (e.g., grep for "valkey" or "redis" when the plan creates a Valkey
   deployment)
3. If a documented convention contradicts the plan's approach, surface it as
   a clarifying question before implementing
4. Log the cross-check results so the user can see what was checked

### Impact

Prevents plan-vs-convention conflicts from reaching implementation. Catches
issues like the Valkey auth pattern before any code is written.

---

## Finding 2: ce-work doesn't detect missing convention artifacts

**Skill:** ce-work
**Severity:** Medium (caused verify-implementation to flag "Critical" findings)
**Effort:** Low

### What happened

The plan's directory structure listed `sealedsecret-honcho.yaml` and
`sealedsecret-honcho-db-credentials.yaml` but the plan body only provided
`kubeseal` commands — no YAML template. ce-work skipped them because no YAML
was provided. verify-implementation flagged them as "Critical — missing."
Every other app in the repo (plane, librechat, hermes-agent, etc.) has
committed SealedSecret template files.

### Root cause

ce-work checks "does the plan provide YAML for this file?" but doesn't check
"does every other app in the repo have this file?" The convention is implicit —
it exists in the repo's file patterns but isn't documented in a way ce-work
can discover from the plan alone.

### Proposed fix

During Phase 1, after building the task list, ce-work should:

1. Pick a reference app from the same category (e.g., `apps/plane/` for a
   new app deployment)
2. List the reference app's files: `ls apps/<reference>/`
3. Diff against the plan's file list
4. Files present in the reference but absent from the plan are either:
   - Intentional omissions (confirm with user)
   - Missing convention artifacts (create them)

### Impact

Catches missing convention artifacts (SealedSecret templates, service labels,
etc.) before implementation, preventing verify-implementation from flagging
them as critical gaps.

---

## Finding 3: ce-work doesn't validate against pre-commit proactively

**Skill:** ce-work
**Severity:** Medium (caused a failed commit and recommit cycle)
**Effort:** Low

### What happened

The Valkey exec probes defaulted to `timeoutSeconds: 1` (Kubernetes default).
The pre-commit hook (`probe-timeout-check.sh`) caught it at commit time.
ce-work had to fix the probes and recommit — a wasted cycle that could have
been avoided.

### Root cause

ce-work's execution loop has "Run tests after changes" but no "Run validation
scripts before staging." For this repo, `/homelab-validate` (or
`.githooks/pre-commit`) is the equivalent of tests for YAML manifests. The
validation is only triggered by `git commit`, not by ce-work proactively.

### Proposed fix

After creating all manifests but before `git add`, ce-work should:

1. Check if a pre-commit hook exists (`.git/hooks/pre-commit` or
   `.githooks/pre-commit`)
2. If yes, run the validation script directly against the working tree files
   (not via git hook — use the script path)
3. If validation fails, fix issues before staging
4. This replaces the "discover at commit time" cycle with a "validate before
   staging" cycle

For this repo specifically:
```bash
# Run validation against working tree files
.claude/skills/homelab-validate/scripts/probe-timeout-check.sh apps/honcho/
.claude/skills/homelab-validate/scripts/yaml-validity.sh apps/honcho/
# ... etc
```

### Impact

Eliminates the commit-fail-fix-recommit cycle. Catches YAML issues (probe
timeouts, sync waves, capability gaps) in one pass before staging.

---

## Finding 4: verify-implementation conflates "missing" with "awaiting manual step"

**Skill:** verify-implementation
**Severity:** Medium (false positive "Critical" findings)
**Effort:** Medium

### What happened

The SealedSecret templates were flagged as "Critical — missing." But they're
placeholders that the operator replaces after running `kubeseal`. The
verification didn't distinguish between "file doesn't exist anywhere" and
"file exists on disk with placeholder values, not yet in git because it
requires a manual operator step."

### Root cause

verify-implementation's completeness check is binary — file exists in the
diff or not. It doesn't check whether the file exists on disk (even if
gitignored) or whether the plan explicitly marks it as a manual-operator
artifact.

### Proposed fix

verify-implementation should:

1. Check if missing files exist on disk (even if gitignored): `ls -la
   apps/honcho/sealedsecret-honcho.yaml`
2. If the file exists on disk but isn't in the diff, check if it's gitignored
3. If gitignored, mark it as "awaiting manual step" (not "missing")
4. Distinguish between:
   - **Missing entirely** — file doesn't exist on disk (Critical)
   - **Awaiting manual step** — file exists on disk, gitignored, needs
     operator action (Warning)
   - **Committed** — file is in the diff (Pass)

### Impact

Prevents false-positive "Critical" findings on files that are intentionally
not committed (plaintext secrets, operator-generated SealedSecrets).

---

## Finding 5: verify-implementation subagents run against stale context on re-verification

**Skill:** verify-implementation
**Severity:** Low (cosmetic — subagents re-verified already-fixed issues)
**Effort:** Low

### What happened

The first verify-implementation run found 2 critical issues. I fixed them and
committed. The second run used `git diff main...HEAD` which now includes the
fix commit. The subagents re-verified the original implementation plus the
fix, but didn't know which findings were already addressed.

### Root cause

verify-implementation always runs `git diff main...HEAD` which includes all
commits on the branch. After a fix commit, the diff is correct — but the
subagents don't receive context about what was already fixed. They
re-verify everything from scratch.

### Proposed fix

When running verify-implementation after a fix commit, pass context to the
subagents:

1. Record the fix commit hash(es)
2. Tell subagents: "Previous verification found issues X, Y, Z. They were
   addressed in commit ABC. Verify the fixes landed correctly and check for
   any NEW issues."
3. Subagents focus on fix verification + new issue detection, not
   re-verifying the entire implementation

### Impact

Reduces redundant verification work on re-runs. Subagents focus on what
changed rather than re-checking everything.

---

## Finding 6: doc-review missed domain-specific security and networking issues

**Skill:** ce-doc-review (security-lens, feasibility reviewers)
**Severity:** High (user caught 2 issues the reviewers missed)
**Effort:** Medium

### What happened

The doc-review found 14 findings (cadence values, auth header, rollback
command, etc.) but missed two issues the user caught during the walk-through:

1. **LiteLLM URL should use external HTTPS domain**, not cluster-internal
   HTTP. The plan used `http://litellm.litellm.svc.cluster.local:4000` but
   the correct URL is `https://litellm.diceninjagaming.com`. This has
   NetworkPolicy implications — egress must allow port 443 (MetalLB IP is
   outside any namespace, so `namespaceSelector` doesn't match).

2. **Valkey `--requirepass` creates plaintext password in ConfigMap.** The
   plan added auth to Valkey, which forced the password into `CACHE_URL` in
   the ConfigMap. ConfigMaps are stored as plaintext in etcd. The same
   password also existed in the SealedSecret (encrypted). This duplication
   is a security gap.

### Root cause

The coherence and feasibility reviewers check internal consistency and
technical feasibility, but they don't have domain-specific knowledge about:

- **Kubernetes networking:** MetalLB IPs are outside any namespace, so
  NetworkPolicy `namespaceSelector` doesn't match them. Egress rules for
  external services need port-based rules, not namespace-based rules.
- **Security patterns:** ConfigMap values are stored as plaintext in etcd.
  Credentials should never be in ConfigMaps — they belong in Secrets (or
  SealedSecrets). The security-lens reviewer checks for auth gaps but
  doesn't check for credentials in non-Secret resources.

### Proposed fix

**Security-lens reviewer:** Add to the persona prompt's "What you check"
section:

> **Credentials in non-Secret resources.** Check ConfigMaps, environment
> variables in Deployment specs, and inline values for credentials (passwords,
> API keys, tokens). ConfigMaps are stored as plaintext in etcd — any
> credential in a ConfigMap is a security gap. Flag when a credential appears
> in both a ConfigMap (plaintext) and a SealedSecret (encrypted) — the
> ConfigMap copy defeats the purpose of encryption.

**Feasibility reviewer:** Add to the persona prompt's "What you check"
section:

> **NetworkPolicy selector vs. actual traffic path.** When a plan uses
> NetworkPolicy `namespaceSelector` to allow egress, verify the destination
> is actually in a Kubernetes namespace. External services (MetalLB IPs,
> external domains) are outside any namespace — `namespaceSelector` won't
> match them. Egress to external services needs port-based rules (e.g.,
> `ports: [{protocol: TCP, port: 443}]` without a `to` selector).

### Impact

Catches security and networking issues that require domain-specific knowledge
about Kubernetes internals. Prevents the user from being the last line of
defense for these patterns.

---

## Finding 7: ce-compound Solution Extractor created a file (violates skill contract)

**Skill:** ce-compound
**Severity:** Low (no user impact, but violates the skill's own rules)
**Effort:** Low

### What happened

The Solution Extractor subagent created
`docs/solutions/conventions/honcho-deployment-patterns.md` directly. The
skill instructions explicitly state: "Phase 1 subagents return TEXT DATA to
the orchestrator. They must NOT use Write, Edit, or create any files. Only
the orchestrator writes files."

### Root cause

The subagent prompt didn't explicitly say "return the documentation as text,
do not create files." The subagent inferred from the task description that
it should write the file. The skill's critical requirement block is in the
orchestrator's instructions, not in the subagent prompt.

### Proposed fix

Add to the Solution Extractor task prompt (in the skill's Phase 1 section):

> **IMPORTANT:** Return the complete documentation as your final text output
> (markdown). Do NOT create or write any files — the orchestrator handles
> file creation. Your output is raw text that the orchestrator will validate
> and write to disk.

### Impact

Ensures the orchestrator maintains control of file creation, which is needed
for frontmatter validation, overlap checking, and vocabulary capture.

---

## Finding 8: No mechanism to detect plan-vs-convention conflicts during doc-review

**Skill:** ce-doc-review
**Severity:** High (same root cause as Finding 1, but at the review layer)
**Effort:** Medium

### What happened

The doc-review checked the plan for internal consistency, feasibility, and
security — but didn't check whether the plan's approach contradicted
established repo conventions. The Valkey auth issue should have been caught
during the feasibility review, not during the user walk-through.

### Root cause

doc-review personas check the document against itself and general best
practices. They don't cross-reference `docs/solutions/` for established
patterns. The feasibility reviewer checks "will this work?" but not "does
this contradict how we've done it before?"

### Proposed fix

Add a step to doc-review's Phase 1 (after reading the document, before
dispatching personas):

1. Extract key resource types and patterns from the document
2. Grep `docs/solutions/` for relevant conventions
3. Pass the relevant convention excerpts to the feasibility reviewer as
   supplementary context
4. The feasibility reviewer checks: "Does the document's approach contradict
   any documented convention? If yes, flag it."

This is the review-layer equivalent of Finding 1 (which is the
implementation-layer fix). Both are needed — Finding 1 catches conflicts at
implementation time, Finding 8 catches them at review time (earlier).

### Impact

Catches plan-vs-convention conflicts during the review phase, before
implementation begins. The user doesn't have to be the one to notice the
contradiction.

---

## Implementation Priority

| Priority | Finding | Skill | Impact | Effort |
|----------|---------|-------|--------|--------|
| 1 | #3 | ce-work | Eliminates commit-fail-fix cycles | Low |
| 2 | #1 | ce-work | Prevents plan-vs-convention conflicts | Low |
| 3 | #7 | ce-compound | Fixes skill contract violation | Low |
| 4 | #2 | ce-work | Catches missing convention artifacts | Low |
| 5 | #8 | ce-doc-review | Catches conflicts at review time | Medium |
| 6 | #6 | ce-doc-review | Domain-specific security/networking checks | Medium |
| 7 | #4 | verify-implementation | Eliminates false-positive critical findings | Medium |
| 8 | #5 | verify-implementation | Reduces redundant re-verification work | Low |

Findings 1-4 are low-effort, high-impact. Findings 5-8 require more
substantial changes to persona prompts or skill workflows.

---

## Notes

- These improvements are specific to the compound-engineering plugin skills.
  Changes to persona prompts (Findings 6, 8) need to be made in the plugin's
  agent definition files, not in this repo.
- Finding 3 (proactive pre-commit validation) is repo-specific — it depends
  on the `.githooks/pre-commit` validation suite existing. Other repos may
  have different validation mechanisms.
- Finding 4 (gitignored file detection) requires verify-implementation to
  check the working tree, not just the diff. This is a behavioral change
  to the completeness subagent.
