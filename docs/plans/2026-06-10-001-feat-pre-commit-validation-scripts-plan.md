---
type: feat
status: active
created: 2026-06-10
---

# feat: Add Three Pre-Commit Validation Scripts

## Summary

Add three new pre-commit validation scripts to the `homelab-validate` suite, catching generic infrastructure patterns that caused the Plane deployment failures: exec probe timeouts, missing Linux capabilities for common images, and missing env var injection in Deployments.

## Problem Frame

The Plane deployment debugging session (2026-06-09 through 2026-06-10) exposed three categories of bugs that are not Plane-specific and will recur with future apps. All three categories have been encountered repeatedly across multiple deployments beyond Plane, and the operator has refined process each time — this plan automates those learned process checks so they fire at commit time rather than debugging time.

1. **Exec probes timing out with default `timeoutSeconds: 1`.** RabbitMQ's `rabbitmq-diagnostics` took 2-5 seconds but the Kubernetes default probe timeout killed it before the command completed. Any app using CLI-based exec probes (redis-cli, pg_isready, celery, valkey-cli) has the same risk.

2. **Missing capabilities for images that drop ALL.** nginx workers need `CAP_SETGID` and `CAP_SETUID` to drop privileges. RabbitMQ's entrypoint needs `CAP_CHOWN`, `CAP_SETGID`, `CAP_SETUID`, and `CAP_DAC_OVERRIDE`. These are image-level requirements, not app-level — any Deployment using these images with `drop: [ALL]` will hit the same bugs.

3. **Missing env var injection in Deployments.** plane-live had no `envFrom` blocks (since corrected) while every other Deployment in the namespace referenced the same ConfigMap and Secret. A single-file check catches any Deployment missing both `envFrom` and `env` blocks.

## Requirements

- **R1:** Catch exec probes with missing or default (1s) `timeoutSeconds` on known-slow CLI commands
- **R2:** Catch missing capabilities for nginx and RabbitMQ images when `drop` includes `ALL`
- **R3:** Warn when a Deployment has no `envFrom` or `env` blocks (missing ConfigMap/Secret injection)
- **R4:** Integrate into the existing pre-commit hook with conditional gating (SKIP when no relevant files staged)
- **R5:** Follow existing script conventions documented in `.claude/skills/homelab-validate/SKILL.md`

## Key Technical Decisions

### KTD-1: Scripts are generic, not Plane-specific

The scripts match on **image name patterns** (nginx, rabbitmq, redis, valkey) and **probe command substrings** (rabbitmq-diagnostics, redis-cli, pg_isready), not on app-specific names. Any Deployment using these images or commands triggers the checks. Plane-specific probe path bugs (`/api/health/` → 404, router basename mismatches) are captured in `docs/troubleshooting/troubleshooting-plane.md` and prevented by the existing research rules in `CLAUDE.md`.

### KTD-2: Hybrid grep + Python3 inline scripts

Simple pattern matching (image name, file discovery) uses shell grep. Structured YAML inspection (probe configs, securityContext, envFrom blocks) uses inline `python3 -c` with `yaml.safe_load_all`. This matches the approach in `networkpolicy-check.sh` and `yaml-validity.sh`.

### KTD-3: Capability and env checks use different severity levels

- **probe-timeout-check.sh:** FAIL for known-slow CLIs with tiered thresholds: slow CLIs (rabbitmq-diagnostics, rabbitmqctl, celery) → FAIL if <5s; fast CLIs (redis-cli, valkey-cli, pg_isready, mysqladmin, mongosh) → FAIL if <2s. WARN for generic exec probes with missing or default timeout.
- **capability-check.sh:** FAIL for images matching KB patterns with missing required capabilities. WARN for images with known privilege-drop entrypoints (gosu, su-exec, su, chroot) lacking SETUID/SETGID when not covered by a KB entry. Capability requirements are sourced from `docs/solutions/` KB files — the KB is the single source of truth.
- **env-check.sh:** All findings are WARN — missing envFrom/env blocks may be intentional. The check is informational only; it does not block commits.

### KTD-4: Conditional gating, not always-run

All three scripts exit early with SKIP when no Deployment files are staged, matching the conditional pattern used by `ingressroute-check.sh` and `longhorn-fsgroup-check.sh`. This avoids noisy output on commits that don't touch Deployments.

## Scope Boundaries

### In Scope
- Exec probe `timeoutSeconds` validation on Deployments
- Capability validation for nginx and RabbitMQ images
- envFrom/env block presence validation on Deployments
- Pre-commit hook wiring and documentation

### Deferred to Follow-Up Work
- Capability patterns for additional images (PostgreSQL, MySQL, MongoDB, WordPress, Redis, Valkey) — add as they appear
- Slow-CLI patterns for additional health checks — add as new image types are deployed
- Runtime probe path validation (checking actual HTTP response codes) — requires running containers, not suitable for pre-commit
- Test infrastructure for validation scripts — a way to run checks against a known set of Deployment fixtures before committing script changes
- rabbitmq-diagnostics probe timeout recommendation: ≥10s (not just ≥5s) — the diagnostic can spike to 5s+ under load; 10s provides headroom

### Outside Scope
- Plane-specific probe path checks (covered by troubleshooting docs and research rules)
- Any runtime verification (kubectl, container exec)
- Modifying existing Deployments to fix pre-existing issues

## Implementation Units

### U1. `probe-timeout-check.sh`

**Goal:** Catch exec probes with default (too-short) timeoutSeconds.

**Approach:** Shell wrapper detects staged Deployment files, invokes Python3 inline to parse YAML and check probes. Python matches probe commands against a known-slow CLI list.

**Dependencies:** None.

**Files:**
- `.claude/skills/homelab-validate/scripts/probe-timeout-check.sh` (create)

**Patterns to follow:**
- `networkpolicy-check.sh` — Python3 inline parsing with `yaml.safe_load_all`
- `longhorn-fsgroup-check.sh` — per-file iteration, failure counter, PASS/FAIL output format

**Checks:**

| Condition | Severity |
|---|---|
| exec probe whose command contains: `rabbitmq-diagnostics`, `rabbitmqctl`, `celery` + `timeoutSeconds` missing or `< 5` | FAIL |
| exec probe whose command contains: `redis-cli`, `valkey-cli`, `pg_isready`, `mysqladmin`, `mongosh` + `timeoutSeconds` missing or `< 2` | FAIL |
| exec probe, generic command + `timeoutSeconds` missing or `= 1` | WARN |
| exec probe with `timeoutSeconds >= 2` | PASS |
| httpGet or tcpSocket probe | not checked |

**Conditional gating (script-internal):** Exit 0 with "SKIP (no Deployments changed)" when no Deployment files are staged. Before invoking Python3, use a fast grep pre-filter: only parse files containing `exec:` to avoid YAML parsing on Deployments without exec probes.

**Test scenarios:**
1. RabbitMQ Deployment with exec probe `["rabbitmq-diagnostics", "check_running"]`, no timeoutSeconds → FAIL ("known-slow CLI — add timeoutSeconds >= 10")
2. Valkey Deployment with exec probe `["valkey-cli", "ping"]`, timeoutSeconds: 1 → FAIL
3. Generic Deployment with exec probe `["some-check"]`, no timeoutSeconds → WARN
4. Deployment with exec probe `["rabbitmq-diagnostics", "check_running"]`, timeoutSeconds: 10 → PASS
5. Deployment with only httpGet probes → PASS (no exec probes present)
6. No Deployment files staged → SKIP

### U2. `capability-check.sh`

**Goal:** Catch missing capabilities for well-known images when `drop` includes `ALL`.

<<<<<<< HEAD
**Approach:** Python3 inline script reads container `image` and `securityContext.capabilities`. Only fires when `drop` contains `ALL`. Matches image names against the base-image knowledge base (`docs/solutions/`) using the same auto-discovery mechanism as `audit.sh` — scans KB files at startup, parses "Image patterns" sections to build a pattern map, then extracts required capabilities from each KB entry's "Required capabilities" table. The KB is the single source of truth for capability requirements; no capability lists are hardcoded in the script.
=======
**Approach:** Python3 inline script reads container `image` and `securityContext.capabilities`. Only fires when `drop` contains `ALL`. Matches image names against a known-requirements map.
>>>>>>> 24543b7 (feat(plan): pre-commit validation scripts plan with review refinements)

**Dependencies:** None.

**Files:**
- `.claude/skills/homelab-validate/scripts/capability-check.sh` (create)

<<<<<<< HEAD
**Patterns to follow:** Same Python3 inline + shell wrapper pattern as `probe-timeout-check.sh`. KB auto-discovery follows the pattern in `.claude/skills/homelab-image-audit/audit.sh` (section-aware awk extraction, process substitution for associative array population). Uses the existing `runAsUser`/`runAsNonRoot` heuristics from `longhorn-fsgroup-check.sh` for generic root-image detection.
=======
**Patterns to follow:** Same Python3 inline + shell wrapper pattern as `probe-timeout-check.sh`. Uses the existing `runAsUser`/`runAsNonRoot` heuristics from `longhorn-fsgroup-check.sh` for generic root-image detection.
>>>>>>> 24543b7 (feat(plan): pre-commit validation scripts plan with review refinements)

This script is a safety net for the CLAUDE.md research rules — it catches cases where the operator skipped the Dockerfile capability check during debugging or rapid iteration. The research rules remain the primary guard; this script is the automated backstop.

**Checks:**

<<<<<<< HEAD
| Condition | Severity |
|---|---|
| Image matches a KB pattern + `drop` contains `ALL` + required capabilities from KB are missing | FAIL |
| Image matches a KB pattern + `drop` contains `ALL` + required capabilities are present | PASS |
| Image matches a KB pattern + KB has no capability table (prose "None." like redis-valkey) + `drop` contains `ALL` + `capabilities.add` is empty | PASS |
| Image does not match any KB pattern + no `runAsUser` + no `runAsNonRoot: true` + known privilege-drop entrypoint detected | WARN |
| Image does not match any KB pattern (no KB entry exists) | not checked |

The capability requirements are sourced from `docs/solutions/` KB files, not hardcoded. Adding a new image type only requires adding a KB entry — the script picks it up automatically. The root-generic KB entry is excluded from auto-discovery and used only as a fallback when no specific KB pattern matches.
=======
| Image pattern | Required capabilities when `drop: [ALL]` | Severity |
|---|---|---|
| `nginx`, `nginx:` (in image string) | SETGID, SETUID, CHOWN, NET_BIND_SERVICE | FAIL |
| `rabbitmq` (in image string) | CHOWN, DAC_OVERRIDE, SETGID, SETUID | FAIL |
| Any image with a known privilege-drop entrypoint (gosu, su-exec, su, chroot) + no `runAsUser` + no `runAsNonRoot: true` | SETUID, SETGID | WARN |

Valkey/Redis images are explicitly skipped — they run as non-root (UID 999) and need no capabilities.

nginx detection is limited to explicit `nginx` substring in the image field. Derived images that bundle nginx under a different name (e.g., WordPress images, Open WebUI) will not match — those require per-image capability research per the existing CLAUDE.md rules.
>>>>>>> 24543b7 (feat(plan): pre-commit validation scripts plan with review refinements)

**Conditional gating (script-internal):** Exit 0 with "SKIP (no Deployments changed)" when no Deployment files are staged. Before invoking Python3, use a fast grep pre-filter: only parse files containing `capabilities:` to avoid YAML parsing on Deployments without security contexts.

**Test scenarios:**
<<<<<<< HEAD
1. nginx Deployment with `drop: [ALL]`, only `CHOWN` added → FAIL ("missing SETGID, SETUID")
2. nginx Deployment with `drop: [ALL]`, `CHOWN`, `SETGID`, `SETUID` added → PASS (NET_BIND_SERVICE is conditional — only required when nginx binds privileged ports <1024)
=======
1. nginx Deployment with `drop: [ALL]`, only `CHOWN` added → FAIL ("missing SETGID, SETUID, NET_BIND_SERVICE")
2. nginx Deployment with `drop: [ALL]`, `CHOWN`, `SETGID`, `SETUID`, `NET_BIND_SERVICE` added → PASS
>>>>>>> 24543b7 (feat(plan): pre-commit validation scripts plan with review refinements)
3. RabbitMQ Deployment with `drop: [ALL]`, missing `DAC_OVERRIDE` → FAIL
4. RabbitMQ Deployment with `drop: [ALL]`, full set (CHOWN, DAC_OVERRIDE, SETGID, SETUID) → PASS
5. Valkey Deployment with `drop: [ALL]`, no capabilities added, `runAsUser: 999` → PASS (non-root, skipped)
6. Generic image with known privilege-drop entrypoint (gosu), `drop: [ALL]`, no `runAsUser`, no `SETUID`/`SETGID` → WARN
7. Deployment with no capabilities block → not checked
8. No Deployment files staged → SKIP

### U3. `env-check.sh`

**Goal:** Warn when Deployments have missing or empty `envFrom`/`env` blocks.

**Approach:** Python3 inline reads each staged Deployment individually, checks for presence of `envFrom` or `env` blocks. Single-file analysis — no cross-file comparison. Exits 0 on WARN (never blocks commit).

**Dependencies:** None.

**Files:**
- `.claude/skills/homelab-validate/scripts/env-check.sh` (create)

**Patterns to follow:** Same Python3 inline + shell wrapper pattern as `probe-timeout-check.sh`. Single-file analysis matching the existing per-file iteration in `longhorn-fsgroup-check.sh`.

**Checks:**

| Condition | Severity |
|---|---|
| Deployment has no `envFrom` block and no `env` block | WARN |
| Deployment has `envFrom` or `env` populated | PASS |

All findings are WARN — env decisions can be intentional. Single-Deployment namespaces produce the same check as multi-Deployment namespaces. A WARN on a Deployment with intentionally no env injection is informational only; the operator acknowledges and moves on. The check's value is catching the accidental omission case (e.g., a new Deployment created without copying the namespace-standard envFrom block).

**Conditional gating:** Exit 0 with "SKIP (no Deployments changed)" when no Deployment files are staged.

**Test scenarios:**
1. Deployment with no `envFrom` block and no `env` block → WARN ("no envFrom or env blocks — may be missing ConfigMap/Secret injection")
2. Deployment with `envFrom` referencing ConfigMap `plane` → PASS
3. Deployment with `env` block containing explicit vars → PASS
4. No Deployment files staged → SKIP

### U4. Wire into pre-commit hook

**Goal:** Register all three scripts in the pre-commit hook.

**Dependencies:** U1, U2, U3.

**Files:**
- `.githooks/pre-commit` (modify)

**Approach:** Insert three unconditional blocks after the existing step 7 (`:latest` tag guard). Renumber step counters from `[7/7]` to `[10/10]`. Each script handles its own conditional gating internally (matching the pattern of `ingressroute-check.sh` and `longhorn-fsgroup-check.sh`). The hook always invokes each script; the script exits 0 with SKIP when no relevant files are staged:

```bash
echo "[N/10] Check description..."
bash "$SCRIPTS/script-name.sh" || FAILED=1
```

**Test scenarios:**
1. `git commit` with no YAML files → full hook skipped (existing behavior unchanged)
2. `git commit` with YAML files but no Deployments → steps 8-10 all SKIP
3. `git commit` with a Deployment → steps 8-10 run
4. Step 8, 9, or 10 fails → commit blocked (FAILED=1 propagates)

### U5. Update documentation

**Goal:** Document new checks in CLAUDE.md and SKILL.md.

**Dependencies:** U4 (scripts must be created and wired before docs describe them).

**Files:**
- `CLAUDE.md` (modify) — add 3 rows to the Pre-Commit Verification check table; update the conditional/unconditional count in prose below the table
- `.claude/skills/homelab-validate/SKILL.md` (modify) — add sections 8-10 following the existing section structure. Each new section documents its conditional gating explicitly (pattern: "This check runs only when Deployment files are staged. On other commits it exits 0 with SKIP."), matching the approach in existing sections 4 (IngressRoute) and 6 (Longhorn fsGroup).

**Test expectation:** none — documentation only.

## Risks & Dependencies

- **Python3 + PyYAML availability:** The existing `yaml-validity.sh` already depends on `python3` with `yaml` module. No new dependency.
- **False positives on capability WARN:** The generic root-image warning (U2) may trigger on images that genuinely don't need SETUID/SETGID. Severity is WARN, not FAIL — the operator reviews and either adds capabilities or adds an explicit `runAsNonRoot: true` to suppress the warning.
- **Performance:** Each script calls `git diff --cached` independently. Negligible (< 50ms each). Acceptable.

## Verification

1. Stage `apps/plane/deployment-rabbitmq.yaml` (has exec probe with timeoutSeconds: 10, correct capabilities, envFrom) → all three scripts PASS
2. Temporarily modify a Deployment to remove `timeoutSeconds` from an exec probe → `probe-timeout-check.sh` FAIL
3. Temporarily modify a Deployment to remove `SETGID` from nginx → `capability-check.sh` FAIL
4. Stage a Deployment with no `envFrom` and no `env` blocks → `env-check.sh` WARN ("no envFrom or env blocks")
5. Run `git commit` with the changes → full hook runs steps 1-10, correctly skipping or running new steps as appropriate

## Deferred / Open Questions

### From 2026-06-10 review

- **nginx derived-image detection** — U2 / Checks table (P2, feasibility + adversarial, confidence 100)

  The capability check matches explicit `nginx` substring only. Derived images that bundle nginx under a different name (e.g., WordPress images, Open WebUI) are not caught. Needs a separate plan covering: (1) identifying which container images utilize nginx, (2) annotating that in the deployment so it can't be missed, and (3) checking proper capability rules are in place.
