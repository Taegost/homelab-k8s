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

Generate the JWT with only Honcho's custom claims:

```python
import json, hmac, hashlib, base64, datetime

now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
header = base64.urlsafe_b64encode(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode()).rstrip(b'=').decode()
payload = base64.urlsafe_b64encode(json.dumps({'ad': True, 't': now}).encode()).rstrip(b'=').decode()
sig = base64.urlsafe_b64encode(hmac.new(AUTH_JWT_SECRET.encode(), f'{header}.{payload}'.encode(), hashlib.sha256).digest()).rstrip(b'=').decode()
jwt = f'{header}.{payload}.{sig}'
```

Do NOT include `sub`, `iat`, `exp`, or any standard JWT claims.

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
