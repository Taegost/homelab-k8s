---
title: "Honcho Deployment Patterns: Cache Auth, LiteLLM Routing, NetworkPolicy, Exec Probes, SealedSecret Waves"
date: 2026-06-23
category: conventions
module: homelab
problem_type: convention
component: honcho
severity: medium
applies_when:
  - "Deploying an app with a Valkey/Redis cache and no auth requirement"
  - "Routing LLM API calls through LiteLLM from a new app"
  - "Writing NetworkPolicy for background workers with no inbound traffic"
  - "Using exec probes on fast-CLI images (valkey-cli, pg_isready, etc.)"
  - "Creating SealedSecrets with ArgoCD sync-wave annotations"
tags:
  - honcho
  - valkey
  - networkpolicy
  - litellm
  - exec-probes
  - sealed-secrets
  - sync-waves
  - cache-auth
---

# Honcho Deployment Patterns

## Context

Honcho (Plastic Labs' self-hosted AI memory backend) was deployed on a k3s
homelab cluster managed by ArgoCD. The deployment involves three components:
an API server, a background deriver worker, and a Valkey cache. Five
deployment patterns were established during implementation that apply to
future apps beyond Honcho.

---

## 1. Valkey/Redis Authentication via NetworkPolicy (Not Password)

### Guidance

Run Valkey/Redis without authentication and use a NetworkPolicy to restrict
ingress to only pods in the same namespace. Do not add `--requirepass` to
the server command or embed a password in `CACHE_URL`.

**Wrong approach** -- password in server args and ConfigMap:

```yaml
# WRONG: password in ConfigMap, embedded in CACHE_URL, AND duplicated in SealedSecret
command:
  - valkey-server
  - --requirepass
  - my_secret_password
data:
  CACHE_URL: "redis://:my_secret_password@valkey.honcho.svc.cluster.local:6379/0"
```

**Right approach** -- no auth, network isolation:

```yaml
# RIGHT: no password, plain URL, NetworkPolicy restricts access
command:
  - valkey-server
  - --maxmemory
  - "96mb"
  - --maxmemory-policy
  - allkeys-lru
data:
  CACHE_URL: "redis://honcho-valkey.honcho.svc.cluster.local:6379/0?suppress=true"
```

The NetworkPolicy restricting ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: honcho-valkey
  namespace: honcho
spec:
  podSelector:
    matchLabels:
      app: honcho-valkey
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: honcho
      ports:
        - protocol: TCP
          port: 6379
```

### Why This Matters

- **ConfigMap stores plaintext in etcd.** A password in the ConfigMap is
  visible to anyone with `kubectl get configmap` access -- it is not a secret,
  it is documentation. Putting a password there provides zero security.
- **Duplication.** Password in ConfigMap `CACHE_URL` AND in the SealedSecret
  means two sources of truth. If they diverge, the cache connection fails with
  an auth error that is hard to trace.
- **NetworkPolicy is stronger.** Restricting ingress at the network level
  means no pod outside the namespace can even reach the Valkey port, password
  or not. This is defense-in-depth that works regardless of authentication
  state.
- **Pattern source.** `apps/plane/deployment-valkey.yaml` established this
  pattern -- Plane also runs Valkey without auth, relying on namespace-level
  network isolation.

### When to Apply

- Any Valkey or Redis deployment used as a cache (not a durable data store)
- Any in-memory data store where the data is ephemeral and loss is acceptable
- When the cache is only consumed by pods in the same namespace
- When the cache holds no user credentials or PII

---

## 2. LiteLLM External URL Routing (HTTPS, Not Cluster-Internal HTTP)

### Guidance

When routing LLM API calls through LiteLLM, use the external HTTPS domain
(`https://litellm.diceninjagaming.com/v1`) instead of the cluster-internal
HTTP endpoint (`http://litellm.litellm.svc.cluster.local:4000`).

**Wrong approach:**

```yaml
LLM_OPENAI_BASE_URL: "http://litellm.litellm.svc.cluster.local:4000/v1"
```

**Right approach:**

```yaml
LLM_OPENAI_BASE_URL: "https://litellm.diceninjagaming.com/v1"
```

### NetworkPolicy impact

LiteLLM's MetalLB IP is outside any Kubernetes namespace, so egress rules
cannot use `namespaceSelector`. Allow egress on port 443 without a namespace
selector:

```yaml
egress:
  # --- LiteLLM proxy (external HTTPS domain, MetalLB IP outside cluster namespaces) ---
  - ports:
      - protocol: TCP
        port: 443
```

### Why This Matters

- **HTTPS for LLM API calls.** Cluster-internal HTTP means API keys travel
  unencrypted across the network. External HTTPS routes through Traefik with
  a valid certificate.
- **Consistency.** Other apps (hermes-agent, LibreChat) already use the
  external domain. Mixing internal and external URLs creates two code paths
  to debug.
- **Firewall friendliness.** Egress to port 443 is universally allowed.
  Egress to a cluster-internal IP on port 4000 requires explicit allowlisting
  that varies by NetworkPolicy.
- **MetalLB limitation.** ExternalName Services cannot resolve to raw IPs
  within Kubernetes. The external domain is the only reliable way to reach a
  MetalLB-backed service from inside the cluster via HTTPS.

### When to Apply

- Any app that calls LiteLLM (or any external API gateway) from inside the cluster
- When LiteLLM is fronted by Traefik with a valid TLS certificate
- When the app has a NetworkPolicy that restricts egress

---

## 3. Egress-Only NetworkPolicy for Background Workers

### Guidance

Background workers that pull work from a database queue (Postgres, MariaDB)
and never receive inbound network requests need an egress-only NetworkPolicy.
Do not include `Ingress` in `policyTypes` -- it creates an implicit deny-all
ingress rule that is unnecessary for a worker with no health endpoint or API.

**Pattern:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: honcho-deriver
  namespace: honcho
spec:
  podSelector:
    matchLabels:
      app: honcho-deriver
  policyTypes:
    - Egress          # <-- only Egress, no Ingress
  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Postgres (database queue)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: postgres
      ports:
        - protocol: TCP
          port: 5432
    # LiteLLM (external HTTPS)
    - ports:
        - protocol: TCP
          port: 443
    # Valkey (cache)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: honcho
          podSelector:
            matchLabels:
              app: honcho-valkey
      ports:
        - protocol: TCP
          port: 6379
```

### Why This Matters

- **No ingress needed.** The deriver is a background worker -- it pulls work
  from a Postgres-backed queue, not from HTTP requests. No Service, no
  IngressRoute, no inbound traffic. Including `Ingress` in `policyTypes`
  creates a deny-all ingress rule that is technically correct but misleading
  -- it implies there was an ingress concern to address.
- **Explicit is better than implicit.** An egress-only policy makes the
  intent clear: this pod talks to specific destinations and nothing else.
  A future reader does not need to wonder "why is there an empty ingress
  section?"
- **Mirrors the API pattern.** The API deployment has both Ingress and Egress
  rules. The deriver has only Egress. This asymmetry documents the
  architectural difference (request-driven vs queue-driven) directly in the
  manifests.

### When to Apply

- Any background worker, cron job, or queue consumer that has no inbound traffic
- Workers that pull from a database queue (Postgres, MariaDB)
- Celery workers, Sidekiq workers, or similar task queue consumers
- Any pod with no Service or IngressRoute

---

## 4. Exec Probe Timeout for Fast CLIs

### Guidance

Kubernetes defaults `timeoutSeconds` to 1 second for probes. Exec probes
that run CLI commands (valkey-cli, pg_isready, mysqladmin, etc.) need an
explicit `timeoutSeconds: 5` to avoid spurious failures. The pre-commit
hook requires >= 2s for fast CLIs; use 5s for safety margin.

**Wrong approach** -- no timeout (Kubernetes default of 1s):

```yaml
livenessProbe:
  exec:
    command:
      - sh
      - -c
      - "valkey-cli ping"
  periodSeconds: 30
  failureThreshold: 3
  # timeoutSeconds defaults to 1 -- too short for CLI execution
```

**Right approach** -- explicit 5s timeout:

```yaml
livenessProbe:
  exec:
    command:
      - sh
      - -c
      - "valkey-cli ping"
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 3
```

### Pre-commit validation tiers

The `probe-timeout-check.sh` script enforces minimum timeouts:

| Tier | CLIs | Minimum timeout |
|------|------|-----------------|
| Slow | rabbitmq-diagnostics, rabbitmqctl, celery | >= 5s |
| Fast | redis-cli, valkey-cli, pg_isready, mysqladmin, mongosh | >= 2s |
| Generic | Any other exec probe with default/missing timeout | WARN |

### Why This Matters

- **1s is too short.** CLI commands need process startup time, network round
  trip, and command execution. Under load or during initial pod startup, 1s
  causes flapping.
- **Flapping kills pods.** A liveness probe that times out counts as failure.
  Three consecutive failures (the default `failureThreshold`) triggers a
  container restart. Spurious restarts are noisy and mask real problems.
- **HTTP probes are different.** HTTP probes use a TCP connection with a
  built-in timeout mechanism. Exec probes rely on `timeoutSeconds` alone.
  Do not conflate the two.

### When to Apply

- Any exec probe that runs a CLI command (valkey-cli, pg_isready, mysqladmin,
  mongosh, rabbitmqctl, celery inspect, etc.)
- Never assume the default 1s timeout is sufficient for exec probes
- HTTP and TCP probes have different timeout mechanisms and do not need this

---

## 5. SealedSecret Sync-Wave Dual Annotation

### Guidance

SealedSecrets must carry the `argocd.argoproj.io/sync-wave` annotation in
**both** `metadata.annotations` and `spec.template.metadata.annotations`.
The top-level annotation controls when ArgoCD syncs the SealedSecret CRD.
The template annotation controls what wave the resulting decrypted Secret
syncs at.

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: honcho
  namespace: honcho
  annotations:
    argocd.argoproj.io/sync-wave: "-1"    # <-- top-level: controls CRD sync
spec:
  encryptedData:
    database-url: ENCRYPTED_VALUE
    jwt-secret: ENCRYPTED_VALUE
  template:
    metadata:
      annotations:
        argocd.argoproj.io/sync-wave: "-1"    # <-- template: controls Secret sync
      name: honcho
      namespace: honcho
    type: Opaque
```

### Why This Matters

- **Two different sync events.** ArgoCD first syncs the SealedSecret CRD
  (top-level annotation), then the Sealed Secrets controller decrypts it and
  creates a Secret (template annotation). These are separate reconciliation
  loops.
- **Missing template annotation = wave 0.** If only the top-level annotation
  is present, the resulting Secret syncs at the default wave (0). This means
  a Deployment at wave 0 can start before its Secret exists, causing
  CreateContainerConfigError.
- **Pre-commit catches it.** The `sync-wave-check.sh` script validates that
  both annotations exist on SealedSecrets. But the convention should be
  understood, not just enforced by tooling.

### When to Apply

- Every SealedSecret with a non-zero sync-wave annotation
- The template annotation value must match the top-level annotation value
- Wave 0 SealedSecrets can omit both annotations (default behavior)

---

## Related

- `apps/plane/deployment-valkey.yaml` -- Valkey without auth pattern source
- `apps/honcho/configmap-honcho.yaml` -- clean CACHE_URL without auth
- `apps/honcho/networkpolicy-honcho-valkey.yaml` -- namespace-level ingress restriction
- `apps/honcho/networkpolicy-honcho-deriver.yaml` -- egress-only pattern
- `apps/honcho/deployment-honcho-deriver.yaml` -- exec probe with explicit timeout
- `apps/honcho/sealedsecret-honcho.yaml` -- dual sync-wave annotation example
- `.claude/skills/homelab-validate/scripts/probe-timeout-check.sh` -- exec probe timeout validation
- `docs/solutions/conventions/sync-wave-ordering.md` -- sync wave reference
- `docs/solutions/base-images-redis-valkey.md` -- Redis/Valkey security context
