# Plan: OIDC Integration Runbook

**Created:** 2026-06-23
**Status:** Not started
**Priority:** Medium
**Category:** Documentation

---

## Problem

Every new app that needs OIDC authentication with Authentik requires the same configuration steps, but the process is not documented. Common pitfalls (wrong callback URL, wrong client type) are discovered through debugging, wasting time.

## Goal

Create a comprehensive runbook for OIDC integrations with Authentik, similar to `docs/postgres-runbooks.md`.

---

## Implementation Details

### File Location

`docs/oidc-runbooks.md`

### Structure

```markdown
# OIDC Integration Runbooks

## Overview

This runbook covers integrating applications with Authentik for OIDC authentication.

## Prerequisites

- Authentik deployed and accessible
- Application deployed with OIDC support
- DNS configured for the application

## New App Integration (OIDC)

### Phase 1: Authentik Provider Setup

1. Create Application in Authentik
2. Create Provider (see Client Type section below)
3. Bind Provider to Application

### Phase 2: Application Configuration

1. Set environment variables
2. Configure callback URL
3. Test authentication flow

### Phase 3: Verification

1. Test login flow
2. Verify token exchange
3. Check for common errors

## Client Type: Public vs Confidential

### When to Use Public (PKCE)

- Application cannot securely store client secrets
- Desktop applications (Electron, native apps)
- Single-page applications (SPAs)
- Applications using PKCE flow

**Examples:** Hermes Agent, Open WebUI

### When to Use Confidential

- Server-side applications with secure secret storage
- Applications that can securely store client_secret
- Traditional web applications with backend

**Examples:** WordPress (if using OIDC), Nextcloud

### How to Determine

Check the application's OIDC implementation:
- Does it send a `client_secret` in the token exchange? → Confidential
- Does it use PKCE (`code_verifier`/`code_challenge`)? → Public

## Callback URL Reference

| Application | Callback Path | Notes |
|-------------|---------------|-------|
| Hermes Agent | `/auth/callback` | Official docs: hermes-agent.nousresearch.com |
| Open WebUI | `/oauth/oidc/callback` | Check Open WebUI docs |
| Mealie | `/api/oidc/callback` | Check Mealie docs |
| Nextcloud | `/apps/oidc_login/oidc` | Via OIDC Login app |

**Always verify the callback path in the application's official documentation.**

## Environment Variables

Common environment variables for OIDC integration:

```bash
# Client ID (from Authentik)
OIDC_CLIENT_ID=<client-id>

# Issuer URL (Authentik provider URL)
OIDC_ISSUER=https://authentik.example.com/application/o/<app-slug>/

# Optional: Scopes (default: openid profile email)
OIDC_SCOPES=openid profile email

# Optional: Client Secret (for confidential clients only)
OIDC_CLIENT_SECRET=<secret>  # Only if using Confidential client type
```

## Troubleshooting

### "invalid_client" Error

**Symptom:** Token exchange fails with `invalid_client`

**Cause:** Client type mismatch — Authentik expects client_secret but app doesn't send it

**Fix:**
1. Check if app uses PKCE → should be Public client
2. Check if app sends client_secret → should be Confidential client
3. Update Authentik provider client type accordingly

### "redirect_uri" Error

**Symptom:** `The request fails due to a missing, invalid, or mismatching redirection URI`

**Cause:** Callback URL in Authentik doesn't match what the app sends

**Fix:**
1. Check app's official documentation for correct callback path
2. Update Authentik provider Redirect URIs to match exactly
3. Ensure HTTPS is used (not HTTP)

### "invalid_grant" Error

**Symptom:** Token exchange fails with `invalid_grant`

**Cause:** Authorization code expired or already used

**Fix:**
1. Try logging in again (codes are single-use and expire quickly)
2. Check for clock skew between servers
3. Verify the app is exchanging the code immediately

## Known Issues

### Hermes Desktop WebSocket Bug

**Issue:** https://github.com/NousResearch/hermes-agent/issues/38412

**Symptom:** Desktop app shows "Could not reach this gateway" despite web dashboard working

**Cause:** Electron sends `file:///null` as Origin header, failing WebSocket security check

**Workaround:** Use web dashboard until upstream fix is merged

## References

- Authentik OIDC documentation: https://docs.goauthentik.io/docs/providers/oauth2/
- Hermes Agent OIDC setup: https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard
```

---

## Files to Create/Modify

| File | Action |
|------|--------|
| `docs/oidc-runbooks.md` | Create |
| `apps/hermes-agent/README.md` | Add reference to this runbook |
| `CLAUDE.md` | Add to "Read Before Acting" section |

---

## Testing

1. Follow the runbook for a new OIDC integration
2. Verify all steps are clear and complete
3. Check that troubleshooting section covers common errors
4. Ensure callback URL reference table is accurate

---

## Notes

- This runbook should be referenced in CLAUDE.md's "Read Before Acting" section
- Consider adding a checklist format for quick reference
- Update callback URL table as new apps are added
- Link to upstream documentation for each application
