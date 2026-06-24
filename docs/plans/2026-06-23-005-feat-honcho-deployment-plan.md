---
title: "feat: Honcho AI memory backend deployment"
type: feat
status: completed
date: 2026-06-23
---

# feat: Honcho AI Memory Backend Deployment

## Summary

Deploy Honcho (Plastic Labs' self-hosted AI memory backend) as an internal
service on the homelab k3s cluster. Honcho is a standalone service providing
a REST API for managing AI conversation memory and a background deriver process
for memory processing. Two Deployments from the same Docker image, backed by
the shared CNPG PostgreSQL cluster (with pgvector), a dedicated Valkey instance
for caching, and LLM access routed through the existing LiteLLM proxy.

Honcho is NOT the hermes-agent -- it is an independent service that Hermes
connects TO as a memory backend.

---

## Section 1: Infrastructure Assessment

### What Already Exists

| Component | Location | Relevance |
|---|---|---|
| PostgreSQL 18 (CNPG) | `postgres` namespace | Honcho's primary data store. pgvector extension available in the CNPG cluster (already installed in `librechat_rag` database; Honcho's database will create it automatically on first startup) |
| PgBouncer pooler | `postgres-pooler.postgres.svc.cluster.local:5432` | **Cannot use.** Honcho's Alembic migration runner takes advisory locks during startup, which are incompatible with PgBouncer's transaction-mode connection pooling. Must use direct `postgres-rw` connection |
| LiteLLM proxy | `https://litellm.diceninjagaming.com` | Honcho's LLM calls route through LiteLLM, giving access to all configured upstream models via a single endpoint |
| ArgoCD app-of-apps | `apps/manifests/` | Standard Application manifest with `directory.recurse: true`, automated sync, prune+selfHeal |
| Traefik ingress | `traefik` namespace | Per-app certs via `letsencrypt-taegost-prod` ClusterIssuer; `default-whitelist` middleware for internal-only routes |
| Sealed Secrets | kube-system controller | All sensitive values encrypted at rest; secret templates with kubeseal commands follow repo convention |
| Valkey pattern | `apps/plane/deployment-valkey.yaml` | Established pattern: `valkey/valkey:7.2.11-alpine`, UID 999, no persistence, minimal resources, exec probes with `valkey-cli ping` |

### What Needs to Be Created

| Resource | Namespace | Purpose |
|---|---|---|
| CNPG `Database` CRD | `postgres` | `honcho` database owned by `honcho` role |
| Role entry in `cluster-postgres.yaml` | `postgres` | Declares the `honcho` role for CNPG management |
| SealedSecret (db credentials) | `postgres` | DB password for CNPG role (sync-wave -3) |
| ConfigMap | `honcho` | Non-secret environment variables shared by API and Deriver pods |
| SealedSecret (app secrets) | `honcho` | DB connection URL, JWT secret, LLM API key (sync-wave -1) |
| Valkey Deployment + Service | `honcho` | In-memory cache for Honcho session data |
| API Deployment + Service | `honcho` | FastAPI REST server on port 8000 |
| Deriver Deployment | `honcho` | Background memory processing worker |
| Certificate | `honcho` | Per-app cert for `honcho.taegost.com` via `letsencrypt-taegost-prod` |
| IngressRoute | `honcho` | Internal-only route via `default-whitelist` middleware |
| NetworkPolicies | `honcho` | Ingress/egress rules for API and Valkey |
| ArgoCD Application | `argocd` | Standard app-of-apps entry, sync-wave 0 |

### Notable Constraints

1. **pgvector is available in the CNPG cluster** -- the `vector` extension is
   already installed in the `librechat_rag` database. Honcho's database will
   create it automatically on first startup via `CREATE EXTENSION IF NOT EXISTS
   vector`; this happens during Alembic migration.

2. **Alembic advisory locks require `postgres-rw`** -- Honcho runs Alembic
   migrations on API startup. Alembic uses PostgreSQL advisory locks to prevent
   concurrent migration runs, which require a persistent connection. PgBouncer in
   transaction mode can terminate the connection between lock acquire and release,
   causing deadlocks. The direct `postgres-rw` endpoint (bypassing PgBouncer) is
   the same pattern used by LiteLLM's Prisma migrations.

3. **Semver tag available** -- `ghcr.io/plastic-labs/honcho:v3.0.10` is a
   published semver tag. Use this for reproducibility rather than digest pinning.
   Upgrade by bumping the tag in the Deployment manifest.

4. **UID/GID 100/100 (deterministic)** -- The Dockerfile at v3.0.10 runs
   `addgroup --system app && adduser --system --group app`, which creates a
   Debian bookworm system user at UID 100, GID 100. This is deterministic
   (not random) and consistent across builds of the same base image.

---

## Section 2: Honcho Deployment Plan

### 2.1 Directory Structure

```
apps/honcho/
├── certificate-honcho.yaml                   # Per-app cert (honcho namespace)
├── configmap-honcho.yaml                     # Non-secret env vars (shared by API + Deriver)
├── database-honcho.yaml                      # CNPG Database CRD (postgres namespace)
├── deployment-honcho-api.yaml                # FastAPI REST server
├── deployment-honcho-deriver.yaml            # Background memory worker
├── deployment-honcho-valkey.yaml             # Valkey cache instance
├── ingressroute-honcho.yaml                  # Internal route (honcho namespace)
├── networkpolicy-honcho-api.yaml             # Ingress/egress rules for API server
├── networkpolicy-honcho-deriver.yaml         # Egress rules for deriver (no ingress -- pulls from DB queue)
├── networkpolicy-honcho-valkey.yaml          # Ingress rules for Valkey cache
├── secret-honcho.yaml                        # Plaintext secret template (gitignored)
├── secret-honcho-db-credentials.yaml         # Plaintext DB credentials (gitignored)
├── sealedsecret-honcho.yaml                  # App secrets (honcho namespace)
├── sealedsecret-honcho-db-credentials.yaml   # DB password (postgres namespace)
├── service-honcho-api.yaml                   # ClusterIP for API
└── service-honcho-valkey.yaml                # ClusterIP for Valkey

apps/manifests/honcho.yaml                    # ArgoCD Application manifest
```

### 2.2 Database Provisioning

Three resources work together: a SealedSecret for the DB password (postgres
namespace), a CNPG Database CRD that creates the database and assigns ownership,
and a role entry in the shared cluster spec.

**Step 1: Plaintext Secret for DB credentials** (`apps/honcho/secret-honcho-db-credentials.yaml` -- gitignored)

This secret lives in the `postgres` namespace so CNPG can set the role password.
The password here must match the one in the app-level secret (section 2.9).

```yaml
# Postgres role credentials for the honcho database.
#
# Fill in a strong password, then seal:
#   kubeseal --format yaml < apps/honcho/secret-honcho-db-credentials.yaml > apps/honcho/sealedsecret-honcho-db-credentials.yaml
#   rm apps/honcho/secret-honcho-db-credentials.yaml
#
# IMPORTANT: use the same password value in secret-honcho.yaml (key: database-url)
# in the honcho namespace -- Kubernetes pods cannot reference secrets across namespaces.
---
apiVersion: v1
kind: Secret
metadata:
  name: honcho-db-credentials
  namespace: postgres
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: honcho
  # Placeholder -- fill in before sealing. Do NOT use dots or dashes.
  password: "your_strong_password_here"
```

**Step 2: Database CRD** (`apps/honcho/database-honcho.yaml`)

```yaml
# Database CRD -- creates the honcho database and assigns honcho as owner.
# The role is declared in apps/postgres/cluster-postgres.yaml under spec.managed.roles.
#
# pgvector extension: available in the CNPG cluster (installed in librechat_rag).
# Honcho will run "CREATE EXTENSION IF NOT EXISTS vector" on first startup
# during Alembic migration. No manual extension setup required.
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: honcho
  namespace: postgres
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  name: honcho
  owner: honcho
  cluster:
    name: postgres
```

**Step 3: Role entry in `apps/postgres/cluster-postgres.yaml`**

Add to `spec.managed.roles`:

```yaml
      - name: honcho
        login: true
        superuser: false
        createdb: false
        createrole: false
        inherit: true
        connectionLimit: -1
        passwordSecret:
          name: honcho-db-credentials
```

### 2.3 Valkey Deployment

Single-replica Valkey instance for Honcho's cache layer. Follows the exact
pattern from `apps/plane/deployment-valkey.yaml`. No PVC needed -- all cached
data is ephemeral and can be lost on restart without impact.

**Deployment** (`apps/honcho/deployment-honcho-valkey.yaml`):

```yaml
# Deployment -- Valkey (Redis-compatible cache)
#
# Honcho uses Valkey for session caching. Cache state is ephemeral -- durable
# state lives in Postgres. Disabling persistence avoids write errors when
# running non-root without a writable /data volume.
#
# No authentication -- network-level isolation via the Valkey NetworkPolicy
# restricts ingress to pods in the honcho namespace. This matches the plane
# pattern: apps/plane/deployment-valkey.yaml also runs without auth.
# allkeys-lru eviction is acceptable for a cache -- no critical data lost.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: honcho-valkey
  namespace: honcho
  labels:
    app.kubernetes.io/part-of: honcho
spec:
  replicas: 1
  selector:
    matchLabels:
      app: honcho-valkey
  template:
    metadata:
      labels:
        app: honcho-valkey
        app.kubernetes.io/part-of: honcho
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: valkey
          image: docker.io/valkey/valkey:7.2.11-alpine
          command:
            - valkey-server
            - --maxmemory
            - 96mb
            - --maxmemory-policy
            - allkeys-lru
          ports:
            - containerPort: 6379
          livenessProbe:
            exec:
              command:
                - sh
                - -c
                - "valkey-cli ping"
            initialDelaySeconds: 10
            periodSeconds: 30
            failureThreshold: 3
          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - "valkey-cli ping"
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 10m
              memory: 48Mi
            limits:
              cpu: 200m
              memory: 192Mi
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            # Valkey image runs as UID 999. Bypasses the entrypoint's
            # privilege-drop step -- detects it is already the correct
            # user and skips chown. ALL capabilities dropped.
            runAsUser: 999
            runAsGroup: 999
            capabilities:
              drop:
                - ALL
```

**Service** (`apps/honcho/service-honcho-valkey.yaml`):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: honcho-valkey
  namespace: honcho
spec:
  selector:
    app: honcho-valkey
  ports:
    - port: 6379
      targetPort: 6379
```

### 2.4 API Deployment

The FastAPI REST server. Alembic runs migrations automatically on startup --
the generous startup probe budget accounts for this. Auth is ALWAYS enabled
(`AUTH_USE_AUTH=true`) -- this is non-negotiable.

The API CAN run multiple replicas safely (Alembic handles concurrent migrations
via database locking). Set to 1 for the initial single-user deployment; scale
up if additional services connect later.

**Deployment** (`apps/honcho/deployment-honcho-api.yaml`):

```yaml
# Deployment -- Honcho API server
#
# FastAPI REST server on port 8000. Alembic runs migrations automatically
# on startup -- the startup probe budget accounts for migration time.
#
# Auth is ALWAYS enabled (AUTH_USE_AUTH=true). This is non-negotiable.
#
# This deployment CAN be scaled beyond 1 replica -- Alembic handles concurrent
# migrations via database locking. Set to 1 for single-user homelab use;
# increase if additional services connect later.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: honcho-api
  namespace: honcho
  labels:
    app.kubernetes.io/part-of: honcho
spec:
  replicas: 1
  # Recreate strategy -- ensures clean state transition during upgrades.
  # At replicas=1 this is functionally equivalent to RollingUpdate, but
  # Recreate makes the intent explicit: terminate old, then start new.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: honcho-api
  template:
    metadata:
      labels:
        app: honcho-api
        app.kubernetes.io/part-of: honcho
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: honcho-api
          image: ghcr.io/plastic-labs/honcho:v3.0.10
          ports:
            - containerPort: 8000
          envFrom:
            - configMapRef:
                name: honcho-config
          env:
            # --- Secrets (from SealedSecret) ---
            - name: DB_CONNECTION_URI
              valueFrom:
                secretKeyRef:
                  name: honcho
                  key: database-url
            - name: LLM_OPENAI_API_KEY
              valueFrom:
                secretKeyRef:
                  name: honcho
                  key: llm-api-key
            - name: AUTH_JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: honcho
                  key: jwt-secret
            # DERIVER_ENABLED is deployment-specific, NOT in the shared ConfigMap.
            # API pod does NOT run the deriver -- a separate deployment handles it.
            - name: DERIVER_ENABLED
              value: "false"
          securityContext:
            # UID/GID 100/100 from Dockerfile: "addgroup --system app &&
            # adduser --system --group app" on Debian bookworm. Deterministic,
            # not random -- safe to hardcode.
            runAsUser: 100
            runAsGroup: 100
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          startupProbe:
            httpGet:
              # /health returns 200 once the API is fully initialized,
              # including Alembic migration completion. Honcho holds port
              # 8000 closed until this point, so early probes get
              # "connection refused" -- that is expected and counts
              # against the failureThreshold budget.
              # Budget: 30 x 10s = 300s.
              path: /health
              port: 8000
            failureThreshold: 30
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            periodSeconds: 30
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
```

**ConfigMap** (`apps/honcho/configmap-honcho.yaml`):

```yaml
# ConfigMap -- honcho-config
#
# Non-sensitive Honcho configuration shared by BOTH the API and Deriver
# deployments. Both pods mount the same ConfigMap via envFrom.
#
# DERIVER_ENABLED is intentionally NOT here -- it has different values per
# deployment (false for API, true for Deriver) and is set in each Deployment
# manifest's env block instead.
#
# Sensitive values (DB_CONNECTION_URI, LLM_OPENAI_API_KEY, AUTH_JWT_SECRET)
# live in sealedsecret-honcho.yaml and are injected as env vars in each
# Deployment's env block via secretKeyRef.
apiVersion: v1
kind: ConfigMap
metadata:
  name: honcho-config
  namespace: honcho
data:
  # --- Auth ---
  # Enable JWT authentication for the Honcho API. ALWAYS enabled -- security
  # is a core pillar. Hermes provides its API key via HONCHO_API_KEY env var.
  AUTH_USE_AUTH: "true"

  # --- Cache ---
  # Valkey for session caching. Cache state is ephemeral; durable state
  # lives in Postgres. No authentication -- network-level isolation via
  # the Valkey NetworkPolicy restricts access to honcho namespace pods.
  CACHE_ENABLED: "true"
  CACHE_URL: "redis://honcho-valkey.honcho.svc.cluster.local:6379/0?suppress=true"

  # --- LLM ---
  # Point at the LiteLLM proxy for OpenAI-compatible access to all upstream models.
  # Honcho's LLM calls (deriver, dialectic, summary, dream) route through here.
  # Uses the secure external domain (HTTPS via Traefik) rather than the
  # cluster-internal HTTP endpoint.
  LLM_OPENAI_BASE_URL: "https://litellm.diceninjagaming.com/v1"
  # Generic model name; LiteLLM routes to the configured upstream.
  LLM_OPENAI_MODEL: "gpt-4o-mini"

  # --- Embedding ---
  # Resolved: openai/text-embedding-3-large via LiteLLM, 3072 dimensions.
  # These are IMMUTABLE after first deployment -- changing requires a full
  # database schema migration and re-embedding of all stored documents.
  EMBEDDING_MODEL_CONFIG__TRANSPORT: "openai"
  EMBEDDING_MODEL_CONFIG__MODEL: "openai/text-embedding-3-large"
  EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL: "https://litellm.diceninjagaming.com/v1"
  EMBEDDING_VECTOR_DIMENSIONS: "3072"

  # --- Telemetry ---
  # Don't phone home -- this is a homelab, not a SaaS deployment.
  TELEMETRY_ENABLED: "false"

  # --- Metrics ---
  METRICS_ENABLED: "true"
```

**Service** (`apps/honcho/service-honcho-api.yaml`):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: honcho-api
  namespace: honcho
spec:
  selector:
    app: honcho-api
  ports:
    - port: 8000
      targetPort: 8000
```

**App-level SealedSecret** (`apps/honcho/secret-honcho.yaml` -- gitignored, then sealed):

```yaml
# App-level secrets for Honcho -- lives in the honcho namespace.
#
# Before sealing, fill in ALL placeholder values:
#   - database-url    : postgresql+psycopg://honcho:<password>@postgres-rw.postgres.svc.cluster.local:5432/honcho
#                       Use the SAME password as honcho-db-credentials in the
#                       postgres namespace. Uses postgres-rw (direct, bypasses
#                       PgBouncer) because Alembic takes advisory locks during
#                       schema migrations on startup -- incompatible with
#                       transaction-mode connection pooling.
#   - jwt-secret      : a random string for JWT signing (generate with: openssl rand -hex 32)
#   - llm-api-key     : your LiteLLM API key for Honcho (see section 2.10)
#
# After sealing, ensure the SealedSecret has sync-wave in BOTH:
#   metadata.annotations AND spec.template.metadata.annotations
apiVersion: v1
kind: Secret
metadata:
  name: honcho
  namespace: honcho
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  # When sealing, ensure the SealedSecret has sync-wave in BOTH:
  #   metadata.annotations AND spec.template.metadata.annotations
spec:
  template:
    metadata:
      annotations:
        argocd.argoproj.io/sync-wave: "-1"
type: Opaque
stringData:
  # Full Postgres connection string. Uses postgres-rw (direct) -- same reason
  # as LiteLLM: Alembic advisory locks are incompatible with PgBouncer.
  database-url: "postgresql+psycopg://honcho:YOUR_PASSWORD_HERE@postgres-rw.postgres.svc.cluster.local:5432/honcho"
  # JWT signing secret -- generate a random hex string:
  #   openssl rand -hex 32
  jwt-secret: "your_jwt_secret_here"
  # LiteLLM API key -- create a dedicated key for Honcho (see section 2.10).
  llm-api-key: "sk_your_litellm_honcho_api_key_here"
```

### 2.5 Deriver Deployment

Same Docker image as the API, but with the command overridden to run the
background memory processing worker. Shares the same ConfigMap and Secret
as the API pod. Remains single-replica -- database queue coordination means
multiple replicas work but are unnecessary for a single-user deployment.

```yaml
# Deployment -- Honcho Deriver (background memory worker)
#
# Same image as the API -- override CMD to run the deriver process.
# The deriver reads from Postgres and processes memory data in the background
# (observations, conclusions, dialectic reasoning, dream consolidation).
#
# DERIVER_ENABLED=true here (vs "false" in the API deployment).
# This is set in the Deployment env block, NOT the shared ConfigMap,
# because the value differs between the two deployments.
#
# No HTTP probes -- the deriver is a background worker with no health endpoint.
# Uses an exec probe to verify the Python process is still running.
#
# Single-replica: database queue coordination means multiple replicas work
# but are unnecessary for a single-user homelab deployment.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: honcho-deriver
  namespace: honcho
  labels:
    app.kubernetes.io/part-of: honcho
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: honcho-deriver
  template:
    metadata:
      labels:
        app: honcho-deriver
        app.kubernetes.io/part-of: honcho
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: honcho-deriver
          # Same image as the API -- override CMD to run the deriver worker.
          image: ghcr.io/plastic-labs/honcho:v3.0.10
          # Override the default CMD to run the deriver process instead of
          # the API server. The deriver reads from Postgres and processes
          # memory data in the background.
          command: ["python", "-m", "src.deriver"]
          ports:
            # Prometheus metrics endpoint (METRICS_ENABLED=true in ConfigMap)
            - containerPort: 9090
          envFrom:
            - configMapRef:
                name: honcho-config
          env:
            - name: DB_CONNECTION_URI
              valueFrom:
                secretKeyRef:
                  name: honcho
                  key: database-url
            - name: LLM_OPENAI_API_KEY
              valueFrom:
                secretKeyRef:
                  name: honcho
                  key: llm-api-key
            - name: AUTH_JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: honcho
                  key: jwt-secret
            # DERIVER_ENABLED is deployment-specific, NOT in the shared ConfigMap.
            # This IS the deriver -- enable it here (overrides the API's "false").
            - name: DERIVER_ENABLED
              value: "true"
          securityContext:
            # UID/GID 100/100 -- same image as the API (see deployment-honcho-api.yaml).
            runAsUser: 100
            runAsGroup: 100
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          # No HTTP probes -- the deriver is a background worker with no health
          # endpoint. Check that the actual deriver process is running, not just
          # that Python is installed.
          livenessProbe:
            exec:
              command:
                - sh
                - -c
                - "pgrep -f src.deriver || exit 1"
            periodSeconds: 30
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
```

### 2.6 Certificate + IngressRoute

Per-app certificate for `honcho.taegost.com` (internal-only, matching the
Hermes pattern). IngressRoute lives in the `honcho` namespace (NOT traefik)
because this uses a per-app cert, not the shared wildcard.

**Certificate** (`apps/honcho/certificate-honcho.yaml`):

```yaml
# Certificate -- honcho.taegost.com
#
# Internal-only service. Uses letsencrypt-taegost-prod issuer (not the
# wildcard) because this is a per-app cert in the honcho namespace.
# Follows the pattern from apps/hermes-agent/certificate-hermes-agent.yaml.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: honcho-taegost-com
  namespace: honcho
spec:
  secretName: honcho-taegost-com-tls
  duration: 2160h
  renewBefore: 720h
  dnsNames:
    - honcho.taegost.com
  issuerRef:
    name: letsencrypt-taegost-prod
    kind: ClusterIssuer
    group: cert-manager.io
```

**IngressRoute** (`apps/honcho/ingressroute-honcho.yaml`):

```yaml
# IngressRoute -- honcho.taegost.com (internal-only)
#
# Lives in the honcho namespace alongside its per-app cert (NOT in traefik).
# default-whitelist middleware restricts access to internal subnets.
# Cross-namespace middleware reference works because allowCrossNamespace: true
# is set globally in apps/traefik/values.yaml (not per-IngressRoute).
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: honcho
  namespace: honcho
  labels:
    app.kubernetes.io/part-of: honcho
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`honcho.taegost.com`)
      services:
        - name: honcho-api
          namespace: honcho
          port: 8000
      middlewares:
        - name: default-whitelist
          namespace: traefik
  tls:
    secretName: honcho-taegost-com-tls
```

### 2.7 NetworkPolicies

Network segmentation for the honcho namespace. The API server needs ingress
from Traefik (for the IngressRoute) and from hermes-agent (for cluster-internal
memory calls), plus egress to Postgres, Valkey, and LiteLLM (via external HTTPS
domain, port 443). The deriver needs egress to Postgres, LiteLLM (port 443),
DNS, and Valkey but no ingress (it pulls work from a database-backed queue).
Valkey only needs ingress from pods within the honcho namespace. All other
ingress is denied.

**API NetworkPolicy** (`apps/honcho/networkpolicy-honcho-api.yaml`):

```yaml
# NetworkPolicy -- honcho-api
#
# Restricts ingress to the API server to only Traefik (for the IngressRoute)
# and hermes-agent (for cluster-internal memory calls). All other ingress is
# denied by the implicit default-deny when policyTypes includes Ingress.
#
# Egress is explicitly allowed to: DNS, Postgres (direct connection bypassing
# PgBouncer), Valkey (cache), and LiteLLM (LLM API). All other egress is
# denied by the implicit default-deny when policyTypes includes Egress.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: honcho-api
  namespace: honcho
spec:
  podSelector:
    matchLabels:
      app: honcho-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # --- Traefik ingress (IngressRoute -> honcho-api:8000) ---
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
          podSelector:
            matchLabels:
              app.kubernetes.io/name: traefik
      ports:
        - protocol: TCP
          port: 8000
    # --- hermes-agent ingress (cluster-internal memory API calls) ---
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: hermes-agent
      ports:
        - protocol: TCP
          port: 8000
  egress:
    # --- DNS (kube-system CoreDNS) ---
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # --- PostgreSQL (direct connection, bypasses PgBouncer) ---
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: postgres
      ports:
        - protocol: TCP
          port: 5432
    # --- Valkey cache (session caching) ---
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
    # --- LiteLLM proxy (LLM API calls via external HTTPS domain) ---
    # litellm.diceninjagaming.com resolves to a MetalLB IP, which is
    # outside any Kubernetes namespace. Allow egress on port 443 for
    # this and any future HTTPS external API calls.
    - ports:
        - protocol: TCP
          port: 443
```

**Valkey NetworkPolicy** (`apps/honcho/networkpolicy-honcho-valkey.yaml`):

```yaml
# NetworkPolicy -- honcho-valkey
#
# Restricts ingress to Valkey to ONLY pods in the honcho namespace.
# Network-level isolation provides defense-in-depth against unauthorized
# access. No authentication required (matches the plane pattern).
#
# Valkey never initiates outbound connections, so no egress policy needed.
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
    # --- Only honcho namespace pods (honcho-api and honcho-deriver) ---
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: honcho
      ports:
        - protocol: TCP
          port: 6379
```

**Deriver NetworkPolicy** (`apps/honcho/networkpolicy-honcho-deriver.yaml`):

```yaml
# NetworkPolicy -- honcho-deriver
#
# Egress-only policy for the deriver background worker. The deriver pulls
# work from a database-backed queue (Postgres) and never receives inbound
# network requests, so no ingress rules are needed.
#
# Egress is explicitly allowed to: DNS, Postgres, LiteLLM (LLM API calls),
# and Valkey (cache). All other egress is denied by the implicit default-deny
# when policyTypes includes Egress.
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
    - Egress
  egress:
    # --- DNS (kube-system CoreDNS) ---
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # --- PostgreSQL (direct connection, bypasses PgBouncer) ---
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: postgres
      ports:
        - protocol: TCP
          port: 5432
    # --- LiteLLM proxy (LLM API calls via external HTTPS domain) ---
    # litellm.diceninjagaming.com resolves to a MetalLB IP, which is
    # outside any Kubernetes namespace. Allow egress on port 443 for
    # this and any future HTTPS external API calls.
    - ports:
        - protocol: TCP
          port: 443
    # --- Valkey cache (session caching) ---
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

### 2.8 ArgoCD Application

Standard app-of-apps entry. Sync-wave 0 (default). `CreateNamespace=true`
handles the `honcho` namespace creation on first sync.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: honcho
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/Taegost/homelab-k8s
    targetRevision: HEAD
    path: apps/honcho
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: honcho
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 2.9 Secrets Summary

Two SealedSecrets are required. The password in both must be identical --
Kubernetes pods cannot reference secrets across namespaces.

| Secret | Namespace | Keys | Purpose | Sync Wave |
|---|---|---|---|---|
| `honcho-db-credentials` | `postgres` | `username`, `password` | CNPG role password management | -3 |
| `honcho` | `honcho` | `database-url`, `jwt-secret`, `llm-api-key` | App runtime secrets | -1 |

**Plaintext secret templates** (gitignored -- fill in before sealing):

See `apps/honcho/secret-honcho-db-credentials.yaml` in section 2.2 Step 1
and `apps/honcho/secret-honcho.yaml` in section 2.4.

**Kubeseal commands** (single-line as required):

```bash
# Seal the DB credentials secret (postgres namespace):
kubeseal --format yaml < apps/honcho/secret-honcho-db-credentials.yaml > apps/honcho/sealedsecret-honcho-db-credentials.yaml

# Seal the app secrets (honcho namespace):
kubeseal --format yaml < apps/honcho/secret-honcho.yaml > apps/honcho/sealedsecret-honcho.yaml
```

**IMPORTANT -- sync-wave preservation in SealedSecrets:**

After sealing, the plaintext `argocd.argoproj.io/sync-wave` annotation from
the Secret's `metadata.annotations` does NOT carry over to the SealedSecret
automatically. You must manually add it in TWO places on the SealedSecret:

1. `metadata.annotations` -- so ArgoCD sees the wave during sync ordering
2. `spec.template.metadata.annotations` -- so the decrypted Secret retains
   the wave annotation

For the DB credentials secret (wave -3), the SealedSecret must look like:

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: honcho-db-credentials
  namespace: postgres
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  encryptedData:
    password: <SEALED_VALUE>
    username: <SEALED_VALUE>
  template:
    metadata:
      annotations:
        argocd.argoproj.io/sync-wave: "-3"
      labels:
        cnpg.io/reload: "true"
      name: honcho-db-credentials
      namespace: postgres
    type: kubernetes.io/basic-auth
```

After sealing, delete the plaintext files:
```bash
rm apps/honcho/secret-honcho-db-credentials.yaml apps/honcho/secret-honcho.yaml
```

### 2.10 LiteLLM API Key Setup (REQUIRED)

Honcho requires an LLM provider for deriver, dialectic, summary, and dream
features. A dedicated LiteLLM API key must be created for Honcho to isolate
usage tracking.

**Steps:**

1. Open the LiteLLM UI at `https://litellm.diceninjagaming.com`
2. Navigate to **Keys** and click **Create Key**
3. Set a meaningful name (e.g., `honcho-memory-backend`)
4. Copy the generated key (starts with `sk-`)
5. Use this key as the `llm-api-key` value in `apps/honcho/secret-honcho.yaml`

**Verify the key works before sealing the secret:**

```bash
curl -s https://litellm.diceninjagaming.com/v1/models \
  -H "Authorization: Bearer sk_YOUR_KEY_HERE" | python3 -m json.tool
# Should return the list of available models
```

**Verify embedding model availability:**

Honcho uses `openai/text-embedding-3-large` (3072 dimensions) via LiteLLM.
Verify LiteLLM can route this before deployment:

```bash
curl -s https://litellm.diceninjagaming.com/v1/embeddings \
  -H "Authorization: Bearer sk_YOUR_KEY_HERE" \
  -H "Content-Type: application/json" \
  -d '{"model": "openai/text-embedding-3-large", "input": "test"}' | python3 -m json.tool
# Should return an embedding vector with 3072 dimensions
```

**Note on embedding model immutability:** The embedding dimensions (3072) are
**immutable per deployment**. Changing the embedding model after initial bootstrap
requires a database schema migration and full re-embedding of all stored documents.

### Deployment Order

The sync-wave annotations on the Database CRD and SealedSecrets handle
ordering automatically through ArgoCD. The effective deployment sequence:

1. SealedSecret for DB credentials decrypts (wave -3)
2. App-level SealedSecret decrypts (wave -1)
3. CNPG creates the `honcho` database and role (wave -1)
4. ConfigMap, Certificate, IngressRoute, Deployments, Services deploy (wave 0)
5. API pod starts, Alembic runs migrations, `/health` returns 200
6. Deriver pod starts processing in the background

---

## Section 3: Hermes Configuration Guide

> **Note:** This section covers Hermes Agent integration and will be extracted
> into a separate plan. Honcho can be deployed and verified standalone using
> Sections 1-2 and 4 only. The Hermes integration (Sections 3.1-3.4) is a
> follow-up that requires updating the hermes-agent SealedSecret and
> Deployment.

### 3.1 Install honcho-ai in the Hermes Container

Hermes Agent's Honcho memory plugin depends on the `honcho-ai` Python package.
This is **not** included in the base Hermes image and must be installed manually
after the first deployment.

```bash
# Install honcho-ai into the Hermes container's Python environment.
# This modifies the running container's filesystem -- if the pod restarts,
# you must re-install. Consider adding this to a custom Dockerfile or
# init container for persistence across restarts.
kubectl exec -n hermes-agent deployment/hermes-agent -- \
  pip install honcho-ai
```

**Persistence note:** The `pip install` writes to the container's filesystem,
not the PVC. A pod restart (node drain, OOMKill, rolling update) loses the
package. Two options to make this permanent:

1. **Custom Dockerfile** -- build a Hermes image with `honcho-ai` pre-installed
   (recommended for production)
2. **Init container** -- add an init container that runs `pip install honcho-ai`
   before the main container starts (quick fix, adds ~10-30s to startup)

For the initial evaluation, manual installation via `kubectl exec` is
acceptable. Track this as a follow-up task.

### 3.2 Environment Variables

Add the following environment variables to `apps/hermes-agent/deployment-hermes-agent.yaml`
under `spec.template.spec.containers[0].env`:

```yaml
# ── Honcho Memory Backend ──────────────────────────────────────────────
# Points Hermes at the self-hosted Honcho instance. Cluster-internal URL
# avoids traversing Traefik for memory calls.
#
# AUTH is ALWAYS enabled on this Honcho deployment. Hermes must provide
# an API key to authenticate.
- name: HONCHO_BASE_URL
  value: "http://honcho.honcho.svc.cluster.local:8000"
# API key for Honcho authentication. Must match the AUTH_JWT_SECRET
# configured in Honcho. Add this key to the hermes-agent SealedSecret.
- name: HONCHO_API_KEY
  valueFrom:
    secretKeyRef:
      name: hermes-agent
      key: honcho-api-key
```

**Key details:**

| Variable | Purpose | Value |
|----------|---------|-------|
| `HONCHO_BASE_URL` | Honcho API endpoint | `http://honcho.honcho.svc.cluster.local:8000` (cluster-internal) |
| `HONCHO_API_KEY` | JWT signing secret for Honcho authentication | From hermes-agent SealedSecret (must match Honcho's `AUTH_JWT_SECRET`) |
| `HERMES_HONCHO_HOST` | Overrides the host key used for config lookup (optional) | Typically not needed |

**Updating the hermes-agent SealedSecret:**

The `honcho-api-key` must be added to the existing hermes-agent SealedSecret.
The value must match the `AUTH_JWT_SECRET` set in Honcho's secret (see Section 2.9).

**How auth works:** Honcho uses JWT-based authentication (HS256). The honcho-ai
SDK reads `HONCHO_API_KEY` and uses it as the JWT signing secret to generate
tokens. The Honcho server verifies those tokens using `AUTH_JWT_SECRET`. Both
values must be identical — they are the same cryptographic key used for signing
(client-side) and verification (server-side). Verified against
`src/security.py` in the Honcho v3.0.10 source.

1. Add `honcho-api-key` to `apps/hermes-agent/sealedsecret-hermes-agent.yaml`
2. Re-seal with `kubeseal`
3. Push to trigger ArgoCD sync

The `honcho-api-key` value is the same string used for `AUTH_JWT_SECRET` in
Honcho's deployment (the JWT signing secret from `openssl rand -hex 32`).
Both systems use this shared secret: Honcho signs JWTs with it, Hermes presents
the token to authenticate.

### 3.3 Hermes Config File (honcho.json)

The Honcho configuration file lives inside the Hermes data volume at
`/opt/data/honcho.json`. This file is created via a **ConfigMap mount**, not
through an interactive setup wizard.

**Config resolution order** (first match wins):

1. `$HERMES_HOME/honcho.json` (profile-local)
2. `~/.hermes/honcho.json` (default profile)
3. `~/.honcho/config.json` (global, cross-app interop)

In the Kubernetes deployment, `$HERMES_HOME` is `/opt/data` because the Hermes
home directory lives on the persistent volume.

**Create the ConfigMap** (`apps/hermes-agent/configmap-honcho-config.yaml`):

```yaml
# Honcho configuration for Hermes Agent.
#
# This file is mounted as /opt/data/honcho.json inside the Hermes container.
# It configures how Hermes connects to Honcho and how memory is processed.
#
# Key concepts:
# - Workspace: a shared memory space for all Hermes peers
# - Peer: a participant in the workspace (you = user peer, Hermes = AI peer)
# - Dialectic: Honcho's tool-using reasoning agent that searches memory to
#   answer questions about the user
# - Dream: background consolidation process that builds reasoning trees from
#   accumulated observations
apiVersion: v1
kind: ConfigMap
metadata:
  name: honcho-config
  namespace: hermes-agent
data:
  # ── honcho.json field reference (for readers unfamiliar with Honcho) ────
  #
  # baseUrl:            Honcho API endpoint. Cluster-internal URL avoids Traefik.
  # workspace:          Shared memory namespace. All Hermes peers share this.
  #                     Different workspaces are completely isolated.
  # peerName:           Your identity in the workspace. Honcho tracks memories
  #                     per-peer. This is the "user" side of conversations.
  #
  # contextCadence:     How many conversation turns between refreshing the base
  #                     context (session summary, user profile, peer card) that
  #                     gets injected into the AI's system prompt.
  #                     1 = every turn (most responsive, most LLM calls).
  #                     3 = every 3rd turn (good balance for evaluation).
  #                     2 = every 2nd turn (mature value, once confident).
  #
  # dialecticCadence:   How many turns between dialectic LLM calls. The dialectic
  #                     is Honcho's reasoning engine that analyzes conversations
  #                     to extract observations about you. More frequent = richer
  #                     memory but more LLM cost.
  #                     2 = every 2nd turn (default, aggressive).
  #                     5 = every 5th turn (conservative for evaluation).
  #                     3 = every 3rd turn (mature value, once confident).
  #
  # recallMode:         How Honcho provides memory to the AI.
  #                     "hybrid" = auto-inject context + provide search tools.
  #                     "context" = auto-inject only, no tools.
  #                     "tools" = tools only, AI decides when to query.
  #
  # sessionStrategy:    How conversations are grouped into sessions.
  #                     "per-directory" = each working directory gets its own
  #                     memory session. Different projects stay isolated.
  #                     "per-session" = fresh each run. "global" = everything shared.
  #
  # dialecticReasoningLevel: How many tool calls the dialectic makes per invocation.
  #                     "minimal" = 1 call (cheapest). "low" = 5 calls (recommended
  #                     start). "medium" = 2 calls. "high" = 4 calls. "max" = 10
  #                     calls (expensive). The system auto-scales up for complex
  #                     queries even when set to "low".
  #
  # dialecticDepth:     How many refinement passes the dialectic makes.
  #                     1 = single pass (cheapest, good for evaluation).
  #                     2 = audit + synthesis (mature value, more thorough).
  #                     3 = reconciliation pass too (rarely needed).
  #                     Passes bail out early if the prior pass was strong.
  #
  # dialecticMaxChars:  Cap on dialectic response length. Keeps memory-augmented
  #                     responses focused. 600 chars is a good default.
  #
  # writeFrequency:     "async" = messages flushed in background (no latency
  #                     penalty). "sync" = blocks until written (safer but slower).
  # saveMessages:       Persist full message history. Required for the deriver
  #                     to process conversations into observations.
  #
  # observation.*:      What Honcho observes and records. All true = full mutual
  #                     observation, which gives the dialectic the most material.
  #
  # ── When to change these values ──────────────────────────────────────────
  #
  # After 1-2 weeks of use, check:
  #   - Are dialectic responses useful? If too shallow, increase dialecticDepth
  #     to 2 and dialecticCadence to 3.
  #   - Are LLM costs acceptable? If too high, increase contextCadence and
  #     dialecticCadence (higher = fewer calls).
  #   - Is memory accumulating? If not, check deriver logs for errors.
  #
  # See Section 3.4 for the full configuration reference with all options.
  # ─────────────────────────────────────────────────────────────────────────
  honcho.json: |
    {
      "baseUrl": "http://honcho.honcho.svc.cluster.local:8000",
      "workspace": "hermes",
      "peerName": "mike",
      "contextCadence": 3,
      "dialecticCadence": 5,
      "hosts": {
        "hermes": {
          "enabled": true,
          "aiPeer": "hermes",
          "recallMode": "hybrid",
          "observation": {
            "user": { "observeMe": true, "observeOthers": true },
            "ai": { "observeMe": true, "observeOthers": true }
          },
          "writeFrequency": "async",
          "sessionStrategy": "per-directory",
          "dialecticReasoningLevel": "low",
          "dialecticDepth": 1,
          "dialecticMaxChars": 600,
          "saveMessages": true
        }
      }
    }
```

**Add the volume mount** to the Hermes Deployment (`deployment-hermes-agent.yaml`):

```yaml
          volumeMounts:
            # ... existing mounts ...
            - name: honcho-config
              mountPath: /opt/data/honcho.json
              subPath: honcho.json
              readOnly: true
      volumes:
        # ... existing volumes ...
        - name: honcho-config
          configMap:
            name: honcho-config
```

### 3.4 Configuration Reference

Every setting in `honcho.json` is explained below. This is a public teaching
repository -- each field includes what it does, why the value was chosen, and
what the alternatives are.

#### Connection Settings

| Field | Value | Description |
|-------|-------|-------------|
| `baseUrl` | `http://honcho.honcho.svc.cluster.local:8000` | Honcho API endpoint. Uses cluster-internal URL to avoid Traefik. Honcho listens on port 8000. |
| `workspace` | `hermes` | Workspace name -- a shared memory namespace. All Hermes peers share this workspace. Different workspaces are completely isolated. |
| `peerName` | `mike` | Your peer identity in the workspace. Honcho tracks memories per-peer. This is the "user" side of the conversation. |

#### Cadence Settings

Cadence controls how often Honcho performs expensive operations during a
conversation. These are **independent** settings -- one controls context
refresh, the other controls dialectic calls.

| Field | Value | Description |
|-------|-------|-------------|
| `contextCadence` | `3` | Number of conversation turns between base context refreshes. Every N turns, Honcho re-evaluates what context to inject into the system prompt. Default is 1 (every turn). Set to 3 for conservative evaluation (halves LLM calls vs default). Reduce to 2 once confident. Higher values reduce cost but may miss rapidly evolving conversations. |
| `dialecticCadence` | `5` | Number of turns between dialectic LLM calls. The dialectic is Honcho's reasoning agent (see below). Default is 2. Set to 5 for conservative evaluation (controls LLM cost during first deployment). Reduce to 3 once confident. In `tools` mode (see recallMode), cadence is irrelevant -- the model decides when to query. |

**Why these are independent:** Context refresh asks "what should I remind
the AI about this user?" and injects it into the system prompt. Dialectic
calls ask "based on this conversation, what should I remember about the
user?" and produce observations/conclusions. You can refresh context frequently
while calling the dialectic less often, or vice versa.

#### Recall Mode

Controls how Honcho provides memory to the AI during conversations.

| Mode | Behavior | Use Case |
|------|----------|----------|
| `hybrid` | Auto-injects context into system prompt + provides tools (search_memory, search_messages, get_observation_context) for the AI to query on demand | **Recommended.** Best balance of passive memory and active recall. The AI gets baseline context automatically and can dig deeper when needed. |
| `context` | Auto-injects context only, no tools provided | Simpler, fewer LLM calls. The AI gets what Honcho thinks is relevant but cannot search memory itself. Misses edge cases where the AI needs to look up something specific. |
| `tools` | Tools only, no auto-injection. The AI decides when to query memory | Most flexible but most expensive. The AI must explicitly call tools for every memory lookup. Good for testing or when you want full control over memory usage. |

#### Session Strategy

Controls how Honcho groups conversation turns into sessions.

| Strategy | Behavior | Use Case |
|----------|----------|----------|
| `per-session` | Each conversation run creates a fresh session. No memory accumulates across runs. | Testing, or when you want memory to be ephemeral. |
| `per-directory` | **(Default)** Each working directory gets its own session. Memory accumulates across runs in the same directory. | **Recommended.** Conversations in the same project directory share context. Different projects are isolated. |
| `per-repo` | Each git repository gets its own session. | Good when you work in multiple directories within the same repo. |
| `global` | Single session everywhere. All conversations share context. | Small personal setups where everything is related. |

#### Dialectic Engine Settings

The dialectic is Honcho's **tool-using reasoning agent**. It answers questions
about the user by searching memory using tools like `search_memory`,
`search_messages`, and `get_observation_context`. It runs **inline during API
calls** -- not as a separate process. When Hermes asks Honcho for context, the
dialectic agent may fire to produce relevant memories.

The dialectic uses two prompt strategies:
- **Cold start** ("who is this person?") -- used when there is no prior context
- **Warm session** ("given this session, what's relevant?") -- used when context exists

| Field | Value | Description |
|-------|-------|-------------|
| `dialecticReasoningLevel` | `low` | Controls the number of tool iterations the dialectic agent uses per call. Each level uses a different budget: |

**Reasoning levels:**

| Level | Tool Iterations | Output Tokens | Use Case |
|-------|-----------------|---------------|----------|
| `minimal` | 1 | 250 | Quick, cheap queries. The dialectic makes one tool call and produces a short answer. Good for simple factual lookups. |
| `low` | 5 | Inherited from model | **Recommended starting point.** Lightweight reasoning. Enough to search memory and synthesize a useful answer without excessive LLM cost. |
| `medium` | 2 | Inherited | Balanced reasoning. Fewer iterations than `low` but may produce more focused results. Good when you want quality over breadth. |
| `high` | 4 | Inherited | Thorough reasoning. For complex questions that require multiple memory lookups and synthesis. Higher cost. |
| `max` | 10 | Inherited | Maximum reasoning depth. Use for complex analytical tasks. Expensive -- each iteration is an LLM call. |

**Note on non-monotonic iterations:** `low` (5 iterations) has MORE tool calls
than `medium` (2) and `high` (4). This is intentional — lower reasoning levels
rely more heavily on tool use to gather context, while higher levels trade
iteration count for more focused per-iteration reasoning (the model's own
reasoning capacity handles more of the work). Verified against Honcho v3.0.10
`.env.template` defaults.

**Note:** The query-adaptive heuristic in Honcho may auto-scale the reasoning
level up for longer or more complex queries, even when `low` is configured.

| Field | Value | Description |
|-------|-------|-------------|
| `dialecticDepth` | `1` | Number of dialectic passes. Each pass refines the output: |

**Dialectic depth passes:**

| Pass | Name | What It Does |
|------|------|--------------|
| 0 | Initial assessment | First evaluation of the conversation. Cold start or warm session depending on prior context. |
| 1 | Self-audit | Identifies gaps in the initial assessment. Synthesizes additional information from recent sessions to fill those gaps. |
| 2 | Reconciliation | Checks for contradictions between passes. Produces the final synthesis. |

More passes mean more thorough analysis but more LLM calls (each pass is a
full dialectic invocation). Passes bail out early if a prior pass returned a
strong signal, so depth 2 does not always mean 2x the cost.

| Field | Value | Description |
|-------|-------|-------------|
| `dialecticMaxChars` | `600` | Maximum characters in the dialectic response. Caps the length of memory-augmented responses to keep them focused. |

#### Observation Settings

Controls what Honcho observes and records.

| Field | Value | Description |
|-------|-------|-------------|
| `observation.user.observeMe` | `true` | Observe and record the user's messages and behavior |
| `observation.user.observeOthers` | `true` | Observe what the user says about other people |
| `observation.ai.observeMe` | `true` | Observe and record the AI's responses |
| `observation.ai.observeOthers` | `true` | Observe what the AI says about other topics/people |

#### Write and Save Settings

| Field | Value | Description |
|-------|-------|-------------|
| `writeFrequency` | `async` | Messages are flushed to the database in a background thread. No latency penalty on conversation turns. Alternative is `sync` (blocks until written) which is safer but slower. |
| `saveMessages` | `true` | Persist full message history. Required for the deriver to process messages into observations and conclusions. |

#### What "Dialectic Output Is Too Thin" Means

If you see messages about thin dialectic output, it means the dialectic agent
did not find enough relevant context in memory to provide a useful response.
This typically happens when:

- `dialecticDepth` is too low (only 1 pass) -- the agent does not have enough
  opportunity to search and synthesize
- `dialecticCadence` is too high -- dialectic calls are too infrequent to build
  up a rich memory representation
- The workspace is new and has little data -- the dialectic needs accumulated
  conversations to work with

**Fix:** Increase `dialecticDepth` from 1 to 2, or decrease `dialecticCadence`
from 5 to 3. Give the system a few days of conversation to build up context.

### 3.5 Recommended Initial Configuration

Start conservative to avoid excessive LLM calls during the evaluation period,
then tighten as confidence grows:

| Setting | Initial Value | Mature Value | Notes |
|---------|---------------|--------------|-------|
| `contextCadence` | `3` | `2` | Base context refresh frequency. Higher = fewer LLM calls |
| `dialecticCadence` | `5` | `3` | Dialectic firing frequency. Start slow to control cost |
| `dialecticDepth` | `1` | `2` | Single pass initially. Increase to 2 if output is too thin |
| `dialecticReasoningLevel` | `low` | `low` | Keep at low; query-adaptive heuristic auto-scales up for longer queries |

**Observation mode:** Keep default observation settings (all four
`observeMe`/`observeOthers` booleans set to `true`) -- full mutual observation
gives the dialectic the most material to work with.

**Write behavior:** `writeFrequency: "async"` -- messages flushed in background
thread with no latency impact.

**Injection frequency:** every 3 turns (`contextCadence: 3`) -- conservative
for evaluation. Reduce to 2 once confident that LLM costs are acceptable.

**Recall mode:** `hybrid` -- auto-inject context plus tools. Best balance for
evaluation.

**Session strategy:** `per-directory` -- each working directory gets its own
memory session. Memory accumulates across runs in the same directory.

---

## Section 4: Verification Steps

Run these checks in order after ArgoCD syncs the Honcho application. Each step
depends on the previous one passing.

### 4.1 Database Connectivity

```bash
# Verify the honcho role exists in CNPG
kubectl get cluster postgres -n postgres -o jsonpath='{.status.managedRolesStatus}' | jq '.readyStatus | to_entries[] | select(.key == "honcho")'

# Verify pgvector extension is present
kubectl exec -n postgres postgres-1 -- psql -U honcho -d honcho -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';"
# Expected: vector | <version>

# Verify Honcho tables were created by Alembic migrations
kubectl exec -n postgres postgres-1 -- psql -U honcho -d honcho -c "\dt"
# Should show tables: workspaces, peers, sessions, messages, conclusions, observations, etc.
```

### 4.2 Valkey Connectivity

```bash
# Verify Valkey is responding (no auth -- network isolation via NetworkPolicy)
kubectl exec -n honcho deployment/honcho-valkey -- valkey-cli ping
# Expected: PONG

# Verify Honcho can reach Valkey (check API logs for cache errors)
kubectl logs -n honcho deployment/honcho-api --tail=50 | grep -i "cache\|redis"
# Should show no connection errors; look for "cache hit" or similar
```

### 4.3 API Health Endpoint

```bash
# Basic process health (cluster-internal)
# The startupProbe already verifies DB connectivity and Alembic migration
# completion -- Honcho holds port 8000 closed until /health returns 200.
# A successful response here confirms the database is reachable and schemas
# are up to date.
kubectl exec -n honcho deployment/honcho-api -- curl -s http://localhost:8000/health
# Expected: {"status":"ok"}

# Verify the API rejects unauthenticated requests (confirms auth is active)
kubectl exec -n honcho deployment/honcho-api -- \
  curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/v3/workspaces
# Expected: 401

# Authenticated request -- confirms DB is queryable via the API
# Get the API key: kubectl get secret -n honcho honcho -o jsonpath='{.data.jwt-secret}' | base64 -d
kubectl exec -n honcho deployment/honcho-api -- \
  curl -s http://localhost:8000/v3/workspaces \
  -H "Authorization: Bearer YOUR_JWT_SECRET_HERE" | python3 -m json.tool
# Expected: empty list (no workspaces yet) or existing workspaces
```

### 4.4 Deriver Processing Messages

```bash
# Check deriver logs for polling activity
kubectl logs -n honcho deployment/honcho-deriver --tail=30
# Should show "polling" or "processing" log lines, not errors

# Verify no crashes
kubectl get pods -n honcho -l app=honcho-deriver
# RESTARTS column should be 0
```

### 4.5 IngressRoute Accessible

```bash
# Test internal access (from a machine on the internal network)
curl -s -o /dev/null -w "%{http_code}" https://honcho.taegost.com/health
# Expected: 200

# Verify FastAPI docs are served
curl -s -o /dev/null -w "%{http_code}" https://honcho.taegost.com/docs
# Expected: 200
```

### 4.6 Hermes Connection

```bash
# From inside the Hermes pod (cluster-internal URL)
kubectl exec -n hermes-agent deployment/hermes-agent -- \
  curl -s http://honcho.honcho.svc.cluster.local:8000/health
# Expected: {"status":"ok"}

# Check Hermes memory provider status
kubectl exec -n hermes-agent deployment/hermes-agent -- hermes honcho status
# Should show connected state with base URL
```

### 4.7 LLM Integration (Dialectic Reasoning)

```bash
# Send messages to trigger the deriver, then check observations
kubectl exec -n honcho deployment/honcho-api -- \
  curl -s http://localhost:8000/v3/workspaces/hermes/peers/mike/observations | python3 -m json.tool
# Should return observations if LLM integration is working

# Check deriver logs for LLM call activity
kubectl logs -n honcho deployment/honcho-deriver --tail=20 | grep -i "llm\|openai\|derivation\|observation"
# Should show successful LLM calls, not connection errors or 401s
```

### 4.8 Honcho API Access (External)

```bash
# Test external access via Traefik
curl -s -o /dev/null -w "%{http_code}" https://honcho.taegost.com/health
# Expected: 200

# Verify API key authentication is working
# (Should return 401 without a valid token)
curl -s https://honcho.taegost.com/v3/workspaces
# Expected: 401 Unauthorized

# With a valid token:
curl -s -H "Authorization: Bearer YOUR_HONCHO_API_KEY" https://honcho.taegost.com/v3/workspaces
# Expected: 200 with workspace list
```

---

## Section 5: Fallback and Rollback Plans

This section covers two distinct scenarios:

- **Fallback** (Section 5.1): Switching to OpenViking as an **alternative**
  memory backend if Honcho proves unsuitable. This is not going back to
  something that worked -- it is trying a different product.
- **Rollback** (Section 5.2): Disabling Honcho and reverting to Hermes's
  **built-in memory system** (MEMORY.md / USER.md files). This IS going back
  to what worked before.

### 5.1 Fallback to OpenViking

OpenViking is an alternative memory backend if Honcho proves problematic. Both
can run side-by-side during evaluation because they use separate namespaces and
databases.

**Why OpenViking is the fallback (not primary):**

| Concern | Detail |
|---------|--------|
| Dialectic reasoning may be too opinionated | Honcho synthesizes conclusions about the user that may not match what the user actually thinks. If the dialectic engine produces insights that feel wrong or intrusive, that is a fundamental design tension, not a tuning problem. |
| Peer model may be confusing | Honcho's concept of "peers" (user peer + AI peer) is designed for multi-user scenarios. In a single-user homelab, the abstraction adds complexity without clear benefit. |
| Operational complexity | Honcho requires two Deployments (API + Deriver), Valkey, and an LLM provider just for memory. OpenViking is a single server + PostgreSQL. |
| OpenViking does not synthesize | It stores and retrieves well but does not make inferences about the user. For some workflows, that restraint is a feature, not a limitation. |

**Kubernetes changes to switch to OpenViking:**

1. Deploy OpenViking into its own namespace (`openviking`) with its own
   PostgreSQL database
2. Create `apps/manifests/openviking.yaml` pointing at `apps/openviking/`
3. Update Hermes deployment env vars: remove `HONCHO_BASE_URL` and
   `HONCHO_API_KEY`, add OpenViking connection vars
4. Switch provider: `hermes config set memory.provider openviking`
5. Restart the gateway: `kubectl rollout restart deployment/hermes-agent -n hermes-agent`

**Data migration:** No automated path exists between Honcho and OpenViking.
Honcho memories can be exported via the API and manually referenced when
setting up OpenViking. Export commands (using cluster-internal URLs for
kubectl exec, external URLs for curl from your workstation):

```bash
# Export observations (from workstation, via external URL)
curl -s -H "Authorization: Bearer YOUR_HONCHO_API_KEY" \
  https://honcho.taegost.com/v3/workspaces/hermes/peers/mike/observations | \
  python3 -m json.tool > honcho-observations-backup.json

# Export conclusions (from workstation, via external URL)
curl -s -H "Authorization: Bearer YOUR_HONCHO_API_KEY" \
  https://honcho.taegost.com/v3/workspaces/hermes/peers/mike/conclusions | \
  python3 -m json.tool > honcho-conclusions-backup.json

# Alternatively, from inside the cluster (auth still required):
kubectl exec -n honcho deployment/honcho-api -- \
  curl -s -H "Authorization: Bearer YOUR_HONCHO_API_KEY" \
  http://localhost:8000/v3/workspaces/hermes/peers/mike/observations | \
  python3 -m json.tool > honcho-observations-backup.json

kubectl exec -n honcho deployment/honcho-api -- \
  curl -s -H "Authorization: Bearer YOUR_HONCHO_API_KEY" \
  http://localhost:8000/v3/workspaces/hermes/peers/mike/conclusions | \
  python3 -m json.tool > honcho-conclusions-backup.json
```

The observations and conclusions are natural-language text that can be
manually added to `MEMORY.md` or `USER.md` as reference material.

**Side-by-side operation:** Both can coexist. Only one is active as Hermes's
memory provider at a time, but the other's infrastructure can remain deployed.
Switch with `hermes config set memory.provider <name>` and a gateway restart.

### 5.2 Rollback to Built-in Memory (MEMORY.md / USER.md)

This is a **rollback** -- going back to the built-in memory system that
Hermes ships with. No data is lost because the built-in system is always
available as a fallback.

Hermes uses `MEMORY.md` and `USER.md` files for persistent memory. Disabling
Honcho reverts to this system without data loss.

**Steps to disable Honcho:**

```bash
# 1. Disable the Honcho provider (preserves config and server-side data)
kubectl exec -n hermes-agent deployment/hermes-agent -- hermes honcho disable

# 2. Disable the external memory provider (falls back to built-in)
kubectl exec -n hermes-agent deployment/hermes-agent -- hermes memory off

# 3. Restart the gateway
kubectl rollout restart deployment/hermes-agent -n hermes-agent
```

**Exporting Honcho memories before rollback:**

Export these before or during the rollback process. Use external URLs from
your workstation (requires valid API key) or cluster-internal URLs from
kubectl exec:

```bash
# List all peers in the workspace (external)
curl -s -H "Authorization: Bearer YOUR_HONCHO_API_KEY" \
  https://honcho.taegost.com/v3/workspaces/hermes/peers | python3 -m json.tool

# Get observations (extracted memories) for a peer (external)
curl -s -H "Authorization: Bearer YOUR_HONCHO_API_KEY" \
  https://honcho.taegost.com/v3/workspaces/hermes/peers/mike/observations | \
  python3 -m json.tool

# Get conclusions (persistent facts) for a peer (external)
curl -s -H "Authorization: Bearer YOUR_HONCHO_API_KEY" \
  https://honcho.taegost.com/v3/workspaces/hermes/peers/mike/conclusions | \
  python3 -m json.tool

# Cluster-internal alternatives (auth still required):
kubectl exec -n honcho deployment/honcho-api -- \
  curl -s -H "Authorization: Bearer YOUR_HONCHO_API_KEY" \
  http://localhost:8000/v3/workspaces/hermes/peers | python3 -m json.tool

kubectl exec -n honcho deployment/honcho-api -- \
  curl -s -H "Authorization: Bearer YOUR_HONCHO_API_KEY" \
  http://localhost:8000/v3/workspaces/hermes/peers/mike/observations | \
  python3 -m json.tool

kubectl exec -n honcho deployment/honcho-api -- \
  curl -s -H "Authorization: Bearer YOUR_HONCHO_API_KEY" \
  http://localhost:8000/v3/workspaces/hermes/peers/mike/conclusions | \
  python3 -m json.tool
```

Export these before tearing down the Honcho infrastructure. The observations
and conclusions are natural-language text that can be manually added to
`MEMORY.md` or `USER.md` as reference material.

**Re-enabling Honcho later:**

```bash
kubectl exec -n hermes-agent deployment/hermes-agent -- hermes honcho enable
kubectl rollout restart deployment/hermes-agent -n hermes-agent
```

The `honcho.json` config file on the PVC is preserved through disable/enable
cycles. Server-side data remains in the Honcho PostgreSQL database as long as
the `honcho` namespace exists.

---

## Section 6: Open Questions / Risks

### OQ1: Container UID Verification

The Honcho Dockerfile at v3.0.10 creates the `app` user with
`addgroup --system app && adduser --system --group app`. On Debian bookworm,
system users start at UID 100. The first available system UID is 100 (since
no prior system user occupies that slot in the base image). This is
**deterministic** -- the same Dockerfile on the same base image always
produces the same UID.

**UID 100, GID 100** is used in the Deployment manifests. If Honcho ever
changes its base image or user creation commands, verify with:

```bash
docker run --rm --entrypoint="" ghcr.io/plastic-labs/honcho:v3.0.10 id app
```

### OQ2: Image Tag Strategy

Honcho v3.0.10 is the latest semver tag (released Jun 15, 2026). The GHCR
image may or may not have a matching `v3.0.10` tag -- verify before
deployment:

```bash
docker manifest inspect ghcr.io/plastic-labs/honcho:v3.0.10
```

If the semver tag does not resolve, pin to the `latest` digest at the time
of deployment and document it in the manifest comments.

### OQ3: pgvector on PostgreSQL 18 Compatibility

Honcho's docker-compose example uses `pgvector/pgvector:pg15`. The shared
CNPG cluster runs PostgreSQL 18. pgvector has tracked PostgreSQL major
versions, so incompatibility is unlikely but not explicitly tested by the
Honcho team.

**Mitigation:** Verify after provisioning:
```bash
kubectl exec -n postgres postgres-1 -- psql -U honcho -d honcho -c \
  "CREATE EXTENSION IF NOT EXISTS vector; SELECT extversion FROM pg_extension WHERE extname = 'vector';"
```

### OQ4: Embedding Model -- RESOLVED

**Decision:** `openai/text-embedding-3-large` via LiteLLM, 3072 dimensions.

The model is available at `https://litellm.diceninjagaming.com` and routes
through the existing LiteLLM proxy. No additional infrastructure (Ollama, etc.)
is needed.

**Embedding dimensions are IMMUTABLE after first deployment.** Changing the
embedding model or dimensions later requires `scripts/configure_embeddings.py`
and a full database schema migration -- every existing embedding must be
recomputed.

The ConfigMap (Section 2.4) has been updated with the resolved values:
```
EMBEDDING_MODEL_CONFIG__MODEL: "openai/text-embedding-3-large"
EMBEDDING_VECTOR_DIMENSIONS: "3072"
```

### OQ5: AGPL-3.0 License Implications

Honcho is AGPL-3.0. A private homelab serving only yourself does not trigger
distribution or network-service obligations. No action required. If the
deployment model changes (offering to others), AGPL applies.

### OQ6: Honcho Telemetry

Explicitly set `TELEMETRY_ENABLED=false` in the ConfigMap. Prevents accidental
activation if the default changes in a future image.

### OQ7: Dream Consolidation -- Detailed Behavior and Risks

**What it does:**

Dream is a background process that runs during idle periods. It consolidates
accumulated observations into higher-level reasoning. Two specialists run in
sequence:

1. **DeductionSpecialist:** Makes inferences from explicit conclusions. Takes
   facts that Honcho has observed and deduces related facts. For example, if
   Honcho observes "user prefers dark mode" and "user uses VS Code," it might
   deduce "user likely uses a dark theme in VS Code."

2. **InductionSpecialist:** Synthesizes higher-level conclusions from multiple
   observations. Builds **reasoning trees** -- structured graphs linking
   conclusions to their supporting premises. Can delete redundant conclusions
   that overlap with existing knowledge.

Both specialists run as LLM calls. Each dream cycle can use up to 20 tool
calls (configurable via `DREAM_MAX_TOOL_ITERATIONS`).

**When it triggers:**

| Trigger | Default | Description |
|---------|---------|-------------|
| Idle time | 60 minutes | Dream only runs when no conversations are active |
| Document threshold | 50 (`DREAM_DOCUMENT_THRESHOLD`) | At least 50 observed documents must exist before the first dream |
| Minimum interval | 8 hours (`DREAM_MIN_HOURS_BETWEEN_DREAMS`) | Prevents excessive dreaming |

**What to watch for:**

- **LLM token consumption:** Each dream cycle uses multiple tool calls and LLM
  invocations. At `DREAM_MAX_TOOL_ITERATIONS=20`, a single dream can consume
  significant tokens. Monitor LiteLLM usage during the first week.
- **Error propagation:** If the LLM produces bad conclusions (hallucinated
  facts, incorrect inferences), the InductionSpecialist may build reasoning
  trees on top of those bad conclusions. This creates a self-reinforcing error
  cycle where incorrect memories become deeply embedded.
- **Redundant observations early on:** In the first few days, the Deduction
  Specialist may produce overlapping or trivial conclusions because the
  observation corpus is small. This is expected and stabilizes as more
  conversations accumulate.

**How to mitigate:**

| Action | How | Why |
|--------|-----|-----|
| Delay first dream | Increase `DREAM_DOCUMENT_THRESHOLD` to 100 | Gives the system more data before consolidating, producing better initial conclusions |
| Reduce dream frequency | Increase `DREAM_MIN_HOURS_BETWEEN_DREAMS` to 12 or 16 | Limits token consumption and reduces opportunity for error propagation |
| Limit tool calls | Decrease `DREAM_MAX_TOOL_ITERATIONS` to 10 | Caps the LLM invocations per dream cycle |
| Monitor activity | Check deriver logs for dream-related entries: `kubectl logs -n honcho deployment/honcho-deriver \| grep -i dream` | Detect excessive dreaming or error patterns early |
| Review conclusions | Query the API periodically to review what Honcho has concluded about you | Catch incorrect inferences before they propagate |

### OQ8: Deriver Scaling -- Detailed Behavior

**How the deriver works:**

The deriver is Honcho's memory formation engine. It polls a database-backed
queue for new messages and processes them into observations and conclusions.
The queue uses exponential backoff polling: 1 second when active, ramping to
30 seconds when idle.

**Key setting: `DERIVER_WORKERS`**

This controls threads **within a single pod**, not pod replicas. Increasing it
requires more CPU and memory because each worker runs concurrent LLM calls.
The default (1 worker) is appropriate for a single-user homelab.

**Scaling options:**

| Approach | How | Trade-off |
|----------|-----|-----------|
| Increase `DERIVER_WORKERS` | Set `DERIVER_WORKERS=2` in the ConfigMap | More threads per pod. Requires proportional CPU/memory increase. Simple to implement. |
| Add pod replicas | Increase `replicas` in `deployment-honcho-deriver.yaml` | Multiple pods coordinate via the shared database queue. No configuration changes needed. Requires more cluster resources. |

**What "falls behind" means:**

When the deriver cannot keep up with incoming messages, the queue depth grows.
This means:

- Messages are **still stored** in the database (no data loss)
- But **no memory processing occurs** until the deriver catches up
- The API stays fully functional (read/write/search work normally)
- **Dialectic responses go stale** -- the dialectic agent searches existing
  observations, which stop being updated during the backlog
- New conversations still work; they just do not benefit from memory until the
  deriver processes them

**How to monitor:**

```bash
# Check deriver logs for polling/processing activity
kubectl logs -n honcho deployment/honcho-deriver --tail=50 | grep -i "polling\|processing\|queue"

# Check for errors
kubectl logs -n honcho deployment/honcho-deriver --tail=50 | grep -i "error\|exception\|traceback"

# Check pod resource usage
kubectl top pod -n honcho -l app=honcho-deriver

# Prometheus metrics (if METRICS_ENABLED=true in ConfigMap)
kubectl port-forward -n honcho deployment/honcho-deriver 9090:9090
# Then visit http://localhost:9090/metrics
```

**Recommendation:** Start with 1 worker. Monitor during the first week. If the
deriver consistently falls behind (queue depth growing, stale dialectic
responses), increase to 2 workers and allocate proportionally more CPU.

### OQ9: Embedding Model Choice -- RESOLVED

**Decision:** `openai/text-embedding-3-large` via LiteLLM, 3072 dimensions.

**Why this matters:**

Honcho stores text embeddings as fixed-dimension vectors in PostgreSQL (via
pgvector). The vector column dimensions are set on first deployment and cannot
be changed without a database migration.

**What "immutable" means in practice:**

1. The `EMBEDDING_VECTOR_DIMENSIONS` environment variable sets the column width
   on first run (Alembic migration creates the vector columns)
2. Every embedding stored in the database matches this dimension
3. Changing to a different model with different dimensions requires:
   - Updating `EMBEDDING_VECTOR_DIMENSIONS`
   - Running `scripts/configure_embeddings.py` (if it exists) or manually
     altering the vector columns
   - **Re-embedding every stored document** (full corpus re-embed)
   - This is expensive and time-consuming -- avoid if possible

The ConfigMap (Section 2.4) is configured with the resolved values. No
additional infrastructure is needed — the model routes through the existing
LiteLLM proxy.
