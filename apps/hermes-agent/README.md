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
   - **Scopes:** Include `openid`, `profile`, `email`

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

### Dashboard shows 401

1. Verify the OIDC client ID in the SealedSecret matches Authentik
2. Check the Authentik provider redirect URI: `https://hermes.taegost.com/oauth/oidc/callback`
3. Verify the Authentik provider has the correct scopes: `openid`, `profile`, `email`

### SSH to sandbox fails

```bash
# Check NetworkPolicy
kubectl get networkpolicy -n hermes-agent

# Check key permissions
kubectl exec -n hermes-agent deployment/hermes-agent -- ls -la /opt/data/.ssh/

# Check sshd logs
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
