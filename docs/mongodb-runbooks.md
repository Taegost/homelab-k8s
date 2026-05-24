# MongoDB Runbooks

This document covers day-two operations for the shared MongoDB instance managed by the Percona Operator for MongoDB. For the current MongoDB server version, see the `image` tag in `apps/percona-mongodb/cluster-mongodb.yaml`.

> **CPU requirement:** MongoDB 8.x binaries are compiled for the `x86-64-v3`
> microarchitecture level (AVX, AVX2, BMI, FMA, F16C, LZCNT, MOVBE, XSAVE).
> All Kubernetes node VMs must expose a `x86-64-v3` (or `host`) CPU to the guest.
> If your hypervisor or bare-metal host does not support x86-64-v3, you must use
> MongoDB 7.x instead — it only requires x86-64-v2. Many hypervisors default to a
> v2-level CPU type; this will cause MongoDB 8 pods to crash with `SIGILL`
> (Illegal instruction). See `docs/troubleshooting.md` for diagnosis, fix, and
> a one-liner to verify CPU compatibility from inside a node.

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
  mongosh "mongodb://APPNAME:${DEST_PASS}@mongodb-rs0.mongodb.svc.cluster.local:27017/APPNAME?authSource=APPNAME" \
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

### Replica set ID mismatch after missing sync-wave annotations

If secrets were deployed without `argocd.argoproj.io/sync-wave` annotations
and the operator auto-generated random credentials before the SealedSecrets
were decrypted, the replica set will be split-brained with mismatched
`replicaSetId` values. See the full GitOps recovery procedure in
`docs/troubleshooting.md` — "MongoDB Replica Set ID Mismatch."

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
