# Plan: Update Hermes Agent README with Troubleshooting Section

**Created:** 2026-06-23
**Status:** Not started
**Priority:** Low
**Category:** Documentation

---

## Problem

The Hermes Agent README we created during deployment is comprehensive but lacks a troubleshooting section. The issues we encountered (certificate issuer, OIDC configuration) are common and should be documented for future reference.

## Goal

Add a troubleshooting section to `apps/hermes-agent/README.md` that documents the issues we encountered and their solutions.

---

## Implementation Details

### Section to Add

Add a new section after "Phase 4: Deploy and Verify" or at the end of the README.

```markdown
## Troubleshooting

### Certificate Stuck Pending

**Symptom:** Certificate shows `Ready: False` for hours, challenge stuck in pending state.

**Check:**
```bash
kubectl get certificate -n hermes-agent
kubectl get challenge -n hermes-agent
kubectl describe challenge <challenge-name> -n hermes-agent | grep -A 5 "Events:"
```

**Common Causes:**

1. **Wrong ClusterIssuer** — The issuer's Route53 credentials don't have access to the domain's hosted zone.

   **Error:** `failed to determine Route 53 hosted zone ID: zone not found in Route 53`

   **Fix:** Update Certificate to use correct issuer (e.g., `letsencrypt-taegost-prod` for `*.taegost.com` domains).

2. **Stuck challenge finalizer** — Challenge deletion blocked by cert-manager finalizer.

   **Fix:** Remove finalizer:
   ```bash
   kubectl patch challenge <challenge-name> -n hermes-agent --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
   ```

**See:** `docs/solutions/runtime-errors/certificate-wrong-route53-issuer.md`

### OIDC Authentication Errors

**Symptom:** Login fails with `invalid_client` or `redirect_uri` error.

**Check:**
- Authentik provider configuration
- Application environment variables
- Callback URL in Authentik matches application's expected path

**Common Causes:**

1. **Wrong callback URL** — Hermes uses `/auth/callback`, not `/oauth/oidc/callback`.

   **Fix:** Update Authentik provider Redirect URIs to `https://hermes.taegost.com/auth/callback`

2. **Wrong client type** — Hermes uses PKCE (public client). Authentik provider must be set to "Public", not "Confidential".

   **Fix:** In Authentik, edit provider and set Client Type to Public.

**See:** `docs/solutions/integration-issues/hermes-agent-oidc-configuration.md`

### Desktop App "Could not reach gateway"

**Symptom:** Hermes Desktop shows "Could not reach this gateway" but web dashboard works.

**Cause:** Known upstream bug — Electron sends `file:///null` as Origin header, failing WebSocket security check.

**Issue:** https://github.com/NousResearch/hermes-agent/issues/38412

**Workaround:** Use web dashboard at `https://hermes.taegost.com` until upstream fix is merged.

### SSH Connection Issues

**Symptom:** Sandbox logs show "Connection closed" immediately after connection.

**Check:**
```bash
kubectl logs -n hermes-agent deployment/hermes-agent-sandbox --tail=50
kubectl exec -n hermes-agent deployment/hermes-agent -- ssh -vvv hermes-sandbox echo test
```

**Common Causes:**

1. **Port mismatch** — Service forwards port 22 → 2222, SSH client config should use port 22.

2. **Host key mismatch** — `known_hosts` ConfigMap doesn't match sandbox's actual host key.

   **Fix:** Regenerate SSH keypairs and update SealedSecrets (see Phase 1).

3. **Network policy blocking** — Sandbox NetworkPolicy may be too restrictive.

   **Check:** `kubectl describe networkpolicy hermes-sandbox -n hermes-agent`
```

---

## Files to Create/Modify

| File | Action |
|------|--------|
| `apps/hermes-agent/README.md` | Add troubleshooting section |

---

## Testing

1. Read through troubleshooting section
2. Verify all commands are correct
3. Check that error messages match actual output
4. Ensure links to related docs are valid

---

## Notes

- This is a documentation-only update
- Reference the solution docs we created earlier
- Keep troubleshooting section focused on issues we actually encountered
- Don't add issues we haven't seen — that's speculative
