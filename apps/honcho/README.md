# Honcho — Manual Runbook

## tiktoken Tokenizer Cache

### Background

Honcho imports Python's `tiktoken` library at startup. Tiktoken downloads the
`o200k_base` BPE merge file (~4 MB) from `openaipublic.blob.core.windows.net`
(Azure Blob Storage) on first use. This causes two problems:

1. **NetworkPolicy** — the honcho namespace has default-deny egress. Azure Blob
   Storage IPs rotate frequently (roughly weekly), making `ipBlock` rules
   unreliable. Allowing broad CIDR ranges defeats the purpose of the policy.

2. **Startup failures** — without network access, the pod crashes with
   `ConnectionError: HTTPSConnectionPool(host='openaipublic.blob.core.windows.net')`
   and enters CrashLoopBackOff.

### Solution

A Longhorn RWM PVC (`honcho-tiktoken-cache`) is mounted into both the API and
deriver deployments at `/home/app/.tiktoken_cache`. The `TIKTOKEN_CACHE_DIR`
environment variable tells tiktoken to read from this path instead of fetching
over the network. The file must be pre-downloaded into the PVC manually.

### Initial Setup (one-time)

After ArgoCD syncs the new PVC and updated deployments, the pods will be in
CrashLoopBackOff because the PVC is empty. Pre-download the tokenizer file:

```bash
# 1. Download the tokenizer file locally
curl -fsSL https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken -o /tmp/o200k_base.tiktoken

# 2. Verify the download (should be ~4 MB)
ls -lh /tmp/o200k_base.tiktoken

# 3. Wait for at least one honcho-api pod to exist (even in CrashLoopBackOff)
kubectl wait --for=condition=Ready pod -n honcho -l app=honcho-api --timeout=60s 2>/dev/null || true

# 4. Copy the file into the PVC via the API pod
#    (the PVC is mounted at /home/app/.tiktoken_cache in both pods)
POD=$(kubectl get pod -n honcho -l app=honcho-api -o jsonpath='{.items[0].metadata.name}')
kubectl cp /tmp/o200k_base.tiktoken honcho/$POD:/home/app/.tiktoken_cache/o200k_base.tiktoken

# 5. Restart both deployments
kubectl rollout restart deployment -n honcho honcho-api
kubectl rollout restart deployment -n honcho honcho-deriver

# 6. Verify pods start successfully
kubectl get pods -n honcho
```

### After Node Reschedule or PVC Re-creation

If the PVC is deleted or the pods move to a node where the PVC hasn't been
mounted, repeat the steps above. The PVC uses `ReadWriteMany` so the file
persists across pod restarts on the same node — this should only be needed if
the PVC itself is recreated.

### Why Not an Egress Rule?

| Approach | Pros | Cons |
|---|---|---|
| `ipBlock` egress rule | Simple, no manual steps | Azure Blob IPs rotate weekly; rule breaks frequently |
| Broad Azure CIDR | More stable than single IP | Still not guaranteed; overly permissive |
| Pre-downloaded PVC | No external dependency; works forever | Manual one-time setup step |

The PVC approach was chosen because it eliminates the external dependency entirely
and aligns with the NetworkPolicy default-deny egress posture.

## pgvector Extension

### Background

Honcho's Alembic migrations run `CREATE EXTENSION IF NOT EXISTS vector` on
startup. The `vector` (pgvector) extension requires PostgreSQL superuser to
create, but the `honcho` role is not a superuser (by design).

### Fix

Pre-create the extension as the postgres superuser:

```bash
# Find the primary pod
kubectl get pods -n postgres -l role=primary

# Create the extension (replace <primary-pod> with the pod name from above)
kubectl exec -n postgres <primary-pod> -- psql -U postgres -d honcho -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

This only needs to be done once per database lifetime. If the database is
recreated, run this command again before the honcho pods start.

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
# Find the primary pod
kubectl get pods -n postgres -l role=primary

# Set the password (replace <primary-pod> and <password>)
# The password must match what's in the honcho-db-credentials secret
kubectl exec -n postgres <primary-pod> -- psql -U postgres -c "ALTER ROLE honcho PASSWORD '<password>';"
```
