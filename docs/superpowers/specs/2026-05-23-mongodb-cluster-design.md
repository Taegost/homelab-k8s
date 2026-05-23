# Shared MongoDB Cluster — Design

## Summary

Add a shared MongoDB cluster to the homelab-k8s platform using the Percona Operator for MongoDB, following the established MariaDB operator pattern (separate CRDs + operator charts, raw cluster CRD, wave ordering). 3-node non-sharded replica set with local-path storage, per-application user management via the cluster CRD, and a runbook matching existing Postgres/MariaDB documentation.

## Architecture

Follow the MariaDB operator pattern — separate CRDs chart + operator chart + raw cluster CRD:

| Component | Namespace | Method | Sync wave |
|---|---|---|---|
| `psmdb-operator-crds` | `psmdb-operator` | Helm chart `percona/psmdb-operator-crds` v1.22.0 | `-3` |
| `psmdb-operator` | `psmdb-operator` | Helm chart `percona/psmdb-operator` v1.22.0 | `-2` |
| MongoDB cluster | `mongodb` | Raw `PerconaServerMongoDB` CRD | `-1` |

CRDs and operator are decoupled (like MariaDB) so removing or upgrading the operator chart never cascade-deletes CRDs and destroys the cluster. PSMDB CRDs are cluster-scoped; the Helm release namespace is `psmdb-operator` for metadata only.

### Wave ordering rationale

- Wave `-3`: CRDs must be registered before the operator starts. Without them, the operator crashes on startup because it cannot set up controllers for resources that don't exist yet.
- Wave `-2`: Operator must be running before the `PerconaServerMongoDB` CRD is applied. ArgoCD would surface "no matches for kind PerconaServerMongoDB" and retry if the CRD isn't registered yet.
- Wave `-1`: Cluster CRD applied after operator is ready. In the `mongodb` namespace alongside platform services like Traefik and storage drivers.

### Operator configuration

```yaml
# apps/percona-mongodb-operator/values.yaml
disableTelemetry: true       # Homelab — no telemetry needed
watchAllNamespaces: true      # Required: operator in psmdb-operator namespace must reconcile CRDs in mongodb namespace
```

### Why local-path (not Longhorn)

MongoDB's native replication already provides data redundancy — each of the 3 replicas holds a complete copy of the data. Using Longhorn on top of that would replicate every write at block level across 3 nodes, doubling write overhead for no practical benefit.

This follows the same reasoning as Postgres/CNPG, which also uses local-path because streaming replication is the intended redundancy layer. The MariaDB cluster uses Longhorn because it has only 2 instances and local-path node-pinning would prevent the primary from rescheduling on node failure — a constraint that doesn't apply to a 3-replica MongoDB set where the replica set tolerates losing 1 node.

With local-path and 3 replicas on 3 nodes:
- Node fails → that pod stays Pending until the node returns. Replica set continues healthy at 2/3 with automatic primary failover. Majority (2) still available for writes.
- Node returns → pod catches up via MongoDB replication.
- If a node is permanently lost → manual PVC cleanup and the operator spins up a replacement on a surviving node.

## Cluster CRD

```yaml
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDB
metadata:
  name: mongodb
  namespace: mongodb
spec:
  image: percona/percona-server-mongodb:8.0.19-7
  replsets:
    - name: rs0
      size: 3
      resources:
        limits:
          cpu: "2"
          memory: 2Gi
        requests:
          cpu: 500m
          memory: 1Gi
      volumeSpec:
        persistentVolumeClaim:
          storageClassName: local-path
          resources:
            requests:
              storage: 20Gi
      affinity:
        antiAffinityTopologyKey: kubernetes.io/hostname
      podDisruptionBudget:
        maxUnavailable: 1
      livenessProbe:
        initialDelaySeconds: 90
        periodSeconds: 30
      readinessProbe:
        initialDelaySeconds: 30
        periodSeconds: 10
  secrets:
    users: mongodb-users
    keyFile: mongodb-keyfile
  users: []
```

### MongoDB version

Percona Server for MongoDB 8.0.19-7 (latest stable as of Feb 2026). Pinned to the patch version for reproducibility. Upgrade by bumping the image tag.

## System Secrets

Two SealedSecrets in the `mongodb` namespace:

1. **`mongodb-users`** — System-level MongoDB credentials (`MONGODB_USER_ADMIN_USER`, `MONGODB_USER_ADMIN_PASSWORD`, `MONGODB_CLUSTER_ADMIN_USER`, `MONGODB_CLUSTER_ADMIN_PASSWORD`, `MONGODB_BACKUP_USER`, `MONGODB_BACKUP_PASSWORD`). The operator manages these accounts automatically.

2. **`mongodb-keyfile`** — Internal replica set authentication key (`mongodb-key`). The operator generates this automatically during cluster creation if not pre-provisioned, but sealing it ensures reproducibility.

Both must be sealed with `kubeseal` before committing. The namespace must exist before sealing (`kubeseal` hashes the namespace into the ciphertext).

## Per-Application User Management

Like Postgres managed roles, application users are declared in `spec.users` of the `PerconaServerMongoDB` CR. Each user references a password secret via `passwordSecretRef`.

Databases are created implicitly by MongoDB on first write — no separate Database CRD exists. This differs from both Postgres (Database CRD) and MariaDB (Database/User/Grant CRDs).

**Adding a new application database and user:**

1. Create a password secret in the app namespace and seal a copy for the `mongodb` namespace (cross-namespace duplication, same as Postgres/MariaDB):
   ```yaml
   # apps/APPNAME/secret-APPNAME-db-credentials.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: APPNAME-db-credentials
     namespace: mongodb
   type: Opaque
   stringData:
     password: PLACEHOLDER_CHANGE_ME
   ```

2. Add the user to `spec.users` in `apps/percona-mongodb/cluster-mongodb.yaml`:
   ```yaml
   - name: APPNAME
     db: APPNAME
     passwordSecretRef:
       name: APPNAME-db-credentials
       key: password
     roles:
       - role: { name: "readWrite", db: "APPNAME" }
   ```

3. The app connects via `mongodb-rs0.mongodb.svc.cluster.local:27017` with username `APPNAME`, password from the sealed secret, and `authSource=APPNAME`.

## Scope Boundaries

### In scope
- Percona Operator for MongoDB installation (CRDs + operator + cluster CRD)
- 3-node non-sharded replica set
- System credentials (sealed secrets)
- Per-application user management
- Runbook documentation matching existing Postgres/MariaDB structure

### Out of scope
- Sharding (explicitly non-sharded)
- Backups (deferred until S3-compatible endpoint is available, matching Postgres/MariaDB)
- TLS for internal MongoDB connections (can be added later)
- Monitoring integration (deferred until Prometheus/Grafana are added)
- Any specific MongoDB-backed application deployment (this is the cluster only)
