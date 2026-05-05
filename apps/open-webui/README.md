# Open WebUI

Web-based chat interface for LiteLLM, providing a ChatGPT/Claude-like experience with model switching, conversation history, and image support.

## Architecture

- **Open WebUI** connects to **LiteLLM** as its backend
- **Authentik** provides OIDC authentication
- **Postgres** (shared CNPG cluster) stores conversation history and user data
- **Redis** (shared with LiteLLM) caches sessions

## Deployment Phases

### Phase 1: Create Namespace and Seal Secrets

1. **Create the namespace:**

   ```bash
   kubectl create namespace open-webui
   ```

2. **Seal the database credentials (postgres namespace):**

   ```bash
   kubeseal --format yaml < apps/open-webui/secret-open-webui-db-credentials.yaml > apps/open-webui/sealedsecret-open-webui-db-credentials.yaml
   rm apps/open-webui/secret-open-webui-db-credentials.yaml
   ```

3. **Fill in and seal the app credentials (open-webui namespace):**

   Edit `apps/open-webui/secret-open-webui.yaml` with all placeholder values:
   - `database-url`: Full Postgres connection string with the password
   - `litellm-master-key`: Same value as `LITELLM_MASTER_KEY` in the litellm secret
   - `webui-session-secret`: Generate with `openssl rand -hex 32`
   - `oidc-client-id`: From Authentik provider
   - `oidc-client-secret`: From Authentik provider

   ```bash
   kubeseal --format yaml < apps/open-webui/secret-open-webui.yaml > apps/open-webui/sealedsecret-open-webui.yaml
   rm apps/open-webui/secret-open-webui.yaml
   ```

Before deploying Open WebUI, you must add the role to the shared Postgres cluster. This is a separate commit to ensure proper ordering:

4. **Edit `apps/postgres/cluster-postgres.yaml`** and add the `open_webui` role under `spec.managed.roles`:

   ```yaml
   - name: open_webui
     login: true
     superuser: false
     createdb: false
     createrole: false
     inherit: true
     connectionLimit: -1
     passwordSecret:
       name: open-webui-db-credentials
   ```

5. **Commit and push:**

   ```bash
   git add apps/postgres/cluster-postgres.yaml
   git commit -m "Add open_webui role to Postgres cluster"
   git push
   ```

6. **Wait for ArgoCD to sync** the postgres application before proceeding.

### Phase 2: Configure Authentik

1. **Create Authentik Groups:**

   In Authentik Admin:
   - Go to **Directory → Groups → Create**
   - Create group: `Open-WebUI Admin` (for admin users)
   - Create group: `Open-WebUI User` (for regular users)
   - Assign users to appropriate groups

2. **Create Authentik OAuth2/OIDC Application:**

   In Authentik Admin:
   - Go to **Applications → Applications → Create**
   - **Name:** Open WebUI
   - **Slug:** `open-webui`
   - **Group:** Select appropriate group
   - **Launch URL:** `https://open-webui.diceninjagaming.com`

3. **Configure Provider:**

   In Authentik Admin:
   - Go to **Applications → Providers → Create**
   - **Name:** Open WebUI Provider
   - **Type:** OAuth2/OIDC Provider
   - **Client ID:** (auto-generated, copy this)
   - **Client Secret:** (auto-generated, copy this)
   - **Signing Key:** Select default
   - **Redirect URIs:** `https://open-webui.diceninjagaming.com/oauth/oidc/callback`
   - **Scopes:** Include `openid`, `profile`, `email`, `groups`

4. **Bind Provider to Application:**

   In Authentik Admin:
   - Edit the Open WebUI application
   - Under **Provider**, select the Open WebUI Provider

5. **Add Property Mapping for Groups:**

   For role-based access control, create a custom scope mapping:
   - Go to **Customization → Property Mappings → Scope Mapping → Create**
   - **Name:** Open WebUI Groups
   - **Scope:** `openid`
   - **Expression:**
     ```python
     return {
         "groups": [g.name for g in user.ak_groups.all()]
     }
     ```
   - Add this mapping to the Open WebUI Provider's scopes

### Phase 3: Deploy and Verify

1. **Sync ArgoCD** and wait for the pod to start

2. **Verify the deployment:**

   ```bash
   kubectl get pods -n open-webui
   kubectl logs -n open-webui deployment/open-webui
   ```

3. **Test the application:**
   - Navigate to `https://open-webui.diceninjagaming.com`
   - You should be redirected to Authentik for login
   - After login, you should see the Open WebUI interface
   - Try sending a message to verify LiteLLM connectivity

## Configuration Reference

| Environment Variable | Description | Default |
|---------------------|-------------|---------|
| `OPENAI_API_BASE_URL` | LiteLLM endpoint | `http://litellm.litellm.svc.cluster.local:4000/v1` |
| `OPENAI_API_KEY` | LiteLLM auth token | from sealed secret |
| `ENABLE_OLLAMA` | Enable local Ollama | `False` |
| `WEBUI_NAME` | UI branding | `Dice Ninja Gaming AI` |
| `SESSION_LIMIT` | Max concurrent sessions per user | `10` |
| `ENABLE_OAUTH_SIGNUP` | Auto-create accounts | `True` |
| `OAUTH_AUTO_REDIRECT_TO_OAUTH_PROVIDER` | Redirect to IdP immediately | `True` |
| `ENABLE_OAUTH_ROLE_MANAGEMENT` | Enable role sync from OIDC groups | `true` |
| `OAUTH_ROLES_CLAIM` | Claim name containing groups | `groups` |
| `OAUTH_ADMIN_ROLES` | Groups with admin access | `Open-WebUI Admin` |
| `OAUTH_ALLOWED_ROLES` | Groups with user access | `Open-WebUI User` |

## Troubleshooting

### Pod not starting

```bash
kubectl describe pod -n open-webui -l app=open-webui
kubectl logs -n open-webui -l app=open-webui
```

### Database connection issues

```bash
# Verify the database exists
kubectl get database -n postgres

# Check the role is active
kubectl get cluster postgres -n postgres -o jsonpath='{.status.managedRolesStatus}' | jq
```

### OIDC login not working

1. Verify the redirect URI in Authentik matches: `https://open-webui.diceninjagaming.com/authorization-code/callback`
2. Check that the OIDC client ID and secret are correct in the sealed secret
3. Verify the Authentik provider has the correct scopes including `openid`, `profile`, `email`, `groups`

### LiteLLM connection issues

```bash
# Verify LiteLLM is running
kubectl get pods -n litellm

# Test connectivity from open-webui pod
kubectl exec -n open-webui deployment/open-webui -- curl -s http://litellm.litellm.svc.cluster.local:4000/health