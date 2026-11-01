---
title: "feat: Add Plane MCP Server to Plane namespace"
type: feat
date: 2026-06-26
---

## Summary

Add the official Plane MCP server (`makeplane/plane-mcp-server`) as a standalone Deployment in the Plane namespace, exposing an HTTP transport on port 8211 for AI agents to interact with Plane's project management data via MCP tools. Includes a NetworkPolicy restricting ingress to Traefik and egress to only the Plane API and DNS.

## Problem Frame

Plane CE is deployed and working in the cluster, but there is no programmatic interface for AI agents (Hermes, future agents) to manage projects, issues, cycles, or work items. The official Plane MCP server provides 100+ tools across 20 categories that expose Plane's full API surface as MCP tools. Deploying it in-cluster gives agents a low-latency, internally-routed connection to Plane without going through the public internet.

## Requirements

### Component Deployment

R1. A new Deployment runs `makeplane/plane-mcp-server` in the `plane` namespace with HTTP transport (port 8211).
R2. A Service exposes port 8211 for the MCP server pods.
R3. An IngressRoute at `plane.home.diceninjagaming.com/mcp/` routes to the MCP Service, using the existing wildcard cert and `default-whitelist` middleware.
R4. The MCP server connects to Plane's API at `http://plane-api.plane.svc.cluster.local:8000` (internal cluster DNS).

### Security

R5. A NetworkPolicy restricts ingress to the MCP server to only Traefik pods on port 8211.
R6. A NetworkPolicy restricts egress to only DNS (kube-system, UDP/TCP 53) and Plane API (plane-api pods in the plane namespace, TCP 8000).
R7. A SealedSecret stores the Plane API key and workspace slug.
R8. The container runs as non-root (UID 65534), drops ALL capabilities, and uses seccomp RuntimeDefault.

### Configuration

R9. A ConfigMap stores non-sensitive MCP config: `PLANE_BASE_URL` and `PLANE_INTERNAL_BASE_URL`.
R10. The SealedSecret provides `PLANE_API_KEY` and `PLANE_WORKSPACE_SLUG` as env vars.
R11. The IngressRoute comment and configmap comment document that the MCP endpoint requires a Plane API key for authentication.

## Key Technical Decisions

### KTD1. Standalone Deployment vs. sidecar in plane-api

**Decision:** Standalone Deployment.

**Rationale:** The MCP server is an independent Python process with its own lifecycle, resource needs, and failure modes. A sidecar would couple its lifecycle to plane-api (restarts, scaling, resource pressure) and complicate resource limits. The existing Plane app follows the pattern of one Deployment per component (api, web, live, space, admin, worker, beatworker). A standalone Deployment keeps the pattern consistent and gives clean NetworkPolicy scoping.

### KTD2. HTTP transport (port 8211) vs. stdio

**Decision:** HTTP transport.

**Rationale:** The Dockerfile defaults to HTTP transport (`CMD ["http"]`, `EXPOSE 8211`). HTTP allows multiple concurrent MCP clients (Hermes, future agents) without process-scoped stdio sessions. The IngressRoute + NetworkPolicy provides access control. The Plane docs recommend HTTP for multi-client scenarios.

### KTD3. Image tag pinned to v0.2.9

**Decision:** `docker.io/makeplane/plane-mcp-server:v0.2.9`.

**Rationale:** The repo's pre-commit hook rejects `:latest` tags. `v0.2.9` is the latest stable release on Docker Hub (published 10 days ago, multi-arch amd64+arm64). Matches the existing Plane component pattern of pinning to specific version tags.

### KTD4. Security context: non-root (UID 65534)

**Decision:** `runAsNonRoot: true`, `runAsUser: 65534` (nobody), drop ALL capabilities.

**Rationale:** The image is based on `python:3.11-slim` which defaults to root. The MCP server is a stateless HTTP process that doesn't write to any filesystem, so `nobody` is safe. No PVC mounts needed. The image audit confirms no special capabilities are required.

### KTD5. MCP server authenticates to Plane API via API key (not OAuth)

**Decision:** API key authentication via `PLANE_API_KEY` env var.

**Rationale:** The MCP server supports OAuth, PAT, and API key auth. For a self-hosted cluster-internal deployment, API key is the simplest path — no OAuth app registration, no redirect URIs, no external-facing auth flow. The key is generated from Plane's admin panel and stored as a SealedSecret.

## Scope Boundaries

### In scope

- Deployment, Service, IngressRoute, ConfigMap, SealedSecret, NetworkPolicy for the MCP server
- Documentation in the IngressRoute comments and configmap about MCP endpoint auth
- The `plane-api` selector label is used as the egress target (no new labels needed)

### Deferred to Follow-Up Work

- **Plane API key generation:** The user must generate an API key from Plane's admin panel (`/god-mode`) before the SealedSecret can be sealed with a real value. This is a manual step outside the manifest change.
- **Hermes MCP client configuration:** Configuring Hermes to connect to the MCP server is a separate task (updating Hermes config to point at the MCP endpoint).
- **MCP server upgrade automation:** No automated image update mechanism — upgrades are manual tag bumps, consistent with the rest of the Plane app.

### Out of scope

- Changes to the existing Plane Deployments, Services, or IngressRoute
- OAuth or PAT-based authentication for the MCP server
- External access to the MCP endpoint (internal-only by design)
- Monitoring or alerting for the MCP server

## Implementation Units

### U1. SealedSecret for MCP server credentials

**Goal:** Store the Plane API key and workspace slug as a SealedSecret.

**Requirements:** R7

**Dependencies:** None (must be created before U2)

**Files:**
- `apps/plane/sealedsecret-plane-mcp.yaml` (new)
- `apps/plane/secret-plane-mcp.yaml` (new, gitignored — plaintext template)

**Approach:** Create a `secret-plane-mcp.yaml` template with placeholder values for `PLANE_API_KEY` and `PLANE_WORKSPACE_SLUG`. Include the `kubeseal` command for the user to run after filling in real values. The SealedSecret carries `sync-wave: "-1"` (app-level secret consumed by Deployment at wave 0).

**Test expectation:** none — SealedSecret manifests are validated by the pre-commit hook's `secret-template-verify.sh` and `plaintext-secret-guard.sh`, not by tests.

**Verification:** The SealedSecret file has correct `sync-wave: "-1"` annotation in both `metadata.annotations` and `spec.template.metadata.annotations`. The plaintext secret template follows naming conventions (`secret-plane-mcp.yaml`, placeholder values with underscores only).

### U2. ConfigMap for MCP server configuration

**Goal:** Store non-sensitive MCP server environment variables.

**Requirements:** R9, R11

**Dependencies:** None

**Files:**
- `apps/plane/configmap-plane-mcp.yaml` (new)

**Approach:** Create a ConfigMap with:
- `PLANE_BASE_URL`: `https://plane.home.diceninjagaming.com` (public URL, used for OAuth redirects)
- `PLANE_INTERNAL_BASE_URL`: `http://plane-api.plane.svc.cluster.local:8000` (internal API URL for server-to-server calls)

The ConfigMap does NOT need a sync-wave annotation — it syncs at wave 0 (default) alongside the Deployment.

**Test expectation:** none — ConfigMap is static configuration, validated by the pre-commit YAML validity check.

**Verification:** The ConfigMap exists in the `plane` namespace with the correct keys. Comment documents the purpose of each key and cross-references the SealedSecret for credentials.

### U3. Deployment for MCP server

**Goal:** Run the Plane MCP server as a standalone Deployment in the plane namespace.

**Requirements:** R1, R4, R8

**Dependencies:** U1 (SealedSecret), U2 (ConfigMap)

**Files:**
- `apps/plane/deployment-plane-mcp.yaml` (new)

**Approach:**
- Image: `docker.io/makeplane/plane-mcp-server:v0.2.9`
- Replica count: 1 (single instance; MCP server is stateless but no benefit to multiple replicas for a homelab)
- Strategy: `Recreate` (matches existing Plane single-replica pattern)
- Labels: `app: plane-mcp`, `app.kubernetes.io/part-of: plane`
- Port: 8211 (named `http`)
- `automountServiceAccountToken: false`
- Security context: `runAsNonRoot: true`, `runAsUser: 65534`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, drop ALL capabilities
- EnvFrom: ConfigMap (`plane-mcp`) and Secret (`plane-mcp`)
- Startup probe: HTTP GET on `/` port 8211 (FastMCP serves a health endpoint)
- Liveness/readiness probes: HTTP GET on `/` port 8211
- Resources: requests 50m CPU / 128Mi memory, limits 200m CPU / 256Mi memory (lightweight Python HTTP server)
- No PVC mounts

**Patterns to follow:** `deployment-plane-live.yaml` (similar lightweight stateless container pattern, security context structure), `deployment-plane-api.yaml` (envFrom + env structure, probe pattern).

**Test scenarios:**
- Happy path: Pod starts, reaches Ready state, responds to HTTP probe on port 8211
- Edge case: MCP server startup may take a few seconds for Python import + FastMCP init — startup probe with generous failureThreshold (10 × periodSeconds 5 = 50s) handles this
- Error path: If PLANE_API_KEY is missing or invalid, the MCP server should start but return errors on tool calls — this is acceptable; the API key validation happens at the API call level, not at startup

**Verification:** `kubectl get deployment plane-mcp -n plane` shows 1/1 ready. `kubectl logs deployment/plane-mcp -n plane` shows FastMCP startup with HTTP transport on port 8211.

### U4. Service for MCP server

**Goal:** Expose the MCP server pods on port 8211 within the cluster.

**Requirements:** R2

**Dependencies:** U3

**Files:**
- `apps/plane/service-plane-mcp.yaml` (new)

**Approach:** ClusterIP Service selecting `app: plane-mcp`, port 8211 targeting 8211. Matches the pattern of existing Plane Services (`service-plane-api.yaml`, etc.).

**Test expectation:** none — Service is a simple selector+port mapping.

**Verification:** `kubectl get svc plane-mcp -n plane` shows ClusterIP on port 8211. `kubectl get endpoints plane-mcp -n plane` shows one endpoint.

### U5. NetworkPolicy for MCP server

**Goal:** Restrict ingress to Traefik only and egress to only DNS and Plane API.

**Requirements:** R5, R6

**Dependencies:** U3

**Files:**
- `apps/plane/networkpolicy-plane-mcp.yaml` (new)

**Approach:** Single NetworkPolicy targeting `app: plane-mcp` with both `Ingress` and `Egress` policyTypes:

**Ingress rules:**
- From: Traefik namespace pods (`kubernetes.io/metadata.name: traefik`, `app.kubernetes.io/name: traefik`)
- Port: TCP 8211

**Egress rules:**
- DNS: kube-system namespace, UDP/TCP 53
- Plane API: plane-api pods in the plane namespace (`app: plane-api`), TCP 8000

**Patterns to follow:** `apps/honcho/networkpolicy-honcho-api.yaml` — identical structure (Traefik ingress, DNS egress, specific service egress). The namespaceSelector + podSelector pattern for restricting to specific pods.

**Test scenarios:**
- Happy path: MCP server pod can reach `plane-api.plane.svc.cluster.local:8000` and resolve DNS names
- Edge case: MCP server cannot reach any other service in the cluster (e.g., cannot reach MinIO, RabbitMQ, Valkey)
- Error path: If the NetworkPolicy egress rule is too restrictive (e.g., wrong port), the MCP server will fail to connect to Plane API — logs will show connection refused/timeout

**Verification:** `kubectl get networkpolicy plane-mcp -n plane` shows the policy. `kubectl exec deployment/plane-mcp -n plane -- curl -s http://plane-api.plane.svc.cluster.local:8000/` returns 200 (Plane API root). `kubectl exec deployment/plane-mcp -n plane -- curl -s http://minio.plane.svc.cluster.local:9000/` times out (blocked by policy).

### U6. IngressRoute for MCP server

**Goal:** Expose the MCP server at `plane.home.diceninjagaming.com/mcp/` via Traefik.

**Requirements:** R3, R11

**Dependencies:** U4

**Files:**
- `apps/plane/ingressroute-plane.yaml` (modify — add MCP route)

**Approach:** Add a new route to the existing Plane IngressRoute (not a separate file — the Plane app uses one IngressRoute for all path-based routes). The route goes before the catch-all web UI route (which must be last):

```
- match: Host(`plane.home.diceninjagaming.com`) && PathPrefix(`/mcp/`)
```

Points to `plane-mcp` Service on port 8211. Uses `default-whitelist` middleware (internal-only access). Comment documents that this is the MCP endpoint requiring API key authentication.

**Test expectation:** none — IngressRoute is validated by the pre-commit `ingressroute-check.sh`.

**Verification:** `curl -s https://plane.home.diceninjagaming.com/mcp/` from an internal subnet returns a response from the MCP server (not a 404 or 502).

## Sources & Research

- [Plane MCP Server GitHub](https://github.com/makeplane/plane-mcp-server) — official Python/FastMCP implementation, Dockerfile, README
- [Plane Developer Docs — MCP Server](https://developers.plane.so/dev-tools/mcp-server) — self-hosted configuration, `PLANE_INTERNAL_BASE_URL` for server-to-server calls
- [Docker Hub: makeplane/plane-mcp-server](https://hub.docker.com/r/makeplane/plane-mcp-server/tags) — multi-arch image, v0.2.9 latest stable
- `apps/honcho/networkpolicy-honcho-api.yaml` — NetworkPolicy pattern (Traefik ingress + DNS + specific service egress)
- `docs/solutions/runtime-errors/plane-ce-deployment-cascade.md` — Plane deployment gotchas (capabilities, probes, env vars)
- `apps/plane/deployment-plane-api.yaml` — existing Plane deployment pattern to follow
