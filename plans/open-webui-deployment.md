# Open WebUI Deployment Plan

## Overview

Deploy **Open WebUI** as a web-based chat interface that connects to your existing LiteLLM proxy. This provides a ChatGPT/Claude-like experience with model switching, conversation history, and image support.

## Architecture

```mermaid
flowchart LR
    subgraph "User Devices"
        Browser["🌐 Browser\n(Mobile/Desktop)"]
    end

    subgraph "Kubernetes Cluster"
        subgraph "traefik namespace"
            Ingress["🚪 Traefik\nIngressRoute"]
        end

        subgraph "open-webui namespace"
            WebUI["🖥️ Open WebUI\n(Port 8080)"]
        end

        subgraph "litellm namespace"
            LiteLLM["🤖 LiteLLM\n(Port 4000)"]
            Redis["📦 Redis\n(Port 6379)"]
        end

        subgraph "postgres namespace"
            Postgres["🗄️ CNPG\n(Shared Instance)"]
        end
    end

    subgraph "External Services"
        Authentik["🔐 Authentik\n(OAuth2/OIDC)"]
    end

    Browser -->|"HTTPS"| Ingress
    Ingress -->|"HTTP"| WebUI
    WebUI -->|"OpenAI API\n+ Bearer Token"| LiteLLM
    LiteLLM -->|"NVIDIA NIM API"| NVIDIA["🟢 NVIDIA Build\n(cloud.nvidia.com)"]
    WebUI -->|"Cache"| Redis
    WebUI -->|"Data"| Postgres
    WebUI -->|"Auth"| Authentik
```

## Requirements Summary

| Requirement | Decision |
|-------------|----------|
| Interface style | Balanced - familiar but feature-rich |
| Authentication | Authentik OAuth2/OIDC (preferred, not hard requirement) |
| Deployment | Native Kubernetes manifests |
| Mobile-friendly | Yes - Open WebUI is responsive |
| Subdomain | `open-webui.diceninjagaming.com` |
| Data persistence | Shared Postgres (via CNPG) |

## Authentication Flow

```mermaid
sequenceDiagram
    participant User
    participant Browser
    participant OpenWebUI
    participant Authentik
    participant LiteLLM

    User->>Browser: Navigate to open-webui.diceninjagaming.com
    Browser->>OpenWebUI: GET /
    OpenWebUI->>Browser: Redirect to Authentik OAuth
    Browser->>Authentik: OAuth login
    Authentik->>Browser: Return with auth code
    Browser->>OpenWebUI: Callback with code
    OpenWebUI->>Authentik: Exchange code for token
    Authentik->>OpenWebUI: Return user info
    
    User->>Browser: Send message
    Browser->>OpenWebUI: POST /api/chat
    OpenWebUI->>LiteLLM: POST /v1/chat/completions<br/>Authorization: Bearer sk-...
    LiteLLM->>NVIDIA: API request
    NVIDIA->>LiteLLM: AI response
    LiteLLM->>OpenWebUI: Chat completion
    OpenWebUI->>Browser: Stream response
```

## Implementation Steps

### 1. Create Namespace

Create `apps/open-webui/namespace.yaml`

### 2. Create Database (CNPG)

Create `apps/open-webui/database-open-webui.yaml`:
- Database name: `open_webui`
- Uses existing CNPG cluster in `postgres` namespace

### 3. Create ConfigMap

Create `apps/open-webui/configmap-open-webui.yaml` with:
- `OLLAMA_BASE_URL`: `http://litellm.litellm.svc.cluster.local:4000/v1`
- `ENABLE_OLLAMA`: `False` (using LiteLLM, not local Ollama)
- `ENABLE_SIGNUP`: `False` (use SSO only)
- `WEBUI_NAME`: Custom branding (optional)
- `SESSION_LIMIT`: `10` (concurrent session limit)
- `DATABASE_URL`: `postgresql://user:pass@host:5432/open_webui` (from SealedSecret)

### 4. Create Deployment

Create `apps/open-webui/deployment.yaml`:
- Image: `ghcr.io/open-webui/open-webui:v0.5.0` (pin to specific version)
- Non-root security context (UID 1014 per container image)
- Resource limits (1CPU, 2Gi memory)
- Health probes (startup/liveness/readiness)
- Volume mount for ConfigMap
- No PVC needed (uses Postgres for data)

### 5. Create Service

Create `apps/open-webui/service.yaml`:
- ClusterIP on port 8080
- Selector: `app: open-webui`

### 6. Create Certificate

Create `apps/open-webui/certificate-open-webui.yaml`:
- Domain: `open-webui.diceninjagaming.com`
- Uses existing `diceninjagaming-prod` ClusterIssuer

### 7. Create IngressRoute

Create `apps/open-webui/ingressroute-open-webui.yaml`:
- Entry point: `websecure`
- Route: `Host(open-webui.diceninjagaming.com)`
- Middleware: `default-whitelist` (internal only initially)
- TLS: `open-webui-tls` secret
- Service: `open-webui:8080`

### 8. Create SealedSecret

Create `apps/open-webui/sealedsecret-open-webui.yaml`:
- `ollama_api_key`: Placeholder (not used, but required by env)
- `WEBUI_SESSION_SECRET`: Random 32-byte value
- `LITELLM_MASTER_KEY`: The same master key used by LiteLLM
- `database-url`: Postgres connection string for Open WebUI database

### 9. Create ArgoCD Application

Create `apps/manifests/open-webui.yaml`:
- Path: `apps/open-webui`
- Target revision: `HEAD`
- Sync policy: `automated` with `self-heal`

### 10. Authentik OAuth2 Setup

Create documentation for setting up OAuth2 provider in Authentik:
- Create application with slug `open-webui`
- Redirect URI: `https://open-webui.diceninjagaming.com/oauth/oidc/callback`
- Property mapping for email
- Assign to users/groups

## File Structure

```
apps/
├── open-webui/
│   ├── namespace.yaml
│   ├── database-open-webui.yaml
│   ├── configmap-open-webui.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── certificate-open-webui.yaml
│   ├── ingressroute-open-webui.yaml
│   ├── sealedsecret-open-webui.yaml
│   └── README.md (setup instructions)
└── manifests/
    └── open-webui.yaml
```

## Key Configuration Values

| Setting | Value | Notes |
|---------|-------|-------|
| Namespace | `open-webui` | New namespace |
| Image | `ghcr.io/open-webui/open-webui:v0.5.0` | Pin to specific version |
| Port | `8080` | Non-privileged |
| OLLAMA_BASE_URL | `http://litellm.litellm.svc.cluster.local:4000/v1` | Internal LiteLLM service |
| Domain | `open-webui.diceninjagaming.com` | New subdomain |
| Auth | OAuth2/OIDC | Via Authentik |
| Database | Shared CNPG | `open_webui` database |
| Storage | Postgres | No PVC needed |

## Security Considerations

1. **Initial deployment**: Internal-only via `default-whitelist` middleware
2. **SSO required**: `ENABLE_SIGNUP: False` prevents local account creation
3. **Session management**: Redis caching for multi-replica support
4. **Non-root container**: Runs as UID 1014 (no fsGroup needed without PVC)
5. **LiteLLM authentication**: Open WebUI uses `LITELLM_MASTER_KEY` from SealedSecret to authenticate to LiteLLM

## Post-Deployment Checklist

- [ ] Verify pod starts successfully
- [ ] Verify database connection works
- [ ] Test OAuth login flow
- [ ] Test model switching
- [ ] Test conversation persistence (restart pod, verify history remains)
- [ ] Test mobile responsiveness
- [ ] (Optional) Open to public with `default-headers` middleware

## Notes

- **Version**: Pin to `v0.5.0` - update to latest stable release as needed
- **Database**: Uses shared CNPG cluster, no PVC required
- **No fsGroup**: Not needed since we're using Postgres instead of Longhorn PVC
- **LITELLM_MASTER_KEY**: Stored in SealedSecret, shared with LiteLLM's master key so Open WebUI can authenticate to LiteLLM's API