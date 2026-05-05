# LiteLLM

LiteLLM is a unified gateway for multiple LLM providers, providing a single OpenAI-compatible API endpoint for all AI models.

## Architecture

- **LiteLLM** proxies requests to various endpoints
- **Postgres** (shared CNPG cluster) stores model configurations and key management state
- **Redis** (shared) handles multi-replica coordination, rate limiting, and health check state
- **Open WebUI** connects to LiteLLM as its backend

## Model Configuration

Models are managed via the LiteLLM UI. This allows for dynamic configuration without requiring code changes or ArgoCD syncs.

### Adding Models via UI

1. **Access the LiteLLM UI:**

   Navigate to `https://litellm.diceninjagaming.com`

2. **Navigate to Model Configuration:**

   Go to **Settings → Model Configuration** (or **Admin → Model Config** depending on your access level)

3. **Add a new model:**

   Click **Add Model** and fill in:
   - **Model Name:** A friendly name for the model (e.g., `qwen-coder-480b`)
   - **Model ID:** The full provider model ID (e.g., `nvidia_nim/qwen/qwen-coder-480b-a35b-instruct`)
   - **API Key:** `os.environ/NVIDIA_API_KEY`

4. **Save and verify:**

   Click **Save**. The model should appear in the available models list.

### Configuring Fallbacks

LiteLLM supports cascading fallbacks — if one model fails, it automatically tries the next in the chain.

To configure fallbacks via the UI:
1. Go to **Settings → Router Settings**
2. Add fallback chains based on your preference

## Required Environment Variables

The following environment variables are injected via the SealedSecret at `apps/litellm/sealedsecret-litellm.yaml`:

| Variable | Description | Source |
|----------|-------------|--------|
| `LITELLM_MASTER_KEY` | Admin API key (must start with `sk-`) | SealedSecret |
| `DATABASE_URL` | Postgres connection string | SealedSecret |
| `NVIDIA_API_KEY` | NVIDIA NIM API key | SealedSecret |
| `REDIS_HOST` | Redis hostname | `redis.litellm.svc.cluster.local` |
| `REDIS_PORT` | Redis port | `6379` |

### Important Settings (via env vars)

| Setting | Value | Reason |
|---------|-------|--------|
| `LITELLM_SETTINGS_DROP_PARAMS` | `true` | Drop unsupported params instead of returning 400 (NVIDIA NIM ignores some OpenAI fields) |
| `LITELLM_GENERAL_SETTINGS_STORE_MODEL_IN_DB` | `true` | Persist model additions to Postgres so they survive pod restarts |
| `LITELLM_GENERAL_SETTINGS_USE_SHARED_HEALTH_CHECK` | `true` | Share health check state across replicas |

## Future Source Control Option

If you prefer to manage models via source control in the future, you can create a ConfigMap from the template below.

### Template ConfigMap

```yaml
# apps/litellm/configmap-litellm.yaml
# TEMPLATE: Copy this to a ConfigMap if you want to manage models via source control.
# NOTE: This template only contains model_list. Infrastructure settings (redis, master_key, etc.)
# are managed via environment variables.
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-config
  namespace: litellm
data:
  config.yaml: |
    model_list:

      # ── Tier 1: NVIDIA Build ──────────────────────────────────────────────

      # Primary coder — large MoE, excels at code generation and completion
      - model_name: qwen-coder-480b
        litellm_params:
          model: nvidia_nim/qwen/qwen-coder-480b-a35b-instruct
          api_key: os.environ/NVIDIA_API_KEY

      # Agentic coding — optimised for multi-step tool-use loops
      - model_name: devstral-2
        litellm_params:
          model: nvidia_nim/mistralai/devstral-2-123b-instruct-2512
          api_key: os.environ/NVIDIA_API_KEY

      # General reasoning and orchestration
      - model_name: mistral-nemotron
        litellm_params:
          model: nvidia_nim/mistralai/mistral-nemotron
          api_key: os.environ/NVIDIA_API_KEY

      # ── Tier 2: NVIDIA Build (benchmark candidates) ───────────────────────

      - model_name: minimax-m2.7
        litellm_params:
          model: nvidia_nim/minimaxai/minimax-m2.7
          api_key: os.environ/NVIDIA_API_KEY

      - model_name: glm-4.7
        litellm_params:
          model: nvidia_nim/z-ai/glm-4.7
          api_key: os.environ/NVIDIA_API_KEY

      # ── Embeddings ────────────────────────────────────────────────────────

      # Code embedding — use with /v1/embeddings, NOT /v1/chat/completions.
      # Verify the full model ID on build.nvidia.com; if requests fail with
      # model-not-found, the ID may need the nvidia/ org prefix (already set here).
      - model_name: nv-embedcode-7b-v1
        litellm_params:
          model: nvidia_nim/nvidia/nv-embedcode-7b-v1
          api_key: os.environ/NVIDIA_API_KEY
        model_info:
          mode: embedding

    router_settings:
      # Cascading fallbacks across NVIDIA Build models. LiteLLM works through
      # each list in order and stops at the first success.
      # Embedding model excluded — no fallback applies to embedding endpoints.
      #
      # Priority order: devstral-2 → qwen-coder-480b → mistral-nemotron → glm-4.7 → minimax-m2.7
      #
      # Each entry defines the full remaining chain from that model's position,
      # so whichever model a client calls directly, they get the same ordered
      # cascade from that point onward.
      fallbacks:
        - {"devstral-2":       ["qwen-coder-480b", "mistral-nemotron", "glm-4.7", "minimax-m2.7"]}
        - {"qwen-coder-480b":  ["mistral-nemotron", "glm-4.7", "minimax-m2.7"]}
        - {"mistral-nemotron": ["glm-4.7", "minimax-m2.7"]}
        - {"glm-4.7":          ["minimax-m2.7"]}

    litellm_settings:
      # Drop unknown/unsupported parameters instead of returning a 400. Needed
      # because OpenAI-native clients often send fields NVIDIA NIM ignores.
      drop_params: true

    general_settings:
      # master_key is injected via the LITELLM_MASTER_KEY env var (from the
      # litellm SealedSecret). Must start with "sk-".
      master_key: os.environ/LITELLM_MASTER_KEY
      # Persist model additions and key management state to Postgres so changes
      # made via the UI survive pod restarts. DATABASE_URL is injected via env var.
      store_model_in_db: true
      # Redis is required for correct multi-replica behaviour. Without it:
      # - Rate limits are tracked per-pod (limits can be exceeded cluster-wide)
      # - Both pods run health checks against every upstream model independently
      # - Spend tracking emits duplicate events
      # - Prisma migration lock is unavailable (falling back to Postgres advisory locks)
      # Use host/port (not redis_url) — documented to be ~80 RPS faster.
      redis_host: redis.litellm.svc.cluster.local
      redis_port: 6379
      # Share health check state across replicas so only one pod per interval
      # actually pings upstream models.
      use_shared_health_check: true
```

### To Re-enable Source Control

1. Copy the template above to `apps/litellm/configmap-litellm.yaml`
2. Commit and push to Git
3. ArgoCD will sync the ConfigMap automatically

## Troubleshooting

### Pod not starting

```bash
kubectl describe pod -n litellm -l app=litellm
kubectl logs -n litellm -l app=litellm
```

### Models not appearing in UI

1. Verify the database is accessible:
   ```bash
   kubectl get pods -n litellm
   kubectl logs -n litellm deployment/litellm | grep -i database
   ```

2. Check that `store_model_in_db` is set to `true` in the environment

3. Verify the SealedSecret is unsealed:
   ```bash
   kubectl get secret -n litellm
   ```

### NVIDIA API errors

1. Verify the NVIDIA_API_KEY is set correctly:
   ```bash
   kubectl get secret -n litellm -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d
   ```

2. Test the API key directly:
   ```bash
   curl -X POST https://integrate.api.nvidia.com/v1/chat/completions \
     -H "Authorization: Bearer $NVIDIA_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{"model": "nvidia_nim/qwen/qwen-coder-480b-a35b-instruct", "messages": [{"role": "user", "content": "test"}]}'
   ```

### Redis connection issues

```bash
kubectl get pods -n litellm
kubectl logs -n litellm deployment/redis
```

### LiteLLM UI not accessible

1. Check the IngressRoute:
   ```bash
   kubectl get ingressroute -n litellm
   kubectl describe ingressroute -n litellm litellm
   ```

2. Check Traefik logs:
   ```bash
   kubectl logs -n traefik deployment/traefik