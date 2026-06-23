# Hermes Agent

Self-improving AI agent by Nous Research with a built-in web dashboard, OpenAI-compatible API server, messaging gateway, and inbound webhook adapter. Runs with an SSH sandbox backend for isolated code execution.

## Architecture

- **Hermes Agent** — main pod running the gateway process (dashboard + API + webhook)
- **Hermes Sandbox** — separate pod running sshd for isolated code execution
- **Authentik** — OIDC authentication for the dashboard
- **LiteLLM** — model inference backend at `litellm.diceninjagaming.com`
- **NetworkPolicy** — enforces sandbox isolation (no cluster or local network access)

## Deployment Phases

### Phase 1: Generate SSH Keypairs

Generation order matters — the sandbox host keypair must be generated first because the known_hosts content is derived from it.

```bash
# 1. Generate sandbox host keypair (sandbox sshd identity)
ssh-keygen -t ed25519 -f hermes-sandbox-host -C "hermes-sandbox-host" -N ""

# 2. Generate known_hosts content from the host public key
echo "hermes-sandbox.hermes-agent.svc.cluster.local $(cat hermes-sandbox-host.pub)" > known_hosts_content

# 3. Generate agent keypair (hermes-agent authenticates to sandbox)
ssh-keygen -t ed25519 -f hermes-agent-client -C "hermes-agent-client" -N ""
```

All four artifacts (both keypairs, known_hosts content, and the SSH config) must be ready before sealing.

### Phase 2: Create Namespace and Seal Secrets

1. **Create the namespace:**

   ```bash
   kubectl create namespace hermes-agent
   ```

2. **Update the known_hosts ConfigMap:**

   Replace the placeholder in `apps/hermes-agent/configmap-hermes-agent-known-hosts.yaml` with the content of `known_hosts_content` generated in Phase 1.

3. **Create and seal the SSH agent keypair secret:**

   Create `secret-hermes-agent-ssh-agent-keys.yaml` locally (gitignored):

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: hermes-agent-ssh-agent-keys
     namespace: hermes-agent
   type: Opaque
   stringData:
     id_ed25519: "<contents of hermes-agent-client>"
     id_ed25519.pub: "<contents of hermes-agent-client.pub>"
   ```

   ```bash
   kubeseal --format yaml < secret-hermes-agent-ssh-agent-keys.yaml > apps/hermes-agent/sealedsecret-hermes-agent-ssh-agent-keys.yaml
   rm secret-hermes-agent-ssh-agent-keys.yaml
   ```

4. **Create and seal the SSH sandbox keypair secret:**

   Create `secret-hermes-agent-ssh-sandbox-keys.yaml` locally (gitignored):

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: hermes-agent-ssh-sandbox-keys
     namespace: hermes-agent
   type: Opaque
   stringData:
     ssh_host_ed25519_key: "<contents of hermes-sandbox-host>"
     ssh_host_ed25519_key.pub: "<contents of hermes-sandbox-host.pub>"
   ```

   ```bash
   kubeseal --format yaml < secret-hermes-agent-ssh-sandbox-keys.yaml > apps/hermes-agent/sealedsecret-hermes-agent-ssh-sandbox-keys.yaml
   rm secret-hermes-agent-ssh-sandbox-keys.yaml
   ```

5. **Create and seal the main Hermes config secret:**

   Create `secret-hermes-agent.yaml` locally (gitignored):

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: hermes-agent
     namespace: hermes-agent
   type: Opaque
   stringData:
     api-server-key: "<generate with: openssl rand -hex 32>"
     oidc-client-id: "<from Authentik OAuth2/OIDC application>"
     webhook-secret: "<generate with: openssl rand -hex 32>"
     litellm-api-key: "<same LiteLLM API key used by Open WebUI>"
   ```

   ```bash
   kubeseal --format yaml < secret-hermes-agent.yaml > apps/hermes-agent/sealedsecret-hermes-agent.yaml
   rm secret-hermes-agent.yaml
   ```

6. **Commit and push:**

   ```bash
   git add apps/hermes-agent/
   git commit -m "feat(hermes-agent): add manifests and sealed secrets"
   git push
   ```

### Phase 3: Configure Authentik OIDC

1. **Create Authentik Group:**

   In Authentik Admin:
   - Go to **Directory → Groups → Create**
   - Create group: `Hermes Users`
   - Assign users to the group

2. **Create Authentik OAuth2/OIDC Application:**

   In Authentik Admin:
   - Go to **Applications → Applications → Create**
   - **Name:** Hermes
   - **Slug:** `hermes`
   - **Launch URL:** `https://hermes.taegost.com`

3. **Configure Provider:**

   In Authentik Admin:
   - Go to **Applications → Providers → Create**
   - **Name:** Hermes Provider
   - **Type:** OAuth2/OIDC Provider
   - **Client Type:** Public (Hermes uses PKCE — confidential clients require a client secret that Hermes doesn't send)
   - **Client ID:** (auto-generated — copy to the `oidc-client-id` field in your SealedSecret)
   - **Client Secret:** (auto-generated — not used by Hermes, but Authentik may still show it)
   - **Signing Key:** Select default
   - **Redirect URIs:** `https://hermes.taegost.com/auth/callback`
   - **Scopes:** Include `openid`, `profile`, `email`, `offline_access`
     (Authentik 2024.2+ requires `offline_access` to issue refresh tokens —
     without it, the dashboard session expires after 15 minutes)
   - **Advanced protocol settings → Refresh Token validity:** Set to 1 day.
     This controls how long the refresh token is valid. The access token TTL
     is 15 minutes (set by Hermes); the refresh token lets the dashboard
     silently obtain new access tokens without re-authenticating. 1 day
     balances convenience against the risk of a stolen refresh token being
     usable indefinitely. The dashboard is internal-only (`default-whitelist`),
     so this is a reasonable trade-off for a homelab.

4. **Bind Provider to Application:**

   In Authentik Admin:
   - Edit the Hermes application
   - Under **Provider**, select the Hermes Provider

### Phase 4: Deploy and Verify

1. **Sync ArgoCD** and wait for pods to start

2. **Verify the deployment:**

   ```bash
   kubectl get pods -n hermes-agent
   kubectl logs -n hermes-agent deployment/hermes-agent
   kubectl logs -n hermes-agent deployment/hermes-agent-sandbox
   ```

3. **Test SSH connectivity from Hermes to Sandbox:**

   ```bash
   kubectl exec -it -n hermes-agent deployment/hermes-agent -- ssh -o StrictHostKeyChecking=yes hermes-sandbox echo "SSH OK"
   ```

4. **Test the application:**
   - Navigate to `https://hermes.taegost.com`
   - You should be redirected to Authentik for login
   - After login, you should see the Hermes dashboard

### Phase 5: Post-Deployment Configuration

1. **Configure LiteLLM backend:**

   ```bash
   kubectl exec -it -n hermes-agent deployment/hermes-agent -- bash
   hermes model
   # Select OpenAI-compatible → set base URL to https://litellm.diceninjagaming.com/v1 → enter API key
   ```

2. **API Server Integration (Open WebUI):**

   The API server is available at `https://hermes.taegost.com/api/v1`.

   In Open WebUI admin, add a new connection:
   - **URL:** `https://hermes.taegost.com/api/v1`
   - **API Key:** the value from the `hermes-agent` SealedSecret's `api-server-key`

   Note: `API_SERVER_MODEL_NAME` can be set to customize the model name shown in Open WebUI.

3. **Multi-profile Management:**

   Profiles are managed inside the container by s6 supervisor:

   ```bash
   kubectl exec -it -n hermes-agent deployment/hermes-agent -- hermes profile create <name>
   ```

   Each profile gets its own config, sessions, and gateway state under `/opt/data/profiles/<name>/`.

4. **Webhook Configuration:**

   Webhooks are configured via `hermes webhook setup` or `config.yaml` under `platforms.webhook`.

   - **Webhook URL:** `https://hermes.taegost.com/webhooks/<route-name>`
   - Reference the [webhook documentation](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/webhooks) for route configuration

## Security Notes

### Credential-at-Risk on PVC

**The hermes-agent process writes API keys to `/opt/data/.env` in plaintext on the Longhorn volume.** Longhorn does not encrypt data at rest. If the physical disk, Longhorn replica, or backup is accessed, all credentials stored by hermes-agent are exposed.

The SSH private key is safe — it is mounted from a Secret via `subPath`, not stored on the PVC. The sandbox pod does NOT have this issue — its sensitive data is mounted read-only from Secrets.

Evaluate whether hermes-agent can read keys from environment variables (SealedSecrets) instead of `.env`. See OQ5 in the deployment plan.

### Sandbox Isolation

The sandbox is isolated via NetworkPolicy:
- **Ingress:** Only port 2222 from the hermes-agent pod
- **Egress:** DNS + open internet only (10.0.0.0/8 and 192.168.0.0/16 blocked)

This prevents the sandbox from reaching cluster-internal services or the local network.

## Configuration Reference

| Environment Variable | Description | Value |
|---------------------|-------------|-------|
| `HERMES_DASHBOARD` | Enable dashboard | `1` |
| `HERMES_DASHBOARD_HOST` | Dashboard listen address | `0.0.0.0` |
| `HERMES_DASHBOARD_PORT` | Dashboard port | `9119` |
| `HERMES_DASHBOARD_PUBLIC_URL` | Public URL for OIDC callback | `https://hermes.taegost.com` |
| `HERMES_DASHBOARD_OIDC_ISSUER` | Authentik OIDC issuer URL | `https://authentik.diceninjagaming.com/application/o/hermes/` |
| `HERMES_DASHBOARD_OIDC_CLIENT_ID` | OIDC client ID | from sealed secret |
| `HERMES_DASHBOARD_OIDC_SCOPES` | OIDC scopes (must include `offline_access` for refresh tokens) | `openid profile email offline_access` |
| `API_SERVER_ENABLED` | Enable API server | `true` |
| `API_SERVER_HOST` | API server listen address | `0.0.0.0` |
| `API_SERVER_PORT` | API server port | `8642` |
| `API_SERVER_KEY` | API authentication key | from sealed secret |
| `WEBHOOK_ENABLED` | Enable webhook adapter | `true` |
| `WEBHOOK_PORT` | Webhook port | `8644` |
| `WEBHOOK_SECRET` | HMAC webhook verification secret | from sealed secret |
| `OPENAI_BASE_URL` | LiteLLM endpoint | `https://litellm.diceninjagaming.com/v1` |
| `OPENAI_API_KEY` | LiteLLM API key | from sealed secret |

## Ports

| Port | Purpose | Middleware |
|------|---------|------------|
| 9119 | Dashboard (SPA + internal API) | `default-whitelist` (internal only) |
| 8642 | API server (OpenAI-compatible + Jobs) | `default-whitelist` (internal only) |
| 8644 | Webhook adapter | `default-headers` (public) |

## IngressRoute Routing

Hermes runs two separate HTTP servers in the same container. The IngressRoute
splits traffic by path prefix:

| Path prefix | Target port | Auth method | Purpose |
|-------------|-------------|-------------|---------|
| `/api/v1/*` | 8642 | `API_SERVER_KEY` Bearer token | OpenAI-compatible endpoints (chat, models, capabilities, runs) |
| `/api/jobs/*` | 8642 | `API_SERVER_KEY` Bearer token | Jobs API (scheduled/background work) |
| `/api/*` (everything else) | 9119 | OIDC session cookies | Dashboard internal API (sessions, auth/ws-ticket, config, keys) |
| `/webhooks/*` | 8644 | HMAC verification | Inbound webhooks (public) |
| `/*` (catch-all) | 9119 | OIDC session cookies | Dashboard SPA |

Route order matters — Traefik evaluates in declaration order, so `/api/v1`
and `/api/jobs` are matched before the broader `/api` prefix. Without this
split, dashboard API calls (sessions, auth, config, keys) get routed to the
API server on 8642, which rejects them with 401/403 because the browser sends
OIDC cookies instead of an `API_SERVER_KEY` Bearer token.

## Troubleshooting

### Pod not starting

```bash
kubectl describe pod -n hermes-agent -l app=hermes-agent
kubectl logs -n hermes-agent -l app=hermes-agent
```

### Certificate stuck pending

If the Hermes certificate shows `Ready: False` and the challenge is stuck
pending, the most common cause is a ClusterIssuer mismatch — the issuer's
Route53 zone doesn't match the domain.

```bash
# Check certificate status
kubectl get certificate -n hermes-agent

# Check challenge status
kubectl get challenge -n hermes-agent

# Inspect the challenge for errors
kubectl describe challenge -n hermes-agent
```

Look for `reason: Waiting for authorization` or Route53 access denied errors.
Verify the ClusterIssuer matches your domain's Route53 hosted zone. If a
challenge is stuck with a finalizer, force-remove it:

```bash
kubectl patch challenge <name> -n hermes-agent --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

See `docs/solutions/runtime-errors/certificate-wrong-route53-issuer.md` for the
full diagnosis walkthrough.

### Dashboard shows 401

1. Verify the OIDC client ID in the SealedSecret matches Authentik
2. Check the Authentik provider redirect URI: `https://hermes.taegost.com/auth/callback`
3. Verify the Authentik provider has the correct scopes: `openid`, `profile`, `email`, `offline_access`

### Dashboard tabs don't load / "Invalid API key" errors in logs

**Symptoms:**
- Chat tab shows 403 on `/api/auth/ws-ticket` and 401 "Invalid API key"
- Config and Keys tabs never load (spinner forever)
- Gateway logs show repeated `WARNING gateway.platforms.api_server: API server rejected invalid API key`
- All dashboard logs show "Error: 404: Not Found"

**Root cause:** The IngressRoute is routing dashboard API calls (`/api/sessions`,
`/api/auth/ws-ticket`, `/api/config`, `/api/keys`) to port 8642 (the API server)
instead of port 9119 (the dashboard). The API server rejects these requests because
the browser sends OIDC session cookies, not an `API_SERVER_KEY` Bearer token.

**Fix:** Ensure the IngressRoute has separate routes for `/api/v1` and `/api/jobs`
(port 8642) and the broader `/api` prefix (port 9119). See the "IngressRoute
Routing" section above. The key is that Traefik evaluates routes in declaration
order — more specific paths must come first.

**How to verify:**

```bash
# Check current IngressRoute
kubectl get ingressroute -n hermes-agent hermes-agent -o yaml

# Test dashboard API endpoint (should return JSON, not 401)
curl -s https://hermes.taegost.com/api/sessions?limit=1

# Check gateway logs for auth rejections (should be quiet after fix)
kubectl logs -n hermes-agent deployment/hermes-agent --tail=50 | grep "rejected invalid API key"
```

### Hermes Desktop can't connect to remote gateway

**Symptoms:**
- Hermes Desktop shows "Could not connect to Hermes gateway" or similar
- Desktop may misleadingly report "OpenRouter API key missing" (GitHub #39365)
- Gateway logs show `API server rejected invalid API key` for Desktop's requests

**Root cause:** Same as above — Desktop connects to the dashboard backend on
port 9119 and uses `/api/sessions`, `/api/auth/ws-ticket`, and `/api/config`
endpoints. If the IngressRoute routes these to port 8642 instead of 9119,
Desktop's OIDC-authenticated requests are rejected by the API server's Bearer
token check.

**Fix:** Same as above — ensure the IngressRoute routing is correct. Once
dashboard API calls reach port 9119, Desktop can authenticate via OIDC and
function normally.

### Dashboard logs out after 15 minutes

**Symptoms:**
- Dashboard redirects to login page after ~15 minutes of inactivity
- No refresh occurs — user must re-authenticate through Authentik each time

**Root cause:** The Hermes dashboard's self-hosted OIDC provider supports
refresh tokens, but Authentik 2024.2+ requires the `offline_access` scope
to issue them. Without it, only the access token is issued (15-minute TTL)
and when it expires the SPA does a full-page redirect to `/login`.

**Fix:**

1. Add `offline_access` to the OIDC scopes in the Deployment:
   ```yaml
   - name: HERMES_DASHBOARD_OIDC_SCOPES
     value: "openid profile email offline_access"
   ```

2. Verify `offline_access` is in the Authentik provider's allowed scopes:
   Authentik Admin → Providers → Hermes Provider → Scopes

3. Set the refresh token lifetime:
   Authentik Admin → Providers → Hermes Provider → Advanced protocol settings
   → Refresh Token validity → 1 day

**How it works:** With `offline_access`, Authentik issues a refresh token
alongside the access token. The Hermes dashboard stores the refresh token
and uses it to silently obtain a new access token before the 15-minute TTL
expires — no user interaction needed. The session persists as long as the
refresh token is valid (controlled by Authentik's provider settings).

### New model added to LiteLLM not showing in Hermes

**Symptoms:**
- A new model was added to the LiteLLM instance but doesn't appear in the
  Hermes model picker or is not available for chat

**Root cause:** Hermes caches the model list from LiteLLM's `/v1/models`
endpoint. Adding a new model to LiteLLM doesn't automatically refresh the
cache in the running Hermes instance.

**Fix:**

1. **Run `hermes model` in the pod** — this queries `/v1/models` and should
   refresh the cache:
   ```bash
   kubectl exec -it -n hermes-agent deployment/hermes-agent -- hermes model
   ```

2. **If that doesn't work, force a cache refresh directly:**
   ```bash
   kubectl exec -n hermes-agent deployment/hermes-agent -- /opt/hermes/.venv/bin/python -c "from hermes_cli.model_switch import list_authenticated_providers; list_authenticated_providers()"
   ```
   This calls the same function `hermes model` uses internally but bypasses
   the interactive picker. No need to select anything — it just refreshes
   the model list from LiteLLM.

3. **If neither works, restart the gateway:**
   ```bash
   kubectl rollout restart deployment/hermes-agent -n hermes-agent
   ```

### SSH to sandbox fails

**Symptoms:** Connection refused, connection timeout, or "Host key verification
failed" when connecting to the Hermes sandbox via SSH.

**Common causes:**

1. **Port mismatch** — the Hermes sandbox SSH runs on port 2222, not the
   standard port 22. This is a sandbox implementation detail, not a security
   measure. Always specify `-p 2222`:
   ```bash
   ssh -p 2222 user@hermes.taegost.com
   ```

2. **Host key mismatch** — if you've reconnected the agent or rebuilt the
   sandbox, the host key will have changed. Remove the stale entry:
   ```bash
   ssh-keygen -R [hermes.taegost.com]:2222
   ```

3. **NetworkPolicy blocking SSH** — verify the NetworkPolicy allows ingress
   on port 2222:
   ```bash
   kubectl get networkpolicy -n hermes-agent
   kubectl describe networkpolicy -n hermes-agent
   ```

4. **Key permissions** — verify the SSH key has correct permissions:
   ```bash
   kubectl exec -n hermes-agent deployment/hermes-agent -- ls -la /opt/data/.ssh/
   ```

5. **sshd not running** — check the sandbox container logs:
   ```bash
   kubectl logs -n hermes-agent deployment/hermes-agent-sandbox
   ```

### Sandbox can't reach internet

```bash
# Check NetworkPolicy egress rules
kubectl describe networkpolicy hermes-sandbox -n hermes-agent

# Test DNS resolution
kubectl exec -n hermes-agent deployment/hermes-agent-sandbox -- nslookup google.com

# Test external connectivity
kubectl exec -n hermes-agent deployment/hermes-agent-sandbox -- curl -s https://httpbin.org/ip
```

### seccomp blocking sshd sessions

If sshd sessions fail immediately after connection (chroot error in container logs), the sandbox pod may need `seccompProfile.type: Unconfined`. Test SSH connectivity first — the startup probe (TCP socket on 2222) may pass even if sessions fail.
