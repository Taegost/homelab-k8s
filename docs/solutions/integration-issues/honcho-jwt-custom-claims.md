---
module: honcho
tags: [jwt, authentication, hermes, honcho]
problem_type: integration-issue
---

# Honcho JWT uses custom claims, not standard sub/iat/exp

## Problem

Generating a JWT with standard claims (`sub`, `iat`, `exp`) for Honcho's
`AUTH_JWT_SECRET` produces "Invalid JWT" errors when Hermes calls the Honcho API.

Honcho uses **custom JWT claim names** — `ad` (admin), `t` (timestamp),
`w` (workspace), `p` (peer), `s` (session). Standard claims are ignored.

The `exp` claim creates a catch-22: PyJWT validates it as a Unix timestamp (per
JWT spec), while Honcho's `parse_datetime_iso` expects ISO 8601. No single
format satisfies both. The solution is to omit `exp` entirely.

## Root Cause

Honcho's [`verify_jwt()`](https://github.com/plastic-labs/honcho/blob/main/src/security.py)
in `src/security.py` decodes the JWT with PyJWT, then reads custom fields
(`ad`, `t`, `w`, `p`, `s`) into a [`JWTParams`](https://github.com/plastic-labs/honcho/blob/main/src/security.py)
model. The `except jwt.PyJWTError` catch-all masks the real error (PyJWT's `exp`
validation) as a generic "Invalid JWT".

An admin JWT (`ad: true`) bypasses all permission checks — no workspace, peer,
or session claims are needed for a service integration like Hermes.

## Solution

Use Honcho's built-in `generate_jwt.py` script (available in the container at
`/app/scripts/generate_jwt.py`). Do NOT hand-roll JWTs — PyJWT's JSON
serialization and Honcho's may differ, causing signature mismatches.

```bash
# Admin JWT (no expiry)
kubectl exec -n honcho deployment/honcho-api -- python /app/scripts/generate_jwt.py --admin --print-only

# Admin JWT with expiry
kubectl exec -n honcho deployment/honcho-api -- python /app/scripts/generate_jwt.py --admin --expires 1y --print-only
```

Do NOT include standard `sub`, `iat`, `exp` claims — Honcho uses custom claim
names (`ad`, `t`, `w`, `p`, `s`).

## Verification

```bash
# Decode the JWT payload (without verification) to confirm the claims
echo "<jwt>" | cut -d. -f2 | python3 -c "import sys, base64, json; print(json.dumps(json.loads(base64.urlsafe_b64decode(sys.stdin.read() + '==')), indent=2))"
# Should show: {"ad": true, "t": "2026-06-24T..."}
```

## References

- [`apps/honcho/README.md`](../../../apps/honcho/README.md) — Hermes Integration section
- [`src/security.py`](https://github.com/plastic-labs/honcho/blob/main/src/security.py) — `verify_jwt()` and `JWTParams` model
- [`src/utils/formatting.py`](https://github.com/plastic-labs/honcho/blob/main/src/utils/formatting.py) — `parse_datetime_iso()`
