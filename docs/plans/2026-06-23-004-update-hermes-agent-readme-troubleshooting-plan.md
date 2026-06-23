# Plan: Hermes Agent README — Troubleshooting Gaps

**Date:** 2026-06-23
**Branch:** `docs/hermes-agent-readme-troubleshooting`
**Status:** Completed
**Type:** docs

---

## Summary

The troubleshooting section in `apps/hermes-agent/README.md` was built
incrementally during today's debugging session. Three gaps remain from
issues discovered during deployment and testing.

## Remaining Work

### 1. Fix incorrect redirect URI in "Dashboard shows 401"

**File:** `apps/hermes-agent/README.md`, line ~300

The current text says:
```
Check the Authentik provider redirect URI: https://hermes.taegost.com/oauth/oidc/callback
```

This is wrong — the correct path is `/auth/callback`. Also update the scopes
line to include `offline_access` (required for token refresh since Authentik 2024.2+. Without this, OIDC TTL is 15 minutes with no refresh).

### 2. Add certificate stuck pending troubleshooting

**File:** `apps/hermes-agent/README.md`

Add a new section after "Pod not starting". Suggested prose:

> **Certificate stuck pending**
>
> If the Hermes certificate shows `Ready: False` and the challenge is stuck
> pending, the most common cause is a ClusterIssuer mismatch — the issuer's
> Route53 zone doesn't match the domain. Check with:
> ```
> kubectl get certificate -n hermes-agent
> kubectl get challenge -n hermes-agent
> kubectl describe challenge -n hermes-agent
> ```
>
> Look for `reason: Waiting for authorization` or Route53 access denied errors.
> Verify the ClusterIssuer matches your domain's Route53 hosted zone. If a
> challenge is stuck with a finalizer, force-remove it:
> ```
> kubectl patch challenge <name> -n hermes-agent --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
> ```

Cross-reference to `docs/solutions/runtime-errors/certificate-wrong-route53-issuer.md`
for the full diagnosis walkthrough.

### 3. Expand SSH troubleshooting

**File:** `apps/hermes-agent/README.md`

The current SSH section (lines 414-425) is commands only. Expand with
prose covering symptoms, causes, and diagnosis. Suggested structure:

> **SSH connection refused or timeout**
>
> Common causes:
> - **Port mismatch** — the Hermes sandbox SSH runs on port 2222, not the
>   standard port 22. This is a sandbox implementation detail, not a security
>   measure. Always specify `-p 2222` when connecting.
> - **Host key mismatch** — if you've reconnected the agent or rebuilt the
>   sandbox, the host key will have changed. Remove the stale entry with:
>   ```
>   ssh-keygen -R [hermes.taegost.com]:2222
>   ```
> - **NetworkPolicy blocking SSH** — verify the NetworkPolicy allows ingress
>   on port 2222:
>   ```
>   kubectl get networkpolicy -n hermes-agent
>   kubectl describe networkpolicy -n hermes-agent
>   ```

Use `docs/solutions/conventions/hermes-agent-ssh-sandbox-deployment-pattern.md`
as reference material for the sandbox SSH details, but do not link it directly
in the user-facing README — that doc is internal and subject to change.

---

## Verification

- All commands are valid kubectl syntax
- Cross-references to solution docs resolve
- Redirect URI matches the setup instructions (line 144)
- SSH port documented as 2222 with explanation that it's a sandbox detail, not security
