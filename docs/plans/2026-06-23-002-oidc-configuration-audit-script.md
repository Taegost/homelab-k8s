# Plan: OIDC Configuration Audit Script

**Created:** 2026-06-23
**Status:** Not started
**Priority:** Medium
**Category:** Manual audit tool

---

## Problem

OIDC integrations with Authentik have common configuration pitfalls:
- Wrong callback URL (e.g., `/oauth/oidc/callback` vs `/auth/callback`)
- Wrong client type (Confidential vs Public for PKCE apps)
- Missing scopes
- Mismatched client IDs between SealedSecret and Authentik

These issues cause `invalid_client` or `redirect_uri` errors that require manual debugging.

## Goal

Create a manual audit script that checks common OIDC configuration issues before or after deployment.

---

## Implementation Details

### Script Location

`.claude/skills/homelab-oidc-audit/audit.sh` (new skill directory)

### Usage

```bash
# Audit a specific app
. .claude/skills/homelab-oidc-audit/audit.sh --app hermes-agent

# Audit all apps with OIDC configuration
. .claude/skills/homelab-oidc-audit/audit.sh --all
```

### What It Checks

#### 1. Deployment Environment Variables

Check if the app's Deployment has the required OIDC environment variables:

```bash
# Required variables
HERMES_DASHBOARD_OIDC_CLIENT_ID  # or app-specific name
HERMES_DASHBOARD_OIDC_ISSUER     # or app-specific name

# Optional but recommended
HERMES_DASHBOARD_OIDC_SCOPES
```

For each app, check:
- Variable exists in Deployment spec
- Value is not empty
- If it references a secretKeyRef, verify the secret exists

#### 2. Callback URL Validation

Extract the callback URL from documentation or README and validate:
- Uses HTTPS (not HTTP)
- Ends with `/auth/callback` or app-specific path
- Domain matches the Certificate/IngressRoute

#### 3. Authentik Provider Configuration (Manual Check)

Since we can't directly query Authentik's API, provide a checklist:

```
For app: hermes-agent

✓ Client Type: Public (for PKCE apps)
✓ Redirect URIs: https://hermes.taegost.com/auth/callback
✓ Scopes: openid, profile, email
✓ Client ID: matches oidc-client-id in SealedSecret
```

#### 4. Known App Patterns

Maintain a mapping of apps to their OIDC callback paths:

```bash
# Format: app_name:callback_path
hermes-agent:/auth/callback
open-webui:/oauth/oidc/callback
mealie:/api/oidc/callback
```

### Output Format

```
=== OIDC Configuration Audit — hermes-agent ===

Deployment Environment:
  ✓ HERMES_DASHBOARD_OIDC_CLIENT_ID: set (from secret/hermes-agent)
  ✓ HERMES_DASHBOARD_OIDC_ISSUER: https://authentik.diceninjagaming.com/application/o/hermes/
  ✓ HERMES_DASHBOARD: 1

Authentik Provider Checklist:
  [ ] Client Type: Public
  [ ] Redirect URIs: https://hermes.taegost.com/auth/callback
  [ ] Scopes: openid, profile, email

Common Issues:
  - If "invalid_client" error: check Client Type is Public (not Confidential)
  - If "redirect_uri" error: check Redirect URIs match exactly

PASS: Environment variables configured correctly
NOTE: Manual Authentik checks required (see checklist above)
```

---

## Files to Create/Modify

| File | Action |
|------|--------|
| `.claude/skills/homelab-oidc-audit/audit.sh` | Create |
| `.claude/skills/homelab-oidc-audit/README.md` | Create (skill documentation) |
| `docs/oidc-runbooks.md` | Reference this script |

---

## Testing

1. Run against hermes-agent → should show correct env vars and checklist
2. Run against an app without OIDC → should skip or show "no OIDC configuration"
3. Run against an app with missing env vars → should warn

---

## Notes

- This is a manual audit tool, not a pre-commit check (OIDC config is runtime-dependent)
- The Authentik checklist must be verified manually since we can't query Authentik's API
- Consider adding to the skill registry in `.claude/skills/` if it proves useful
- Future enhancement: Query Authentik API if credentials are available
