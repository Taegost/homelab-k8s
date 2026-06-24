# Honcho — Manual Runbook

## Architecture

| Component | Image | Purpose |
|---|---|---|
| honcho-api | `ghcr.io/plastic-labs/honcho:v3.0.10` | HTTP API on port 8000 |
| honcho-deriver | `ghcr.io/plastic-labs/honcho:v3.0.10` | Background worker (`src.deriver`) |
| honcho-valkey | `valkey/valkey:7.2.11-alpine` | Session cache on port 6379 |

Both Honcho containers run as UID/GID 100/100 (Debian `app` user). Valkey
runs as UID/GID 999. All drop ALL capabilities and deny privilege escalation.

## Initial Setup (one-time)

After ArgoCD syncs the new PVC, ConfigMap, and deployments, complete these
steps before the pods will start successfully.

### 1. pgvector Extension

Honcho's Alembic migrations run `CREATE EXTENSION IF NOT EXISTS vector` on
startup. The `vector` (pgvector) extension requires PostgreSQL superuser to
create, but the `honcho` role is not a superuser (by design). Pre-create it:

```bash
kubectl exec -n postgres $(kubectl get pod -n postgres -l role=primary -o jsonpath='{.items[0].metadata.name}') -- psql -U postgres -d honcho -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

If the database is recreated, run this again before the honcho pods start.

### 2. tiktoken Tokenizer Cache

Honcho imports Python's `tiktoken` library at startup. Tiktoken downloads the
`o200k_base` BPE merge file (~4 MB) from `openaipublic.blob.core.windows.net`
(Azure Blob Storage) on first use. The honcho namespace has default-deny egress,
so this download is blocked by NetworkPolicy.

A Longhorn RWM PVC (`honcho-tiktoken-cache`) is mounted into both the API and
deriver deployments at `/home/app/.tiktoken_cache`. The `TIKTOKEN_CACHE_DIR`
environment variable tells tiktoken to read from this path instead of fetching
over the network. Pre-download the file using a temporary pod:

```bash
# 1. Download the tokenizer file locally
curl -fsSL https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken -o /tmp/o200k_base.tiktoken

# 2. Verify the download (should be ~4 MB)
ls -lh /tmp/o200k_base.tiktoken

# 3. Create a temporary pod that mounts the PVC
kubectl run tiktoken-loader -n honcho --image=busybox --restart=Never --overrides='{"spec":{"containers":[{"name":"tiktoken-loader","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"tiktoken-cache","mountPath":"/cache"}]}],"volumes":[{"name":"tiktoken-cache","persistentVolumeClaim":{"claimName":"honcho-tiktoken-cache"}}]}}' && kubectl wait --for=condition=Ready pod/tiktoken-loader -n honcho --timeout=30s

# 4. Copy the file into the PVC via the temporary pod
#    Tiktoken caches files by SHA-1 hash of the download URL, not by the
#    original filename. The hash for o200k_base is precomputed below.
kubectl cp /tmp/o200k_base.tiktoken honcho/tiktoken-loader:/cache/fb374d419588a4632f3f557e76b4b70aebbca790

# 5. Clean up the temporary pod
kubectl delete pod -n honcho tiktoken-loader

# 6. Restart both deployments
kubectl rollout restart deployment -n honcho honcho-api
kubectl rollout restart deployment -n honcho honcho-deriver

# 7. Verify pods start successfully
kubectl get pods -n honcho
```

The PVC uses `ReadWriteMany` so the file persists across pod restarts. This
only needs to be repeated if the PVC itself is recreated.

---

## Embedding Dimension Limitation

pgvector's HNSW index has a hard limit of **2000 dimensions** for the `vector`
type. The current configuration uses `openai/text-embedding-3-small` (1536
dimensions), which is within this limit and matches Honcho's default.

If a future model requires more than 2000 dimensions, the options are:
- Use `text-embedding-3-small` at 1536 dimensions (current)
- Use `text-embedding-3-large` with MRL truncation to 2048 dimensions
- Skip the HNSW index entirely (sequential scan, supports up to 16,000
  dimensions — fine for small datasets)
- Use the `halfvec` type (supports up to 4,000 dimensions with HNSW)

Changing the embedding model or dimensions after data exists requires a
destroy-and-rebuild — Honcho's `configure_embeddings.py` refuses to ALTER
columns that already contain non-null embeddings.
See [Honcho's docs](https://honcho.dev/docs/v3/contributing/changing-embeddings).

---

## Database Password Reconciliation

### Background

CNPG manages the `honcho` role password declaratively via the
`honcho-db-credentials` secret in the `postgres` namespace. If the secret is
deleted and recreated (e.g., during re-sealing), CNPG may not automatically
update the role password in PostgreSQL.

### Symptoms

Pods fail with: `FATAL: password authentication failed for user "honcho"`

### Fix

Manually set the password in PostgreSQL to match the secret:

```bash
kubectl exec -n postgres $(kubectl get pod -n postgres -l role=primary -o jsonpath='{.items[0].metadata.name}') -- psql -U postgres -c "ALTER ROLE honcho PASSWORD '<password>';"
```

The password must match what's in the `honcho-db-credentials` secret.

---

## Configuration Reference

### ConfigMap (`configmap-honcho.yaml`)

Non-sensitive values shared by both API and Deriver via `envFrom`:

| Variable | Value | Notes |
|---|---|---|
| `AUTH_USE_AUTH` | `"true"` | JWT authentication required for API access |
| `CACHE_ENABLED` | `"true"` | Valkey session cache |
| `CACHE_URL` | `"redis://honcho-valkey.honcho.svc.cluster.local:6379/0?suppress=true"` | Cluster-internal Valkey address |
| `LLM_OPENAI_BASE_URL` | `"https://litellm.diceninjagaming.com/v1"` | LiteLLM proxy |
| `LLM_OPENAI_MODEL` | `"xiaomi-token/mimo-v2.5"` | LiteLLM model name |
| `EMBEDDING_MODEL_CONFIG__TRANSPORT` | `"openai"` | |
| `EMBEDDING_MODEL_CONFIG__MODEL` | `"openai/text-embedding-3-small"` | 1536 dimensions — see Embedding Dimension Limitation |
| `EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL` | `"https://litellm.diceninjagaming.com/v1"` | |
| `EMBEDDING_VECTOR_DIMENSIONS` | `"1536"` | Must match embedding model output |
| `TELEMETRY_ENABLED` | `"false"` | |
| `METRICS_ENABLED` | `"true"` | Prometheus metrics on port 9090 |

### Secrets (SealedSecret `honcho` in `honcho` namespace)

| Secret Key | Env Var | Notes |
|---|---|---|
| `database-url` | `DB_CONNECTION_URI` | Full Postgres connection string |
| `jwt-secret` | `AUTH_JWT_SECRET` | Generate with `openssl rand -hex 32` |
| `llm-api-key` | `LLM_OPENAI_API_KEY` | LiteLLM API key (prefixed `sk-`) |

### Deployment-Specific Variables

| Variable | API Pod | Deriver Pod |
|---|---|---|
| `DERIVER_ENABLED` | `"false"` | `"true"` |
| `TIKTOKEN_CACHE_DIR` | `/home/app/.tiktoken_cache` | `/home/app/.tiktoken_cache` |

### Dream Consolidation Tuning

The deriver runs "dream" consolidation jobs in the background. These settings
control when and how aggressively consolidation runs. Add them to the ConfigMap
if the defaults cause excessive API usage:

| Variable | Default | Recommended | Notes |
|---|---|---|---|
| `DREAM_DOCUMENT_THRESHOLD` | `50` | `100` | Documents before first dream triggers |
| `DREAM_MIN_HOURS_BETWEEN_DREAMS` | `8` | `12`–`16` | Minimum interval between dreams |
| `DREAM_MAX_TOOL_ITERATIONS` | `20` | `10` | Max LLM calls per dream session |
| `DERIVER_WORKERS` | `1` | `2` | Threads within the pod (not replicas) |

---

## Resource Limits

### honcho-api

| Resource | Request | Limit |
|---|---|---|
| CPU | 100m | 1000m |
| Memory | 256Mi | 512Mi |

### honcho-deriver

| Resource | Request | Limit |
|---|---|---|
| CPU | 100m | 500m |
| Memory | 256Mi | 512Mi |

### honcho-valkey

| Resource | Request | Limit |
|---|---|---|
| CPU | 10m | 200m |
| Memory | 48Mi | 192Mi |

Valkey maxmemory is capped at 96mb with `allkeys-lru` eviction. No persistence
(cache-only; Honcho rebuilds state from Postgres on restart).

---

## NetworkPolicy

### honcho-api

| Direction | Source/Destination | Ports |
|---|---|---|
| Ingress | `traefik` namespace (Traefik pod) | TCP/8000 |
| Ingress | `hermes-agent` namespace | TCP/8000 |
| Egress | `kube-system` (DNS) | UDP+TCP/53 |
| Egress | `postgres` namespace | TCP/5432 |
| Egress | `honcho` namespace (Valkey) | TCP/6379 |
| Egress | External (any) | TCP/443 |

### honcho-deriver

| Direction | Source/Destination | Ports |
|---|---|---|
| Egress | `kube-system` (DNS) | UDP+TCP/53 |
| Egress | `postgres` namespace | TCP/5432 |
| Egress | `honcho` namespace (Valkey) | TCP/6379 |
| Egress | External (any) | TCP/443 |

### honcho-valkey

| Direction | Source/Destination | Ports |
|---|---|---|
| Ingress | `honcho` namespace | TCP/6379 |

Valkey has no authentication — isolation is network-level only.
See `apps/honcho/convention-valkey-no-auth.md`.

---

## Sync-Wave Ordering

| Resource | Wave | Namespace | Rationale |
|---|---|---|---|
| `honcho-db-credentials` SealedSecret | `-3` | `postgres` | CNPG reads password at role creation |
| CNPG Database CRD | `-1` | `postgres` | Creates database + role after secret decrypts |
| `honcho` SealedSecret | `-1` | `honcho` | Must decrypt before Deployments at wave 0 |
| All other resources | `0` | `honcho` | Default wave |

---

## Verification

After the initial setup steps are complete:

```bash
# 1. Check all pods are running
kubectl get pods -n honcho

# 2. Verify API health endpoint
kubectl exec -n honcho deployment/honcho-api -- curl -sf http://localhost:8000/health

# 3. Verify deriver is running
kubectl logs -n honcho deployment/honcho-deriver --tail=20

# 4. Verify pgvector extension exists
kubectl exec -n postgres $(kubectl get pod -n postgres -l role=primary -o jsonpath='{.items[0].metadata.name}') -- psql -U postgres -d honcho -c "SELECT * FROM pg_extension WHERE extname = 'vector';"

# 5. Verify Valkey is responding
kubectl exec -n honcho deployment/honcho-valkey -- valkey-cli ping

# 6. Verify NetworkPolicy (hermes-agent can reach honcho-api)
kubectl exec -n hermes-agent deployment/hermes-agent -- curl -sf http://honcho-api.honcho.svc.cluster.local:8000/health
```

---

## Hermes Integration

Hermes connects to Honcho for persistent memory and personalization via the
`hermes memory setup honcho` CLI command. The NetworkPolicy already allows
ingress from the `hermes-agent` namespace to `honcho-api` on port 8000.

### Step 1: Add Environment Variable

Add `HONCHO_API_KEY` to the hermes-agent deployment
(`apps/hermes-agent/deployment-hermes-agent.yaml`):

```yaml
# ── Honcho Memory Backend ──────────────────────────────────────
- name: HONCHO_API_KEY
  valueFrom:
    secretKeyRef:
      name: hermes-honcho-api-key
      key: jwt-secret
```

When Honcho has auth enabled (`AUTH_USE_AUTH: "true"`), the `HONCHO_API_KEY`
value must be a JWT token **signed with** the server's `AUTH_JWT_SECRET` — not
the raw secret itself. If auth is disabled, `HONCHO_API_KEY` can be left blank.

To generate the JWT:

```bash
# 1. Extract the AUTH_JWT_SECRET from the Honcho SealedSecret
#    (unseal first if needed, or read from the plaintext source)
AUTH_JWT_SECRET="<value from honcho secret>"

# 2. Generate a JWT signed with HS256
#    Honcho expects iat/exp as ISO 8601 datetime strings, NOT Unix timestamps.
HEADER=$(echo -n '{"alg":"HS256","typ":"JWT"}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
PAYLOAD=$(echo -n '{"sub":"hermes","iat":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","exp":"'$(date -u -d "+365 days" +%Y-%m-%dT%H:%M:%SZ)'"}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -hmac "$AUTH_JWT_SECRET" -binary | base64 -w0 | tr '+/' '-_' | tr -d '=')
JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

# 3. Create the plaintext secret
cat > apps/hermes-agent/secret-hermes-honcho-api-key.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: hermes-honcho-api-key
  namespace: hermes-agent
type: Opaque
stringData:
  honcho-api-key: "$JWT"
EOF

# 4. Seal and clean up
kubeseal --format yaml < apps/hermes-agent/secret-hermes-honcho-api-key.yaml > apps/hermes-agent/sealedsecret-hermes-honcho-api-key.yaml
rm apps/hermes-agent/secret-hermes-honcho-api-key.yaml
```

Alternative using Python (if openssl is not available):

```bash
AUTH_JWT_SECRET="<value from honcho secret>"
python3 -c "
import json, hmac, hashlib, base64, time, datetime
now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
exp = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=365)).strftime('%Y-%m-%dT%H:%M:%SZ')
header = base64.urlsafe_b64encode(json.dumps({'alg':'HS256','typ':'JWT'}).encode()).rstrip(b'=').decode()
payload = base64.urlsafe_b64encode(json.dumps({'sub':'hermes','iat':now,'exp':exp}).encode()).rstrip(b'=').decode()
sig = base64.urlsafe_b64encode(hmac.new('$AUTH_JWT_SECRET'.encode(), f'{header}.{payload}'.encode(), hashlib.sha256).digest()).rstrip(b'=').decode()
print(f'{header}.{payload}.{sig}')
"
```

### Step 2: Run the Memory Setup CLI

After ArgoCD syncs the env var, exec into the Hermes pod and run the setup:

```bash
# Interactive wizard — select "honcho" from the provider list
kubectl exec -it -n hermes-agent deployment/hermes-agent -- hermes memory setup

# Or direct activation
kubectl exec -it -n hermes-agent deployment/hermes-agent -- hermes memory setup honcho
```

For a self-hosted Honcho instance, the wizard will ask for the base URL. Use
the cluster-internal address:

```
http://honcho-api.honcho.svc.cluster.local:8000
```

### Step 2a: Gateway Identity Mapping

The setup wizard detects connected gateway platforms (e.g., Telegram) and asks
"who talks to this gateway?". For a single-user homelab, pick **"just me"** —
this sets `pinUserPeer: true`, collapsing all gateway users to the configured
`peerName`. Picking "me + other people" maps specific runtime IDs via
`userPeerAliases` instead, which is only needed for multi-user setups.

### Step 3: Verify

> **Note:** `hermes honcho` subcommands are only available after Honcho is
> activated as the memory provider — Step 2 must complete successfully first.

```bash
# Check connection status and config
kubectl exec -it -n hermes-agent deployment/hermes-agent -- hermes honcho status
```

### Post-Setup Configuration

After setup, these CLI commands tune Honcho's behavior:

| Command | Purpose |
|---|---|
| `hermes honcho mode` | Recall mode: `hybrid`, `context`, or `tools` |
| `hermes honcho strategy` | Session strategy: `per-session`, `per-directory`, `per-repo`, `global` |
| `hermes honcho tokens` | Token budget for context and dialectic |
| `hermes honcho peer` | Show/update peer names and reasoning level |
| `hermes honcho identity` | Seed the AI peer's Honcho identity |
| `hermes honcho sync` | Sync Honcho config to all existing profiles |
| `hermes honcho peers` | Show peer identities across all profiles |
| `hermes honcho sessions` | List known Honcho session mappings |
| `hermes honcho map` | Map current directory to a Honcho session name |
| `hermes honcho enable` | Enable Honcho for the active profile |
| `hermes honcho disable` | Disable Honcho for the active profile |

Default session strategy is `per-directory` — one Honcho session per working
directory where context accumulates across runs.

### References

- [Honcho Memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/honcho) — Hermes docs
- [Memory Providers](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers) — full provider list
