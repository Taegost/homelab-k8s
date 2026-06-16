---
type: feat
status: active
created: 2026-06-16
origin: docs/plans/2026-06-10-001-feat-pre-commit-validation-scripts-plan.md
---

# feat: Implement Pre-Commit Validation Scripts (probe-timeout, capability, env)

## Summary

Implement the three remaining validation scripts from the pre-commit validation
plan: `probe-timeout-check.sh`, `capability-check.sh`, and `env-check.sh`. Wire
them into the pre-commit hook and update documentation.

This plan is the implementation companion to the design plan at
`docs/plans/2026-06-10-001-feat-pre-commit-validation-scripts-plan.md`. All
requirements, key technical decisions, and scope boundaries are defined there.
This plan focuses on the concrete implementation approach.

## Problem Frame

See origin: `docs/plans/2026-06-10-001-feat-pre-commit-validation-scripts-plan.md`

Three categories of deployment bugs discovered during the Plane debugging session
(2026-06-09/10) need automated pre-commit checks:
1. Exec probes with default 1s timeout on known-slow CLIs
2. Missing capabilities for images that drop ALL
3. Deployments missing envFrom/env blocks

## Requirements

- **R1:** Catch exec probes with missing or default `timeoutSeconds` on known-slow CLI commands
- **R2:** Catch missing capabilities for nginx and RabbitMQ images when `drop` includes `ALL`
- **R3:** Warn when a Deployment has no `envFrom` or `env` blocks
- **R4:** Integrate into the existing pre-commit hook with conditional gating
- **R5:** Follow existing script conventions in `.claude/skills/homelab-validate/SKILL.md`

## Key Technical Decisions

All KTDs are defined in the origin plan. Summary:

- **KTD-1:** Scripts match image name patterns, not app-specific names
- **KTD-2:** Hybrid grep + Python3 inline (matches `networkpolicy-check.sh` pattern)
- **KTD-3:** Tiered severity — FAIL for known-slow CLIs and missing capabilities, WARN for env gaps
- **KTD-4:** Conditional gating — SKIP when no Deployment files staged

## Implementation Units

### U1. `probe-timeout-check.sh`

**Goal:** Catch exec probes with default (too-short) `timeoutSeconds`.

**Requirements:** R1, R4, R5

**Dependencies:** None

**Files:**
- `.claude/skills/homelab-validate/scripts/probe-timeout-check.sh` (create)

**Approach:**

Shell wrapper + Python3 inline, following the `networkpolicy-check.sh` pattern.

**Shell wrapper:**
1. `git diff --cached --name-only` to get staged YAML files
2. `grep -l "kind: Deployment"` to filter to Deployments only
3. Fast pre-filter: `grep -l 'exec:'` to skip Deployments without exec probes
4. If no files survive pre-filter, echo "SKIP (no Deployments with exec probes staged)" and exit 0
5. For each file, invoke Python3 inline to parse and check

**Python3 inline checks:**
- Load YAML with `yaml.safe_load_all`
- For each Deployment, iterate all containers
- For each container, check `livenessProbe`, `readinessProbe`, `startupProbe`
- If probe has `exec` field, extract the command (first element of `command` array)
- Match command against tiered CLI lists:
  - Slow tier (FAIL if <5s): `rabbitmq-diagnostics`, `rabbitmqctl`, `celery`
  - Fast tier (FAIL if <2s): `redis-cli`, `valkey-cli`, `pg_isready`, `mysqladmin`, `mongosh`
- If `timeoutSeconds` is missing, Kubernetes defaults to 1s — treat as `timeoutSeconds: 1`
- Generic exec probes with missing/default timeout: WARN (not FAIL)

**Output format** (matching existing scripts):

```text
=== Probe Timeout Check ===
  apps/plane/deployment-rabbitmq.yaml
    PASS: exec probe timeoutSeconds: 10
  apps/foo/deployment-foo.yaml
    FAIL: livenessProbe exec [redis-cli ping] — timeoutSeconds missing (default 1s), need >= 2
PASS: all exec probe timeouts adequate

```

**Test scenarios:**
1. RabbitMQ Deployment with exec probe `["rabbitmq-diagnostics", "check_running"]`, no timeoutSeconds → FAIL
2. Valkey Deployment with exec probe `["valkey-cli", "ping"]`, timeoutSeconds: 1 → FAIL
3. Generic Deployment with exec probe `["some-check"]`, no timeoutSeconds → WARN
4. Deployment with exec probe `["rabbitmq-diagnostics", "check_running"]`, timeoutSeconds: 10 → PASS
5. Deployment with only httpGet probes → PASS (no exec probes present)
6. No Deployment files staged → SKIP

### U2. `capability-check.sh`

**Goal:** Catch missing capabilities for well-known images when `drop` includes `ALL`.

**Requirements:** R2, R4, R5

**Dependencies:** None

**Files:**
- `.claude/skills/homelab-validate/scripts/capability-check.sh` (create)

**Approach:**

Shell wrapper + Python3 inline + KB auto-discovery. This is the most complex
script — it reads capability requirements from `docs/solutions/` KB files
rather than hardcoding them.

**KB auto-discovery (shell, at startup):**

Reuse the pattern from `audit.sh`:

```bash
KB_DIR="$REPO_ROOT/docs/solutions"
declare -A IMAGE_PATTERNS
declare -A TYPE_TO_KB

for kb_file in "$KB_DIR"/base-images-*.md; do
    [[ "$kb_file" == *"root-generic"* ]] && continue
    type_name=$(basename "$kb_file" .md | sed 's/^base-images-//')
    TYPE_TO_KB["$type_name"]="$(basename "$kb_file")"
    while read -r pattern; do
        IMAGE_PATTERNS["$pattern"]="$type_name"
    done < <(awk '/^## Image patterns/{flag=1; next} /^## /{flag=0} flag' "$kb_file" \
        | grep -oP '`\K[^`]+' | sed 's/\*//g')
done

```

**Capability extraction from KB (shell function):**

For a given KB file, extract the required capabilities from the markdown table:

```bash
_extract_caps() {
    local kb_file="$1"
    # Read from "## Required capabilities" table header to next ## or EOF
    # Extract capability names from first column (backtick-wrapped)
    awk '/^\| Capability \| Why \|/{flag=1; next} /^$|^## /{flag=0} flag' "$kb_file" \
        | grep -oP '`\K[^`]+'
}

```

If the KB file has "None." in the prose after the heading (like redis-valkey),
the extraction returns empty — that means no capabilities required.

**Shell wrapper:**
1. `git diff --cached --name-only` to get staged YAML files
2. `grep -l "kind: Deployment"` to filter to Deployments
3. Fast pre-filter: `grep -l 'capabilities:'` to skip Deployments without security contexts
4. If no files survive, echo "SKIP" and exit 0
5. For each file, invoke Python3 inline

**Python3 inline checks:**
- Load YAML with `yaml.safe_load_all`
- For each Deployment, iterate all containers
- For each container:
  - Extract `image` field
  - Check if `securityContext.capabilities.drop` contains `"ALL"`
  - If not, skip (check only applies when drop: ALL)
  - Match image against `IMAGE_PATTERNS` (passed as env var or heredoc)
  - If matched, get the type, look up required capabilities (passed as env var)
  - Compare required vs `securityContext.capabilities.add`
  - Report missing capabilities as FAIL
  - If KB has no capability table (empty required set) and `add` is empty: PASS
- If image doesn't match any KB pattern: skip (not checked). The script
  cannot detect privilege-drop entrypoints (gosu, su-exec) because they
  live in the image's Dockerfile ENTRYPOINT, not in the Deployment's
  command/args fields. Unknown images require manual Dockerfile review
  per the CLAUDE.md research rules.

**KB data approach:** Instead of building JSON in shell and passing via env
var, pass the KB directory path to Python3 and let it read the markdown files
directly. Python3 can parse the markdown tables with regex, avoiding
shell-to-Python3 data serialization entirely. This matches the approach used
by `networkpolicy-check.sh` (Python3 reads files directly) and is more robust
than shell-constructed JSON.

**Output format:**

```text
=== Capability Check ===
  apps/plane/deployment-plane-admin.yaml
    FAIL: container 'admin' (nginx-derived) — drop: [ALL] but missing: SETGID, SETUID
  apps/plane/deployment-rabbitmq.yaml
    PASS: container 'rabbitmq' — all required capabilities present
  apps/plane/deployment-valkey.yaml
    PASS: container 'valkey' — no capabilities required (non-root image)
PASS: all capability checks passed

```

**Test scenarios:**
1. nginx Deployment with `drop: [ALL]`, only `CHOWN` added → FAIL ("missing SETGID, SETUID")
2. nginx Deployment with `drop: [ALL]`, `CHOWN`, `SETGID`, `SETUID` added → PASS
3. RabbitMQ Deployment with `drop: [ALL]`, missing `DAC_OVERRIDE` → FAIL
4. RabbitMQ Deployment with `drop: [ALL]`, full set → PASS
5. Valkey Deployment with `drop: [ALL]`, no capabilities added, `runAsUser: 999` → PASS
6. Unknown image with `drop: [ALL]` → not checked (no KB entry)
7. Deployment with no capabilities block → not checked
8. No Deployment files staged → SKIP

### U3. `env-check.sh`

**Goal:** Warn when Deployments have missing or empty `envFrom`/`env` blocks.

**Requirements:** R3, R4, R5

**Dependencies:** None

**Files:**
- `.claude/skills/homelab-validate/scripts/env-check.sh` (create)

**Approach:**

Simplest of the three scripts. Shell wrapper + Python3 inline.

**Shell wrapper:**
1. `git diff --cached --name-only` to get staged YAML files
2. `grep -l "kind: Deployment"` to filter to Deployments
3. If no Deployments, echo "SKIP" and exit 0
4. For each file, invoke Python3 inline

**Python3 inline checks:**
- Load YAML with `yaml.safe_load_all`
- For each Deployment, iterate main containers only (`spec.containers`,
  not `spec.initContainers`) — init containers are short-lived setup
  tasks that legitimately have no env injection
- For each container, check for `envFrom` or `env` keys
- If neither exists: WARN
- If either exists (even empty list): PASS

**Important:** All findings are WARN — this script never blocks commits.
Exit code is always 0.

**Output format:**

```text
=== Env Check ===
  apps/plane/deployment-plane-api.yaml
    PASS: has envFrom
  apps/foo/deployment-foo.yaml
    WARN: no envFrom or env blocks — may be missing ConfigMap/Secret injection
WARN: 1 Deployment(s) with missing env injection (non-blocking)

```

**Test scenarios:**
1. Deployment with no `envFrom` and no `env` → WARN
2. Deployment with `envFrom` referencing ConfigMap → PASS
3. Deployment with `env` block → PASS
4. No Deployment files staged → SKIP

### U4. Wire into pre-commit hook

**Goal:** Register all three scripts in the pre-commit hook.

**Requirements:** R4

**Dependencies:** U1, U2, U3

**Files:**
- `.githooks/pre-commit` (modify)

**Approach:**

The hook currently runs 8 checks (1/8 through 8/8). Add three new conditional
blocks after the NetworkPolicy check (step 8). Renumber all steps to 1/11
through 11/11.

Each new block follows the existing conditional pattern:

```bash
# N. Check name (only if Deployments changed)
if echo "$STAGED" | grep -q 'deployment'; then
  echo ""
  echo "[N/11] Check name..."
  bash "$SCRIPTS/script-name.sh" || FAILED=1
else
  echo ""
  echo "[N/11] Check name — SKIP (no Deployments changed)"
fi

```

**Placement:** After step 8 (NetworkPolicy), before the final PASS/FAIL summary.
Steps 9-11 are the new checks. The script-internal SKIP (when no exec probes,
no capabilities blocks, etc.) is an additional layer — the hook-level gating
avoids invoking the scripts at all when no Deployments are staged.

**Note on env-check.sh:** Since env-check.sh only produces WARN (never FAIL),
the `|| FAILED=1` still applies — the script always exits 0 on WARN. If a
future env check is promoted to FAIL, only the script changes; the hook wiring
stays the same.

**Test scenarios:**
1. `git commit` with no YAML files → full hook skipped
2. `git commit` with YAML files but no Deployments → steps 9-11 all SKIP
3. `git commit` with a Deployment → steps 9-11 run
4. Step 9 or 10 fails → commit blocked (FAILED=1 propagates)
5. Step 11 produces WARN → commit proceeds (exit 0)

### U5. Update documentation

**Goal:** Document new checks in CLAUDE.md and SKILL.md.

**Requirements:** R5

**Dependencies:** U4

**Files:**
- `CLAUDE.md` (modify) — add 3 rows to Pre-Commit Verification table
- `.claude/skills/homelab-validate/SKILL.md` (modify) — add sections 8, 9, 10

**Approach:**

**CLAUDE.md table additions:**

| Probe timeout | `probe-timeout-check.sh` | Exec probes with default/too-short `timeoutSeconds` on known-slow CLIs |
| Capabilities | `capability-check.sh` | Missing capabilities for images that drop ALL (reads from KB) |
| Env injection | `env-check.sh` | Deployments missing `envFrom`/`env` blocks (WARN only) |

Update the conditional check prose to include "Deployment" in the list of
conditional file triggers.

**SKILL.md additions:**

Three new sections (8, 9, 10) following the existing section structure. Each
documents its conditional gating: "This check runs only when Deployment files
are staged. On other commits it exits 0 with SKIP."

**Test expectation:** none — documentation only.

---

## Risks & Dependencies

- **Python3 + PyYAML:** Already a dependency (`yaml-validity.sh`, `networkpolicy-check.sh`). No new dependency.
- **KB format stability:** `capability-check.sh` parses markdown tables from `docs/solutions/`. If the table format changes, the script breaks. Mitigated by the fact that the same format is used by `audit.sh` (which also parses these files) — format changes would break both, providing early warning.
- **False positives on env WARN:** The env check may flag Deployments that intentionally have no env injection. Severity is WARN, not FAIL — informational only.

## Verification

1. Stage a Deployment with an exec probe and no timeoutSeconds → `probe-timeout-check.sh` FAIL
2. Stage a Deployment with correct probe timeouts → `probe-timeout-check.sh` PASS
3. Stage a Deployment with `drop: [ALL]` and missing capabilities → `capability-check.sh` FAIL
4. Stage a Deployment with correct capabilities → `capability-check.sh` PASS
5. Stage a Deployment with no envFrom/env → `env-check.sh` WARN (non-blocking)
6. Run full `git commit` → hook runs 1/11 through 11/11, correct SKIP/run behavior
7. Run `/homelab-validate` manually → all checks pass

## Deferred / Open Questions

From origin plan:
- **nginx derived-image detection** — capability-check matches explicit nginx
  substring only. Derived images that bundle nginx under a different name are
  not caught. Needs a separate plan.
- **Test infrastructure** — a way to run checks against known Deployment
  fixtures before committing script changes.
