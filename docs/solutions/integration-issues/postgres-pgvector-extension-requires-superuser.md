---
title: pgvector extension requires superuser to create
date: 2026-06-24
category: integration-issues
module: postgres
problem_type: permission_error
component: extensions
symptoms:
  - "permission denied to create extension \"vector\""
  - "Must be superuser to create this extension"
  - Application CrashLoopBackOff on startup after database provisioning
root_cause: permission_model
resolution_type: manual_pre_provisioning
severity: medium
tags: [postgres, cnpg, pgvector, vector, extensions, superuser, honcho]
---

# pgvector extension requires superuser to create

## Problem

Applications that use pgvector (the `vector` extension for PostgreSQL) fail on
startup because their Alembic migrations run `CREATE EXTENSION IF NOT EXISTS vector`,
but the application's database role is non-superuser by design.

## Symptoms

Pod logs show:

```
sqlalchemy.exc.ProgrammingError: (psycopg.errors.InsufficientPrivilege) permission denied to create extension "vector"
HINT:  Must be superuser to create this extension.
[SQL: CREATE EXTENSION IF NOT EXISTS vector]
```

The pod enters CrashLoopBackOff.

## Root Cause

PostgreSQL requires superuser privileges to create most extensions, including
`pgvector`. CNPG managed roles are intentionally non-superuser (the `superuser`
field defaults to `false` in the managed roles spec). This is a security
best practice — application roles should not have superuser access.

There is no way to grant `CREATE EXTENSION` for a specific extension to a
non-superuser role in PostgreSQL. The extension must be created by a superuser
first; once created, all roles in the database can use it.

## Solution

Pre-create the extension as the postgres superuser before the application pods
start:

```bash
kubectl exec -n postgres $(kubectl get pod -n postgres -l role=primary -o jsonpath='{.items[0].metadata.name}') -- psql -U postgres -d APPNAME -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

Then restart the application pods:

```bash
kubectl rollout restart deployment -n NAMESPACE DEPLOYMENT_NAME
```

## Dimension Limitation

pgvector's HNSW and IVFFlat indexes have a hard limit of **2000 dimensions** for
the `vector` type. When selecting an embedding model, ensure the dimension count
stays within this limit if an index is required. See `apps/honcho/README.md` for
an example of how this constraint affected model selection.

## Prevention

When deploying any application that requires PostgreSQL extensions:

1. Check the application's Alembic migrations or startup code for
   `CREATE EXTENSION` statements
2. Pre-create the extension as superuser **before** syncing the application
   Deployment
3. Document the extension requirement in the app's README or the postgres
   runbook

## When to Repeat

Extensions are database-scoped. If the database is dropped and recreated (e.g.,
after deleting and re-syncing the CNPG Database CRD), the extension must be
re-created.

## Related

- [PostgreSQL extensions section in postgres-runbooks.md](../../postgres-runbooks.md#postgresql-extensions)
- Honcho deployment: `apps/honcho/README.md` — tiktoken cache and pgvector steps
