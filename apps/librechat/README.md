# LibreChat

Unified AI chat interface for multiple providers (OpenAI, Anthropic, Google, custom endpoints). Replaces Open WebUI as the primary AI chat frontend.

## Architecture

| Component | Purpose | Storage |
|-----------|---------|---------|
| **LibreChat** (2 replicas) | Main application — chat UI, API, SSE streaming | 5Gi RWX Longhorn (images, uploads, logs) |
| **MongoDB** (shared cluster) | Conversation history, user accounts, agent configs | 3-node Percona replica set (local-path) |
| **Meilisearch** | Full-text search across conversations | 2Gi RWO Longhorn (cache — rebuildable) |
| **Redis** | SSE pub/sub backplane for multi-replica HA | Ephemeral |
| **RAG API** | Document processing and vector search | Stateless |
| **pgvector** (shared CNPG) | Vector embeddings for RAG | Shared Postgres cluster |
| **LiteLLM** (external) | AI provider gateway — LibreChat connects via custom endpoint | Managed separately |

## Service Dependencies

```
LibreChat──┬──MongoDB───Meilisearch
           ├──Redis
           ├──RAG API───pgvector (CNPG)
           └──LiteLLM (external)
```

All services except LiteLLM are in the `librechat` namespace. LiteLLM runs in the `litellm` namespace.

## Prerequisites

### pgvector extension (one-time)

The RAG API requires the `pgvector` extension on the `librechat_rag` database. This must be created once by a PostgreSQL superuser:

```bash
PRIMARY=$(kubectl get pod -n postgres -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n postgres "$PRIMARY" -- psql -U postgres -d librechat_rag -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

The extension persists in the database — no need to repeat after restarts, pod rebuilds, or cluster recovery (CNPG replication preserves it).

### LiteLLM API key

LibreChat connects to LiteLLM as an OpenAI-compatible custom endpoint. The `LITELLM_API_KEY` must be set in the `librechat` SealedSecret. Get the key from the LiteLLM UI at `https://litellm.diceninjagaming.com`.

### First admin account

After deployment, LibreChat's registration is open. Create the first admin account immediately, then lock down registration:

```bash
kubectl get configmap librechat-config -n librechat -o yaml | sed 's/registration:/&\n    enabled: false/' | kubectl apply -f -
kubectl rollout restart deployment/librechat -n librechat
```

Any host on the internal subnets can register as admin until this is done.

## Configuration

### AI providers

Endpoints are configured in `configmap-librechat.yaml` under `data.librechat.yaml`. The default configuration points to LiteLLM as the sole provider. Add additional providers (direct OpenAI, Anthropic, etc.) here.

Sensitive values (API keys, JWT secrets, MongoDB URI) live in the `librechat` SealedSecret and are injected as environment variables.

### Model discovery

LibreChat auto-discovers available models from LiteLLM's `/v1/models` endpoint (`models.fetch: true`). No manual model listing needed unless adding non-LiteLLM providers.

## Data Classification

| PVC | Type | Recovery |
|-----|------|----------|
| `librechat-data` (5Gi RWX) | **Source of truth** | User uploads and images are irreplaceable. Restore from backup. |
| `meilisearch-data` (2Gi RWO) | **Cache** | Indexes rebuilt from MongoDB. Delete PVC, restart Meilisearch, re-index. |

MongoDB data (conversations, users, configs) lives on the shared Percona cluster — not on Longhorn. See `docs/mongodb-runbooks.md` for backup and recovery.

## Longhorn-Specific Notes

### ext4 `lost+found`

Meilisearch stores its database at `/meili_data/db` (a subdirectory) rather than `/meili_data` directly. Longhorn volumes formatted with ext4 contain a `lost+found` directory at the volume root (owned by root:root). Meilisearch would see this as existing data and fail to initialize. The subdirectory sidesteps this — `lost+found` stays harmlessly at the volume root. See `docs/troubleshooting.md` for more detail.

### `fsGroup: 1000`

Both Meilisearch and LibreChat pods set `fsGroup: 1000` in their pod securityContext. Longhorn volumes are provisioned owned by root — without `fsGroup`, non-root containers (UID 1000) cannot write to the volume.

## Troubleshooting

### Pod status

```bash
kubectl get pods -n librechat
```

### Meilisearch

```bash
kubectl logs -n librechat deployment/meilisearch
kubectl exec -n librechat deployment/meilisearch -- ls -la /meili_data/db
```

"failed to infer the version of the database" → the data directory has unexpected contents (typically `lost+found`). Verify `MEILI_DB_PATH` is set to `/meili_data/db`. If the PVC has stale data, delete it (data is cache — rebuildable).

### RAG API

```bash
kubectl logs -n librechat deployment/rag-api
kubectl get pods -n librechat -l app=rag-api
```

"permission denied to create extension vector" → the one-time pgvector setup hasn't been run. See Prerequisites above.

### MongoDB connectivity

```bash
kubectl logs -n librechat deployment/librechat | grep -i mongo
kubectl exec -n librechat deployment/librechat -- env | grep MONGO_URI
```

### Redis

```bash
kubectl logs -n librechat deployment/redis
kubectl exec -n librechat deployment/redis -- redis-cli PING
```

### NetworkPolicies

```bash
kubectl get networkpolicy -n librechat
kubectl describe networkpolicy -n librechat
```

If LibreChat can't reach Meilisearch or Redis, check that NetworkPolicies are applied and the pod labels match the selectors (`app: librechat` for egress sources).
