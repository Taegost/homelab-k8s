---
title: "feat: Certificate issuer validation pre-commit check"
type: feat
status: active
date: 2026-06-23
origin: docs/plans/2026-06-23-001-certificate-issuer-validation-script.md
---

# feat: Certificate issuer validation pre-commit check

## Summary

Add a pre-commit validation script that catches Certificate-to-ClusterIssuer mismatches before they're committed. The Hermes Agent deployment spent 2+ hours debugging a silent DNS-01 failure caused by referencing `letsencrypt-diceninjagaming-prod` for a `taegost.com` domain. This script prevents that class of error.

## Problem Frame

Each domain in the cluster maps to a specific ClusterIssuer backed by Route53 credentials for that domain's hosted zone. Referencing the wrong issuer causes cert-manager's ACME DNS-01 challenge to fail silently — the error is buried in cert-manager logs as "zone not found in Route 53" and takes hours to diagnose. The existing 11-check pre-commit suite catches IngressRoute, fsGroup, probe, and capability issues, but has no Certificate-specific validation.

## Requirements

- R1. The script extracts `spec.issuerRef.name` and `spec.dnsNames` from each staged `certificate-*.yaml` file
- R2. A hardcoded domain-to-issuer mapping catches the most common misconfiguration: domain matches a known pattern but uses the wrong issuer (WARN)
- R3. The script runs conditionally — only when `certificate-*.yaml` files are staged in the commit
- R4. Output follows the existing script format: section header, per-file details, PASS/WARN summary (mismatch produces WARN per KTD-3, not FAIL)
- R5. The pre-commit hook counter increments from 11 to 12 checks

## Key Technical Decisions

- **KTD-1: Python with PyYAML for YAML parsing.** Certificate files may be multi-document YAML and `spec.dnsNames` is a list. Python handles both natively, matching the pattern in `probe-timeout-check.sh` and `capability-check.sh`. Shell-based grep is fragile for nested structures.
- **KTD-2: Embedded domain-to-issuer mapping.** The mapping is small (2 domain patterns), changes rarely (only when new domains or issuers are added), and the script runs in the pre-commit hook where no external config lookup is practical. Hardcode it in the script.
- **KTD-3: Domain mismatch is WARN, not FAIL.** The mapping could be incomplete if new domains are added. A hard block would require updating the script simultaneously with every new Certificate. WARN surfaces the likely error without blocking legitimate work.
- **KTD-4: No cluster access.** The script does not call `kubectl` to verify the ClusterIssuer exists — the pre-commit hook runs locally and may not have cluster access. Validation is purely against the static domain-to-issuer mapping.

## Implementation Units

### U1. Create certificate-issuer-check.sh

**Goal:** New validation script that parses staged Certificate YAML files and checks issuer-to-domain consistency.

**Dependencies:** None

**Files:**
- `.claude/skills/homelab-validate/scripts/certificate-issuer-check.sh` (create)

**Approach:**
- Bash wrapper with Python inline (same pattern as `probe-timeout-check.sh:26-87`)
- Pre-filter: `git diff --cached --name-only` → grep for `certificate-.*\.yaml`
- Python block:
  - Load each file with `yaml.safe_load_all` (handles multi-document YAML)
  - For each Certificate document, extract `spec.issuerRef.name` and `spec.dnsNames[0]`
  - Match domain against hardcoded mapping:
    - `*.diceninjagaming.com` / `*.home.diceninjagaming.com` → `letsencrypt-diceninjagaming-prod`
    - `*.taegost.com` → `letsencrypt-taegost-prod`
  - If domain matches a pattern but issuer differs → WARN
  - If issuer contains `staging` → WARN (staging issuers should not be committed)
- Bash wrapper checks Python exit code and WARN/FAIL output, exits accordingly
- Output format matches existing scripts: `=== Certificate Issuer Check ===` header, per-file block, summary line

**Patterns to follow:**
- `probe-timeout-check.sh` for Python-in-bash structure, multi-document YAML handling, and exit code propagation
- `ingressroute-check.sh` for git-diff pre-filter and PASS/FAIL output style
- `capability-check.sh` for Python exit code handling pattern (`&& rc=0 || rc=$?`)

**Test scenarios:**
- Certificate with matching domain and issuer → PASS
- Certificate with `*.taegost.com` domain but `letsencrypt-diceninjagaming-prod` issuer → WARN with expected issuer shown
- Certificate with `*.diceninjagaming.com` domain but `letsencrypt-taegost-prod` issuer → WARN
- Certificate with staging issuer (e.g., `letsencrypt-diceninjagaming-staging`) → WARN
- Certificate with unknown domain pattern (e.g., `example.com`) → PASS (no mapping match)
- Non-Certificate file staged → script skipped (pre-filter)
- Multi-document YAML with mixed Certificates and other kinds → only Certificates checked

**Verification:** Run the script manually against test Certificate YAML files. Confirm it outputs the expected PASS/WARN for each scenario.

### U2. Integrate into pre-commit hook

**Goal:** Wire the new script into the existing pre-commit validation suite as check 12.

**Dependencies:** U1

**Files:**
- `.githooks/pre-commit` (modify)

**Approach:**
- Add conditional block after check 11 (env injection, lines 115-123):
  ```bash
  # 12. Certificate issuer check (only if Certificate files changed)
  if echo "$STAGED" | grep -q 'certificate-'; then
    echo ""
    echo "[12/12] Certificate issuer check..."
    bash "$SCRIPTS/certificate-issuer-check.sh" || FAILED=1
  else
    echo ""
    echo "[12/12] Certificate issuer check — SKIP (no Certificates changed)"
  fi
  ```
- Update all existing `[N/11]` labels to `[N/12]` — search the file for the pattern `\[.*\/11\]` to find all occurrences

**Test scenarios:**
- Commit touching only `certificate-*.yaml` files → check 12 runs, others skip
- Commit touching only `deployment-*.yaml` files → check 12 skips, others run
- Commit touching both → all applicable checks run
- Pre-commit hook counter displays `[12/12]` consistently

**Verification:** Stage a Certificate file with a wrong issuer, run `git commit`, confirm the hook blocks or warns.

### U3. Cross-reference solutions doc

**Goal:** Update the prevention section of the existing solutions doc to reference the new script.

**Dependencies:** U1

**Files:**
- `docs/solutions/runtime-errors/certificate-wrong-route53-issuer.md` (modify)

**Approach:** Add a bullet to the `## Prevention` section:
- `Pre-commit validation: the homelab-validate suite includes a certificate issuer check that warns when a Certificate's domain doesn't match its ClusterIssuer's expected domain pattern.`

**Test expectation:** none — documentation-only change.

**Verification:** The solutions doc mentions the script in its Prevention section.
