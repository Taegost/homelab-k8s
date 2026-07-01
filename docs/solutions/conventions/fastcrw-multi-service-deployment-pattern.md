---
title: "Multi-Service Web Crawling Stack Deployment Pattern"
date: 2026-06-30
category: conventions
module: homelab
problem_type: convention
component: tooling
severity: low
applies_when:
  - "Deploying multi-service stacks with mixed resource profiles to k3s"
  - "Configuring per-pod NetworkPolicies with DNS and HTTPS-only egress"
  - "Setting up wildcard TLS certificates with Traefik for new domains"
  - "Managing tiered browser rendering (lightweight + heavy fallback)"
  - "Implementing SealedSecret workflow for sensitive configuration"
tags:
  - kubernetes
  - k3s
  - network-policy
  - sealed-secrets
  - argocd
  - traefik
  - wildcard-tls
  - web-crawling
  - lightpanda
  - chrome-stealth
---

# Multi-Service Web Crawling Stack Deployment Pattern

## Context

Self-hosted web crawling infrastructure replaces external third-party services
(Firecrawl, Tavily) with a local stack composed of three cooperating services:
a Rust-based REST API server (fastCRW), a lightweight JavaScript renderer
(LightPanda), and a full Chromium browser fallback (Chrome-Stealth). All three
run on a small k3s Kubernetes cluster with MetalLB in L2 mode and Traefik as
the ingress controller.

The deployment runs in a dedicated `fastcrw` namespace. Each pod has explicit
NetworkPolicy rules, node placement constraints based on resource profile, and
security contexts tuned to the specific container image. A wildcard TLS
certificate covers all services under `*.taegost.com`.

This pattern emerged from deploying fastCRW (github.com/us/crw) to replace
dependency on external scraping services, while following every established
homelab convention for security, networking, and GitOps.

## Guidance

### Namespace and Service Overview

Three services coexist in the `fastcrw` namespace:

| Service | Image | Port | Resource Profile | Role |
|---|---|---|---|---|
| fastcrw | `ghcr.io/us/crw:v0.19.0` | 3000 | Lightweight (~50 MB idle) | REST API + crawl orchestrator |
| LightPanda | `lightpanda/browser:0.3.3` | 9222 (CDP) | Lightweight (~64 MB idle) | Primary JS renderer |
| Chrome-Stealth | `ghcr.io/browserless/chromium:v2.27.0` | 3000 | Heavy (3Gi limit) | Fallback JS renderer (anti-detection) |

Browser tier escalation: HTTP (no browser) → LightPanda (lightweight JS) →
Chrome-Stealth (anti-detection). fastCRW auto-detects SPAs and escalates
through tiers based on response quality.

### Per-Pod NetworkPolicy (Not Default-Deny)

Each pod gets its own NetworkPolicy specifying exact ingress and egress rules.
This is more explicit and easier to audit than a namespace-wide default-deny
with exception rules. Each policy is self-documenting.

**Port 80 (plaintext HTTP) is deliberately blocked** for all pods. Only port
443 egress is allowed. This is a policy decision — if a site doesn't have TLS,
it's not worth crawling.

**Egress to Traefik uses `namespaceSelector`, not `ipBlock`.** MetalLB in L2
mode causes hairpin routing issues where `ipBlock` rules for LoadBalancer IPs
fail with ECONNREFUSED. The `namespaceSelector` approach routes through
ClusterIP, bypassing the hairpin entirely.

See `docs/solutions/runtime-errors/metallb-hairpin-networkpolicy-egress.md` for
the full root-cause analysis of this pattern.

```yaml
# fastcrw NetworkPolicy — API server
# Ingress: from Traefik pods only
# Egress: DNS + LightPanda (9222) + Chrome-Stealth (3000) + Traefik (443) + Internet (443)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: fastcrw
  namespace: fastcrw
spec:
  podSelector:
    matchLabels:
      app: fastcrw
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
      ports:
        - protocol: TCP
          port: 3000
  egress:
    # DNS resolution (kube-dns)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # LightPanda CDP (in-cluster, same namespace)
    - to:
        - podSelector:
            matchLabels:
              app: lightpanda
      ports:
        - protocol: TCP
          port: 9222
    # Chrome-Stealth WS (in-cluster, same namespace)
    - to:
        - podSelector:
            matchLabels:
              app: chrome-stealth
      ports:
        - protocol: TCP
          port: 3000
    # Traefik namespace — covers SearXNG via external FQDN
    # (resolved through Traefik's ClusterIP, avoids MetalLB hairpin)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
      ports:
        - protocol: TCP
          port: 443
    # Internet HTTPS — port 443 only, excluding cluster and local networks
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 169.254.0.0/16
              - 100.64.0.0/10
      ports:
        - protocol: TCP
          port: 443
```

LightPanda and Chrome-Stealth have simpler policies: ingress from fastcrw pods
only, egress DNS + internet HTTPS.

### Node Affinity by Resource Profile

Lightweight pods prefer `memory-tier=small` nodes. Heavy browser pods avoid
small nodes. This maximizes cluster utilization without overcommitting small
nodes.

```yaml
# Lightweight pod (fastcrw) — prefer small nodes
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: memory-tier
              operator: In
              values:
                - small
```

```yaml
# Heavy pod (Chrome-Stealth, LightPanda) — avoid small nodes
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: memory-tier
              operator: NotIn
              values:
                - small
```

### Wildcard Certificate for New Domains

When adding services under a new domain (e.g., `*.taegost.com`), create a
wildcard Certificate in the `traefik` namespace. This follows the established
pattern from `*.diceninjagaming.com`.

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

IngressRoute resources for wildcard-cert services live in the `traefik`
namespace (the file lives in the app directory for discoverability):

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: fastcrw
  namespace: traefik
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`fastcrw.taegost.com`) && PathPrefix(`/`)
      kind: Rule
      middlewares:
        - name: default-whitelist
          namespace: traefik
      services:
        - name: fastcrw
          namespace: fastcrw
          port: 3000
  tls:
    secretName: wildcard-taegost-com-tls
```

### Security Context Per Image (Never Copy)

Each container image has a different privilege model. Never copy security
contexts between apps. Always check the Dockerfile for USER, EXPOSE, and
privilege-drop patterns.

See `docs/solutions/best-practices/security-context-audit-pattern.md` for the
audit workflow. Run the audit script before writing any securityContext:

```bash
.claude/skills/homelab-image-audit/audit.sh --image <image> --type <type>
```

For the crawling stack:

| Image | UID | Why | Notes |
|---|---|---|---|
| fastcrw | 1000 | Rust static binary, runs as root by default but upstream docker-compose uses cap_drop ALL + read_only | K8s override for defense-in-depth |
| LightPanda | 1000 | Runs as root by default, no USER in Dockerfile | Port 9222 (> 1024), no capabilities needed |
| Chrome-Stealth | 999 | Browserless v2 uses `blessuser` (UID 999) | Chromium sandbox requires this UID |

All three use:
```yaml
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

### ConfigMap with Env Var Override for Secrets

Application config goes in a ConfigMap. Secrets are injected via `secretKeyRef`
env vars that override config file values at runtime. This keeps secrets out of
the ConfigMap (plaintext avoidance).

```yaml
# ConfigMap — non-sensitive config
apiVersion: v1
kind: ConfigMap
metadata:
  name: fastcrw-config
  namespace: fastcrw
data:
  config.docker.toml: |
    [renderer.chrome]
    ws_url = "ws://chrome-stealth.fastcrw.svc.cluster.local:3000/chromium?stealth=true"
    # Token is injected via CRW_RENDERER__CHROME__WS_URL env var from SealedSecret
```

```yaml
# Deployment — secret overrides via env var
env:
  - name: CRW_RENDERER__CHROME__WS_URL
    valueFrom:
      secretKeyRef:
        name: fastcrw
        key: CHROME_WS_URL
  - name: CRW_AUTH__API_KEYS
    valueFrom:
      secretKeyRef:
        name: fastcrw
        key: API_KEYS
```

### SealedSecret Workflow

App-level SealedSecrets use sync-wave `-1` with dual annotations (decrypted
before Deployments at wave 0). See `docs/solutions/conventions/sync-wave-ordering.md`
for the canonical wave reference.

```bash
# 1. Create plaintext template (gitignored)
# 2. Fill in real values
# 3. Seal:
kubeseal --format yaml --controller-name sealed-secrets-controller --controller-namespace kube-system < apps/fastcrw/secret-fastcrw.yaml > apps/fastcrw/sealedsecret-fastcrw.yaml
# 4. Add sync-wave "-1" to SealedSecret's spec.template.metadata.annotations
# 5. Delete plaintext template
# 6. Commit sealedsecret-fastcrw.yaml
```

### startupProbe for Heavy Containers

Chrome-Stealth's Chromium browser takes 2-4 minutes to fully initialize on
cold start (browser process spawn, anti-detection setup). Without a
startupProbe, the livenessProbe would kill the container during initialization.

```yaml
# Chrome-Stealth — 5-minute startup window
startupProbe:
  tcpSocket:
    port: 3000
  periodSeconds: 10
  failureThreshold: 30  # 10s × 30 = 300s = 5 min
```

LightPanda and fastcrw are lightweight and don't need startupProbes.

### readinessProbe on All Deployments

Every deployment includes a readinessProbe to prevent traffic routing to
unready pods. Use HTTP for API servers, TCP for browser/CDP endpoints:

```yaml
# fastcrw (API server) — HTTP health endpoint
readinessProbe:
  httpGet:
    path: /health
    port: 3000
  periodSeconds: 10

# LightPanda / Chrome-Stealth (browser) — TCP socket check
readinessProbe:
  tcpSocket:
    port: 9222  # or 3000 for chrome-stealth
  periodSeconds: 10
```

### Recreate Strategy for Single-Replica Deployments

Single-replica deployments use `strategy: Recreate` to avoid port conflicts.
The default `RollingUpdate` creates the new pod before terminating the old one,
causing port binding failures.

```yaml
spec:
  replicas: 1
  strategy:
    type: Recreate
```

## Why This Matters

**Per-pod NetworkPolicy over default-deny.** For a small stack with three
services, per-pod policies are simpler to reason about. Each policy documents
exactly what that pod can reach — self-documenting network segmentation.

**Port 443-only egress.** Blocking port 80 eliminates an entire class of
plaintext data-leak vectors. Modern web services should use HTTPS.

**namespaceSelector for Traefik egress.** MetalLB L2 hairpin makes `ipBlock`
rules for LoadBalancer IPs fail silently. `namespaceSelector` routes through
ClusterIP, bypassing the hairpin. This is the same pattern used by honcho and
LiteLLM — see `docs/solutions/conventions/honcho-deployment-patterns.md`.

**Node affinity by resource profile.** Lightweight services (~50 MB) co-locate
on small nodes; heavy browsers (3Gi) avoid them. Maximizes utilization without
overcommitting.

**Security context per image.** Chrome-Stealth requires UID 999 for Chromium
sandbox compatibility. fastCRW and LightPanda use UID 1000. Copying contexts
between apps causes permission errors or security gaps.

**startupProbe for Chromium.** Without it, Chromium's 2-4 minute cold start
triggers liveness kills and crash loops. The 5-minute startup window prevents
this.

**Recreate strategy.** With a single replica, the old pod must terminate before
the new pod binds the same port. RollingUpdate causes port conflicts.

## When to Apply

- Deploying a multi-service stack with mixed resource profiles (lightweight + heavy)
- Running on k3s with MetalLB L2 mode and Traefik ingress
- Adding services under a new wildcard domain
- Deploying browser automation workloads with extended cold-start times
- Managing secrets via SealedSecrets in a GitOps workflow

## Examples

### Before: External Service (No K8s Manifests)

Browser automation via external API endpoint. No network policies, no pod
scheduling, no security contexts.

### After: Self-Hosted Stack

14 manifests across 3 directories:

```
apps/fastcrw/
├── namespace-fastcrw.yaml
├── configmap-fastcrw-config.yaml
├── deployment-fastcrw.yaml          # API server (UID 1000, prefers small nodes)
├── service-fastcrw.yaml
├── deployment-lightpanda.yaml       # Primary browser (UID 1000, avoids small nodes)
├── service-lightpanda.yaml
├── deployment-chrome-stealth.yaml   # Fallback browser (UID 999, startupProbe)
├── service-chrome-stealth.yaml
├── ingressroute-fastcrw.yaml        # → traefik namespace (wildcard cert)
├── networkpolicy-fastcrw.yaml       # Ingress: traefik, Egress: DNS + browsers + internet
├── networkpolicy-lightpanda.yaml    # Ingress: fastcrw, Egress: DNS + internet
├── networkpolicy-chrome-stealth.yaml # Ingress: fastcrw, Egress: DNS + internet
├── secret-fastcrw.yaml              # Plaintext template (gitignored)
└── (sealedsecret-fastcrw.yaml)      # Sealed version (committed)

apps/manifests/
└── fastcrw.yaml                     # ArgoCD Application

apps/traefik/certificates/
└── certificate-taegost-wildcard.yaml # *.taegost.com wildcard cert
```

## Related

- `docs/solutions/runtime-errors/metallb-hairpin-networkpolicy-egress.md` — MetalLB L2 hairpin root cause and namespaceSelector solution
- `docs/solutions/conventions/sync-wave-ordering.md` — ArgoCD sync wave ordering (SealedSecret dual annotations)
- `docs/solutions/best-practices/security-context-audit-pattern.md` — Per-image security context audit workflow
- `docs/solutions/conventions/honcho-deployment-patterns.md` — Overlapping patterns (namespaceSelector egress, SealedSecret annotations, exec probe timeouts)
- `docs/solutions/conventions/hermes-agent-ssh-sandbox-deployment-pattern.md` — Multi-pod deployment with per-container security contexts
- `docs/solutions/runtime-errors/librechat-deployment-cascade.md` — Sync-wave ordering failure cautionary reference
