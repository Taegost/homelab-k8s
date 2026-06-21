---
title: "LibreChat Deployment — MongoDB Sync Ordering, Env Vars, and NetworkPolicy"
date: 2026-06-21
category: runtime-errors
module: librechat
problem_type: runtime_error
component: tooling
symptoms:
  - "MongoDB cluster bootstrapped with random credentials instead of sealed values"
  - "RAG API crashing with AttributeError on redis connection"
  - "All probes failing with 404 on /api/health"
  - "NetworkPolicy blocking all ingress including Traefik"
  - "Registration blocked despite enabled true in ConfigMap"
root_cause: config_error
resolution_type: config_change
severity: high
tags:
  - librechat
  - mongodb
  - networkpolicy
  - sync-waves
  - environment-variables
  - registration
---

# LibreChat Deployment — MongoDB Sync Ordering, Env Vars, and NetworkPolicy

## Problem

Deploying LibreChat v0.8.5 required integrating five services behind shared MongoDB and PostgreSQL clusters. The deployment encountered a cascade of issues spanning ArgoCD sync ordering, incorrect environment variables, wrong passwords, health probe misconfiguration, NetworkPolicy misconfiguration, and registration config.

## Symptoms

- MongoDB cluster CRD applied before SealedSecrets — operator generated random credentials
- RAG API crashing: `AttributeError: 'NoneType' object has no attribute 'startswith'`
- All probes returning 404 on `/api/health`
- NetworkPolicy blocking all traffic
- Registration returning "not allowed" despite config

## What Didn't Work

- **MongoDB CRD at same wave as SealedSecrets** — race condition
- **`DB_NAME`/`DB_USER`/`DB_PASSWORD` env vars for RAG API** — expects `POSTGRES_DB`/`POSTGRES_USER`/`POSTGRES_PASSWORD`
- **Probe path `/api/health`** — LibreChat exposes `/health` on port 3080
- **`podSelector` without `namespaceSelector`** — matches same namespace only
- **`enabled: true` in ConfigMap** — LibreChat uses `ALLOW_REGISTRATION` env var
- **`allowedDomains: []`** — blocks all; `["*"]` — not valid

## Solution

### MongoDB sync ordering

```yaml
# SealedSecret — wave -3
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
# PerconaServerMongoDB CRD — wave -2
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

When operator had stale credentials, required delete-and-recreate of the CRD.

### RAG API environment variables

```yaml
env:
  - name: POSTGRES_DB        # NOT DB_NAME
    value: librechat_rag
  - name: POSTGRES_USER      # NOT DB_USER
    value: librechat_rag
  - name: POSTGRES_PASSWORD  # NOT DB_PASSWORD
    valueFrom:
      secretKeyRef: ...
  - name: PGVECTOR_CREATE_EXTENSION
    value: "false"           # DDL fails through PgBouncer
  - name: RAG_UPLOAD_DIR
    value: /tmp/uploads
```

### Health probes

```yaml
livenessProbe:
  httpGet:
    path: /health    # NOT /api/health
    port: 3080
```

### NetworkPolicy

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: traefik
        podSelector:
          matchLabels:
            app.kubernetes.io/name: traefik
```

### Registration workflow

1. Set `ALLOW_REGISTRATION=true` env var
2. Set `allowedDomains: ["gmail.com"]`
3. Create first admin account
4. Set `ALLOW_REGISTRATION=false`

## Why This Works

Each fix addressed a distinct failure mode. MongoDB sync ordering ensures secrets decrypt before the CRD reads them. RAG API env var names match upstream expectations. The probe path matches the actual endpoint. The NetworkPolicy uses proper cross-namespace selectors.

## Prevention

- **Verify env var names against upstream docs** before writing manifests
- **Use sync-wave annotations for all resource dependencies**
- **Test health probes with curl** against the running container
- **When NetworkPolicy uses podSelector for another namespace, always pair with namespaceSelector**
- **Deploy incrementally** to isolate failures

## Related

- `docs/mongodb-runbooks.md` — MongoDB operational procedures
- `docs/sealed-secrets.md` — sealed secrets workflow
- `apps/librechat/README.md` — LibreChat documentation
