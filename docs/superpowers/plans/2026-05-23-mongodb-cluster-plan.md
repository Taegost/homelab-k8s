# Shared MongoDB Cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install Percona Operator for MongoDB v1.22.0 with a 3-node non-sharded replica set, local-path storage, and sealed system secrets.

**Architecture:** Follows the MariaDB operator pattern — separate CRDs chart (wave -3) + operator chart with values (wave -2) + raw `PerconaServerMongoDB` CRD with secrets (wave -1). Operator runs in `psmdb-operator` namespace, cluster in `mongodb` namespace.

**Tech Stack:** Percona Operator for MongoDB 1.22.0, Percona Server for MongoDB 8.0.19-7, local-path StorageClass, Sealed Secrets, ArgoCD

**Design doc:** `docs/superpowers/specs/2026-05-23-mongodb-cluster-design.md`

---

### Task 1: ArgoCD Application — PSMDB Operator CRDs (wave -3)

**Files:**
- Create: `apps/manifests/percona-mongodb-operator-crds.yaml`

- [ ] **Step 1: Create the ArgoCD Application manifest for the CRDs chart**

```yaml
# apps/manifests/percona-mongodb-operator-crds.yaml
# ArgoCD Application — Percona MongoDB Operator CRDs
#
# Installs the PerconaServerMongoDB CRDs as a separate Helm chart. CRDs are
# deliberately decoupled from the operator chart so that removing or upgrading
# the operator chart never triggers Helm to cascade-delete the CRDs and destroy
# all MongoDB clusters along with them.
#
# Sync wave -3: Must run before the psmdb-operator (wave -2) so the
# psmdb.percona.com API group is registered before the operator starts.
# Without this, the operator cannot set up its controllers.
#
# ServerSideApply is required: PSMDB CRD resources exceed the kubectl
# annotation size limit under client-side apply.
#
# prune: false — CRDs should not be pruned by ArgoCD lifecycle. Deleting CRDs
# cascades to all PerconaServerMongoDB instances cluster-wide.
#
# To upgrade: update targetRevision here AND in apps/manifests/percona-mongodb-operator.yaml
# — both charts must stay on the same version.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: percona-mongodb-operator-crds
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  project: default
  source:
    repoURL: https://percona.github.io/percona-helm-charts
    chart: psmdb-operator-crds
    targetRevision: 1.22.0
  destination:
    server: https://kubernetes.default.svc
    namespace: psmdb-operator
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Commit**

```bash
git add apps/manifests/percona-mongodb-operator-crds.yaml
git commit -m "feat: add Percona MongoDB operator CRDs ArgoCD Application (wave -3)"
```

---

### Task 2: ArgoCD Application — PSMDB Operator (wave -2)

**Files:**
- Create: `apps/percona-mongodb-operator/values.yaml`
- Create: `apps/manifests/percona-mongodb-operator.yaml`

- [ ] **Step 1: Create the operator Helm values**

```yaml
# apps/percona-mongodb-operator/values.yaml
# Percona Operator for MongoDB Helm values
# Chart: percona/psmdb-operator  Version: 1.22.0

# Disable telemetry for homelab use.
disableTelemetry: true

# Must watch all namespaces — the operator runs in psmdb-operator but the
# PerconaServerMongoDB CRD lives in the mongodb namespace. Without this,
# the operator only watches its own namespace and never reconciles the cluster.
watchAllNamespaces: true
```

- [ ] **Step 2: Create the ArgoCD Application manifest for the operator**

```yaml
# apps/manifests/percona-mongodb-operator.yaml
# ArgoCD Application — Percona Operator for MongoDB
#
# Installs the Percona Operator for MongoDB, which manages MongoDB clusters as
# Kubernetes-native CRDs. All PerconaServerMongoDB resources depend on the
# CRDs this operator installs.
#
# Sync wave -2: Runs after the psmdb-operator-crds Application (wave -3) which
# installs the psmdb.percona.com CRDs. Must be fully ready before the MongoDB
# cluster Application (wave -1) attempts to create a PerconaServerMongoDB CR.
#
# ServerSideApply is required: PSMDB CRDs contain fields that exceed the
# kubectl annotation size limit under client-side apply.
#
# To upgrade: update targetRevision and check the changelog at
# https://github.com/percona/percona-server-mongodb-operator/releases
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: percona-mongodb-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  sources:
    # Source 1: The psmdb-operator Helm chart
    - repoURL: https://percona.github.io/percona-helm-charts
      chart: psmdb-operator
      targetRevision: 1.22.0
      helm:
        valueFiles:
          - $values/apps/percona-mongodb-operator/values.yaml
    # Source 2: This repo, used only as a $values reference for the Helm
    # chart above.
    - repoURL: https://github.com/Taegost/homelab-k8s
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: psmdb-operator
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 3: Commit**

```bash
git add apps/percona-mongodb-operator/values.yaml apps/manifests/percona-mongodb-operator.yaml
git commit -m "feat: add Percona MongoDB operator ArgoCD Application (wave -2)"
```

---

### Task 3: MongoDB System Secrets (plaintext, for sealing)

**Files:**
- Create: `apps/percona-mongodb/secret-mongodb-users.yaml`
- Create: `apps/percona-mongodb/secret-mongodb-keyfile.yaml`
- Create: `apps/percona-mongodb/secret-mongodb-encryption-key.yaml`

> **Note:** These are plaintext placeholder secrets. They are gitignored (`secret-*.yaml`). After the user fills in real passwords, they will be sealed in Task 7.

- [ ] **Step 1: Create the system users secret**

```yaml
# apps/percona-mongodb/secret-mongodb-users.yaml
# System-level MongoDB user credentials.
# Fill in strong unique passwords for each user below, then seal:
#   kubeseal --format yaml < apps/percona-mongodb/secret-mongodb-users.yaml > apps/percona-mongodb/sealedsecret-mongodb-users.yaml
#   rm apps/percona-mongodb/secret-mongodb-users.yaml
#
# The secret must exist before the PerconaServerMongoDB CR is applied —
# the operator reads these credentials at cluster creation time to initialize
# the admin database. If the secret doesn't exist, the operator generates
# random credentials and stores them in a secret named <cluster-name>-users.
apiVersion: v1
kind: Secret
metadata:
  name: mongodb-users
  namespace: mongodb
type: Opaque
stringData:
  MONGODB_BACKUP_USER: backup
  MONGODB_BACKUP_PASSWORD: your_backup_password_here
  MONGODB_CLUSTER_ADMIN_USER: clusterAdmin
  MONGODB_CLUSTER_ADMIN_PASSWORD: your_cluster_admin_password_here
  MONGODB_CLUSTER_MONITOR_USER: clusterMonitor
  MONGODB_CLUSTER_MONITOR_PASSWORD: your_cluster_monitor_password_here
  MONGODB_DATABASE_ADMIN_USER: databaseAdmin
  MONGODB_DATABASE_ADMIN_PASSWORD: your_database_admin_password_here
  MONGODB_USER_ADMIN_USER: userAdmin
  MONGODB_USER_ADMIN_PASSWORD: your_user_admin_password_here
```

- [ ] **Step 2: Create the internal auth keyfile secret**

```yaml
# apps/percona-mongodb/secret-mongodb-keyfile.yaml
# MongoDB internal cluster authentication key.
# Generate a strong random key and base64-encode it:
#   openssl rand -base64 756 | tr -d '\n' | base64 -w0
# Then seal:
#   kubeseal --format yaml < apps/percona-mongodb/secret-mongodb-keyfile.yaml > apps/percona-mongodb/sealedsecret-mongodb-keyfile.yaml
#   rm apps/percona-mongodb/secret-mongodb-keyfile.yaml
apiVersion: v1
kind: Secret
metadata:
  name: mongodb-keyfile
  namespace: mongodb
type: Opaque
data:
  mongodb-key: your_base64_encoded_random_key_here
```

- [ ] **Step 3: Create the data-at-rest encryption key secret**

```yaml
# apps/percona-mongodb/secret-mongodb-encryption-key.yaml
# MongoDB data-at-rest encryption key.
# Generate a 32-byte random key and base64-encode it:
#   openssl rand -base64 32 | tr -d '\n' | base64 -w0
# Then seal:
#   kubeseal --format yaml < apps/percona-mongodb/secret-mongodb-encryption-key.yaml > apps/percona-mongodb/sealedsecret-mongodb-encryption-key.yaml
#   rm apps/percona-mongodb/secret-mongodb-encryption-key.yaml
apiVersion: v1
kind: Secret
metadata:
  name: mongodb-encryption-key
  namespace: mongodb
type: Opaque
data:
  encryption-key: your_base64_encoded_32_byte_key_here
```

- [ ] **Step 4: Commit the plaintext secrets (they will be deleted after sealing in Task 7)**

```bash
git add apps/percona-mongodb/secret-mongodb-users.yaml apps/percona-mongodb/secret-mongodb-keyfile.yaml apps/percona-mongodb/secret-mongodb-encryption-key.yaml
git commit -m "feat: add MongoDB system secret templates (plaintext, to be sealed)"
```

---

### Task 4: MongoDB Cluster CRD

**Files:**
- Create: `apps/percona-mongodb/cluster-mongodb.yaml`

- [ ] **Step 1: Create the PerconaServerMongoDB CR**

```yaml
# apps/percona-mongodb/cluster-mongodb.yaml
# PerconaServerMongoDB — Shared MongoDB 8.0 cluster
#
# This is the shared MongoDB instance used by applications that require
# document-store storage. New application users are added to spec.users
# in this file — each user gets a passwordSecretRef pointing to a SealedSecret
# in this namespace. Databases are created implicitly by MongoDB on first use.
# See docs/mongodb-runbooks.md.
#
# Storage: local-path PVCs on each node. MongoDB's native replication provides
# data redundancy across all 3 nodes — Longhorn is intentionally not used here
# to avoid double-replication overhead (same rationale as Postgres/CNPG).
#
# Version: Percona Server for MongoDB 8.0.19-7 (latest stable as of 2026-02).
# To upgrade: update the image tag and check the Percona Operator release notes
# at https://github.com/percona/percona-server-mongodb-operator/releases
# for any required SetFCV or upgrade steps.
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDB
metadata:
  name: mongodb
  namespace: mongodb
  finalizers:
    - percona.com/delete-psmdb-pods-in-order
spec:
  crVersion: 1.22.0

  image: percona/percona-server-mongodb:8.0.19-7
  imagePullPolicy: IfNotPresent

  # Disable automated upgrades — we pin the operator and MongoDB versions.
  # When ready to upgrade: update the image tag and operator targetRevision,
  # then set apply: once with a scheduled window.
  upgradeOptions:
    versionServiceEndpoint: https://check.percona.com
    apply: disabled
    schedule: "0 2 * * *"
    setFCV: false

  # Update strategy: SmartUpdate rolls pods one at a time, respecting
  # replica set primary order (secondaries first, primary last).
  updateStrategy: SmartUpdate

  secrets:
    users: mongodb-users
    keyFile: mongodb-keyfile
    encryptionKey: mongodb-encryption-key

  # --- Replica set configuration ---
  replsets:
    - name: rs0
      size: 3

      # Spread across nodes where possible but do not require it.
      # With 3 nodes and 3 replicas, preferred anti-affinity places one pod
      # per node. If a node fails, the remaining 2 pods can colocate on the
      # surviving nodes rather than one sitting Pending.
      affinity:
        antiAffinityTopologyKey: "kubernetes.io/hostname"

      # Allow 1 pod unavailable during voluntary disruptions (upgrades, node drain).
      # With 3 replicas, the replica set maintains a majority (needs 2) during
      # the disruption window.
      podDisruptionBudget:
        maxUnavailable: 1

      # 20Gi per replica. Shared across all databases — expand via PVC resize
      # if needed. For context, a typical homelab app database is under 100MB.
      volumeSpec:
        persistentVolumeClaim:
          storageClassName: local-path
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 20Gi

      # Resource limits. MongoDB's WiredTiger cache defaults to 50% of available
      # memory, so the limit directly controls cache size. 2Gi limit → ~1Gi cache.
      # These match the operator defaults; adjust if workloads demand more.
      resources:
        limits:
          cpu: "1"
          memory: 2Gi
        requests:
          cpu: 500m
          memory: 1Gi

      # Startup probe: MongoDB can take 60-90s on first start while it runs
      # initial sync and builds indexes. The generous initial delay prevents
      # unnecessary restarts during cluster bootstrap.
      livenessProbe:
        failureThreshold: 4
        initialDelaySeconds: 90
        periodSeconds: 30
        timeoutSeconds: 10

      readinessProbe:
        failureThreshold: 8
        initialDelaySeconds: 30
        periodSeconds: 10
        timeoutSeconds: 2

      # WiredTiger storage engine tuning.
      # cacheSizeRatio: 0.5 means WiredTiger uses 50% of (memory limit - 1Gi) ≈ 512MB
      # for its internal cache. This is the MongoDB default; increase only if
      # working set consistently exceeds the cache.
      storage:
        engine: wiredTiger
        wiredTiger:
          engineConfig:
            cacheSizeRatio: 0.5
            journalCompressor: snappy
          collectionConfig:
            blockCompressor: snappy
          indexConfig:
            prefixCompression: true

  # --- Sharding: disabled ---
  # Non-sharded cluster — single replica set only. This is the right default
  # for homelab; sharding adds mongos routers and config server replicas
  # that increase resource usage without benefit at this scale.
  sharding:
    enabled: false

  # --- Per-application users ---
  # Add application users here. Each user gets a readWrite role on its own
  # database. The password secret must exist in the mongodb namespace.
  # See docs/mongodb-runbooks.md for the full workflow.
  #
  # Example:
  #   - name: myapp
  #     db: myapp
  #     passwordSecretRef:
  #       name: myapp-db-credentials
  #       key: password
  #     roles:
  #       - role: { name: "readWrite", db: "myapp" }
  users: []

  # --- Backups: deferred ---
  # PITR backups require an S3-compatible endpoint. When that is set up:
  #   1. Create and seal credentials for the S3 endpoint
  #   2. Add a backup section with storages and tasks
  #   3. Update docs/mongodb-runbooks.md with restore procedures
```

- [ ] **Step 2: Commit**

```bash
git add apps/percona-mongodb/cluster-mongodb.yaml
git commit -m "feat: add MongoDB cluster CRD — 3-node replica set, local-path, MongoDB 8.0"
```

---

### Task 5: ArgoCD Application — MongoDB Cluster (wave -1)

**Files:**
- Create: `apps/manifests/percona-mongodb.yaml`

- [ ] **Step 1: Create the ArgoCD Application manifest for the cluster**

```yaml
# apps/manifests/percona-mongodb.yaml
# ArgoCD Application — Shared MongoDB Cluster
#
# Deploys the PerconaServerMongoDB CRD and sealed system credentials for the
# shared MongoDB instance used by all document-store applications.
#
# New per-application users are added to spec.users in the cluster CRD —
# see apps/percona-mongodb/cluster-mongodb.yaml. Each user references a
# SealedSecret in the mongodb namespace. See docs/mongodb-runbooks.md.
#
# Sync wave -1: Runs alongside Traefik and storage drivers — all are platform
# services that applications consume. Must run after the Percona MongoDB
# operator (wave -2) has installed its CRDs. If this Application syncs before
# the CRDs exist, ArgoCD will surface "no matches for kind PerconaServerMongoDB"
# errors and retry — it will self-heal once the operator is ready, but wave -1
# avoids the noise.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: percona-mongodb
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  source:
    repoURL: https://github.com/Taegost/homelab-k8s
    targetRevision: HEAD
    path: apps/percona-mongodb
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: mongodb
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Commit**

```bash
git add apps/manifests/percona-mongodb.yaml
git commit -m "feat: add MongoDB cluster ArgoCD Application (wave -1)"
```

---

### Task 6: MongoDB Runbook Documentation

**Files:**
- Create: `docs/mongodb-runbooks.md`

- [ ] **Step 1: Create the runbook**

Write the following to `docs/mongodb-runbooks.md`:

```markdown
# MongoDB Runbooks

This document covers day-two operations for the shared MongoDB instance managed by the Percona Operator for MongoDB. For the current MongoDB server version, see the `image` tag in `apps/percona-mongodb/cluster-mongodb.yaml`.

---

## Architecture overview

| Component | Detail |
|-----------|--------|
| Operator | Percona Operator for MongoDB (psmdb-operator) — version: see `apps/manifests/percona-mongodb-operator.yaml` `targetRevision` |
| MongoDB version | see `image` tag in `apps/percona-mongodb/cluster-mongodb.yaml` |
| Instances | 3 (single replica set `rs0`, anti-affinity across nodes) |
| Storage | `local-path` PVCs — MongoDB replication provides data redundancy |
| Connection | `mongodb-rs0.mongodb.svc.cluster.local:27017` |
| Replication | Standard MongoDB replica set with majority write concern |

### Why local-path instead of Longhorn

MongoDB's native replication provides data redundancy across all 3 nodes — each replica holds a complete copy of the data. Using Longhorn here would add a second replication layer (block-level across nodes) on top of MongoDB's replication, doubling the write overhead for no practical benefit. This is the same rationale as the Postgres cluster's use of local-path.

With 3 replicas, the replica set maintains a majority (2/3) for writes even if one node fails. The pod on the failed node sits Pending until the node returns (its local-path PVC is node-pinned), at which point it catches up via replication. If a node is permanently lost, delete the PVC and the operator spins up a replacement on a surviving node.

### Per-application users

Every application gets its own MongoDB user scoped to its own database. This is enforced at the credential layer — each user has a `readWrite` role on its database only.

Users are declared in `spec.users` in `apps/percona-mongodb/cluster-mongodb.yaml`. Unlike the Postgres cluster (which has no standalone Role CRD and forces roles into the Cluster spec) and unlike MariaDB (which provides standalone User/Database/Grant CRDs), MongoDB uses the cluster CRD's `spec.users` field with a `passwordSecretRef` pointing to a Kubernetes Secret.

Databases are created implicitly by MongoDB on first use — no separate Database resource exists. A user's `db` field sets their authentication database; their role's `db` field sets the target database they have access to.

---

## First-time setup

The `mongodb` namespace must exist before sealing secrets (`kubeseal` hashes the namespace into the ciphertext):

```bash
kubectl create namespace mongodb --dry-run=client -o yaml | kubectl apply -f -
```

Fill in real passwords and keys in the plaintext secrets, then seal each one:

```bash
# 1. Edit each secret file and replace placeholder values:
#    - apps/percona-mongodb/secret-mongodb-users.yaml
#    - apps/percona-mongodb/secret-mongodb-keyfile.yaml
#    - apps/percona-mongodb/secret-mongodb-encryption-key.yaml

# 2. Generate the keyfile value:
#    openssl rand -base64 756 | tr -d '\n' | base64 -w0

# 3. Generate the encryption key:
#    openssl rand -base64 32 | tr -d '\n' | base64 -w0

# 4. Seal all three secrets:
kubeseal --format yaml < apps/percona-mongodb/secret-mongodb-users.yaml > apps/percona-mongodb/sealedsecret-mongodb-users.yaml
kubeseal --format yaml < apps/percona-mongodb/secret-mongodb-keyfile.yaml > apps/percona-mongodb/sealedsecret-mongodb-keyfile.yaml
kubeseal --format yaml < apps/percona-mongodb/secret-mongodb-encryption-key.yaml > apps/percona-mongodb/sealedsecret-mongodb-encryption-key.yaml

# 5. Delete plaintext secrets:
rm apps/percona-mongodb/secret-mongodb-*.yaml

# 6. Commit and push:
git add apps/
git commit -m "Add shared MongoDB cluster with Percona Operator"
git push
```

ArgoCD will sync in wave order: psmdb-operator-crds (wave -3) → psmdb-operator (wave -2) → MongoDB cluster (wave -1). The CRDs must be registered before the operator starts — the separate CRDs chart ensures this ordering. The cluster takes 3–5 minutes to initialize on first sync as it bootstraps the 3-node replica set.

Verify the cluster is healthy:

```bash
kubectl get psmdb -n mongodb
# NAME      REPLSETS   READY   STATUS   AGE
# mongodb   1           3       ready   5m

kubectl get pods -n mongodb
# NAME                              READY   STATUS    RESTARTS   AGE
# mongodb-rs0-0                     2/2     Running   0          5m
# mongodb-rs0-1                     2/2     Running   0          4m
# mongodb-rs0-2                     2/2     Running   0          3m
# percona-server-mongodb-operator-* 1/1     Running   0          5m
```

---

## Adding a new application

Use this workflow when deploying an application that needs a new MongoDB database.

### Phase 1 — Provision the user

Create a password secret in the app folder with `namespace: mongodb`, then add the user to `spec.users` in the cluster CRD.

**1. Create the password secret:**

```yaml
# apps/APPNAME/secret-APPNAME-db-credentials.yaml
# Fill in a strong password, then seal:
#   kubeseal --format yaml < apps/APPNAME/secret-APPNAME-db-credentials.yaml > apps/APPNAME/sealedsecret-APPNAME-db-credentials.yaml
#   rm apps/APPNAME/secret-APPNAME-db-credentials.yaml
apiVersion: v1
kind: Secret
metadata:
  name: APPNAME-db-credentials
  namespace: mongodb
type: Opaque
stringData:
  password: PLACEHOLDER_CHANGE_ME
```

> **Password duplication:** If the application pod reads its database password from a separate app-namespace secret (e.g. `apps/APPNAME/secret-APPNAME.yaml` in the `APPNAME` namespace), the password value must match what is in `sealedsecret-APPNAME-db-credentials` above. Kubernetes pods cannot reference secrets across namespaces, so the credential must appear in both the `mongodb`-namespace secret (for the operator to read) and the app-namespace secret (for the pod to connect). Keep them in sync when rotating passwords.

**2. Add the user to `apps/percona-mongodb/cluster-mongodb.yaml` under `spec.users`:**

```yaml
  - name: APPNAME
    db: APPNAME
    passwordSecretRef:
      name: APPNAME-db-credentials
      key: password
    roles:
      - role: { name: "readWrite", db: "APPNAME" }
```

**3. Seal the credentials, commit, and sync:**

```bash
# Create the mongodb namespace if it doesn't already exist:
kubectl create namespace mongodb --dry-run=client -o yaml | kubectl apply -f -

kubeseal --format yaml < apps/APPNAME/secret-APPNAME-db-credentials.yaml > apps/APPNAME/sealedsecret-APPNAME-db-credentials.yaml
rm apps/APPNAME/secret-APPNAME-db-credentials.yaml

git add apps/
git commit -m "Add APPNAME: provision MongoDB user and credentials"
git push
```

Sync ArgoCD and verify the user was created:

```bash
# Check the operator logs for user creation:
kubectl logs -n psmdb-operator -l app.kubernetes.io/name=percona-server-mongodb-operator | grep -i "user\|APPNAME"
```

### Phase 2 — Deploy the application

Add the application's `Deployment`, `Service`, `IngressRoute`, and any other manifests to `apps/APPNAME/`. The connection string for the app:

```
mongodb://APPNAME:<password>@mongodb-rs0.mongodb.svc.cluster.local:27017/APPNAME?authSource=APPNAME
```

> **`fsGroup` is required for any Deployment that mounts a Longhorn PVC.** Fresh
> Longhorn volumes are provisioned owned by root — a non-root container cannot
> write to them without it. Set `fsGroup` in `spec.template.spec.securityContext`
> to the GID the container runs as. Check the image's Dockerfile first; do not
> assume it matches another app in the stack.

Commit, push, and sync. ArgoCD picks up the new manifests automatically.

### Phase 3 — Smoke test

Verify the application is healthy and can read/write its database:

```bash
# Start a temporary mongosh pod to test connectivity:
kubectl run mongosh-test -n mongodb --image=mongo:8.0 --rm -it --restart=Never -- \
  mongosh "mongodb://APPNAME:<password>@mongodb-rs0.mongodb.svc.cluster.local:27017/APPNAME?authSource=APPNAME" \
  --eval 'db.test.insert({status: "ok"}); db.test.find()'

# Clean up test data:
kubectl run mongosh-clean -n mongodb --image=mongo:8.0 --rm -it --restart=Never -- \
  mongosh "mongodb://APPNAME:<password>@mongodb-rs0.mongodb.svc.cluster.local:27017/APPNAME?authSource=APPNAME" \
  --eval 'db.test.drop()'
```

Once confirmed, the deployment is complete.

---

## Migrating an existing application

Use this workflow when moving an application that already has a MongoDB database into the shared cluster.

### Phase 1 — Provision the user

Follow Phase 1 from [Adding a new application](#adding-a-new-application) above. At the end of this phase:

- The user exists in `spec.users` in `cluster-mongodb.yaml`
- The `SealedSecret` exists in `apps/APPNAME/`
- The application's `Deployment` does **not** exist yet
- The source system is still running normally

### Phase 2 — Migrate the data

Use `mongodump` / `mongorestore`:

```bash
# 1. Dump from source
mongodump --uri="mongodb://SOURCE_USER:SOURCE_PASS@SOURCE_HOST:27017/SOURCE_DB?authSource=admin" \
  --out=/tmp/APPNAME-dump

# 2. Restore into the new cluster.
# Extract the destination password first to avoid quoting issues:
DEST_PASS=$(kubectl get secret APPNAME-db-credentials -n mongodb \
  -o jsonpath='{.data.password}' | base64 -d)

# Start a temporary restore pod:
kubectl run mongo-restore -n mongodb --image=mongo:8.0 --restart=Never -- sleep infinity
kubectl wait -n mongodb --for=condition=Ready pod/mongo-restore --timeout=60s

# Copy the dump and restore:
kubectl cp /tmp/APPNAME-dump mongodb/mongo-restore:/tmp/dump
kubectl exec -n mongodb mongo-restore -- \
  mongorestore "mongodb://APPNAME:${DEST_PASS}@mongodb-rs0.mongodb.svc.cluster.local:27017/APPNAME?authSource=APPNAME" \
  /tmp/dump

# Verify row counts:
kubectl exec -n mongodb mongo-restore -- \
  mongosh "mongodb://APPNAME:\$DEST_PASS@mongodb-rs0.mongodb.svc.cluster.local:27017/APPNAME?authSource=APPNAME" \
  --eval 'db.COLLECTION_NAME.countDocuments()'

# Clean up:
kubectl delete pod -n mongodb mongo-restore
rm -rf /tmp/APPNAME-dump
```

Compare counts against the source. If anything looks wrong, fix it before proceeding — the source is still live and untouched.

### Phase 3 — Deploy the application and smoke test

1. Stop or put the source application into read-only mode to prevent new writes during cutover
2. If the source had activity since the initial dump, run a final incremental `mongodump` with a query filter on `_id` or a timestamp field
3. Add the application's `Deployment`, `Service`, `IngressRoute`, etc. to `apps/APPNAME/`
4. Update the application's database connection string to point at the new cluster
5. Commit, push, sync ArgoCD
6. Smoke test: verify the application is healthy and data looks correct
7. Once confirmed: decommission the source database and application

---

## Enabling backups (deferred)

The Percona Operator supports PITR backups via the `backup` section in the `PerconaServerMongoDB` CR with S3-compatible storage. When an S3-compatible endpoint is available:

1. Create and seal credentials for the S3 endpoint
2. Add a `backup` section to `apps/percona-mongodb/cluster-mongodb.yaml` with:
   - `storages` block pointing at the S3 endpoint
   - `tasks` block with a schedule
3. Document the restore procedure in `docs/disaster-recovery.md`

---

## Expanding the cluster storage

local-path PVCs can be expanded, but the process requires node coordination since each PVC is node-pinned:

```bash
# 1. For each PVC in the replica set:
kubectl patch pvc -n mongodb mongod-data-mongodb-rs0-0 \
  -p '{"spec":{"resources":{"requests":{"storage":"40Gi"}}}}'

# 2. The Percona operator will perform a rolling restart to apply the new size.
# Monitor progress:
kubectl get psmdb mongodb -n mongodb --watch
```

> local-path expansion is not online — the pod must restart for the filesystem to be resized. The operator handles this via its `SmartUpdate` strategy, restarting secondaries first, then the primary.

---

## Troubleshooting

### Cluster not reaching ready state

```bash
kubectl describe psmdb mongodb -n mongodb
kubectl get events -n mongodb --sort-by='.lastTimestamp'

# Operator logs:
kubectl logs -n psmdb-operator -l app.kubernetes.io/name=percona-server-mongodb-operator
```

### Replica set not converging

```bash
# Check each pod's mongod logs:
kubectl logs -n mongodb mongodb-rs0-0 -c mongod
kubectl logs -n mongodb mongodb-rs0-1 -c mongod
kubectl logs -n mongodb mongodb-rs0-2 -c mongod

# Check replica set status via mongosh:
kubectl exec -n mongodb mongodb-rs0-0 -c mongod -- \
  mongosh -u clusterAdmin -p "$(kubectl get secret mongodb-users -n mongodb -o jsonpath='{.data.MONGODB_CLUSTER_ADMIN_PASSWORD}' | base64 -d)" \
  --eval 'rs.status()' --quiet
```

### SealedSecret exists but Secret was never created

Same troubleshooting as Postgres and MariaDB — see the sealed-secrets controller logs:

```bash
kubectl logs -n kube-system -l name=sealed-secrets-controller
```

Common causes:
1. **Wrong cluster key** — re-seal with the current cluster's key
2. **Controller not running** — check pod status in `kube-system`
3. **Namespace mismatch** — SealedSecret must be in the namespace it was sealed for (`mongodb`)

### Per-application user can't authenticate

```bash
# Verify the secret referenced by passwordSecretRef exists and is decrypted:
kubectl get secret APPNAME-db-credentials -n mongodb

# Check the operator logs for user creation errors:
kubectl logs -n psmdb-operator -l app.kubernetes.io/name=percona-server-mongodb-operator | grep APPNAME

# Test authentication directly:
kubectl run mongosh-test -n mongodb --image=mongo:8.0 --rm -it --restart=Never -- \
  mongosh "mongodb://APPNAME:<password>@mongodb-rs0.mongodb.svc.cluster.local:27017/APPNAME?authSource=APPNAME" \
  --eval 'db.runCommand({connectionStatus: 1})'
```
```

- [ ] **Step 2: Commit**

```bash
git add docs/mongodb-runbooks.md
git commit -m "docs: add MongoDB runbook — add app, migrate, troubleshoot"
```

---

### Task 7: Seal Secrets and Final Commit

> **Pre-requisite:** The user must fill in real passwords in the plaintext secret files and generate the keyfile/encryption key values before this task.

**Files:**
- Create: `apps/percona-mongodb/sealedsecret-mongodb-users.yaml`
- Create: `apps/percona-mongodb/sealedsecret-mongodb-keyfile.yaml`
- Create: `apps/percona-mongodb/sealedsecret-mongodb-encryption-key.yaml`
- Delete: `apps/percona-mongodb/secret-mongodb-users.yaml`
- Delete: `apps/percona-mongodb/secret-mongodb-keyfile.yaml`
- Delete: `apps/percona-mongodb/secret-mongodb-encryption-key.yaml`

- [ ] **Step 1: Ensure the `mongodb` namespace exists**

`kubeseal` hashes the namespace into the ciphertext. Sealing before the namespace exists produces a secret the controller cannot decrypt.

```bash
kubectl create namespace mongodb --dry-run=client -o yaml | kubectl apply -f -
```

- [ ] **Step 2: Generate the keyfile value and update the secret**

Generate a 756-byte random key, base64-encode it, and replace `your_base64_encoded_random_key_here` in `apps/percona-mongodb/secret-mongodb-keyfile.yaml`:

```bash
openssl rand -base64 756 | tr -d '\n' | base64 -w0
```

- [ ] **Step 3: Generate the encryption key and update the secret**

Generate a 32-byte encryption key, base64-encode it, and replace `your_base64_encoded_32_byte_key_here` in `apps/percona-mongodb/secret-mongodb-encryption-key.yaml`:

```bash
openssl rand -base64 32 | tr -d '\n' | base64 -w0
```

- [ ] **Step 4: Fill in all passwords in `apps/percona-mongodb/secret-mongodb-users.yaml`**

Replace every `your_*_password_here` placeholder with a strong, unique password. All six passwords must be different from each other.

- [ ] **Step 5: Seal all three secrets**

```bash
kubeseal --format yaml < apps/percona-mongodb/secret-mongodb-users.yaml > apps/percona-mongodb/sealedsecret-mongodb-users.yaml
kubeseal --format yaml < apps/percona-mongodb/secret-mongodb-keyfile.yaml > apps/percona-mongodb/sealedsecret-mongodb-keyfile.yaml
kubeseal --format yaml < apps/percona-mongodb/secret-mongodb-encryption-key.yaml > apps/percona-mongodb/sealedsecret-mongodb-encryption-key.yaml
```

- [ ] **Step 6: Delete plaintext secrets**

```bash
rm apps/percona-mongodb/secret-mongodb-users.yaml
rm apps/percona-mongodb/secret-mongodb-keyfile.yaml
rm apps/percona-mongodb/secret-mongodb-encryption-key.yaml
```

- [ ] **Step 7: Commit all sealed secrets and verify nothing plaintext slipped through**

```bash
git status
# Confirm no secret-*.yaml files remain

git add apps/percona-mongodb/sealedsecret-*.yaml
git add apps/percona-mongodb/cluster-mongodb.yaml
git add docs/mongodb-runbooks.md
git commit -m "feat: add sealed MongoDB system secrets and runbook

Sealed secrets for mongodb-users, mongodb-keyfile, and mongodb-encryption-key.
The PerconaServerMongoDB CRD references these by name at cluster creation time.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 8: Push and verify ArgoCD syncs**

```bash
git push
```

After push, watch ArgoCD sync the three new Applications in wave order:

```bash
# Watch the Applications sync:
kubectl get applications -n argocd -l app.kubernetes.io/name=percona-mongodb --watch

# Once synced, verify the cluster is healthy:
kubectl get psmdb -n mongodb --watch
# Wait for REPLSETS=1, READY=3, STATUS=ready

# Verify pods:
kubectl get pods -n mongodb
```

- [ ] **Step 9: Add the runbook reference to CLAUDE.md**

Modify `CLAUDE.md` — add to the "Read Before Acting" section:

```markdown
- **New app deployment with MongoDB database** → `docs/mongodb-runbooks.md`
```

And add MongoDB to the Core Stack table:

```markdown
| Percona MongoDB Operator CRDs | cluster-scoped | Helm | `-3` |
| Percona MongoDB Operator | `psmdb-operator` | Helm | `-2` |
| MongoDB cluster | `mongodb` | PSMDB CRD | `-1` |
```

And add to the Repository Structure tree under `apps/`:

```markdown
│   ├── percona-mongodb/           # MongoDB cluster CRD + sealed secrets
│   ├── percona-mongodb-operator/  # Percona MongoDB operator Helm values
```
```

- [ ] **Step 10: Commit the CLAUDE.md update**

```bash
git add CLAUDE.md
git commit -m "docs: add MongoDB runbook reference to CLAUDE.md"
git push
```
