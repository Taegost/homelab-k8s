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
| App connection string | `postgres-pooler.postgres.svc.cluster.local:5432` |
| Direct cluster string | `postgres-rw.postgres.svc.cluster.local:5432` (avoid for normal app use) |

Applications must connect through PgBouncer (`postgres-pooler`), not directly to the cluster. The only exception is applications that use `SET LOCAL`, advisory locks, or `LISTEN/NOTIFY`, which are incompatible with PgBouncer's transaction pooling mode.

### Why local-path instead of Longhorn

CNPG's streaming replication is explicitly designed to be the redundancy layer. Each instance gets its own `local-path` PVC on its local node; CNPG streams WAL continuously between them so both nodes always have a complete, up-to-date copy of the data.

If the primary's node fails, CNPG promotes the replica on the surviving node to primary. The old primary's pod sits `Pending` on the dead node (local-path PVCs are node-pinned by `nodeAffinity`) until the node returns, at which point CNPG resyncs it as the new replica. This is the documented, intended operational model — no manual intervention required in the normal case.

Using Longhorn here would add a second replication layer (block-level across nodes) on top of CNPG's WAL streaming, doubling the write overhead for no practical benefit. The MariaDB cluster uses Longhorn instead because mariadb-operator does not have the same tight coupling to local-path, and Longhorn allows the operator to reschedule pods on any surviving node after a failure without manual PV cleanup. See `docs/mariadb-runbooks.md` for the full comparison.

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
# apps/APPNAME/database-APPNAME.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: APPNAME
  namespace: postgres
spec:
  name: APPNAME
  owner: APPNAME
  cluster:
    name: postgres
```

```yaml
# apps/APPNAME/secret-APPNAME-db-credentials.yaml
# Fill in a strong password, then seal:
#   kubeseal --format yaml < apps/APPNAME/secret-APPNAME-db-credentials.yaml \
#     > apps/APPNAME/sealedsecret-APPNAME-db-credentials.yaml
#   rm apps/APPNAME/secret-APPNAME-db-credentials.yaml
apiVersion: v1
kind: Secret
metadata:
  name: APPNAME-db-credentials
  namespace: postgres
  labels:
    # Required: tells CNPG to watch this secret and re-reconcile the managed
    # role if the secret didn't exist yet at initial sync time (race condition
    # between SealedSecret decryption and CNPG's first reconciliation attempt).
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: APPNAME
  password: PLACEHOLDER_CHANGE_ME
```

> **Password duplication:** If the application reads its database password from a separate app-level Secret (e.g. `apps/APPNAME/secret-APPNAME.yaml`), the key used by that app (for example `DB_PASSWORD`) must contain the **same value** as the password above. Kubernetes pods cannot reference secrets across namespaces, so the credential must appear in both the `postgres`-namespace secret (for CNPG to set the role) and the app-namespace secret (for the pod to connect). Keep them in sync when rotating passwords.

**2. Add the role to `apps/postgres/cluster-postgres.yaml` under `spec.managed.roles`:**

```yaml
- name: APPNAME
  login: true
  superuser: false
  createdb: false
  createrole: false
  inherit: true
  connectionLimit: -1
  passwordSecret:
    name: APPNAME-db-credentials
```

**3. Create the ArgoCD Application manifest (pointing at the app folder):**

```yaml
# apps/manifests/APPNAME.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: APPNAME
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/Taegost/homelab-k8s
    targetRevision: HEAD
    path: apps/APPNAME
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: APPNAME
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**4. Seal the credentials, commit, and sync:**

```bash
# Create the app namespace and postgres namespace if they don't already exist —
# required before sealing. kubeseal hashes the namespace into the ciphertext;
# sealing before the namespace exists produces a secret the controller cannot decrypt.
kubectl create namespace APPNAME --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace postgres --dry-run=client -o yaml | kubectl apply -f -

kubeseal --format yaml < apps/APPNAME/secret-APPNAME-db-credentials.yaml > apps/APPNAME/sealedsecret-APPNAME-db-credentials.yaml
rm apps/APPNAME/secret-APPNAME-db-credentials.yaml

git add apps/
git commit -m "Add APPNAME: provision database and role"
git push
```

Sync ArgoCD and verify the database was created and the role is active:

```bash
kubectl get database -n postgres
kubectl get cluster postgres -n postgres -o jsonpath='{.status.managedRolesStatus}' | jq
```

### Phase 2 — Deploy the application

Add the application's `Deployment`, `Service`, `IngressRoute`, and any other manifests to `apps/APPNAME/`. The connection string for the app to use:

```
host:     postgres-pooler.postgres.svc.cluster.local
port:     5432
database: APPNAME
user:     APPNAME
password: (from sealedsecret-APPNAME)
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
# 1. Dump from source (pg_dump is available inside the source postgres container)
docker exec -i -e PGPASSWORD=$POSTGRES_PASSWORD source_postgres_container pg_dump \
  --username=SOURCE_USER \
  --dbname=SOURCE_DB \
  --format=custom \
  > /tmp/APPNAME.dump

# 2. Extract the destination password into a shell variable first to avoid
#    quoting issues with special characters when injecting into the pod env.
PGPASS=$(kubectl get secret APPNAME-db-credentials -n postgres \
  -o jsonpath='{.data.password}' | base64 -d)

# 3. Start a restore pod in the postgres namespace with PGPASSWORD baked in.
#    Use single quotes for the literal prefix to prevent shell expansion of
#    special characters in the password. The variable reference is double-quoted
#    separately so it expands correctly.
kubectl run pg-restore -n postgres --image=postgres:18 --restart=Never \
  --env='PGPASSWORD='"${PGPASS}" -- sleep infinity
kubectl wait -n postgres --for=condition=Ready pod/pg-restore --timeout=60s

# 3. Restore into the new cluster (connect via the cluster service, not pooler,
#    to avoid transaction-mode pooling restrictions during restore)
#
# If running from inside the cluster (see below), pull the password directly
# from the secret to avoid shell quoting issues with special characters.
# Do NOT quote the PGPASSWORD value when using kubectl exec -- env, as the
# quotes may be passed literally to the process rather than stripped by the shell.
kubectl cp /tmp/APPNAME.dump postgres/pg-restore:/tmp/APPNAME.dump
kubectl exec -n postgres pg-restore -- env \
  pg_restore \
  --host=postgres-rw.postgres.svc.cluster.local \
  --username=APPNAME \
  --dbname=APPNAME \
  --no-owner \
  --no-privileges \
  /tmp/APPNAME.dump

**Verify the data before continuing:**

kubectl exec -n postgres pg-restore -- psql \
  --host=postgres-rw.postgres.svc.cluster.local \
  --username=APPNAME --dbname=APPNAME \
  -c "SELECT COUNT(*) FROM TABLE_NAME;"

# Clean up
kubectl delete pod -n postgres pg-restore
rm /tmp/APPNAME.dump

```

Compare counts against the source. If anything looks wrong, fix it before proceeding — the source is still live and untouched. Leave the `pg-restore` pod running; you may need it again for a final incremental sync in Phase 3.

### Phase 3 — Deploy the application and smoke test

1. Stop or put the source application into read-only mode to prevent new writes during cutover
2. If the source had any activity since the initial dump, run a final incremental sync using the still-running `pg-restore` pod
3. Add the application's `Deployment`, `Service`, `IngressRoute`, etc. to `apps/APPNAME/`
4. Update the application's database connection string to point at the new cluster
5. Commit, push, sync ArgoCD
6. Smoke test: verify the application is healthy and data looks correct
7. Once confirmed: decommission the source database and application, then clean up the restore pod:

```bash
kubectl delete pod -n postgres pg-restore
rm /tmp/APPNAME.dump
```
