# n8n HA Migration

This document covers migrating n8n from single-instance mode to queue mode (HA)
with multiple workers. Follow the phases in order — each phase is independently
verifiable and leaves the system in a working state if you stop there.

---

## Background

n8n in single-instance mode runs one process that handles everything: the editor UI,
webhook listener, and workflow execution. This is simple but has no horizontal
scalability and executions block the UI during heavy workloads.

Queue mode separates concerns:
- **Main process** — serves the UI and webhook listener; enqueues workflow executions
- **Worker processes** — pull jobs from the queue and execute workflows

Queue mode requires:
- PostgreSQL (already done)
- Redis (as the job queue broker)
- S3-compatible object storage for binary data (so all workers read/write the same files)
- All custom nodes present in every replica's image (so workers can execute any workflow)

---

## Prerequisites

Before starting, confirm:

- [ ] MinIO (or another S3-compatible endpoint) is deployed and accessible from the cluster
- [ ] A Redis instance is available (deploy one in the `n8n` namespace, or use a shared instance)
- [ ] n8n is healthy in single-instance mode: `kubectl get pods -n n8n`
- [ ] No critical workflows are mid-execution (queue mode restart will interrupt in-flight executions)

---

## Phase 1 — Migrate binary data to S3

Binary data (files produced by workflows) currently writes to the Longhorn PVC at
`/home/node/.n8n/storage/` (the v3 path, adopted from day one via
`N8N_MIGRATE_FS_STORAGE_PATH=true`). This must move to S3 before adding workers,
because workers cannot share an RWO volume.

**1. Copy existing binary data to S3** (if any files exist):

```bash
# Get a shell on the running n8n pod
kubectl exec -it -n n8n deploy/n8n -- sh

# List what's in storage — if empty, skip the copy step
ls /home/node/.n8n/storage/
```

If there are files, copy them to your S3 bucket before proceeding. 
Files left behind will not be accessible to n8n after the switch.

**2. Create a secret for S3 credentials:**

```yaml
# apps/n8n/secret-n8n-s3.yaml — fill in, seal, delete
apiVersion: v1
kind: Secret
metadata:
  name: n8n-s3
  namespace: n8n
type: Opaque
stringData:
  access-key: PLACEHOLDER_CHANGE_ME
  secret-key: PLACEHOLDER_CHANGE_ME
```

```bash
kubeseal --format yaml < apps/n8n/secret-n8n-s3.yaml \
  > apps/n8n/sealedsecret-n8n-s3.yaml
rm apps/n8n/secret-n8n-s3.yaml
```

**3. Update `apps/n8n/deployment-n8n.yaml`:**

Replace `N8N_DEFAULT_BINARY_DATA_MODE: filesystem` with:

```yaml
- name: N8N_DEFAULT_BINARY_DATA_MODE
  value: "s3"
- name: N8N_BINARY_DATA_STORAGE_S3_HOST
  value: "YOUR_S3_ENDPOINT_HOST"    # hostname or IP of your S3-compatible endpoint
- name: N8N_BINARY_DATA_STORAGE_S3_PORT
  value: "9000"                     # adjust to your endpoint's port
- name: N8N_BINARY_DATA_STORAGE_S3_SSL
  value: "false"                    # set to "true" if your endpoint uses HTTPS
- name: N8N_BINARY_DATA_STORAGE_S3_BUCKET_NAME
  value: "n8n"
- name: N8N_BINARY_DATA_STORAGE_S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: n8n-s3
      key: access-key
- name: N8N_BINARY_DATA_STORAGE_S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: n8n-s3
      key: secret-key
```

**4. Commit, push, sync. Verify n8n starts and workflows run correctly.**

After confirming S3 is working, remove the volume mount and volume entry for `n8n-data` from the Deployment,
and delete `apps/n8n/persistentvolumeclaim-n8n-data.yaml`. 

Make sure to sync ArgoCD after that.

---

## Phase 2 — Package custom nodes into a custom image

If you have installed any community or custom nodes via the n8n UI, they live in
the container filesystem and will not be present on new worker replicas unless
baked into the image.

**Skip this phase if you have no custom nodes installed.** Check with:

```bash
kubectl exec -n n8n deploy/n8n -- ls /home/node/.n8n/nodes/
```

**1. Create a Dockerfile** in a new repo directory (e.g. `docker/n8n/`):

```dockerfile
# Extend the official n8n image and install custom nodes at build time.
# All replicas (main + workers) pull this image, ensuring identical environments.
# To add a node: append another npm install line and rebuild.
FROM docker.n8n.io/n8nio/n8n:VERSION

# Install custom nodes — replace with the actual package names
USER root
RUN npm install -g \
    n8n-nodes-some-package \
    n8n-nodes-another-package
USER node
```

Replace `VERSION` with the current n8n version tag from `deployment-n8n.yaml`.

**2. Build and push** to your container registry (ghcr.io, local registry, etc.).

**3. Update the image reference** in `deployment-n8n.yaml` from the stock n8n image
to your custom image. Commit, push, sync.

**4. Verify** that existing workflows using those nodes still execute correctly.

Going forward, adding a new custom node means updating the Dockerfile, rebuilding,
and bumping the image tag — not installing via the UI.

---

## Phase 3 — Enable queue mode

With S3 and custom images in place, the deployment is stateless and ready to scale.

**1. Deploy Redis** in the `n8n` namespace. A minimal single-instance Redis is
sufficient for the job queue (it is not a data store — job loss on Redis restart
just means executions need to be re-triggered, not data loss):

```yaml
# apps/n8n/deployment-redis.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: n8n
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      automountServiceAccountToken: false
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - containerPort: 6379
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: n8n
spec:
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
```

**2. Add queue mode env vars** to `deployment-n8n.yaml`:

```yaml
- name: EXECUTIONS_MODE
  value: "queue"
- name: QUEUE_BULL_REDIS_HOST
  value: "redis.n8n.svc.cluster.local"
- name: QUEUE_BULL_REDIS_PORT
  value: "6379"
```

**3. Confirm the database connection is still using `postgres-rw` (direct).** Queue
mode uses advisory locks, which are incompatible with PgBouncer transaction pooling —
but n8n also sends `statement_timeout` at connection startup, which PgBouncer rejects
even in single-instance mode. The direct connection was set from day one for this
reason; no change needed here.

**4. Change the Deployment strategy** from `Recreate` to `RollingUpdate`.
The RWO volume blocker is gone; rolling updates are now safe.

**5. Commit, push, sync.** Verify the main process starts in queue mode:

```bash
kubectl logs -n n8n deploy/n8n | grep -i queue
# Should show: "Running in queue mode"
```

**6. Add worker replicas** by creating a second Deployment (or scaling the existing
one if you configure it as a worker via `N8N_WORKER=true`). The recommended pattern
is separate Deployments for main and workers so they can scale independently:

```yaml
# apps/n8n/deployment-n8n-worker.yaml
# Copy deployment-n8n.yaml, rename to n8n-worker, add:
#   - name: N8N_WORKER
#     value: "true"
# Workers do not serve the UI or webhooks; remove the readiness/liveness probes
# that hit /healthz if the worker image does not expose that endpoint.
```

---

## Post-Migration Verification

```bash
# All pods running
kubectl get pods -n n8n

# Trigger a test workflow via the editor and confirm it executes
# Check worker logs show job pickup
kubectl logs -n n8n -l app=n8n-worker --tail=50
```

Once confirmed, decommission any legacy infrastructure (old PVC if not already deleted).
