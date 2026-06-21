---
name: add-database-app
description: Adding an app that requires PostgreSQL, MariaDB, or MongoDB. Covers per-engine gotchas, connection patterns, and the phased workflow for database provisioning.
triggers:
  - "database"
  - "postgres"
  - "mariadb"
  - "mongodb"
  - "add db"
  - "new db app"
edges:
  - target: context/stack.md
    condition: when checking database versions, connection strings, or operator details
  - target: context/conventions.md
    condition: when checking sync wave rules or naming conventions
  - target: patterns/seal-secret.md
    condition: when creating database credentials
  - target: patterns/add-app.md
    condition: when creating the app Deployment and manifests
last_updated: 2026-06-16
---

# Add Database App

## Context

Read the relevant runbook first — do not skip:
- PostgreSQL: `docs/postgres-runbooks.md`
- MariaDB: `docs/mariadb-runbooks.md`
- MongoDB: `docs/mongodb-runbooks.md`

Each database engine has different provisioning patterns, connection methods, and credential management. Do not mix patterns between engines.

## Task: PostgreSQL (CNPG)

### Steps

1. Follow the phased workflow in `docs/postgres-runbooks.md` — do not skip phases
2. Declare the role in `apps/postgres/cluster-postgres.yaml` under `spec.managed.roles`
3. Create TWO SealedSecrets with identical password values:
   - One in `postgres` namespace (for CNPG role password)
   - One in the app namespace (for pod to connect)
4. Create app Deployment referencing the app-namespace secret
5. Connection: `postgres-pooler.postgres.svc.cluster.local:5432` (PgBouncer, use for normal queries)
6. Direct: `postgres-rw.postgres.svc.cluster.local:5432` (only for advisory locks or Alembic migrations)

### Gotchas

- **Two secrets, one password.** The CNPG role password and the app connection secret must have identical values. If they diverge, auth fails silently — the pod starts but gets `password authentication failed`.
- **Phased workflow is mandatory.** The database must be provisioned and verified before the Deployment is created. Creating both in the same commit causes race conditions.
- **PgBouncer vs direct.** Use the pooler for all normal queries. Direct connection is only for advisory locks or migration frameworks that require it.
- **Sync waves.** App-level SealedSecrets at wave `-1`. No wave needed on the CNPG role declaration (it's in the `postgres` namespace's own cluster manifest).

### Verify

- [ ] Role declared in `cluster-postgres.yaml`
- [ ] Two SealedSecrets created with identical password
- [ ] Connection string uses pooler endpoint
- [ ] App connects successfully (check pod logs)

## Task: MariaDB (mariadb-operator)

### Steps

1. Follow `docs/mariadb-runbooks.md`
2. Create Database, User, and Grant CRDs in the app's own folder (`apps/<app-name>/`)
3. Set `namespace: mariadb` on all three CRDs — they must live in the mariadb namespace
4. Create SealedSecret for the database password in the app namespace
5. Connection: write → `mariadb-primary.mariadb.svc.cluster.local:3306`, read → `mariadb-secondary.mariadb.svc.cluster.local:3306`

### Gotchas

- **CRDs go in the app folder but deploy to `mariadb` namespace.** The `namespace: mariadb` field on the CRD is what matters — the file lives in `apps/<app-name>/` for discoverability.
- **SealedSecret namespace scoping.** The password secret sealed for the app namespace cannot decrypt in `mariadb`. If the User CRD references a `passwordSecretRef` in the mariadb namespace, that secret needs to be sealed for `mariadb`.
- **Sync waves.** User CRDs with cross-namespace `passwordSecretRef` at wave `-2`. Database and Grant CRDs at wave `-1`.

### Verify

- [ ] Database, User, Grant CRDs all have `namespace: mariadb`
- [ ] SealedSecret sealed for correct namespace
- [ ] Sync waves in correct order
- [ ] App connects to primary for writes, secondary for reads

## Task: MongoDB (PSMDB)

### Steps

1. Follow `docs/mongodb-runbooks.md`
2. Cluster CRD and sealed secrets in `apps/percona-mongodb/`
3. Connection via the Percona MongoDB Operator service endpoints

### Gotchas

- **MongoDB cluster CRD at wave `-1`.** Infrastructure SealedSecrets at wave `-3`.
- **Percona operator manages replication.** Do not configure replica sets manually — the operator handles it.

### Verify

- [ ] Cluster CRD references correct sealed secrets
- [ ] Sync waves correct
- [ ] App connects successfully

## Update Scaffold

- [ ] Update `.mex/ROUTER.md` "Current Project State" if what's working/not built has changed
- [ ] Update any `.mex/context/` files that are now out of date
- [ ] If this is a new task type without a pattern, create one in `.mex/patterns/` and add to `INDEX.md`
