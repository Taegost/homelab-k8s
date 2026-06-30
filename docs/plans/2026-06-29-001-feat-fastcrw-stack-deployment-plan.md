---
title: "feat: Deploy fastCRW web crawling stack"
created: 2026-06-29
type: feat
origin: standalone (no brainstorm doc)
depth: standard
status: draft
deepened: 2026-06-30
---

# Plan: Deploy fastCRW Web Crawling Stack

## Problem Frame

Hermes Agent needs a self-hosted web scraping/crawling backend to replace
dependency on external services (Firecrawl, Tavily). fastCRW is a Rust-native
Firecrawl/Tavily alternative that provides a REST API (`/v1/scrape`, `/v1/crawl`,
`/v1/map`, `/v1/search`) backed by a tiered browser rendering system: HTTP →
LightPanda → Chrome-Stealth. This stack will serve as the web content extraction layer
for the homelab AI infrastructure.

## Scope

Deploy three services into a new `fastcrw` namespace, managed by ArgoCD:

| Service | Image | Role | Port |
|---------|-------|------|------|
| **fastcrw** | `ghcr.io/us/crw:v0.19.0` | REST API server + orchestrator | 3000 (HTTP) |
| **lightpanda** | `lightpanda/browser:0.3.3` | Primary JS renderer (lightweight, ~64 MB) | 9222 (CDP/WS) |
| **chrome-stealth** | `ghcr.io/browserless/chromium:v2.27.0` | Fallback JS renderer (anti-detection, Browserless v2) | 3000 (HTTP/WS) |

External SearXNG at `https://searxng.diceninjagaming.com` provides `/v1/search`
(no bundled sidecar).

### Non-goals

- Bundled SearXNG sidecar (existing instance used instead)
- Proxy rotation configuration (future work)
- Monitoring/change-tracking webhooks (future work)
- MCP server deployment (consumed via REST API or embedded locally)

## Key Technical Decisions

### KTD-1: Wildcard certificate for `*.taegost.com`

No wildcard cert exists for the taegost.com domain. Create one in the `traefik`
namespace, mirroring the `*.diceninjagaming.com` wildcard pattern at
`apps/traefik/certificates/certificate-dng-root-wildcard.yaml`. Uses
`letsencrypt-taegost-prod` ClusterIssuer with DNS01/Route53 validation.

**Rationale:** Matches the established pattern. A wildcard cert lets all future
`*.taegost.com` services share one certificate without per-app cert resources.

### KTD-2: Egress restricted to port 443 only (no port 80)

All pods in the `fastcrw` namespace are restricted to port 443 egress for
external traffic. Port 80 (plaintext HTTP) is deliberately blocked.

**Rationale:** Mike's explicit directive — if a site doesn't have TLS, it's not
worth crawling. This is a policy decision, not an oversight. LightPanda and
The renderer will navigate HTTPS-only; any HTTP-only site will fail and fastCRW will
handle the error gracefully (it already has per-tier timeout/escalation logic).

**Risk:** Some legitimate sites serve content on HTTP-only or redirect HTTP→HTTPS
via a 301. The redirect itself won't work, but the initial HTTPS URL (if
discovered via SearXNG or a crawl) will. This is an acceptable trade-off per
Mike's directive.

### KTD-3: Per-pod NetworkPolicy (not default-deny)

Each pod gets its own NetworkPolicy specifying exact ingress and egress rules,
rather than a namespace-wide default-deny with exception rules.

**Rationale:** More explicit, easier to audit, matches the hermes-sandbox pattern.
Each policy is self-documenting — you can read the policy and know exactly what
that pod can reach.

### KTD-4: Node affinity strategy

- **fastcrw**: `preferredDuringSchedulingIgnoredDuringExecution` with
  `memory-tier` key, `operator: In`, `values: ["small"]`, weight 100.
- **lightpanda, chrome-stealth**: same structure but
  `operator: NotIn`, `values: ["small"]` (matching the existing convention in
  hermes-agent, open-webui, etc.)

**Rationale:** fastCRW is lightweight (~50 MB idle, Rust binary). Browser pods
need more memory and should avoid small-memory nodes.

### KTD-5: Chrome-Stealth SealedSecret for `CHROME_WS_URL`

The full Browserless v2 websocket URL (including the `token` query parameter)
will be stored as a SealedSecret in the `fastcrw` namespace at sync-wave
`-1` (decrypted before Deployments at wave 0). The key is `CHROME_WS_URL`.

**Rationale:** The token is embedded in the URL rather than passed as a separate
env var. Follows the existing sealed-secrets workflow documented in
`docs/sealed-secrets.md`.

### KTD-6: Config via ConfigMap (config.docker.toml)

fastCRW's `config.docker.toml` will be mounted as a read-only ConfigMap. Key
overrides from the upstream default:
- `renderer.lightpanda.ws_url` = `ws://lightpanda.fastcrw.svc.cluster.local:9222/`
- `renderer.chrome.ws_url` = `ws://chrome-stealth.fastcrw.svc.cluster.local:3000/chromium?stealth=true`
  (the `token` query param is injected via the `CRW_RENDERER__CHROME__WS_URL`
  env var from the SealedSecret so the token is not stored in plaintext)
- `search.searxng_url` = `https://searxng.diceninjagaming.com`
- Resource limits tuned for single-user homelab (pool size, timeouts)

**Note on hostnames:** `lightpanda.fastcrw.svc.cluster.local` and
`chrome-stealth.fastcrw.svc.cluster.local` are Kubernetes Service FQDNs within
the `fastcrw` namespace. K8s DNS resolves these to the corresponding Service
ClusterIPs automatically. This is the standard in-cluster service discovery
pattern — not pod hostnames.

**Rationale:** Follows the upstream docker-compose pattern exactly. ConfigMap
allows ArgoCD to manage config changes declaratively.

## High-Level Technical Design

```text
                    ┌──────────────┐
                    │   Traefik    │
                    │  (ingress)   │
                    └──────┬───────┘
                           │ :3000
                    ┌──────▼───────┐
                    │   fastcrw    │──── /v1/search ────► searxng.diceninjagaming.com
                    │   (API)      │                      (external, :443)
                    └──┬───────┬───┘
           ┌───────────┘       └───────────┐
           │ :9222/WS          │ :3000/WS
    ┌──────▼──────┐     ┌──────▼──────────┐
    │ lightpanda  │     │ chrome-stealth  │
    │  (primary)  │     │  (fallback)     │
    └─────────────┘     └─────────────────┘
           │                    │
           └────────────────────┘
                           │ :443 only
                           ▼
                     Internet (HTTPS)
```

Browser tier escalation: HTTP (fast, no browser) → LightPanda (lightweight JS)
→ Chrome-Stealth (anti-detection). fastCRW auto-detects SPAs and escalates
through tiers based on response quality.

## System-Wide Impact

**ArgoCD:** New Application `fastcrw` adds to cluster sync surface. No new ArgoCD project or RBAC needed — uses `project: default`.

**cert-manager / Route53:** New wildcard certificate `*.taegost.com` adds one DNS-01 validation request and one certificate secret lifecycle to manage. The `letsencrypt-taegost-prod` ClusterIssuer already exists; no additional issuer or credential setup is required.

**Traefik:** New IngressRoute on `fastcrw.taegost.com` adds one frontend/backend mapping. Uses existing `default-whitelist` middleware chain (no new middleware). TLS secret is kept in `traefik` namespace and referenced cross-namespace; `allowCrossNamespace: true` in Traefik Helm values permits this (established pattern via `searxng`).

**DNS:** An A record for `fastcrw.taegost.com` must point to the Traefik load-balancer IP. This is external to the cluster (managed at the DNS provider).

**NetworkPolicy surface:** Three new NetworkPolicies in `fastcrw` namespace. These are additive — no existing policies are modified. Default-allow behavior in other namespaces is unchanged.

**Node resources:** Browser pods (LightPanda, Chrome-Stealth) request non-small-memory nodes. If all non-small nodes are at capacity, browser pods will remain Pending until node autoscaling or manual capacity adjustment. fastCRW itself (lightweight Rust binary) can schedule on small-memory nodes.

**Cluster egress:** All `fastcrw` namespace pods are restricted to port 443 external egress. This is a hardening change, not a compatibility break — there are no existing apps in this namespace to disrupt.

## Implementation Units

### U1: Wildcard Certificate for `*.taegost.com`

**Files:**
- `apps/traefik/certificates/certificate-taegost-wildcard.yaml` (new)

Create a Certificate resource in the `traefik` namespace:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-taegost-com
  namespace: traefik
spec:
  secretName: wildcard-taegost-com-tls
  duration: 2160h
  renewBefore: 720h
  dnsNames:
    - "*.taegost.com"
  issuerRef:
    name: letsencrypt-taegost-prod
    kind: ClusterIssuer
    group: cert-manager.io
```

**Pattern reference:** `apps/traefik/certificates/certificate-dng-root-wildcard.yaml`

**Dependencies:** None (standalone, the ClusterIssuer already exists).

**Verification:** `kubectl get certificate -n traefik wildcard-taegost-com` shows
Ready=True after cert-manager processes it.

---

### U2: Namespace + ArgoCD Application

**Files:**
- `apps/fastcrw/namespace-fastcrw.yaml` (new)
- `apps/manifests/fastcrw.yaml` (new)

Namespace resource:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: fastcrw
  labels:
    app.kubernetes.io/name: fastcrw
    app.kubernetes.io/managed-by: ArgoCD
```

ArgoCD Application pointing at `apps/fastcrw/` with `directory.recurse: true`,
`CreateNamespace=false` (since we define the namespace explicitly), automated
sync with prune + selfHeal.

**Pattern reference:** `apps/manifests/hermes-agent.yaml`,
`apps/open-webui/namespace-open-webui.yaml`

**Dependencies:** U1 (certificate must exist before IngressRoute references it).

**Verification:** `argocd app get fastcrw` shows Synced + Healthy.

---

### U3: SealedSecret for Browserless Websocket URL

**Files:**
- `apps/fastcrw/sealedsecret-fastcrw-browserless.yaml` (new)

SealedSecret containing a single key `CHROME_WS_URL` with the full Browserless v2
websocket URL (e.g., `ws://chrome-stealth.fastcrw.svc.cluster.local:3000/chromium?token=...&stealth=true`).
Sync-wave `-1` in both `metadata.annotations` and `spec.template.metadata.annotations`
(dual annotation per established convention). The unsealed Secret is referenced by
the fastCRW Deployment via `secretKeyRef` (as `CRW_RENDERER__CHROME__WS_URL`).

**Pattern reference:** `docs/sealed-secrets.md`

**Dependencies:** None (can be created independently, but must be applied
before the fastcrw Deployment).

**Verification:** `kubectl get secret -n fastcrw` shows the unsealed secret
after ArgoCD syncs.

---

### U4: ConfigMap for fastCRW Configuration

**Files:**
- `apps/fastcrw/configmap-fastcrw-config.yaml` (new)

Contains `config.docker.toml` with overrides for the K8s environment:

```toml
[server]
# Intentionally disabled for single-user homelab use. Re-enable before any
# broader exposure — rate_limit_rps > 0 prevents accidental DoS from aggressive
# scrapes or misbehaving clients.
rate_limit_rps = 0

[request]
deadline_ms_default = 15000
auto_extend_deadline_for_ladder = true

[renderer]
http_timeout_ms = 4000
lightpanda_timeout_ms = 2500
chrome_timeout_ms = 30000
chrome_intercept_resources = true
chrome_nav_budget_ms = 12000
chrome_backend = "vanilla"
chrome_context_pool_enabled = true

[renderer.lightpanda]
ws_url = "ws://lightpanda.fastcrw.svc.cluster.local:9222/"

[renderer.chrome]
ws_url = "ws://chrome-stealth.fastcrw.svc.cluster.local:3000/chromium?stealth=true"

[renderer.chrome_pool]
size = 4

[search]
searxng_url = "https://searxng.diceninjagaming.com"
query_expand = true
query_expand_variants = 3
answer_calibrated = true

[auth]
api_keys = ["fc-key-1234", "fc-key-5678"]

[document]
enabled = true
sandbox = true
sandbox_memory_bytes = 536870912
```

Note: `chrome_pool.size = 4` (reduced from upstream's 8) for homelab resource
constraints. The stealth override (`ws_url` pointing at chrome-stealth) is set
via the `CRW_RENDERER__CHROME__WS_URL` env var on the Deployment (not in
configmap) because it includes a secret token.

**Pattern reference:** upstream `config.docker.toml`

**Dependencies:** None.

**Verification:** `kubectl get configmap -n fastcrw fastcrw-config -o yaml`

---

### U5: fastCRW Deployment + Service

**Files:**
- `apps/fastcrw/deployment-fastcrw.yaml` (new)
- `apps/fastcrw/service-fastcrw.yaml` (new)

Deployment spec:
- Image: `ghcr.io/us/crw:v0.19.0` (pinned semver)
- Container port: 3000
- Config volume: ConfigMap mounted at `/app/config.docker.toml` (read-only) via `subPath: config.docker.toml`
- Env: `CRW_CONFIG=config.docker.toml`, `RUST_LOG=info`,
  `CRW_RENDERER__CHROME__WS_URL` (from SealedSecret key `CHROME_WS_URL`)
- Resources: requests 64Mi/100m, limits 2Gi/1000m
- Security: `runAsNonRoot: true`, `runAsUser: 1000`, `readOnlyRootFilesystem: true`,
  `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false`
- **Note:** If fastCRW writes to `/tmp` (sandbox files, temporary downloads),
  add an `emptyDir` volume mounted at `/tmp` so the read-only root filesystem
  does not block runtime operation
- Node affinity: prefer `memory-tier=small` (weight 100)
- Liveness/readiness: HTTP GET `/health` on port 3000

Service: ClusterIP, port 3000 → 3000.

**Pattern reference:** `apps/hermes-agent/deployment-hermes-agent.yaml`

**Dependencies:** U2 (namespace), U3 (SealedSecret for `CHROME_WS_URL`), U4 (configmap).

**Verification:** `kubectl get pods -n fastcrw` shows fastcrw pod Running + Ready.

---

### U6: LightPanda Deployment + Service

**Files:**
- `apps/fastcrw/deployment-lightpanda.yaml` (new)
- `apps/fastcrw/service-lightpanda.yaml` (new)

Deployment spec:
- Image: `lightpanda/browser:0.3.3` (pinned semver)
- Container port: 9222
- Resources: requests 64Mi/50m, limits 1Gi/500m
- Node affinity: prefer NOT `memory-tier=small` (weight 100)
- Liveness: TCP socket check on port 9222
- **Note:** LightPanda can OOM/segfault on adversarial pages. Kubernetes
  Deployment controller auto-restarts containers; no explicit `restartPolicy`
  is needed (default is `Always`).

Service: ClusterIP, port 9222 → 9222.

**Pattern reference:** upstream docker-compose `lightpanda` service

**Dependencies:** U2.

**Verification:** `kubectl get pods -n fastcrw` shows lightpanda pod Running.

---

### U7: Chrome-Stealth Deployment + Service

**Files:**
- `apps/fastcrw/deployment-chrome-stealth.yaml` (new)
- `apps/fastcrw/service-chrome-stealth.yaml` (new)

Deployment spec:
- Image: `ghcr.io/browserless/chromium:v2.27.0` (pinned per upstream)
- Container port: 3000
- Env: `CONCURRENT=15`, `MAX_QUEUE_LENGTH=30`, `TIMEOUT=30000`,
  `EXIT_ON_HEALTH_FAILURE=true`
- Resources: requests 512Mi/100m, limits 3Gi/1000m
- Node affinity: prefer NOT `memory-tier=small` (weight 100)
- Liveness: TCP socket check on port 3000
- `emptyDir` with `medium: Memory` and `sizeLimit: 512Mi` mounted at `/tmp`
  (Kubernetes equivalent of tmpfs for session state)

Service: ClusterIP, port 3000 → 3000.

**Pattern reference:** upstream docker-compose `chrome-stealth` service

**Dependencies:** U2.

**Verification:** `kubectl get pods -n fastcrw` shows chrome-stealth pod Running.

---

### U8: IngressRoute

**Files:**
- `apps/fastcrw/ingressroute-fastcrw.yaml` (new)

IngressRoute:
- Host: `fastcrw.taegost.com`
- Route: `Host(\`fastcrw.taegost.com\`) && PathPrefix(\`/\`)`
- Service: fastcrw port 3000
- Middlewares: `default-whitelist` (namespace: traefik)
- TLS: `secretName: wildcard-taegost-com-tls`

**Pattern reference:** `apps/hermes-agent/ingressroute-hermes-agent.yaml`

**Dependencies:** U1 (wildcard cert), U5 (fastcrw service).

**Verification:** `curl -H "Host: fastcrw.taegost.com" <traefik-lb-ip>/health`
returns 200.

---

### U9: NetworkPolicies

**Files:**
- `apps/fastcrw/networkpolicy-fastcrw.yaml` (new)
- `apps/fastcrw/networkpolicy-lightpanda.yaml` (new)
- `apps/fastcrw/networkpolicy-chrome-stealth.yaml` (new)

#### fastcrw NetworkPolicy

**Ingress:**
- From Traefik pods in `traefik` namespace → port 3000

**Egress:**
1. DNS (kube-system/kube-dns) → UDP+TCP 53
2. LightPanda pods in `fastcrw` namespace → port 9222
3. Chrome-Stealth pods in `fastcrw` namespace → port 3000
4. Traefik pods in `traefik` namespace → port 443
5. Internet (0.0.0.0/0 except 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10) → port 443 only

**Note:** SearXNG is reached via external FQDN `https://searxng.diceninjagaming.com`.
An explicit egress rule to the `traefik` namespace is included to cover
split-horizon / internal DNS resolution paths.

#### lightpanda / chrome-stealth NetworkPolicy (identical structure)

**Ingress:**
- From fastcrw pods in `fastcrw` namespace → CDP port (9222 or 3000)

**Egress:**
1. DNS (kube-system/kube-dns) → UDP+TCP 53
2. Internet (0.0.0.0/0 except 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10) → port 443 only

**Pattern reference:** `apps/hermes-agent/networkpolicy-hermes-sandbox.yaml`

**Dependencies:** U2.

**Verification:**
- `kubectl run -n fastcrw --rm -i --restart=Never debug --image=curlimages/curl -- curl -sf http://lightpanda.fastcrw.svc.cluster.local:9222/json/version`
  succeeds (internal CDP reachability)
- `kubectl run -n fastcrw --rm -i --restart=Never debug --image=curlimages/curl -- curl -sfI https://example.com`
  succeeds (HTTPS egress)
- `kubectl run -n fastcrw --rm -i --restart=Never debug --image=curlimages/curl -- curl -sfI http://example.com`
  fails (HTTP egress blocked — expected)

From a lightpanda pod:

- Ingress only from fastcrw pods (verify by attempting to reach `lightpanda.fastcrw.svc.cluster.local:9222` from a debug pod in another namespace using `curl` — should time out or fail)
---

## Implementation Order

```text
U1 (wildcard cert) ──┬
                     ───► U2 (namespace + ArgoCD app) ───► U3 (SealedSecret)
U4 (configmap) ─────┬                                     │
                                                           ▼
U5 (fastcrw deploy) ◄── depends on U2, U3, U4 ──────── U3 (for env var)
U6 (lightpanda deploy) ◄── depends on U2
U7 (chrome-stealth deploy) ◄── depends on U2
U8 (IngressRoute) ◄── depends on U1, U5
U9 (NetworkPolicies) ◄── depends on U2
```

U1, U4 can be done in parallel. U5-U7 can be done in parallel once their
dependencies are met. U8 and U9 can be done in parallel after U5 and U2
respectively.

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| LightPanda OOM/segfault on adversarial pages | Medium — breaks the primary JS tier, requests fall through to Chrome-Stealth | `restart: Always` + `mem_limit: 1Gi` (upstream pattern) |
| Port 443-only egress blocks HTTP→HTTPS redirects | Low — some sites may not be reachable | Acceptable per policy directive. SearXNG returns HTTPS URLs preferentially. |
| Browserless v2 SSPL license | Low — internal use only | No third-party service exposure. Document for future reference. |
| `--ignore-certificate-errors` on Chrome-Stealth | Low — disables TLS validation in the fallback renderer | **Accepted risk** for internal scraping: renderer only touches public content, not sensitive data. Required for crawling sites with self-signed or expired certs. |
| No persistent storage for fastCRW | Low — crawl jobs are ephemeral by design | Stateless API server; no PVC needed for v1. Change-tracking snapshots would need storage (future work). |

## Test Scenarios

### TS-1: Health check

`curl https://fastcrw.taegost.com/health` returns 200.

### TS-2: Scrape a page

```bash
curl -X POST https://fastcrw.taegost.com/v1/scrape \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","formats":["markdown"]}'
```

Returns markdown content of example.com.

### TS-3: Search via SearXNG

```bash
curl -X POST https://fastcrw.taegost.com/v1/search \
  -H "Content-Type: application/json" \
  -d '{"query":"fastCRW web crawler","limit":5}'
```

Returns search results from SearXNG.

### TS-4: Browser tier escalation

Scrape a known SPA (e.g., a React app) — fastCRW should auto-escalate from
HTTP → LightPanda → Chrome-Stealth as needed. Verify via `RUST_LOG=info` logs showing
tier progression.

### TS-5: NetworkPolicy enforcement

From a fastcrw pod (via `kubectl run --rm -i --restart=Never debug --image=curlimages/curl`):

- `curl -sfI https://example.com` → succeeds
- `curl -sfI http://example.com` → fails (port 80 blocked)
- `curl -sf http://lightpanda.fastcrw.svc.cluster.local:9222/json/version` → succeeds (internal CDP)
- `curl -sf http://kube-apiserver:6443` → fails (cluster CIDR blocked)

From a lightpanda pod:

- Ingress only from fastcrw pods (verify by attempting to reach `lightpanda.fastcrw.svc.cluster.local:9222` from a debug pod in another namespace using `curl` — should time out or fail)

### TS-6: TLS termination

`curl -v https://fastcrw.taegost.com/health 2>&1 | grep "SSL certificate"`
shows valid Let's Encrypt cert for `*.taegost.com`.

### TS-7: ArgoCD sync

ArgoCD shows all resources Synced + Healthy in the `fastcrw` application.
No out-of-sync drift after initial deploy.

---

## Sources & Research

- fastCRW README: `github.com/us/crw` — architecture, docker-compose,
  config.docker.toml, security model
- fastCRW docker-compose.yml — service definitions, env vars, healthchecks,
  resource limits, security hardening
- fastCRW docker-compose.stealth.yml — chrome-stealth override pattern
- fastCRW config.docker.toml — renderer tiers, timeouts, pool sizing,
  SearXNG integration
- LightPanda: `hub.docker.com/r/lightpanda/browser` — CDP port 9222,
  low-memory headless browser
- Browserless v2: `ghcr.io/browserless/chromium:v2.27.0` — SSPL-3.0,
  TOKEN auth, CONCURRENT/TIMEOUT env vars
- homelab-k8s repo: existing patterns for NetworkPolicy, IngressRoute,
  node affinity, SealedSecret, ArgoCD Application, Certificate resources
