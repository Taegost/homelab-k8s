---
title: feat: Add LibreChat with MongoDB and Meilisearch
type: feat
status: active
date: 2026-05-23
---

# feat: Add LibreChat with MongoDB and Meilisearch

## Summary

Deploy LibreChat v0.8.5 as a raw-manifest app using the shared MongoDB cluster and a per-app Meilisearch instance. Internal-only access at `librechat.home.diceninjagaming.com` via the `*.home.diceninjagaming.com` wildcard cert with `default-whitelist` middleware. Non-sensitive config in a ConfigMap; sensitive values (API keys, JWT secrets, credentials) in a SealedSecret.

---

## Problem Frame

LibreChat provides a unified chat interface for multiple AI providers (OpenAI, Anthropic, Google, custom endpoints). It requires MongoDB for document storage and Meilisearch for full-text search. This plan adds it as the first MongoDB-backed application in the cluster, accessible internally at `librechat.home.diceninjagaming.com` with potential future public exposure.

---

## Requirements

- R1. LibreChat v0.8.5 deployed and accessible at `librechat.home.diceninjagaming.com`
- R2. MongoDB database and user provisioned via the shared Percona cluster
- R3. Meilisearch v1.35.1 deployed as a per-app service with persistent storage
- R4. Internal-only access using wildcard TLS cert and `default-whitelist` middleware
- R5. AI provider configuration isolated in a SealedSecret
- R6. User-uploaded images persist across pod restarts

---

## Scope Boundaries

- LibreChat deployment with MongoDB + Meilisearch
- Internal-only IngressRoute (Traefik namespace, wildcard cert)
- SealedSecret for all sensitive config

### Deferred to Follow-Up Work

- **RAG/vector search (pgvector):** requires PostgreSQL + pgvector deployment — separate PR
- **Redis session store:** not needed for single-replica homelab deployment
- **Public access:** user explicitly deferred; requires per-app Certificate + `default-headers` middleware swap
- **Automated LibreChat upgrades:** manual image tag bump in Deployment (repo convention for manifest-based apps)

---

## Context & Research

### Relevant Code and Patterns

- `apps/percona-mongodb/cluster-mongodb.yaml` — MongoDB user provisioning via `spec.users`
- `apps/mealie/deployment-mealie.yaml` — Deployment pattern (env vars, probes, securityContext)
- `apps/mealie/sealedsecret-mealie.yaml` — App-level SealedSecret pattern
- `apps/arr-stack/bazarr/ingressroute-bazarr.yaml` — Internal IngressRoute in traefik namespace with `default-whitelist`
- `apps/manyfold/deployment-redis.yaml` — Per-app auxiliary service pattern (Deployment + Service + PVC)
- `apps/manyfold/deployment-redis.yaml` — full securityContext with fsGroup for Longhorn PVCs
- `apps/manifests/mealie.yaml` — ArgoCD Application manifest pattern (wave 0)
- `docs/mongodb-runbooks.md` — Adding a new application workflow

### External References

- LibreChat v0.8.5 Docker image: `librechat/librechat:v0.8.5` (Docker Hub)
- Meilisearch v1.35.1: `getmeili/meilisearch:v1.35.1`
- LibreChat config reference: `librechat.example.yaml` (v1.3.9 schema for LibreChat v0.8.5)
- LibreChat env vars: `MONGO_URI`, `MEILI_HOST`, `MEILI_MASTER_KEY`, `JWT_SECRET`, `JWT_REFRESH_SECRET`, `CREDS_KEY`, `CREDS_IV`, `DOMAIN_CLIENT`, `DOMAIN_SERVER`, `TRUST_PROXY`, `PORT`=3080, `HOST`=0.0.0.0

---

## Key Technical Decisions

- **Per-app Meilisearch (not shared):** follows the existing Redis pattern (authentik, manyfold, litellm each have their own Redis). Meilisearch is heavier than Redis but same principle — LibreChat owns its indexes and config. If another app needs Meilisearch later, extract to shared service.
- **Raw manifests (not Helm):** repo convention. Every app in the repo uses raw manifests deployed via ArgoCD directory-of-manifests.
- **Wildcard cert + traefik namespace IngressRoute:** matches the arr-stack internal-only pattern. Uses the `*.home.diceninjagaming.com` wildcard cert (`wildcard-home-diceninjagaming-com-tls`). The IngressRoute lives in `traefik` namespace to reference this shared TLS secret. If public access is needed later, switch to per-app Certificate.
- **Recreate strategy for both Deployments:** Meilisearch and LibreChat each have a Longhorn RWO PVC. Single replica with `Recreate` ensures the new pod can reattach the volume regardless of node placement. Both Deployments must set `fsGroup` in the pod `securityContext` — Longhorn volumes are provisioned owned by root.
- **Config split: ConfigMap for librechat.yaml, SealedSecret for sensitive values:** Non-sensitive config (UI preferences, endpoint definitions) lives in a ConfigMap mounted at `/app/librechat.yaml`. Sensitive values (API keys, JWT secrets, MONGO_URI, MEILI_MASTER_KEY) stay in a SealedSecret injected as env vars. This avoids the sealed-secret workflow for routine AI provider changes and the `subPath`-from-Secret staleness problem (subPath mounts do not auto-update when the Secret changes).

---

## Output Structure

```
apps/librechat/
├── configmap-librechat.yaml                       # CREATE (librechat.yaml, non-sensitive config)
├── deployment-librechat.yaml                      # CREATE
├── deployment-meilisearch.yaml                    # CREATE
├── ingressroute-librechat.yaml                    # CREATE (traefik namespace)
├── persistentvolumeclaim-meilisearch-data.yaml    # CREATE
├── persistentvolumeclaim-librechat-images.yaml    # CREATE
├── sealedsecret-librechat-db-credentials.yaml     # CREATE (committed, mongodb namespace)
├── sealedsecret-librechat.yaml                    # CREATE (committed, librechat namespace)
├── secret-librechat-db-credentials.yaml           # CREATE (plaintext, gitignored, temporary)
├── secret-librechat.yaml                          # CREATE (plaintext, gitignored, temporary)
├── service-librechat.yaml                         # CREATE
└── service-meilisearch.yaml                       # CREATE
apps/manifests/
└── librechat.yaml                                 # CREATE (ArgoCD Application)

# Also modified (NOT in apps/librechat/):
#   apps/percona-mongodb/cluster-mongodb.yaml      # MODIFY: add librechat user to spec.users
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
- The database `LibreChat` is created implicitly on first write — no separate Database CRD needed
- **Password duplication:** The password value must be identical in two secrets: the operator-facing `sealedsecret-librechat-db-credentials.yaml` (mongodb namespace) and the `MONGO_URI` embedded in `secret-librechat.yaml` (librechat namespace). Generate one password, place it in both plaintext secrets, seal both, then delete both plaintext files. See `docs/mongodb-runbooks.md` for details.
- **Password characters:** MongoDB connection strings require URL-encoding for `@`, `:`, `/`, `%` in passwords. Generate alphanumeric-only passwords or URL-encode special characters in the MONGO_URI value.

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

**Goal:** Create a ConfigMap for non-sensitive LibreChat config (`librechat.yaml`) and a SealedSecret for sensitive values (API keys, JWT secrets, MongoDB URI, Meilisearch master key).

**Requirements:** R5

**Dependencies:** U1 (MongoDB credentials must exist to form the MONGO_URI)

**Files:**
- Create: `apps/librechat/configmap-librechat.yaml` (committed directly)
- Create: `apps/librechat/secret-librechat.yaml` (plaintext, gitignored, for sealing)
- Create: `apps/librechat/sealedsecret-librechat.yaml` (committed, after sealing)

**Approach:**
- ConfigMap with key `librechat.yaml` containing the non-sensitive config. Mounted as a file at `/app/librechat.yaml` in the Deployment (standard ConfigMap volume mount — auto-updates without restart, unlike `subPath`).
- SealedSecret with env vars: `MONGO_URI`, `MEILI_MASTER_KEY`, `JWT_SECRET`, `JWT_REFRESH_SECRET`, `CREDS_KEY`, `CREDS_IV`, AI provider keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.), `DOMAIN_CLIENT`, `DOMAIN_SERVER`
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

**Goal:** Deploy a per-app Meilisearch v1.35.1 instance with persistent data storage.

**Requirements:** R3

**Dependencies:** U2 (Meilisearch master key must match the value in the LibreChat secret)

**Files:**
- Create: `apps/librechat/deployment-meilisearch.yaml`
- Create: `apps/librechat/service-meilisearch.yaml`
- Create: `apps/librechat/persistentvolumeclaim-meilisearch-data.yaml`

**Approach:**
- Single replica, `Recreate` strategy (required for RWO PVC reattachment)
- PVC: `longhorn` StorageClass, 10Gi, RWO — Meilisearch data is a single-node embedded DB
- Image: `getmeili/meilisearch:v1.35.1`
- Port: 7700
- Env: `MEILI_MASTER_KEY` from sealed secret, `MEILI_NO_ANALYTICS=true`, `MEILI_DB_PATH=/meili_data`
- Pod securityContext: `fsGroup: 1000` (required — Longhorn volumes provisioned owned by root; Meilisearch runs as UID 1000)
- Container securityContext: `runAsUser: 1000`, `runAsGroup: 1000`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities: {drop: [ALL]}`
- The PVC must be mounted at `/meili_data` to match `MEILI_DB_PATH`

**Patterns to follow:**
- `apps/manyfold/deployment-redis.yaml` — per-app auxiliary service pattern

**Test scenarios:**
- Happy path: Meilisearch pod starts, passes health check on port 7700, persists data across restarts
- Edge case: PVC not yet provisioned — pod waits in Pending, starts once Longhorn volume is ready

**Verification:**
- `kubectl get pods -n librechat` shows meilisearch pod Running
- `kubectl logs deployment/meilisearch -n librechat` shows "Server listening on port 7700"

---

### U4. Create LibreChat Deployment + Service + PVC

**Goal:** Deploy the LibreChat v0.8.5 container with config, secrets, and persistent image storage.

**Requirements:** R1, R6

**Dependencies:** U1 (MongoDB user), U2 (sealed secret), U3 (Meilisearch running)

**Files:**
- Create: `apps/librechat/deployment-librechat.yaml`
- Create: `apps/librechat/service-librechat.yaml`
- Create: `apps/librechat/persistentvolumeclaim-librechat-images.yaml`

**Approach:**
- Single replica, `Recreate` strategy
- Image: `librechat/librechat:v0.8.5`
- Port: 3080
- Env vars injected from sealed secret: `MONGO_URI`, `MEILI_HOST`, `MEILI_MASTER_KEY`, `JWT_SECRET`, `JWT_REFRESH_SECRET`, `CREDS_KEY`, `CREDS_IV`, `DOMAIN_CLIENT`, `DOMAIN_SERVER`, `TRUST_PROXY`, `HOST=0.0.0.0`, `PORT=3080`, AI provider keys
- `librechat.yaml` mounted from ConfigMap `librechat-config` as a volume at `/app/librechat.yaml` (standard mount, not `subPath` — auto-updates when ConfigMap changes, though pod restart still needed for app to re-read)
- PVC: `longhorn`, 5Gi, RWO mounted at `/app/client/public/images`
- Pod securityContext: `fsGroup: 1000` (required — Longhorn volumes provisioned owned by root). Determine exact GID from the LibreChat Dockerfile before implementing; 1000 is the common Node.js default.
- Container securityContext: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities: {drop: [ALL]}`
- Probes: startup (path `/api/health`, initialDelay 15s, period 10s, failureThreshold 12), liveness (path `/api/health`, period 30s), readiness (path `/api/health`, period 10s)
- `MEILI_HOST=http://meilisearch.librechat.svc.cluster.local:7700`
- `MONGO_URI=mongodb://librechat:<password>@mongodb-rs0.mongodb.svc.cluster.local:27017/LibreChat?authSource=LibreChat`
- `DOMAIN_CLIENT=https://librechat.home.diceninjagaming.com`
- `DOMAIN_SERVER=https://librechat.home.diceninjagaming.com`
- `TRUST_PROXY=1`

**Patterns to follow:**
- `apps/mealie/deployment-mealie.yaml` — Deployment structure, probes, securityContext
- `apps/mealie/service-mealie.yaml` — ClusterIP Service pattern

**Test scenarios:**
- Happy path: LibreChat pod starts, passes health probes, serves UI on port 3080
- Integration: LibreChat connects to MongoDB, initializes database on first start
- Integration: LibreChat connects to Meilisearch, creates search indexes
- Error path: MongoDB unreachable — startup probe fails, pod restarts until MongoDB is available

**Verification:**
- `kubectl get pods -n librechat` shows librechat pod Running
- `kubectl logs deployment/librechat -n librechat` shows successful startup, no connection errors
- `kubectl port-forward -n librechat svc/librechat 3080:3080` → `curl localhost:3080/api/health` returns 200

---

### U5. Create IngressRoute (Internal-Only)

**Goal:** Expose LibreChat at `librechat.home.diceninjagaming.com` with internal-only access control.

**Requirements:** R4

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

**Dependencies:** U1–U5 (all manifests must be in place)

**Files:**
- Create: `apps/manifests/librechat.yaml`

**Approach:**
- Wave 0 (standard app wave)
- Points at `apps/librechat/` directory, recurses
- Destination namespace: `librechat`
- Standard sync policy: automated, prune, selfHeal, CreateNamespace

**Patterns to follow:**
- `apps/manifests/mealie.yaml`

**Test scenarios:**
- Happy path: After commit and push, ArgoCD detects the new Application and syncs all resources
- Test expectation: none — pure config, no behavioral change

**Verification:**
- `kubectl get application -n argocd librechat` shows Healthy and Synced
- All pods Running in `librechat` namespace

---

### U7. Update CLAUDE.md

**Goal:** Add LibreChat to the repository documentation.

**Requirements:** None (documentation hygiene)

**Dependencies:** U6

**Files:**
- Modify: `CLAUDE.md`

**Approach:**
- Add `apps/librechat/` entry to Repository Structure tree
- No Core Stack entry needed (application workload, not infrastructure)

**Test scenarios:**
- Test expectation: none — documentation only

**Verification:**
- `CLAUDE.md` contains `librechat/` entry in the Repository Structure section

---

## System-Wide Impact

- **New namespace:** `librechat` — managed by ArgoCD (`CreateNamespace=true`)
- **MongoDB cluster CRD:** modified to add the `librechat` user
- **New workload:** 2 Deployments (librechat, meilisearch), 2 PVCs (Longhorn)
- **Traefik:** new IngressRoute in traefik namespace — no config changes needed
- **Unchanged invariants:** MongoDB cluster topology, Meilisearch is per-app (not shared), wildcard cert unchanged, existing apps unaffected

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| MongoDB cluster must be healthy before U1 user creation | Already deployed; verify `kubectl get psmdb mongodb -n mongodb` shows `ready` |
| Meilisearch master key must match between Meilisearch Deployment and LibreChat config | Both reference the same secret key; single source of truth in `sealedsecret-librechat.yaml` |
| MongoDB password special characters break the MONGO_URI | Generate alphanumeric-only passwords using `openssl rand -base64 32 \| tr -dc 'a-zA-Z0-9'`; document URL-encoding fallback in runbook |
| LibreChat v0.8.5 config schema version (1.3.9) must match the actual `librechat.example.yaml` from the v0.8.5 tag | Verify version field against the tagged release before committing; bump image tag to upgrade |
| First registered LibreChat user becomes admin — no recovery if lost | Internal-only deployment reduces risk (only subnet-whitelisted users can access); document in runbook |
| LibreChat health endpoint may return 200 even when MongoDB or Meilisearch are unreachable | Smoke test after deployment by sending a chat message; do not rely on probe pass alone |

---

## Sources & References

- **Origin document:** None (planning bootstrap from user request)
- Related code: `apps/percona-mongodb/cluster-mongodb.yaml`, `apps/mealie/`, `apps/manyfold/deployment-redis.yaml`
- External docs: [LibreChat releases](https://github.com/danny-avila/LibreChat/releases), [librechat.example.yaml](https://github.com/danny-avila/LibreChat/blob/main/librechat.example.yaml)
- Docker images: `librechat/librechat:v0.8.5`, `getmeili/meilisearch:v1.35.1`
