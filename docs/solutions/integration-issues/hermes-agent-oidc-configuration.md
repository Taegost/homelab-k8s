---
title: Hermes Agent OIDC authentication failures
date: 2026-06-23
category: integration-issues
module: hermes-agent
problem_type: integration_issue
component: authentication
symptoms:
  - "Invalid redirect_uri" error from Authentik after login
  - "invalid_client" error during token exchange
  - Dashboard accessible but desktop app cannot connect
  - "Dashboard logs out after 15 minutes of inactivity"
root_cause: config_error
resolution_type: config_change
severity: medium
tags: [hermes-agent, oidc, authentik, pkce, desktop-app, websocket, offline_access, refresh-token]
---

# Hermes Agent OIDC authentication failures

## Problem

Multiple OIDC configuration issues when deploying Hermes Agent with Authentik as the identity provider:

1. Redirect URI mismatch causing "Invalid redirect_uri" error
2. Client type mismatch causing "invalid_client" error during token exchange
3. Desktop app WebSocket connection rejected (upstream bug)
4. Missing `offline_access` scope causing 15-minute session timeout

## Symptoms

- After Authentik login, redirect back to Hermes fails with: `{"detail":"Invalid code: IDP rejected token request: invalid_client"}`
- Or: `The request fails due to a missing, invalid, or mismatching redirection URI (redirect_uri)`
- Desktop app shows "Could not reach this gateway" despite web dashboard working

## What Didn't Work

- Using `/oauth/oidc/callback` as the redirect URI (wrong path)
- Configuring Authentik provider as "Confidential" client type

## Solution

### 1. Correct Redirect URI

The Hermes dashboard callback path is `/auth/callback`, not `/oauth/oidc/callback`:

**Authentik Provider Configuration:**
- **Redirect URIs:** `https://hermes.taegost.com/auth/callback`

**Source:** Official Hermes docs at https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard

### 2. Set Client Type to Public

Hermes uses PKCE (Proof Key for Code Exchange) and does not send a client secret during token exchange. Authentik's "Confidential" client type requires a secret, causing `invalid_client`:

**Authentik Provider Configuration:**
- **Client Type:** Public (not Confidential)
- **Client Secret:** Not used by Hermes (can be left as auto-generated, not needed in env var)

### 3. Desktop App WebSocket Issue

The Hermes Desktop app has a known upstream bug where WebSocket connections to remote gateways are rejected with 403:

**Issue:** https://github.com/NousResearch/hermes-agent/issues/38412
**PR:** https://github.com/NousResearch/hermes-agent/pull/40408

**Workaround:** Use the web dashboard at `https://hermes.taegost.com` until the upstream fix is merged.

### 4. Add `offline_access` Scope for Refresh Tokens

The dashboard logs out after 15 minutes because Authentik 2024.2+ requires the
`offline_access` scope to issue refresh tokens. Without it, only the access token
is issued (15-minute TTL) and when it expires the SPA redirects to `/login`.

**Deployment env var:**
```yaml
- name: HERMES_DASHBOARD_OIDC_SCOPES
  value: "openid profile email offline_access"
```

**Authentik Provider Configuration:**
- **Scopes:** Include `offline_access` alongside `openid`, `profile`, `email`
- **Advanced protocol settings → Refresh Token validity:** Set to 1 day
  (balances convenience against risk — the dashboard is internal-only)

The Hermes self-hosted OIDC provider already supports refresh tokens — when the
IDP issues them, the dashboard uses the `refresh_token` grant for silent re-auth
before the access token expires. No user interaction needed.

## Why This Works

1. **Redirect URI:** The OIDC spec requires exact match between registered and requested redirect URIs. Hermes hardcodes `/auth/callback` as the path.

2. **Public Client:** PKCE is designed for public clients that cannot securely store secrets. The authorization code exchange uses the code_verifier instead of a client_secret. Authentik's "Confidential" mode rejects requests without a secret.

3. **Desktop App:** The Electron client sends `file:///null` as the Origin header, which fails the WebSocket security check. This is an upstream bug in the gateway code.

4. **Refresh Tokens:** The OIDC `offline_access` scope tells the IDP to issue a refresh token alongside the access token. The Hermes dashboard stores the refresh token and uses it to silently obtain a new access token before the 15-minute TTL expires. Authentik 2024.2+ requires this scope to be explicitly requested — it is not included in the default `openid profile email` set.

## Prevention

- Always check the application's official documentation for the correct callback path
- For OIDC providers, understand whether the application uses PKCE (public) or client_secret (confidential)
- When deploying new OIDC integrations, test the full flow before committing configuration

## Related Issues

- Hermes Agent OIDC docs: https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard
- Desktop WebSocket bug: https://github.com/NousResearch/hermes-agent/issues/38412
- [Hermes Agent IngressRoute misrouted /api/* to API server instead of dashboard](../runtime-errors/hermes-agent-ingressroute-api-misroute.md)
  — same symptom family (401/403 on dashboard, Desktop can't connect) but
  different root cause (IngressRoute port routing vs. OIDC config). Check
  both when debugging dashboard auth errors.
