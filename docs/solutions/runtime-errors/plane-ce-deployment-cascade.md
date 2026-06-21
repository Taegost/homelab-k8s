---
title: "Plane CE Deployment Cascade — 12 Failures in One App"
date: 2026-06-21
category: runtime-errors
module: plane
problem_type: runtime_error
component: tooling
symptoms:
  - "Multiple pods in CrashLoopBackOff after initial deployment"
  - "RabbitMQ OOMKilled despite low actual memory usage"
  - "Django management commands failing with SECRET_KEY env variable is required"
  - "WebSocket server returning 404 on every HTTP health probe"
  - "File uploads failing with Failed to upload image"
root_cause: config_error
resolution_type: config_change
severity: high
tags:
  - plane
  - capabilities
  - probes
  - environment-variables
  - traefik
  - cors
  - rabbitmq
---

# Plane CE Deployment Cascade — 12 Failures in One App

## Problem

Deploying Plane CE v1.3.1 as custom Kubernetes manifests encountered 12 distinct failures across capabilities, memory management, probe semantics, environment variable wiring, Traefik routing, and a frontend React Router bug. Each fix revealed the next failure underneath.

## Symptoms

- 5+ pods in `CrashLoopBackOff` immediately after initial deployment
- RabbitMQ kernel OOM-killed repeatedly
- Django commands crashing: `CommandError: SECRET_KEY env variable is required`
- `AttributeError: 'NoneType' object has no attribute 'startswith'` in redis connection
- Admin setup page shows blank page after clicking "Get Started"
- File uploads returning 405 from Traefik

## What Didn't Work

- **Initial deployment with minimal security context** — nginx workers crashed without `SETGID`/`SETUID`
- **Adding only `CAP_CHOWN`** — missed `SETGID`/`SETUID` for nginx and `DAC_OVERRIDE` for RabbitMQ
- **Probe path `/api/health/`** — does not exist in Plane v1.3.1
- **HTTP probes on plane-live** — WebSocket-only server returns 404 on all HTTP paths
- **Clearing `CORS_ALLOWED_ORIGINS` to allow all** — set `CSRF_TRUSTED_ORIGINS=[]`, blocking all origins
- **Traefik `PathPrefix('/uploads/')`** — trailing slash does not match bare `/uploads` in presigned URLs
- **Traefik redirect middleware for `/god-mode`** — React Router basename mismatch is upstream bug

## Solution

### Layer 1: Capabilities

Nginx-based containers need `CHOWN`, `SETGID`, `SETUID`. RabbitMQ additionally needs `DAC_OVERRIDE` for probe commands to read the mode-0600 Erlang cookie.

### Layer 2: Memory

```yaml
# configmap-rabbitmq.yaml
data:
  rabbitmq.conf: |
    vm_memory_high_watermark.absolute = 500MB
```

Container limit bumped to 768Mi.

### Layer 3: Probe configuration

| Service | Probe Type | Path/Config | Why |
|---------|-----------|-------------|-----|
| plane-api | HTTP | `/` (returns 200) | `/api/health/` does not exist |
| plane-space | HTTP | `/spaces/` | Router basename is `/spaces/` |
| plane-live | TCP socket | N/A | WebSocket-only server |
| RabbitMQ | Exec | `timeoutSeconds: 10` | Default 1s kills healthy pods |

### Layer 4: Environment variables

- **SECRET_KEY**: Mapped from `live-server-secret-key` key (not `secret-key`)
- **REDIS_URL**: Full `redis://` URL — Plane uses `from_url()`, not individual vars
- **API_BASE_URL**: Required by plane-live for startup validation
- **plane-live**: Had zero env blocks — added full configuration

### Layer 5: Traefik routing

Added `PathPrefix('/uploads')` (no trailing slash) routing to MinIO.

### Layer 6: CORS/CSRF

Reverted to explicit origin instead of wildcard.

### Layer 7: ArgoCD Job handling

Manual `kubectl delete job plane-migrator` required before ArgoCD could sync updated Job spec.

## Why This Works

Each layer was a distinct failure mode that masked the next. The capabilities fix unblocked nginx but exposed the RabbitMQ cookie issue. The memory fix unblocked RabbitMQ boot but exposed probe timeouts. The deployment required solving all 12 issues — partial fixes produced pods that appeared healthy but crashed on specific operations.

## Prevention

- **Pre-deployment checklist**: verify probe paths, verify all env vars, check capability requirements, test IngressRoute rules
- **When dropping ALL capabilities, trace every binary** in the process tree
- **Never use default `timeoutSeconds: 1` for exec probes** — 10s minimum
- **For memory-aware apps, always set absolute memory thresholds**
- **Deploy Jobs with `ttlSecondsAfterFinished`** for automatic cleanup

## Related

- `docs/solutions/runtime-errors/rabbitmq-fsgroup-erlang-cookie.md` — detailed RabbitMQ cookie conflict
- `docs/troubleshooting/troubleshooting-plane.md` — full troubleshooting runbook
- `apps/plane/` — all Plane deployment manifests
