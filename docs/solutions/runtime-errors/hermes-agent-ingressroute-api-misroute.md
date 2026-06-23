---
title: "Hermes Agent IngressRoute misrouted /api/* to API server instead of dashboard"
date: 2026-06-23
category: runtime-errors
module: hermes-agent
problem_type: runtime_error
component: traefik
symptoms:
  - "Dashboard SPA /api/* calls return 401 Unauthorized or 403 Forbidden"
  - "Chat tab shows 403 on /api/auth/ws-ticket then 401 Invalid API key"
  - "Config and Keys tabs never load (spinner forever)"
  - "Gateway logs flooded with 'API server rejected invalid API key'"
  - "Hermes Desktop cannot connect to remote gateway"
root_cause: config_error
resolution_type: config_change
severity: high
tags: [hermes-agent, traefik, ingressroute, path-routing, oidc, dashboard, api-server]
---

# Hermes Agent IngressRoute misrouted /api/* to API server instead of dashboard

## Problem

The hermes-agent IngressRoute sent all `/api/*` traffic to port 8642 (the
OpenAI-compatible API server), but the dashboard SPA on port 9119 makes its
own `/api/*` calls (sessions, auth/ws-ticket, config, keys) that are
authenticated via OIDC session cookies — not the `API_SERVER_KEY` Bearer
token the API server expects. This broke the entire dashboard UI and prevented
Hermes Desktop from connecting.

## Symptoms

- Chat tab shows HTTP 403 on `/api/auth/ws-ticket`, then HTTP 401
  `{"error": {"message": "Invalid API key", "type": "invalid_request_error", "code": "invalid_api_key"}}`
- Config and Keys tabs never load (spinner forever)
- Gateway logs flooded with:
  `WARNING gateway.platforms.api_server: API server rejected invalid API key: remote='10.42.2.167' method='GET' path='/api/sessions?limit=50&offset=0&order=created'`
- All dashboard logs show `Error: 404: Not Found`
- Hermes Desktop shows "Could not connect to Hermes gateway" (GitHub #39365
  describes a misleading "OpenRouter API key missing" error from the same
  root cause)

## What Didn't Work

- GitHub issues #39365 and #38412 provided context on the two-server
  architecture and the misleading Desktop error message, but neither issue
  contained a specific IngressRoute fix.
- The unofficial Helm chart (ultraworkers/hermes-agent-helm-chart) confirmed
  the two-server architecture with ports 9119 and 8642, but uses a
  single-port model without the dashboard — it couldn't serve as a routing
  reference.
- Official Hermes docs don't document which `/api/*` paths belong to which
  server. Path ownership had to be determined empirically from gateway log
  output and the API server documentation.

## Solution

Split the single `/api` IngressRoute into three routes. More specific paths
are declared first so Traefik matches them before the catch-all `/api` prefix.

**Before:**

```yaml
routes:
  - match: Host(`hermes.taegost.com`) && PathPrefix(`/api`)
    services:
      - name: hermes-agent
        port: 8642        # everything /api/* went here
  - match: Host(`hermes.taegost.com`) && PathPrefix(`/webhooks`)
    services:
      - name: hermes-agent
        port: 8644
  - match: Host(`hermes.taegost.com`)
    services:
      - name: hermes-agent
        port: 9119
```

**After** (`apps/hermes-agent/ingressroute-hermes-agent.yaml`):

```yaml
routes:
  # API Server: OpenAI-compatible endpoints
  - match: Host(`hermes.taegost.com`) && PathPrefix(`/api/v1`)
    services:
      - name: hermes-agent
        port: 8642
  # API Server: Jobs API (programmatic access)
  - match: Host(`hermes.taegost.com`) && PathPrefix(`/api/jobs`)
    services:
      - name: hermes-agent
        port: 8642
  # Dashboard: internal API (sessions, auth, config, keys)
  - match: Host(`hermes.taegost.com`) && PathPrefix(`/api`)
    services:
      - name: hermes-agent
        port: 9119
  - match: Host(`hermes.taegost.com`) && PathPrefix(`/webhooks`)
    services:
      - name: hermes-agent
        port: 8644
  - match: Host(`hermes.taegost.com`)
    services:
      - name: hermes-agent
        port: 9119
```

## Why This Works

Hermes runs two separate HTTP servers in the same container:

| Port | Server | Auth method | Endpoints |
|------|--------|-------------|-----------|
| 9119 | Dashboard | OIDC session cookies | `/api/sessions`, `/api/auth/ws-ticket`, `/api/config`, `/api/keys`, SPA |
| 8642 | API Server | `API_SERVER_KEY` Bearer token | `/v1/*`, `/api/v1/*`, `/api/jobs/*` |
| 8644 | Webhook | HMAC verification | `/webhooks/*` |

The original single `/api` route forwarded everything to port 8642. When the
browser-based dashboard SPA called `/api/sessions` or `/api/auth/ws-ticket`,
it sent OIDC cookies — not a Bearer token. The API server rejected these with
401/403.

By declaring `/api/v1` and `/api/jobs` as separate, more specific routes
first, Traefik matches them before the broader `/api` prefix. The remaining
`/api/*` paths (sessions, auth, config, keys) now reach port 9119 where the
dashboard server handles them with OIDC cookie authentication.

This also fixed Hermes Desktop connectivity — Desktop connects to the
dashboard backend and uses the same `/api/sessions` and `/api/auth/ws-ticket`
endpoints that were being misrouted.

## Prevention

- When deploying applications with multiple HTTP servers behind a single
  IngressRoute, document which URL paths belong to which server and which
  authentication mechanism each uses **before** writing routing rules.
- Test dashboard/UI functionality after any IngressRoute change — the browser
  sends different credentials (cookies) than programmatic clients (Bearer
  tokens).
- Add inline comments to IngressRoute files listing which server owns each
  path prefix and how it is authenticated.
- When investigating "Invalid API key" errors on a dashboard, check whether
  the request is being routed to the wrong port/server before assuming the key
  itself is wrong — the misleading error message is a known issue (GitHub
  #39365).

## Related Docs

- [Hermes Agent OIDC authentication failures](../integration-issues/hermes-agent-oidc-configuration.md)
  — same symptom family (401/403 on dashboard) but different root cause
  (OIDC config vs. IngressRoute port routing). Check both when debugging
  dashboard auth errors.
