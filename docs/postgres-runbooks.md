# Postgres Runbooks

This document covers day-two operations for the shared PostgreSQL 18 instance managed by CloudNativePG (CNPG).

For disaster recovery (cluster loss, full restore from backup), see [disaster-recovery.md](disaster-recovery.md).

---

## Architecture overview

| Component | Detail |
|-----------|--------|
| Operator | CloudNativePG (CNPG) |
| Postgres version | 18.3 |
| Instances | 2 (primary + 1 replica, anti-affinity across nodes) |
| Storage | `local-path` PVCs — CNPG streaming replication provides redundancy |
| Connection pooling | PgBouncer via CNPG `Pooler` (transaction mode) |
| WAL archiving / backups | **Deferred** — will be configured when an S3-compatible endpoint is available |
| App connection string | `postgres-pooler-rw.postgres.svc.cluster.local:5432` |
| Direct cluster string | `postgres-rw.postgres.svc.cluster.local:5432` (avoid for normal app use) |

Applications must connect through PgBouncer (`postgres-pooler-rw`), not directly to the cluster. The only exception is applications that use `SET LOCAL`, advisory locks, or `LISTEN/NOTIFY`, which are incompatible with PgBouncer's transaction pooling mode.

### Per-application roles

Every application gets its own PostgreSQL role (user) and owns its own database. This is not optional — it enforces isolation at the database layer: an application's credentials only grant access to its own database, so a misconfiguration or credential leak in one app cannot expose another app's data.

Roles are declared in `spec.managed.roles` in `apps/postgres/cluster-postgres.yaml`. CNPG has no standalone Role CRD — this is the only supported declarative mechanism. See the [CNPG declarative role management docs](https://cloudnative-pg.io/documentation/current/declarative_role_management/) for the full list of available fields.

---

## First-time setup

Seal the superuser secret, then commit everything to `main`:

```bash
# Seal superuser credentials
kubeseal --format yaml < apps/postgres/secret-postgres-superuser.yaml > apps/postgres/sealedsecret-postgres-superuser.yaml
rm apps/postgres/secret-postgres-superuser.yaml

# Commit and push
git add apps/
git commit -m "Add shared Postgres cluster with CNPG"
git push
```

ArgoCD will sync in wave order: CNPG operator (wave 0) → Postgres cluster (wave 1). The cluster takes 2–3 minutes to initialize on first sync.

Verify the cluster is healthy:

```bash
kubectl get cluster -n postgres
# NAME       AGE   INSTANCES   READY   STATUS                     PRIMARY
# postgres   3m    2           2       Cluster in healthy state   postgres-1
```

---

## Enabling backups (deferred)

WAL archiving and scheduled base backups require an S3-compatible endpoint. When that is set up:

1. Add a `barmanObjectStore` block to `apps/postgres/cluster.yaml` pointing at the endpoint
2. Create and seal `apps/postgres/secret-backup-credentials.yaml` with the access key and secret
3. Re-add `apps/postgres/scheduled-backup.yaml` with a `ScheduledBackup` CRD
4. Update the disaster recovery section in `docs/disaster-recovery.md`

CNPG's barman supports any S3-compatible endpoint via `endpointURL`. Path-style addressing is required for most self-hosted S3 implementations.

---

## Adding a new application (no existing database)

Use this workflow when deploying a fresh application that needs a new Postgres database.

### Phase 1 — Provision the database

Create the ArgoCD `Application` manifest and database resources, but do not add the application's `Deployment` yet.

**1. Create the app folder with the database manifest:**

```yaml
# apps/<appname>/database-<appname>.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: <appname>
  namespace: postgres
spec:
  name: <appname>
  owner: <appname>
  cluster:
    name: postgres
```

```yaml
# apps/<appname>/secret-<appname>-db-credentials.yaml
# Fill in a strong password, then seal:
#   kubeseal --format yaml < apps/<appname>/secret-<appname>-db-credentials.yaml \
#     > apps/<appname>/sealedsecret-<appname>-db-credentials.yaml
#   rm apps/<appname>/secret-<appname>-db-credentials.yaml
apiVersion: v1
kind: Secret
metadata:
  name: <appname>-db-credentials
  namespace: postgres
type: kubernetes.io/basic-auth
stringData:
  username: <appname>
  password: PLACEHOLDER_CHANGE_ME
```

**2. Add the role to `apps/postgres/cluster-postgres.yaml` under `spec.managed.roles`:**

```yaml
- name: <appname>
  login: true
  superuser: false
  createdb: false
  createrole: false
  inherit: true
  connectionLimit: -1
  passwordSecret:
    name: <appname>-db-credentials
```

**3. Create the ArgoCD Application manifest (pointing at the app folder):**

```yaml
# apps/manifests/<appname>.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <appname>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/Taegost/homelab-k8s
    targetRevision: HEAD
    path: apps/<appname>
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: <appname>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**4. Seal the credentials, commit, and sync:**

```bash
kubeseal --format yaml < apps/<appname>/secret-<appname>-db-credentials.yaml \
  > apps/<appname>/sealedsecret-<appname>-db-credentials.yaml
rm apps/<appname>/secret-<appname>-db-credentials.yaml

git add apps/
git commit -m "Add <appname>: provision database and role"
git push
```

Sync ArgoCD and verify the database was created and the role is active:

```bash
kubectl get database -n postgres
kubectl get cluster postgres -n postgres -o jsonpath='{.status.managedRolesStatus}' | jq
```

### Phase 2 — Deploy the application

Add the application's `Deployment`, `Service`, `IngressRoute`, and any other manifests to `apps/<appname>/`. The connection string for the app to use:

```
host:     postgres-pooler-rw.postgres.svc.cluster.local
port:     5432
database: <appname>
user:     <appname>
password: (from sealedsecret-db-credentials)
```

Commit, push, and sync. ArgoCD picks up the new manifests automatically.

### Phase 3 — Smoke test

Verify the application is healthy and can read/write its database. Once confirmed, the deployment is complete.

---

## Migrating an existing application

Use this workflow when moving an application that already has a database (on any Postgres version) into the shared cluster.

The migration is split into three phases to work with ArgoCD rather than against it. The source database stays live throughout as a rollback point — do not decommission it until the smoke test passes.

### Phase 1 — Provision the database

Follow Phase 1 from [Adding a new application](#adding-a-new-application-no-existing-database) above. At the end of this phase:

- The ArgoCD `Application` exists and is synced
- The `Database` CRD exists in the `postgres` namespace
- The role exists in `spec.managed.roles` in `cluster-postgres.yaml` and is confirmed active
- The application's `Deployment` does **not** exist yet
- The source system is still running normally

### Phase 2 — Migrate the data

Use `pg_dump` / `pg_restore`. This is a logical dump and works across major Postgres versions.

```bash
# On a machine that can reach both the source DB and the cluster:

# 1. Dump from source
pg_dump \
  --host=<source_host> \
  --username=<source_user> \
  --dbname=<source_db> \
  --format=custom \
  --file=/tmp/<appname>.dump

# 2. Restore into the new cluster (connect via the cluster service, not pooler,
#    to avoid transaction-mode pooling restrictions during restore)
pg_restore \
  --host=postgres-rw.postgres.svc.cluster.local \
  --username=<appname> \
  --dbname=<appname> \
  --no-owner \
  --no-privileges \
  /tmp/<appname>.dump

# Clean up the dump file
rm /tmp/<appname>.dump
```

If you cannot reach the cluster service directly, run the restore from inside the cluster:

```bash
kubectl run pg-restore --rm -it --image=postgres:18 --restart=Never -- bash
# Then run the pg_restore command above from inside the pod
```

**Verify the data before continuing:**

```bash
# Spot-check row counts on key tables
kubectl exec -it -n postgres postgres-1 -- psql -U postgres -d <appname> -c "\dt"
kubectl exec -it -n postgres postgres-1 -- psql -U postgres -d <appname> \
  -c "SELECT COUNT(*) FROM <important_table>;"
```

Compare counts against the source. If anything looks wrong, fix it before proceeding — the source is still live and untouched.

### Phase 3 — Deploy the application and smoke test

1. Stop or put the source application into read-only mode to prevent new writes during cutover
2. Run a final incremental sync if the source had any activity since the initial dump
3. Add the application's `Deployment`, `Service`, `IngressRoute`, etc. to `apps/<appname>/`
4. Update the application's database connection string to point at the new cluster
5. Commit, push, sync ArgoCD
6. Smoke test: verify the application is healthy and data looks correct
7. Once confirmed: decommission the source database and application
