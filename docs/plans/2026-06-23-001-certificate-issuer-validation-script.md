# Plan: Certificate Issuer Validation Script

**Created:** 2026-06-23
**Status:** Not started
**Priority:** High
**Category:** Pre-commit validation

---

## Problem

When deploying Hermes Agent, the Certificate resource referenced `letsencrypt-diceninjagaming-prod` instead of `letsencrypt-taegost-prod`. This caused the ACME DNS-01 challenge to fail silently for 2+ hours with "zone not found in Route 53" buried in cert-manager logs.

## Goal

Create a pre-commit validation script that catches Certificate issuer mismatches before they're committed, saving hours of debugging.

## Trigger Condition

Run when `certificate-*.yaml` files are staged in a commit (same pattern as IngressRoute, Longhorn fsGroup, and other conditional checks).

---

## Implementation Details

### Script Location

`.claude/skills/homelab-validate/scripts/certificate-issuer-check.sh`

### What It Checks

1. **Parse Certificate YAML** — Extract `spec.issuerRef.name` and `spec.dnsNames` from each staged Certificate file

2. **Validate issuer exists** — Check if the referenced ClusterIssuer exists in the cluster:
   ```bash
   kubectl get clusterissuer <name> -o name 2>/dev/null
   ```

3. **Domain-to-issuer mapping** (optional, more complex):
   - Query Route53 for hosted zones matching the Certificate's `dnsNames`
   - Verify the issuer's credentials have access to that zone
   - This requires AWS CLI access and may not be available in all environments

4. **Known issuer mapping** — Maintain a simple mapping of domain patterns to expected issuers:
   ```bash
   # Format: domain_pattern:expected_issuer
   "*.diceninjagaming.com:letsencrypt-diceninjagaming-prod"
   "*.taegost.com:letsencrypt-taegost-prod"
   ```
   Check if the Certificate's domain matches a pattern but uses a different issuer.

### Validation Logic

```
For each staged certificate-*.yaml:
  1. Extract issuerRef.name
  2. Extract dnsNames[0] (primary domain)
  3. If issuer doesn't exist → FAIL
  4. If domain matches known pattern AND issuer doesn't match → WARN
  5. Otherwise → PASS
```

### Output Format

```
=== Certificate Issuer Check ===
--- apps/hermes-agent/certificate-hermes-agent.yaml ---
  Domain: hermes.taegost.com
  Issuer: letsencrypt-diceninjagaming-prod
  WARN: Domain matches *.taegost.com but issuer is for diceninjagaming.com
         Expected: letsencrypt-taegost-prod
PASS: 0 warnings (or FAIL: 1 warning)
```

### Integration with Pre-Commit Hook

Add to `.githooks/pre-commit` as a conditional check:

```bash
# Certificate issuer check (only when Certificate files are staged)
if echo "$STAGED_FILES" | grep -q "certificate-.*\.yaml"; then
  run_check "Certificate issuer" "$SKILL_DIR/scripts/certificate-issuer-check.sh"
fi
```

---

## Files to Create/Modify

| File | Action |
|------|--------|
| `.claude/skills/homelab-validate/scripts/certificate-issuer-check.sh` | Create |
| `.githooks/pre-commit` | Add conditional check |
| `docs/solutions/runtime-errors/certificate-wrong-route53-issuer.md` | Reference this script in Prevention section |

---

## Testing

1. Create a Certificate with wrong issuer → script should warn
2. Create a Certificate with correct issuer → script should pass
3. Create a Certificate with unknown domain → script should pass (no pattern match)
4. Stage a non-Certificate file → script should be skipped

---

## Notes

- The domain-to-issuer mapping is optional but catches the most common error
- If Route53 access is available, a more robust check is possible
- This check is advisory (WARN) not blocking, since the mapping may be incomplete
- Consider adding to `/homelab-validate` skill documentation
