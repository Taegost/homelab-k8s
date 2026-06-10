# Plane Troubleshooting

Plane CE deployment issues and resolutions. All issues occurred during initial deployment of Plane v1.3.1 (June 2026).

---

## TL;DR — what actually went wrong

| Incident | Looked like | Actually was | Fix |
|----------|-------------|--------------|-----|
| RabbitMQ crash-loop (2026-06-09) | OOMKill — RabbitMQ memory too high | RabbitMQ reads `/proc/meminfo` (host 13.6GB) not cgroup limit (256Mi), computes watermark = 5.4GB, kernel OOMKills at 256Mi | Set `vm_memory_high_watermark.absolute = 500MB` via ConfigMap; bump container limit to 768Mi |
| RabbitMQ crash-loop round 2 (2026-06-09) | RabbitMQ service unstable | `rabbitmq-diagnostics` probes run as root but `.erlang.cookie` is mode 0600 owned by rabbitmq. Without `CAP_DAC_OVERRIDE`, root respects file permissions — can't read cookie, probe always fails | Add `DAC_OVERRIDE` capability |
| RabbitMQ crash-loop round 3 (2026-06-09) | Still crashing after DAC fix | Kubernetes default `timeoutSeconds: 1` on exec probes. `rabbitmq-diagnostics` takes 2-5s under CPU load, probe times out before command completes | Set `timeoutSeconds: 10` on all RabbitMQ probes; bump CPU 500m→1000m |
| plane-admin, plane-web crash (2026-06-09) | Nginx worker crash | `setgid(101) failed: Operation not permitted` — nginx workers call `setgid()` to drop from root to nginx user. `CAP_SETGID` and `CAP_SETUID` were dropped | Add `SETGID` + `SETUID` capabilities |
| plane-live crash (2026-06-09) | No logs, connection refused on port 3000 | Pod had zero `envFrom`/`env` blocks — no configuration injected at all. Then missing `API_BASE_URL` env var (required for startup validation). Then HTTP probes returned 404 on all paths (server is WebSocket-based) | Add `envFrom` + `env` blocks; add `API_BASE_URL` to ConfigMap; switch probes to TCP socket |
| plane-space crash (2026-06-09) | CrashLoopBackOff with Readiness probe failure | Router `basename="/spaces/"` — probe hit `/` returning 404 (≥400 = Kubernetes probe failure). Then space pages called API backend which was down, causing probe timeout | Change probe path to `/spaces/`; add `timeoutSeconds: 10` to probes |
| plane-api crash (2026-06-09) | CrashLoopBackOff — connection refused to RabbitMQ | Chain of cascading failures: RabbitMQ unstable → Celery tasks fail → API `register_instance` management command crashes on startup. Then `SECRET_KEY` env var was missing (mapped to wrong Secret key). Then probe path `/api/health/` doesn't exist in Plane v1.3.1 — returns 404 | Fix RabbitMQ (above); map `SECRET_KEY` to existing `live-server-secret-key` Secret key; change probe path to `/` |
| ArgoCD sync stuck (2026-06-09) | OutOfSync — new migrator Job can't be applied | Kubernetes Jobs have immutable `spec.template`. ArgoCD tried to update existing Completed Job with new env vars → rejected | `kubectl delete job plane-migrator -n plane` — ArgoCD recreates with updated spec |

---

## RabbitMQ

### Container OOMKill despite low memory usage

**Symptom:** RabbitMQ pod enters `CrashLoopBackOff`. Logs show system memory alarm firing at startup despite the container using far less memory than its limit. The container is OOMKilled by the kernel.

**Cause:** RabbitMQ reads `/proc/meminfo` which reports host-level RAM, NOT the container's cgroup memory limit. RabbitMQ computes `vm_memory_high_watermark` as 40% of host RAM (5.4GB on a 13.6GB host) and allocates freely until the kernel OOMKills it at the container limit (originally 256Mi).

**Fix — set absolute memory watermark below the container limit:**

Create a ConfigMap overriding the watermark to an absolute value:

```yaml
# configmap-rabbitmq.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rabbitmq-config
  namespace: plane
data:
  99-memory.conf: |
    vm_memory_high_watermark.absolute = 500MB
```

Mount it in the Deployment:
```yaml
volumeMounts:
  - name: rabbitmq-config
    mountPath: /etc/rabbitmq/conf.d/99-memory.conf
    subPath: 99-memory.conf
volumes:
  - name: rabbitmq-config
    configMap:
      name: rabbitmq-config
```

Container limit must exceed the absolute watermark by enough for Erlang VM overhead (~200Mi). Recommended: 768Mi limit with 500MB watermark.

See `apps/plane/configmap-rabbitmq.yaml` and `apps/plane/deployment-rabbitmq.yaml`.

### `rabbitmq-diagnostics` always fails — probes never pass

**Symptom:** RabbitMQ server boots successfully (port 5672 open, `rabbitmqctl status` shows healthy node) but the pod stays 0/1 ready. Startup/liveness/readiness probes all use `rabbitmq-diagnostics check_running` which consistently fails. Events show: `Startup probe failed: command timed out after 1s`.

**Two-part root cause:**

1. **`CAP_DAC_OVERRIDE` missing:** `rabbitmq-diagnostics` probes run as root inside the container. The `.erlang.cookie` file is mode `0600` owned by `rabbitmq:rabbitmq` (UID 100, GID 101). Root normally bypasses file permissions via `CAP_DAC_OVERRIDE`, but the container drops ALL capabilities. Without this capability, root respects file permissions and cannot read the cookie — the diagnostics CLI fails.

2. **Probe timeout too short:** Kubernetes default `timeoutSeconds: 1` on exec probes. `rabbitmq-diagnostics` commands take 2-5 seconds to respond under CPU load (Erlang distribution setup, EPMD queries). The probe times out after 1 second even when the command would succeed given enough time.

**Fix:**

```yaml
# Container capabilities — add DAC_OVERRIDE
securityContext:
  capabilities:
    add:
      - CHOWN
      - DAC_OVERRIDE
      - SETGID
      - SETUID

# All probes — set timeoutSeconds: 10
startupProbe:
  exec:
    command: ["rabbitmq-diagnostics", "check_running"]
  failureThreshold: 20
  periodSeconds: 10
  timeoutSeconds: 10
livenessProbe:
  exec:
    command: ["rabbitmq-diagnostics", "check_running"]
  periodSeconds: 30
  failureThreshold: 3
  timeoutSeconds: 10
readinessProbe:
  exec:
    command: ["rabbitmq-diagnostics", "check_port_connectivity"]
  periodSeconds: 10
  timeoutSeconds: 10
```

**Resource requirements:** RabbitMQ's Erlang BEAM VM uses ~500m CPU during steady state but spikes near 1000m during boot (JIT compilation, Mnesia initialization). Set CPU limit to at least 1000m to avoid throttled boot and probe timeouts.

---

## Nginx Frontends (plane-admin, plane-web)

### `setgid(101) failed (1: Operation not permitted)`

**Symptom:** Container starts, nginx entrypoint completes, then nginx workers crash immediately:
```
setgid(101) failed (1: Operation not permitted)
worker process 30 exited with fatal code 2 and cannot be respawned
```

**Cause:** Nginx workers call `setgid(101)` and `setuid()` to drop from root to the nginx user (UID 101). The container drops ALL capabilities and only adds back `CHOWN` (for the entrypoint's chown of `/var/cache/nginx/client_temp`). `setgid()` requires `CAP_SETGID`; `setuid()` requires `CAP_SETUID`.

**Fix:** Add both capabilities alongside `CHOWN`:
```yaml
securityContext:
  capabilities:
    add:
      - CHOWN
      - SETGID
      - SETUID
```

Applies to: `apps/plane/deployment-plane-admin.yaml`, `apps/plane/deployment-plane-web.yaml`.

---

## Plane Live Server (plane-live)

### No logs, connection refused — missing configuration

**Symptom:** Pod starts but produces no logs. Liveness and readiness probes report `connection refused` on port 3000. Container restarts repeatedly.

**Root cause (three-layer):**

1. **No env vars injected:** The deployment had zero `envFrom` or `env` blocks. The Node.js process started without any database/API/Redis configuration and crashed silently.

2. **Missing required `API_BASE_URL`:** After adding env vars, the live server validates environment on startup. `API_BASE_URL` was required but not present in the ConfigMap. Error: `Invalid environment variables: API_BASE_URL: Required`.

3. **HTTP probes always fail:** The live server is WebSocket-based (HocusPocus + Express) and does not serve HTTP on any path. All HTTP GET probes returned 404, which Kubernetes treats as failure. TCP socket probes are the correct choice.

**Fix:**

```yaml
# Add configuration injection (same as other Plane pods)
envFrom:
  - configMapRef:
      name: plane
  - secretRef:
      name: plane
env:
  - name: SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: plane
        key: live-server-secret-key
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: plane
        key: database-password
  # ... AWS, LIVE_SERVER_SECRET_KEY, RABBITMQ_PASSWORD

# Use TCP socket probes, not HTTP
livenessProbe:
  tcpSocket:
    port: 3000
  periodSeconds: 30
  failureThreshold: 3
readinessProbe:
  tcpSocket:
    port: 3000
  periodSeconds: 10
```

Also add `API_BASE_URL` to the ConfigMap:
```yaml
# In configmap-plane.yaml
API_BASE_URL: "http://plane-api.plane.svc.cluster.local:8000"
```

See: `apps/plane/deployment-plane-live.yaml`, `apps/plane/configmap-plane.yaml`.

---

## Plane Space Server (plane-space)

### Readiness probe 404 — router basename mismatch

**Symptom:** Pod crashes with `CrashLoopBackOff`. Events: `Readiness probe failed: HTTP probe failed with statuscode: 404`.

**Cause:** The space server's React Router has `basename="/spaces/"`. Kubernetes probes hit `/`, which the router rejects with 404. Kubernetes treats any HTTP status ≥ 400 as probe failure.

**Fix:** Change probe paths from `/` to `/spaces/`:
```yaml
livenessProbe:
  httpGet:
    path: /spaces/
    port: 3000
readinessProbe:
  httpGet:
    path: /spaces/
    port: 3000
```

**Secondary issue — probe timeout:** Space pages call the API backend to render. If the API is slow or down, responses can take 5-10 seconds. The default 1s probe timeout causes spurious failures. Add `timeoutSeconds: 10` to probes.

See: `apps/plane/deployment-plane-space.yaml`.

---

## Plane API (plane-api)

### SECRET_KEY env var missing

**Symptom:** API pod crashes with `CommandError: SECRET_KEY env variable is required.` Django management command `register_instance` fails during startup before Gunicorn workers start.

**Cause:** The `SECRET_KEY` env var was not mapped. Plane uses `live-server-secret-key` (already present in the sealed secret) for Django's cryptographic signing. No new secret value needed — just the env var mapping.

**Fix:** Add explicit env var mapping in the Deployment:
```yaml
env:
  - name: SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: plane
        key: live-server-secret-key
```

Applies to all Django-based pods: `plane-api`, `plane-worker`, `plane-beatworker`, and `plane-migrator`.

### Health probe returns 404

**Symptom:** Gunicorn workers boot successfully, API serves requests, but probes fail: `GET /api/health/ 404`. Pod stays 0/1 ready.

**Cause:** Plane v1.3.1 does not have an `/api/health/` endpoint. The Django admin login at `/` returns 200 and is a valid liveness check.

**Fix:** Change all probe paths from `/api/health/` to `/`:
```yaml
startupProbe:
  httpGet:
    path: /
    port: 8000
```

See: `apps/plane/deployment-plane-api.yaml`.

---

## ArgoCD Sync

### Job update fails — immutable spec.template

**Symptom:** ArgoCD shows `OutOfSync` or `SyncFailed`. The `plane-migrator` Job cannot be updated because Kubernetes Jobs have immutable `spec.template`.

**Cause:** The migrator Job was deployed, completed, and then the manifest was updated (added `SECRET_KEY` env var). ArgoCD tries to apply the updated Job spec to the existing completed Job, which Kubernetes rejects.

**Fix:** Delete the existing Job — ArgoCD recreates it with the updated spec:
```bash
kubectl delete job plane-migrator -n plane
```

ArgoCD will create a fresh Job on next sync. After completion, set `ttlSecondsAfterFinished` on the Job manifest so old Jobs auto-cleanup (already set to 3600 in `apps/plane/job-plane-migrator.yaml`).

---

## Resource Recommendations

Minimum resource limits for Plane v1.3.1 in a homelab environment:

| Component | CPU Limit | Memory Limit | Notes |
|-----------|-----------|--------------|-------|
| rabbitmq | 1000m | 768Mi | BEAM spikes during boot; set `vm_memory_high_watermark.absolute` |
| plane-api | 1000m | 1Gi | Django with Gunicorn 2 workers |
| plane-worker | 500m | 768Mi | Celery worker — memory varies by task type |
| plane-beatworker | 200m | 256Mi | Celery beat scheduler — lightweight |
| plane-web | 200m | 256Mi | nginx serving Next.js static |
| plane-admin | 200m | 256Mi | nginx serving admin panel |
| plane-space | 200m | 256Mi | Node.js React Router server |
| plane-live | 200m | 256Mi | Node.js WebSocket server |
| valkey | 200m | 192Mi | With `--maxmemory 96mb` |
| minio | 500m | 512Mi | S3-compatible storage |
| plane-migrator | 500m | 512Mi | One-shot Django migration Job |
