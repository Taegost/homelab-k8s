---
title: feat: Add LibreChat with MongoDB, Meilisearch, and Redis
type: feat
status: completed
date: 2026-05-23
deepened: 2026-05-24
---

# feat: Add LibreChat with MongoDB, Meilisearch, and Redis

## Summary

Deploy LibreChat v0.8.5 as a raw-manifest app using the shared MongoDB cluster, the shared CNPG Postgres cluster (pgvector for RAG), a per-app Meilisearch instance, a per-app RAG API instance, and a per-app Redis instance (SSE pub/sub backplane for 2-replica HA). Internal-only access at `librechat.home.diceninjagaming.com` via the `*.home.diceninjagaming.com` wildcard cert with `default-whitelist` middleware. Non-sensitive config in a ConfigMap; sensitive values (API keys, JWT secrets, credentials) in SealedSecrets. NetworkPolicies lock down Meilisearch, Redis, and LibreChat ingress to authorized sources only.

---

## Problem Frame

LibreChat provides a unified chat interface for multiple AI providers (OpenAI, Anthropic, Google, custom endpoints). It requires MongoDB for document storage, Meilisearch for full-text search, pgvector (via shared CNPG Postgres) for RAG vector embeddings, a RAG API service for document processing, and — with 2 replicas for HA — Redis for SSE pub/sub state sharing between replicas. This plan adds it as the first MongoDB-backed application in the cluster, accessible internally at `librechat.home.diceninjagaming.com` with potential future public exposure. LibreChat is expected to become the primary AI chat interface, replacing Open WebUI.

---

## Requirements

- R1. LibreChat v0.8.5 deployed with 2 replicas and accessible at `librechat.home.diceninjagaming.com`
- R2. MongoDB database and user provisioned via the shared Percona cluster
- R3. Meilisearch v1.35.1 deployed as a per-app service with persistent storage (2Gi)
- R4. Internal-only access using wildcard TLS cert and `default-whitelist` middleware
- R5. AI provider configuration isolated in a SealedSecret
- R6. User-uploaded images and file uploads persist across pod restarts
- R7. Redis deployed as a per-app service for SSE pub/sub state sharing between replicas
- R8. NetworkPolicies restrict Meilisearch ingress to LibreChat pods only, and LibreChat ingress to Traefik only
- R9. RAG vector database (pgvector) provisioned on the shared CNPG Postgres cluster with RAG API deployed

---

## Scope Boundaries

- LibreChat deployment with MongoDB + Meilisearch + Redis + RAG API
- pgvector database on the shared CNPG Postgres cluster
- Internal-only IngressRoute (Traefik namespace, wildcard cert)
- SealedSecrets for all sensitive config
- NetworkPolicies for Meilisearch, Redis (ingress from librechat pods) and LibreChat (ingress from Traefik only)
- 2 replicas for LibreChat with Longhorn RWX PVC and RollingUpdate strategy
- Sizing: Meilisearch 2Gi PVC, LibreChat 5Gi RWX PVC (images + uploads + logs)

### Deferred to Follow-Up Work

- **Public access:** user explicitly deferred; requires per-app Certificate + `default-headers` middleware swap. TRUST_PROXY hardened through NetworkPolicy regardless (see U9).
- **Automated LibreChat upgrades:** manual image tag bump in Deployment (repo convention for manifest-based apps)
- **S3 storage for uploads/images:** LibreChat supports S3-compatible backends (MinIO, Backblaze B2, etc.). Switch to S3 when available; eliminates local PVC dependency for uploads.
- **PVC capacity monitoring:** deferred to future monitoring/observability stack

---

## Context & Research

### Relevant Code and Patterns

- `apps/percona-mongodb/cluster-mongodb.yaml` — MongoDB user provisioning via `spec.users`
- `apps/mealie/deployment-mealie.yaml` — Deployment pattern (env vars, probes, securityContext)
- `apps/mealie/sealedsecret-mealie.yaml` — App-level SealedSecret pattern
- `apps/arr-stack/bazarr/ingressroute-bazarr.yaml` — Internal IngressRoute in traefik namespace with `default-whitelist`
- `apps/manyfold/deployment-redis.yaml` — Per-app auxiliary service pattern (Deployment + Service, ephemeral)
- `apps/manifests/mealie.yaml` — ArgoCD Application manifest pattern (wave 0)
- `docs/mongodb-runbooks.md` — Adding a new application workflow
- `apps/argocd/argocd.yaml` — Existing ArgoCD NetworkPolicies (7 policies, standard `networking.k8s.io/v1`)
- `apps/postgres/cluster-postgres.yaml` — CNPG cluster CRD with `spec.managed.roles` for app database/role provisioning
- `docs/postgres-runbooks.md` — Adding a new CNPG database and role
- Cluster uses Cilium CNI — standard Kubernetes NetworkPolicy fully supported

### External References

- LibreChat v0.8.5 Docker image: `librechat/librechat:v0.8.5` (Docker Hub)
- Meilisearch v1.35.1: `getmeili/meilisearch:v1.35.1`
- LibreChat config reference: `librechat.example.yaml` (v1.3.9 schema for LibreChat v0.8.5)
- LibreChat env vars: `MONGO_URI`, `MEILI_HOST`, `MEILI_MASTER_KEY`, `JWT_SECRET`, `JWT_REFRESH_SECRET`, `CREDS_KEY`, `CREDS_IV`, `DOMAIN_CLIENT`, `DOMAIN_SERVER`, `TRUST_PROXY`, `PORT`=3080, `HOST`=0.0.0.0
- Meilisearch docs: LMDB index ~7-10x raw data size (19K docs = 224MB); `MEILI_MAX_INDEXING_MEMORY` critical — defaults to 2/3 of host RAM, ignores container limits
- LibreChat official minimum: 1 GiB RAM, 1 vCPU. Recommends 2 GiB RAM with all features enabled.
- MongoDB Node.js driver: default `maxPoolSize=100`. Percona server default `maxIncomingConnections=1,000,000`.
- LibreChat RAG API: `ghcr.io/danny-avila/librechat-rag-api-dev-lite:v0.8.0` (pinned, GHCR). Port 8000. Stateless — connects to pgvector database. Also available at `registry.librechat.ai/danny-avila/librechat-rag-api-dev-lite` (upstream registry). Both registries carry identical images; GHCR chosen for consistency with other repo image references.

---

## Key Technical Decisions

- **2 replicas for LibreChat with RWX PVC and RollingUpdate (changed from single replica + Recreate).** LibreChat is expected to become the primary AI chat interface (replacing Open WebUI) and warrants HA. 2 replicas ensure service continuity during node drains and pod failures. Requires Longhorn RWX PVC (shared filesystem mounted on both pods). Enables `RollingUpdate` for zero-downtime deploys. Meilisearch stays single replica — embedded LMDB does not support multi-writer.
- **Per-app Redis for SSE pub/sub.** With 2 replicas, Traefik load-balances requests. SSE streaming state must be shared between replicas — Redis provides the pub/sub backplane that LibreChat uses for this. Follows the existing per-app Redis pattern (authentik, manyfold, litellm each have their own).
- **Per-app Meilisearch (not shared):** follows the existing Redis pattern. Meilisearch is heavier than Redis but same principle — LibreChat owns its indexes and config. If another app needs Meilisearch later, extract to shared service.
- **Raw manifests (not Helm):** repo convention. Every app in the repo uses raw manifests deployed via ArgoCD directory-of-manifests.
- **Wildcard cert + traefik namespace IngressRoute:** matches the arr-stack internal-only pattern. Uses the `*.home.diceninjagaming.com` wildcard cert (`wildcard-home-diceninjagaming-com-tls`). The IngressRoute lives in `traefik` namespace to reference this shared TLS secret. If public access is needed later, switch to per-app Certificate.
- **Config split: ConfigMap for librechat.yaml, SealedSecret for sensitive values:** Non-sensitive config (UI preferences, endpoint definitions) lives in a ConfigMap mounted at `/app/librechat.yaml`. Sensitive values (API keys, JWT secrets, MONGO_URI, MEILI_MASTER_KEY, Redis URL) stay in a SealedSecret injected as env vars. This avoids the sealed-secret workflow for routine AI provider changes and the `subPath`-from-Secret staleness problem.
- **NetworkPolicies for least-privilege ingress.** Cilium CNI enforces standard `networking.k8s.io/v1` NetworkPolicy. Meilisearch port 7700 restricted to `app: librechat` pods. LibreChat port 3080 restricted to Traefik pods (`app.kubernetes.io/name: traefik`). This hardens TRUST_PROXY (LibreChat can only be reached through Traefik, which correctly sets `X-Forwarded-*` headers) and contains Meilisearch within the namespace.
- **MongoDB connection pool size: 20.** A middle ground between the driver default (100, oversized for single-user) and conservative floor (10). Documented in `docs/mongodb-runbooks.md` as a per-app setting.
- **PVC sizing (researched).** Meilisearch: 2Gi — official benchmark shows 19K docs = 224MB on-disk LMDB. Homelab message volume (tens of thousands) produces sub-1Gi index with years of headroom. LibreChat: 5Gi RWX — covers images, uploads, and logs for a single user. 5Gi is generous headroom. (Prior plan had 10Gi for Meilisearch — 5x overprovisioned.)
- **Meilisearch PVC = cache, LibreChat uploads PVC = source-of-truth.** Meilisearch indexes are derived from MongoDB data and can be rebuilt. User-uploaded files and images on the LibreChat PVC are irreplaceable original data. This distinction drives recovery procedures and backup prioritization.
- **RAG vector database on shared CNPG Postgres (not standalone pgvector).** The docker-compose uses a standalone `pgvector/pgvector` container. Using the shared CNPG cluster with the `pgvector` extension avoids deploying and maintaining another database. Matches the Postgres pattern: database + role in `apps/postgres/cluster-postgres.yaml`, SealedSecret for the password in both `postgres` and `librechat` namespaces. RAG API connects to `postgres-pooler.postgres.svc.cluster.local:5432/librechat_rag`. See `docs/postgres-runbooks.md`.
- **MongoDB credentials secret stays in `apps/librechat/` (Option A).** Consistent with Postgres pattern (open-webui places its Postgres secret in its own folder, deployed to the `postgres` namespace by its own Application). The password Secret referenced by `spec.users.passwordSecretRef` is deployed by the `librechat` Application (wave 0), while the cluster CRD lives in the `percona-mongodb` Application (wave -2). This creates a transient cross-Application timing gap — the operator retries every ~60s and self-heals once both sync. The alternative (placing app creds in `apps/percona-mongodb/`) eliminates the gap but co-locates app credentials with system-level resources.

---

## Output Structure

```
apps/librechat/
├── configmap-librechat.yaml                       # CREATE (librechat.yaml, non-sensitive config)
├── database-librechat-rag.yaml                    # CREATE (CNPG Database CRD, postgres namespace)
├── deployment-librechat.yaml                      # CREATE (2 replicas, RWX PVC, RollingUpdate)
├── deployment-meilisearch.yaml                    # CREATE (single replica, 2Gi RWO PVC, Recreate)
├── deployment-rag-api.yaml                        # CREATE (single replica, stateless)
├── deployment-redis.yaml                          # CREATE (single replica, ephemeral)
├── ingressroute-librechat.yaml                    # CREATE (traefik namespace)
├── networkpolicy-librechat.yaml                   # CREATE (ingress from Traefik only)
├── networkpolicy-meilisearch.yaml                 # CREATE (ingress from librechat pods only)
├── networkpolicy-redis.yaml                       # CREATE (ingress from librechat pods only)
├── persistentvolumeclaim-librechat.yaml           # CREATE (5Gi RWX for images + uploads + logs)
├── persistentvolumeclaim-meilisearch-data.yaml    # CREATE (2Gi RWO for search index)
├── sealedsecret-librechat-db-credentials.yaml     # CREATE (committed, mongodb namespace)
├── sealedsecret-librechat-rag-api-db-credentials.yaml  # CREATE (committed, librechat namespace)
├── sealedsecret-librechat-rag-db-credentials.yaml # CREATE (committed, postgres namespace)
├── sealedsecret-librechat.yaml                    # CREATE (committed, librechat namespace)
├── secret-librechat-db-credentials.yaml           # CREATE (plaintext, gitignored, temporary)
├── secret-librechat-rag-api-db-credentials.yaml   # CREATE (plaintext, gitignored, temporary)
├── secret-librechat-rag-db-credentials.yaml       # CREATE (plaintext, gitignored, temporary)
├── secret-librechat.yaml                          # CREATE (plaintext, gitignored, temporary)
├── service-librechat.yaml                         # CREATE
├── service-meilisearch.yaml                       # CREATE
├── service-rag-api.yaml                           # CREATE
└── service-redis.yaml                             # CREATE
apps/manifests/
└── librechat.yaml                                 # CREATE (ArgoCD Application)

# Also modified (NOT in apps/librechat/):
#   apps/percona-mongodb/cluster-mongodb.yaml      # MODIFY: add librechat user to spec.users
#   apps/postgres/cluster-postgres.yaml            # MODIFY: add librechat_rag database and role
```

---

## Implementation Units

### U1. Provision MongoDB User for LibreChat

**Goal:** Add a `librechat` user and database to the shared MongoDB cluster so LibreChat can connect.

**Requirements:** R2

**Dependencies:** None (MongoDB cluster must exist — already deployed)

**Files:**
- Modify: `apps/percona-mongodb/cluster-mongodb.yaml`
- Create: `apps/librechat/secret-librechat-db-credentials.yaml` (plaintext, gitignored)
- Create: `apps/librechat/sealedsecret-librechat-db-credentials.yaml` (committed, after sealing)

**Approach:**
- Add a `librechat` user entry to `spec.users` in the cluster CRD with `readWrite` role on the `LibreChat` database
- Create the password secret in the `mongodb` namespace (cross-namespace — same pattern as Postgres/MariaDB)
- The SealedSecret needs sync wave `-3` in both `metadata.annotations` and `spec.template.metadata.annotations`. Within the `librechat` Application, this ensures the decrypted Secret exists before the LibreChat Deployment (wave `0`) starts. Note: per-resource waves only order within a single Application — they do not order across Applications. The `percona-mongodb` Application (wave `-1`) syncs before `librechat` (wave `0`), so the cluster CRD is reconciled before the password Secret is processed. The operator retries until the Secret exists.
- The database `LibreChat` is created implicitly on first write — no separate Database CRD needed
- **Password duplication:** The password value must be identical in two secrets: the operator-facing `sealedsecret-librechat-db-credentials.yaml` (mongodb namespace) and the `MONGO_URI` embedded in `secret-librechat.yaml` (librechat namespace). Generate one password, place it in both plaintext secrets, seal both, then delete both plaintext files. **Both secret files must include a comment cross-referencing each other** (e.g., `# This password must match the MONGO_URI in secret-librechat.yaml`) so the duplication requirement is visible at edit time. See `docs/mongodb-runbooks.md` for details.
- **Password characters:** MongoDB connection strings require URL-encoding for `@`, `:`, `/`, `%` in passwords. Generate alphanumeric-only passwords or URL-encode special characters in the MONGO_URI value.
- **Connection pool:** Append `&maxPoolSize=20` to the MONGO_URI to limit LibreChat to 20 concurrent MongoDB connections (documented in `docs/mongodb-runbooks.md` as a per-app setting).
- **Credential rotation ordering:** When rotating the MongoDB password, update the librechat-namespace secret first (stale value, no effect), then the mongodb-namespace secret (operator rotates), then restart LibreChat. Reverse order causes app downtime.

**Patterns to follow:**
- `docs/mongodb-runbooks.md` — Adding a new application, Phase 1
- `apps/mealie/database-mealie.yaml` — Database CRD pattern (different CRD but same concept)
- `apps/mealie/sealedsecret-mealie-db-credentials.yaml` — cross-namespace secret pattern

**Test scenarios:**
- Happy path: After applying the modified cluster CRD, the operator creates the `librechat` user. Verify via `mongosh` connection test using the credentials.
- Edge case: User secret does not exist yet when CRD is applied — operator retries and creates user once secret appears.

**Verification:**
- Operator logs show user `librechat` created successfully
- `mongosh` connection test succeeds with the new credentials

---

### U2. Create LibreChat ConfigMap and SealedSecret

**Goal:** Create a ConfigMap for non-sensitive LibreChat config (`librechat.yaml`) and a SealedSecret for sensitive values (API keys, JWT secrets, MongoDB URI, Meilisearch master key, Redis URL).

**Requirements:** R5, R7

**Dependencies:** U1 (MongoDB credentials must exist to form the MONGO_URI)

**Files:**
- Create: `apps/librechat/configmap-librechat.yaml` (committed directly)
- Create: `apps/librechat/secret-librechat.yaml` (plaintext, gitignored, for sealing)
- Create: `apps/librechat/sealedsecret-librechat.yaml` (committed, after sealing)

**Approach:**
- ConfigMap with key `librechat.yaml` containing the non-sensitive config. Mounted as a file at `/app/librechat.yaml` in the Deployment (standard ConfigMap volume mount — auto-updates without restart, unlike `subPath`). **Note:** LibreChat reads `librechat.yaml` at startup only. After editing the ConfigMap, run `kubectl rollout restart deployment/librechat -n librechat` to apply changes.
- SealedSecret needs sync wave `-1` in both `metadata.annotations` and `spec.template.metadata.annotations` to guarantee it exists before the Deployment (wave `0`) starts.
- SealedSecret with env vars: `MONGO_URI`, `MEILI_MASTER_KEY`, `JWT_SECRET`, `JWT_REFRESH_SECRET`, `CREDS_KEY`, `CREDS_IV`, AI provider keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.) — credentials only. Non-sensitive config (`DOMAIN_CLIENT`, `DOMAIN_SERVER`, `TRUST_PROXY`, `HOST`, `PORT`, `MEILI_HOST`, `REDIS_URI`, `RAG_API_URL`) is set directly in the Deployment env (see U4) to avoid kubeseal for routine changes.
- This split means routine AI provider changes only need a ConfigMap edit + pod restart — no `kubeseal` required. Credential rotation follows the normal sealed secret workflow.

The ConfigMap's `librechat.yaml` content defaults to a minimal config:

```yaml
# Minimal librechat.yaml — add endpoints, registration, and custom models below.
# See https://github.com/danny-avila/LibreChat/blob/main/librechat.example.yaml
version: "1.3.9"
cache: true
interface:
  privacyPolicy: ""
  termsOfService: ""
  modelSelect: true
  parameters: true
  presets: true
  prompts: true
  bookmarks: true
  multiConvo: true
  agents: true
registration:
  socialLogins: []
  allowedDomains: []
endpoints: {}
```

- **First-admin protection:** After deploying and registering the first admin account, set `registration: false` in this ConfigMap and restart the Deployment. Any host on the whitelisted subnets (192.168.5.0/24, 192.168.6.0/24) can otherwise register as the sole admin of an app storing API keys for paid AI providers.

**Patterns to follow:**
- `apps/mealie/sealedsecret-mealie.yaml` — multi-key app secret pattern

**Test scenarios:**
- Happy path: ConfigMap is created, SealedSecret decrypts to valid Secret, Deployment references both, LibreChat starts with valid config.
- Edge case: librechat.yaml contains invalid YAML — LibreChat logs a config parse error on startup.

**Verification:**
- ConfigMap exists in `librechat` namespace
- SealedSecret exists in `librechat` namespace and is in sync per ArgoCD
- Secret decrypts successfully (`kubectl get secret librechat -n librechat -o yaml`)

---

### U3. Create Meilisearch Deployment + Service + PVC

**Goal:** Deploy a per-app Meilisearch v1.35.1 instance with persistent data storage (2Gi PVC).

**Requirements:** R3

**Dependencies:** U2 (Meilisearch master key must match the value in the LibreChat secret)

**Files:**
- Create: `apps/librechat/deployment-meilisearch.yaml`
- Create: `apps/librechat/service-meilisearch.yaml`
- Create: `apps/librechat/persistentvolumeclaim-meilisearch-data.yaml`

**Approach:**
- Single replica, `Recreate` strategy (required for RWO PVC reattachment; Meilisearch embedded LMDB does not support multi-writer)
- PVC: `longhorn` StorageClass, **2Gi**, RWO — covers tens of thousands of chat messages with years of headroom (19K docs = 224MB on-disk per Meilisearch benchmarks)
- Image: `getmeili/meilisearch:v1.35.1`
- Port: 7700
- Env: `MEILI_MASTER_KEY` from sealed secret, `MEILI_NO_ANALYTICS=true`, `MEILI_DB_PATH=/meili_data`, `MEILI_MAX_INDEXING_MEMORY=512MB` (critical — Meilisearch defaults `max_indexing_memory` to 2/3 of host RAM, ignoring container limits; without this, a 1Gi container will be OOM-killed on a multi-GB host node)
- Resources: `requests: {cpu: 100m, memory: 256Mi}`, `limits: {cpu: 500m, memory: 1Gi}`
- Pod securityContext: `fsGroup: 1000` (required — Longhorn volumes provisioned owned by root; Meilisearch runs as UID 1000)
- Container securityContext: `runAsUser: 1000`, `runAsGroup: 1000`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities: {drop: [ALL]}`
- The PVC must be mounted at `/meili_data` to match `MEILI_DB_PATH`
- **PVC classification:** This PVC is a **cache** — indexes are derived from MongoDB data and can be rebuilt. If lost: delete PVC, restart Meilisearch, trigger full re-index from LibreChat admin UI.

**Patterns to follow:**
- `apps/manyfold/deployment-redis.yaml` — per-app auxiliary service pattern

**Test scenarios:**
- Happy path: Meilisearch pod starts, passes health check on port 7700, persists data across restarts
- Edge case: PVC not yet provisioned — pod waits in Pending, starts once Longhorn volume is ready

**Verification:**
- `kubectl get pods -n librechat` shows meilisearch pod Running
- `kubectl logs deployment/meilisearch -n librechat` shows "Server listening on port 7700"
- `kubectl describe pod -n librechat -l app=meilisearch` confirms resource limits applied

---

### U10. Provision CNPG pgvector Database for RAG

**Goal:** Add a `librechat_rag` database and role with the `pgvector` extension on the shared CNPG Postgres cluster for RAG vector embeddings.

**Requirements:** R9

**Dependencies:** None (CNPG cluster must exist — already deployed)

**Files:**
- Modify: `apps/postgres/cluster-postgres.yaml`
- Create: `apps/librechat/database-librechat-rag.yaml` (Database CRD, namespace: postgres)
- Create: `apps/librechat/secret-librechat-rag-db-credentials.yaml` (plaintext, gitignored, postgres namespace)
- Create: `apps/librechat/sealedsecret-librechat-rag-db-credentials.yaml` (committed, postgres namespace)
- Create: `apps/librechat/secret-librechat-rag-api-db-credentials.yaml` (plaintext, gitignored, librechat namespace — for RAG API env var)
- Create: `apps/librechat/sealedsecret-librechat-rag-api-db-credentials.yaml` (committed, librechat namespace)
- Note: Password must be identical across the two namespace secrets (same duplication pattern as MongoDB); both plaintext files must cross-reference each other in comments

**Approach:**
- Add a `librechat_rag` managed role to `spec.managed.roles` in the CNPG cluster CRD with `LOGIN` privilege and `createdb: false` (matches all 10 existing CNPG roles — the Database CRD handles ownership)
- Create a `Database` CRD (`database-librechat-rag.yaml`) declaring `spec.name: librechat_rag`, `spec.owner: librechat_rag`, `spec.cluster.name: postgres` — follow the pattern in `docs/postgres-runbooks.md` used by every existing CNPG app
- The Database CRD creates the database declaratively — no manual `kubectl exec` or `CREATE DATABASE` needed
- The SealedSecret needs the `cnpg.io/reload: "true"` label on the Secret template (both `metadata.labels` and `spec.template.metadata.labels`). This ensures CNPG re-reconciles the managed role if the SealedSecret decrypts after the initial CRD reconciliation — a known CNPG race condition mitigated by every existing DB credentials SealedSecret in the repo
- Enable the `pgvector` extension: `CREATE EXTENSION IF NOT EXISTS vector;` — this must run once after database creation. Add an init step or document as a post-deploy manual action
- Password duplication: same pattern as Postgres apps — password in both `postgres` namespace (for CNPG role) and `librechat` namespace (for RAG API connection). Both secret files must cross-reference each other in comments
- Connection string: `postgresql://librechat_rag:<password>@postgres-pooler.postgres.svc.cluster.local:5432/librechat_rag`
- Sync wave `-3` on the SealedSecret (within librechat Application, before Deployment at wave `0`) — same pattern as MongoDB credentials
- Follow `docs/postgres-runbooks.md` for the exact role and database provisioning workflow

**Patterns to follow:**
- `docs/postgres-runbooks.md` — Adding a new application with PostgreSQL
- `apps/postgres/cluster-postgres.yaml` — existing CNPG managed roles
- `apps/open-webui/` — app with Postgres credentials in two namespaces

**Test scenarios:**
- Happy path: After applying the modified cluster CRD and Database CRD, then running the pgvector extension init step, the `librechat_rag` role can connect and the `vector` extension is available
- Edge case: Database CRD not yet synced when RAG API starts — API auto-creates tables on first successful DB connection (verify this behavior against the RAG API image)

**Verification:**
- CNPG operator logs show role `librechat_rag` created
- `psql` connection test succeeds with the new credentials (via postgres-pooler or postgres-rw)
- `SELECT * FROM pg_extension WHERE extname='vector';` returns a row

---

### U11. Create RAG API Deployment + Service

**Goal:** Deploy the LibreChat RAG API v0.8.0 (stateless) for document processing and vector search.

**Requirements:** R9

**Dependencies:** U10 (CNPG pgvector database and role must exist)

**Files:**
- Create: `apps/librechat/deployment-rag-api.yaml`
- Create: `apps/librechat/service-rag-api.yaml`

**Approach:**
- Single replica (stateless — no PVC needed; all data in CNPG)
- Image: `ghcr.io/danny-avila/librechat-rag-api-dev-lite:v0.8.0` (pinned)
- Port: 8000
- Env vars: `DB_HOST=postgres-pooler.postgres.svc.cluster.local`, `DB_PORT=5432`, `DB_NAME=librechat_rag`, `DB_USER=librechat_rag`, `DB_PASSWORD` (from SealedSecret), `RAG_PORT=8000`
- Resources: `requests: {cpu: 100m, memory: 256Mi}`, `limits: {cpu: 1000m, memory: 1Gi}` (Python service, ~1.5GB image but runtime memory is lower; 1Gi is generous for single-user document processing)
- Container securityContext: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities: {drop: [ALL]}`
- RAG API URL in LibreChat Deployment: `RAG_API_URL=http://rag-api.librechat.svc.cluster.local:8000` (set directly in Deployment env, non-sensitive)
- No probes defined in docker-compose — add basic HTTP GET `/health` probe if the image exposes one. If not, rely on pod Running state and LibreChat's own health reporting

**Patterns to follow:**
- `apps/manyfold/deployment-redis.yaml` — per-app auxiliary service pattern (stateless, no PVC)

**Test scenarios:**
- Happy path: RAG API pod starts, connects to pgvector database, responds on port 8000
- Integration: LibreChat can upload a document → RAG API processes it → vector embeddings stored in pgvector → semantic search returns relevant chunks
- Error path: pgvector database unreachable — RAG API fails to start or returns errors; LibreChat chat functionality unaffected (RAG is additive, not blocking)

**Verification:**
- `kubectl get pods -n librechat` shows rag-api pod Running
- `kubectl logs deployment/rag-api -n librechat` shows successful database connection
- `kubectl exec -n librechat deployment/librechat -- curl -s http://rag-api:8000/health` returns success (if health endpoint exists)

---

### U8. Create Redis Deployment + Service

**Goal:** Deploy a per-app Redis instance for SSE pub/sub state sharing between the two LibreChat replicas.

**Requirements:** R7

**Dependencies:** U2 (Redis URL must be in the LibreChat sealed secret)

**Files:**
- Create: `apps/librechat/deployment-redis.yaml`
- Create: `apps/librechat/service-redis.yaml`

**Approach:**
- Single replica (Redis holds ephemeral pub/sub state — no persistence needed, no PVC)
- Image: `redis:8.6.2-alpine` (matches litellm pattern)
- Port: 6379
- Args: `--maxmemory 96mb --maxmemory-policy noeviction` (prevents silent eviction of SSE session state; matches manyfold/authentik pattern)
- Resources: `requests: {cpu: 50m, memory: 32Mi}`, `limits: {cpu: 200m, memory: 128Mi}`
- Container securityContext: `runAsUser: 999`, `runAsGroup: 999`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities: {drop: [ALL]}` (UID 999 matches existing litellm/manyfold Redis pattern — `redis:alpine` runs as the `redis` user, UID 999)
- Redis URL in LibreChat sealed secret: `REDIS_URI=redis://redis.librechat.svc.cluster.local:6379`
- No password — cluster-internal only, NetworkPolicy restricts LibreChat ingress (see U9), and Redis holds no persistent data

**Patterns to follow:**
- `apps/manyfold/deployment-redis.yaml` — per-app Redis pattern
- `apps/litellm/deployment-redis.yaml` — resource limit pattern for alpine Redis

**Test scenarios:**
- Happy path: Redis pod starts, accepts connections from LibreChat pods
- Edge case: Redis pod restarts — LibreChat SSE sessions break momentarily, clients reconnect. No data loss (ephemeral state).
- Error path: Redis unavailable — LibreChat pods still start (Redis is runtime dependency, not startup dependency) but SSE streaming may fail until Redis recovers.

**Verification:**
- `kubectl get pods -n librechat` shows redis pod Running
- `kubectl exec -n librechat deployment/redis -- redis-cli PING` returns PONG

---

### U4. Create LibreChat Deployment + Service + PVC

**Goal:** Deploy the LibreChat v0.8.5 container with 2 replicas, config, secrets, persistent storage for images/uploads, and Redis-backed SSE pub/sub.

**Requirements:** R1, R6, R7

**Dependencies:** U1 (MongoDB user), U2 (sealed secret), U3 (Meilisearch running), U8 (Redis running), U11 (RAG API running) — U11 transitively requires U10 (CNPG pgvector database)

**Files:**
- Create: `apps/librechat/deployment-librechat.yaml`
- Create: `apps/librechat/service-librechat.yaml`
- Create: `apps/librechat/persistentvolumeclaim-librechat.yaml`

**Approach:**
- **2 replicas**, `RollingUpdate` strategy (enabled by RWX PVC — both pods can mount the shared volume simultaneously)
- Image: `librechat/librechat:v0.8.5`
- Port: 3080
- Env vars from SealedSecret: `MONGO_URI`, `MEILI_MASTER_KEY`, `JWT_SECRET`, `JWT_REFRESH_SECRET`, `CREDS_KEY`, `CREDS_IV`, AI provider keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.)
- Env vars set directly in Deployment (non-sensitive): `DOMAIN_CLIENT=https://librechat.home.diceninjagaming.com`, `DOMAIN_SERVER=https://librechat.home.diceninjagaming.com`, `HOST=0.0.0.0`, `PORT=3080`, `TRUST_PROXY=1`, `MEILI_HOST=http://meilisearch.librechat.svc.cluster.local:7700`, `REDIS_URI=redis://redis.librechat.svc.cluster.local:6379`, `RAG_API_URL=http://rag-api.librechat.svc.cluster.local:8000`
- `NODE_OPTIONS=--max-old-space-size=1536` (75% of 2Gi container limit; leaves room for V8 non-heap memory, jemalloc overhead)
- Resources: `requests: {cpu: 100m, memory: 512Mi}`, `limits: {cpu: 2000m, memory: 2Gi}` (LibreChat official minimum 1 GiB, 2 GiB recommended with all features)
- `librechat.yaml` mounted from ConfigMap `librechat-config` as a volume at `/app/librechat.yaml` (standard mount, not `subPath` — auto-updates when ConfigMap changes, but LibreChat reads at startup only; run `kubectl rollout restart deployment/librechat -n librechat` after ConfigMap edits)
- PVC: `longhorn`, **5Gi**, **RWX** mounted at `/app/client/public/images` (subPath: `images`), `/app/uploads` (subPath: `uploads`), `/app/logs` (subPath: `logs`)
- **PVC classification:** This PVC is **source-of-truth** — user-uploaded files and images cannot be rebuilt from other data stores. Losing this PVC means permanent data loss of uploads (unlike Meilisearch which rebuilds from MongoDB).
- Pod securityContext: `fsGroup: 1000` (required — Longhorn volumes provisioned owned by root). Verify exact GID against the LibreChat Dockerfile before implementing; 1000 is the common Node.js default. Note: the value must match what the LibreChat Dockerfile uses — it may differ from Meilisearch's UID.
- Container securityContext: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities: {drop: [ALL]}`
- Probes: startup (path `/api/health`, initialDelay 15s, period 10s, failureThreshold 12), liveness (path `/api/health`, period 30s), readiness (path `/api/health`, period 10s)
- **Note:** LibreChat's `/api/health` endpoint may return 200 even when MongoDB or Meilisearch are unreachable. Smoke test after deployment by sending a chat message; do not rely on probe pass alone.
- `MONGO_URI=mongodb://librechat:<password>@mongodb-rs0.mongodb.svc.cluster.local:27017/LibreChat?authSource=LibreChat&maxPoolSize=20`
- `DOMAIN_CLIENT=https://librechat.home.diceninjagaming.com`
- `DOMAIN_SERVER=https://librechat.home.diceninjagaming.com`

**Pre-implementation blocking checks:**
- Verify the actual LibreChat Dockerfile UID/GID for `fsGroup` (do not assume 1000)
- Verify the actual listen port from the Dockerfile (do not assume 3080 or 80)
- These follow the CLAUDE.md discipline — research container security context per app, never copy from existing

**Patterns to follow:**
- `apps/mealie/deployment-mealie.yaml` — Deployment structure, probes, securityContext
- `apps/mealie/service-mealie.yaml` — ClusterIP Service pattern
- `apps/litellm/deployment-redis.yaml` — resource limit pattern

**Test scenarios:**
- Happy path: LibreChat pod starts, passes health probes, serves UI on port 3080
- Integration: LibreChat connects to MongoDB, initializes database on first start
- Integration: LibreChat connects to Meilisearch, creates search indexes
- Integration: LibreChat connects to Redis, SSE pub/sub functional across both replicas
- Error path: MongoDB unreachable — startup probe fails, pod restarts until MongoDB is available
- Edge case: SealedSecret not yet decrypted on first sync — pod enters CreateContainerConfigError briefly, self-heals once Secret exists

**Verification:**
- `kubectl get pods -n librechat` shows 2 librechat pods Running
- `kubectl logs deployment/librechat -n librechat` shows successful startup, no connection errors
- `kubectl port-forward -n librechat svc/librechat 3080:3080` → `curl localhost:3080/api/health` returns 200

---

### U9. Create NetworkPolicies

**Goal:** Restrict ingress traffic to Meilisearch (from LibreChat pods only) and LibreChat (from Traefik pods only).

**Requirements:** R8

**Dependencies:** U3 (Meilisearch Service), U4 (LibreChat Service), U8 (Redis Service)

**Files:**
- Create: `apps/librechat/networkpolicy-meilisearch.yaml`
- Create: `apps/librechat/networkpolicy-librechat.yaml`
- Create: `apps/librechat/networkpolicy-redis.yaml`

**Approach:**
- Standard `networking.k8s.io/v1/NetworkPolicy` — Cilium CNI enforces these. Matches existing ArgoCD NetworkPolicies.
- **Meilisearch policy:** PodSelector `app: meilisearch`, policyTypes `Ingress`, ingress from pods with `app: librechat` on port 7700. All other pods (any namespace) denied.
- **LibreChat policy:** PodSelector `app: librechat`, policyTypes `Ingress`, ingress from pods with `app.kubernetes.io/name: traefik` on port 3080. All other pods and direct access denied. This hardens `TRUST_PROXY=1` — the only path to LibreChat is through Traefik, which correctly strips and re-sets `X-Forwarded-*` headers.
- **Redis policy:** PodSelector `app: redis`, policyTypes `Ingress`, ingress from pods with `app: librechat` on port 6379. All other pods (any namespace) denied. Protects SSE pub/sub channels carrying AI conversation streaming data.
- All three policies are additive — they add restrictions, don't replace existing defaults.

**Patterns to follow:**
- `apps/argocd/argocd.yaml` — existing ArgoCD NetworkPolicy resources (7 policies, same API version)

**Test scenarios:**
- Happy path: LibreChat pod can reach Meilisearch on port 7700
- Happy path: Traefik pod can reach LibreChat on port 3080
- Edge case: A pod in another namespace with label `app: test` cannot reach Meilisearch port 7700
- Edge case: A pod in the `librechat` namespace without label `app: librechat` cannot reach LibreChat port 3080
- Integration: External HTTP request through Traefik → IngressRoute → LibreChat Service → LibreChat pod succeeds (full path)
- Happy path: LibreChat pod can reach Redis on port 6379
- Edge case: A pod in another namespace cannot reach Redis port 6379

**Verification:**
- `kubectl get networkpolicy -n librechat` shows both policies
- `kubectl exec -n librechat deployment/librechat -- wget -qO- http://meilisearch:7700/health` works (if wget available, or curl)
- External access through `https://librechat.home.diceninjagaming.com` works (Traefik → LibreChat path open)

---

### U5. Create IngressRoute (Internal-Only)

**Goal:** Expose LibreChat at `librechat.home.diceninjagaming.com` with internal-only access control.

**Requirements:** R1, R4

**Dependencies:** U4 (LibreChat Service must exist)

**Files:**
- Create: `apps/librechat/ingressroute-librechat.yaml`

**Approach:**
- IngressRoute in `traefik` namespace (to reference the shared wildcard TLS secret)
- Host: `librechat.home.diceninjagaming.com`
- TLS: wildcard cert `wildcard-home-diceninjagaming-com-tls`
- Middleware: `default-whitelist` (traefik namespace) — restricts to internal subnets
- Service: `librechat.librechat.svc.cluster.local:3080`
- Cross-namespace service reference (allowed by Traefik)
- Traefik's `forwardedHeaders.trustedIPs: 10.0.0.0/8` ensures correct `X-Forwarded-*` headers reaching LibreChat (combined with NetworkPolicy U9, this trust is well-bounded)

**Patterns to follow:**
- `apps/arr-stack/bazarr/ingressroute-bazarr.yaml` — traefik-namespace IngressRoute, wildcard cert, `default-whitelist`

**Test scenarios:**
- Happy path: Request from internal subnet (192.168.5.0/24 or 192.168.6.0/24) reaches LibreChat UI
- Edge case: Request from external IP — blocked by `default-whitelist` middleware with 403

**Verification:**
- `kubectl get ingressroute -n traefik librechat` shows the route
- Internal browser access at `https://librechat.home.diceninjagaming.com` loads the LibreChat UI
- External access (e.g., cellular) returns 403

---

### U6. Create ArgoCD Application Manifest

**Goal:** Register LibreChat as an ArgoCD Application so it syncs automatically.

**Requirements:** R1

**Dependencies:** U1–U5, U8–U11 (all manifests must be in place)

**Files:**
- Create: `apps/manifests/librechat.yaml`

**Approach:**
- Wave 0 (standard app wave)
- Points at `apps/librechat/` directory, recurses
- Destination namespace: `librechat`
- Standard sync policy: automated, prune, selfHeal, CreateNamespace
- Note: `CreateNamespace=true` only creates `librechat` — the `mongodb` namespace (where the DB credentials SealedSecret is deployed) must already exist from the `percona-mongodb` Application sync

**Patterns to follow:**
- `apps/manifests/mealie.yaml`

**Test scenarios:**
- Test expectation: none — pure config, no behavioral change

**Verification:**
- `kubectl get application -n argocd librechat` shows Healthy and Synced
- All pods Running in `librechat` namespace

---

### U7. Update CLAUDE.md and mongodb-runbooks.md

**Goal:** Add LibreChat to repository documentation and document per-app MongoDB connection settings.

**Requirements:** None (documentation hygiene)

**Dependencies:** U6

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/mongodb-runbooks.md`

**Approach:**
- Add `apps/librechat/` entry to Repository Structure tree in CLAUDE.md
- Add `librechat` database to the MongoDB section in CLAUDE.md
- Document `maxPoolSize` as a per-app MongoDB connection string parameter in `docs/mongodb-runbooks.md` (and note the Rationale: Node.js driver defaults to 100, which is oversized for single-user homelab; single-digit connection pools are fine)
- Document the MongoDB credential rotation order (app-namespace secret first, operator-namespace second, restart app)
- No Core Stack entry needed (application workload, not infrastructure)

**Test scenarios:**
- Test expectation: none — documentation only

**Verification:**
- `CLAUDE.md` contains `librechat/` entry in the Repository Structure section
- `docs/mongodb-runbooks.md` contains `maxPoolSize` guidance and credential rotation procedure

---

## System-Wide Impact

- **New namespace:** `librechat` — managed by ArgoCD (`CreateNamespace=true`)
- **MongoDB cluster CRD:** modified to add the `librechat` user
- **CNPG Postgres cluster CRD:** modified to add the `librechat_rag` database and role with pgvector extension
- **New workload:** 4 Deployments (librechat × 2 replicas, meilisearch, rag-api, redis), 2 PVCs (Longhorn: 2Gi RWO meilisearch, 5Gi RWX librechat)
- **Traefik:** new IngressRoute in traefik namespace — no config changes needed
- **NetworkPolicies:** 3 new `networking.k8s.io/v1/NetworkPolicy` resources — first non-ArgoCD network policies in the cluster
- **Unchanged invariants:** MongoDB cluster topology, CNPG cluster topology (pgvector extension added, no topology change), Meilisearch is per-app (not shared), Redis is per-app (not shared), wildcard cert unchanged, existing apps unaffected (no impact on MariaDB)
- **Sync wave annotations:**
  - MongoDB credentials SealedSecret (`mongodb` namespace): wave `-3` within the `librechat` Application (ensures Secret is decrypted before the LibreChat Deployment at wave `0`). Applied in both `metadata.annotations` and `spec.template.metadata.annotations`. Does NOT order before the cluster CRD cross-Application — see Cross-Application timing below.
  - RAG DB credentials SealedSecrets (`postgres` and `librechat` namespaces): wave `-3` (same rationale as MongoDB creds)
  - LibreChat app SealedSecret (`librechat` namespace): wave `-1` (before Deployment at `0`)
  - All other resources: wave `0` (default)
- **Cross-Application timing:** The password Secret lives in `apps/librechat/` and is deployed by the `librechat` Application. The cluster CRD referencing it via `passwordSecretRef` lives in `apps/percona-mongodb/`. On first sync, the operator cannot create the user until both Applications have synced. Gap is transient (~60s operator retry interval); self-heals.
- **MongoDB credential ownership:** The `librechat` Application deploys a SealedSecret to the `mongodb` namespace. ArgoCD does not namespace-lock resources — the resource's own `metadata.namespace` takes priority. The `mongodb` namespace must exist before the `librechat` Application syncs. This is the same pattern used by open-webui for Postgres.
- **PVC state classification:**
  - Meilisearch (2Gi RWO): **cache** — indexes derived from MongoDB, rebuildable. If lost, delete PVC, restart Meilisearch, re-index from LibreChat admin UI.
  - LibreChat (5Gi RWX): **source-of-truth** — user-uploaded files and images are irreplaceable. Protect with Longhorn replication and backup when available.
- **First MongoDB consumer:** LibreChat is the first application using the shared MongoDB cluster. The cluster configuration (1 CPU / 2Gi per replica, 20Gi local-path PVCs, ~512MB effective WiredTiger cache) has never been exercised under real workload. Monitor MongoDB metrics after deployment; PVC expansion procedure in `docs/mongodb-runbooks.md`.
- **MongoDB cluster recovery note:** The recovery procedure in `docs/troubleshooting.md` (replica set ID mismatch recovery) destroys all MongoDB PVCs and Secrets, including the `librechat-db-credentials` Secret. All LibreChat conversation history, user accounts, and agent configurations are permanently lost. No S3 backup is configured for MongoDB. Acknowledge and accept this risk until S3 backup is implemented.
- **TRUST_PROXY hardening:** `TRUST_PROXY=1` is safe because the LibreChat NetworkPolicy restricts ingress to Traefik pods only. Traefik strips and correctly re-sets `X-Forwarded-*` headers from the real connection. If the app goes public, no config change needed — the NetworkPolicy already enforces the trust boundary.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| MongoDB cluster must be healthy before U1 user creation | Already deployed; verify `kubectl get psmdb mongodb -n mongodb` shows `ready` |
| Meilisearch master key must match between Meilisearch Deployment and LibreChat config | Both reference the same secret key; single source of truth in `sealedsecret-librechat.yaml` |
| MongoDB password special characters break the MONGO_URI | Generate alphanumeric-only passwords using `openssl rand -base64 32 \| tr -dc 'a-zA-Z0-9'`; document URL-encoding fallback in runbook |
| LibreChat v0.8.5 config schema version (1.3.9) must match the actual `librechat.example.yaml` from the v0.8.5 tag | Verify version field against the tagged release before committing; bump image tag to upgrade |
| First registered LibreChat user becomes admin — no recovery if lost | Internal-only deployment reduces risk (only subnet-whitelisted users can access). Set `registration: false` in ConfigMap after creating first admin account and restart pod |
| LibreChat health endpoint may return 200 even when MongoDB or Meilisearch are unreachable | Smoke test after deployment by sending a chat message; do not rely on probe pass alone |
| SealedSecret not decrypted before Deployment starts on first ArgoCD sync | ArgoCD self-heals — pod may crash-loop briefly until Secret exists. Expected for initial deploy. Verify with `kubectl get secret -n librechat` before checking pod status |
| ConfigMap changes do not trigger pod restart | After editing `configmap-librechat.yaml`, run `kubectl rollout restart deployment/librechat -n librechat` — LibreChat reads `librechat.yaml` at startup only |
| Longhorn PVCs pruned when ArgoCD Application is deleted | Longhorn default `reclaimPolicy: Delete`. Before deleting the Application, back up Meilisearch indexes (rebuildable) and LibreChat uploads (irreplaceable). Or change per-volume reclaim policy before deletion |
| Removing LibreChat user from MongoDB CRD does not drop database | After removing the user entry from `spec.users`, the `LibreChat` database and all collections persist consuming disk. Run `db.dropDatabase()` in mongosh to reclaim space |
| MongoDB credential rotation in wrong order causes app downtime | Rotate in this order: (1) update librechat-namespace secret first (stale value, no effect), (2) update mongodb-namespace secret (operator rotates), (3) restart LibreChat |
| Meilisearch `max_indexing_memory` defaults to 2/3 of host RAM, ignoring container limits | Set `MEILI_MAX_INDEXING_MEMORY=512MB` (half of 1Gi limit). Without this, Meilisearch OOMs inside a 1Gi container on a multi-GB host node |
| LibreChat container listen port and fsGroup UID/GID must match the actual Docker image | Verify Dockerfile before implementing — do not assume 3080 (port) or 1000 (GID). Blocking pre-implementation check per CLAUDE.md discipline |
| Cluster recovery procedure destroys all MongoDB data including LibreChat conversations | Acknowledge and accept — no S3 backup configured for MongoDB. Conversations, users, agent configs are permanently lost on cluster rebuild |
| Meilisearch PVC is a cache but not labeled as such — risk of treating it as critical backup target | Documented in U3 and System-Wide Impact: cache, rebuildable from MongoDB. Recovery: delete PVC, restart Meilisearch, re-index |
| NetworkPolicy prevents legitimate internal access — e.g., debugging from a toolbox pod | Access Meilisearch via `kubectl exec` into a librechat pod. Or temporarily allow a toolbox pod's labels. Debug workflow documented inline |
| No rate limiting on auth endpoints — brute-force risk from compromised host on internal subnets | Accepted risk for internal-only deployment. Subnet whitelist limits the attack surface to trusted hosts. Revisit if the app goes public |
| CNPG does not auto-create databases — `librechat_rag` database may not exist when RAG API starts | Create the database manually via `kubectl exec` into CNPG primary after role provisioning, or configure RAG API to auto-create on first connect. Document the init step in post-deploy checklist |
| pgvector extension must be enabled before RAG API creates embedding tables | Init container on RAG API runs `CREATE EXTENSION IF NOT EXISTS vector;` at pod startup. Idempotent via `IF NOT EXISTS`. If the extension is not marked trusted by CNPG, the init container will surface the failure — run the GRANT manually once as postgres superuser |

---

## Post-Deploy Monitoring

After first sync, verify:

```bash
# All pods running
kubectl get pods -n librechat

# Secrets decrypted
kubectl get secret -n librechat

# MongoDB user created
kubectl logs -n mongodb -l app.kubernetes.io/name=percona-server-mongodb-operator | grep librechat

# Meilisearch responding
kubectl exec -n librechat deployment/librechat -- curl -s http://meilisearch:7700/health

# RAG API healthy
kubectl exec -n librechat deployment/librechat -- curl -s http://rag-api:8000/health

# LibreChat healthy
kubectl port-forward -n librechat svc/librechat 3080:3080
curl localhost:3080/api/health

# NetworkPolicies active
kubectl get networkpolicy -n librechat

# Registration locked down (MUST run after creating first admin account)
kubectl get configmap librechat-config -n librechat -o jsonpath='{.data.librechat\.yaml}' | grep -q 'registration: false' && echo "OK: registration disabled" || echo "ACTION REQUIRED: set registration: false in ConfigMap and restart LibreChat"
```

Smoke test: send a chat message and verify Meilisearch indexes it (search returns the message).

Watch items (first week):
- MongoDB resource usage (first workload on the cluster)
- Meilisearch memory usage vs. 1Gi limit
- RAG API memory usage (Python service, monitor for leaks under document processing load)
- Longhorn snapshot count for Meilisearch PVC (frequently written; existing cluster pruning should handle)
- LibreChat PVC usage (`du -sh /app/client/public/images /app/uploads`)

---

## Sources & References

- **Origin document:** None (planning bootstrap from user request)
- Related code: `apps/percona-mongodb/cluster-mongodb.yaml`, `apps/mealie/`, `apps/manyfold/deployment-redis.yaml`, `apps/argocd/argocd.yaml`
- External docs: [LibreChat releases](https://github.com/danny-avila/LibreChat/releases), [librechat.example.yaml](https://github.com/danny-avila/LibreChat/blob/main/librechat.example.yaml), [Meilisearch storage internals](https://www.meilisearch.com/docs/resources/internals/storage)
- Docker images: `librechat/librechat:v0.8.5`, `getmeili/meilisearch:v1.35.1`, `redis:8.6.2-alpine`, `ghcr.io/danny-avila/librechat-rag-api-dev-lite:v0.8.0`
