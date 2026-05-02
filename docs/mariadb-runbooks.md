# MariaDB Runbooks

This document covers day-two operations for the shared MariaDB 12.2.2 instance managed by mariadb-operator.

---

## Architecture overview

| Component | Detail |
|-----------|--------|
| CRD chart | mariadb-operator-crds (Helm chart v26.3.0, wave -3) |
| Operator | mariadb-operator (Helm chart v26.3.0, wave -2) |
| MariaDB version | 12.2.2 |
| Instances | 2 (primary + 1 replica, anti-affinity across nodes) |
| Storage | `longhorn` PVCs — see rationale below |
| Connection (writes) | `mariadb-primary.mariadb.svc.cluster.local:3306` |
| Connection (reads) | `mariadb-secondary.mariadb.svc.cluster.local:3306` |
| Replication | Async with GTID strict mode, autoFailover enabled |

Applications must connect through the primary service for all write operations. The secondary service is available for read-only queries but is optional — most apps should just use the primary.

### Why Longhorn instead of local-path

The Postgres cluster uses `local-path` because CNPG's streaming replication is explicitly designed around it: the replication provides the data redundancy, and CNPG's failover logic accounts for the fact that pods are node-pinned by their local-path PVC.

MariaDB uses `longhorn` for two reasons:

1. **Pod rescheduling on node failure.** local-path stamps a `nodeAffinity` onto every PV that pins it to a specific node. If that node fails, the pod sits `Pending` indefinitely — it cannot be rescheduled elsewhere. Longhorn PVCs are not node-pinned, so if the primary's node fails the operator can bring the primary pod up on any surviving node immediately, without manual PV/PVC cleanup.

2. **Volume expansion.** local-path ignores capacity limits and does not support reliable PVC expansion. Longhorn supports online volume expansion, which matters here because all app databases share a single cluster PVC and we cannot size per-database.

The trade-off is double-replication overhead (Longhorn block replication + async DB replication). For production-critical WordPress sites this is the right call.

### Per-application databases

Every application gets its own MariaDB database and user. Isolation is enforced at the credential layer — each app's user only has access to its own database.

Unlike the Postgres cluster (where CNPG has no standalone Role CRD and forces roles into the Cluster spec), mariadb-operator provides standalone `Database`, `User`, and `Grant` CRDs. These live in the **owning app's folder** (e.g. `apps/wordpress-sitename/`) with `namespace: mariadb` set on each resource. The app's ArgoCD Application deploys them to the `mariadb` namespace automatically.

---

## First-time setup

Fill in real passwords, seal the root secret, then commit:

```bash
# The mariadb namespace must exist before sealing — kubeseal uses the namespace
# as part of the authenticated encryption and will produce an undecryptable secret
# if the namespace doesn't exist in the cluster at sealing time.
kubectl create namespace mariadb

# Edit apps/mariadb/secret-mariadb-root.yaml and replace both PLACEHOLDER_CHANGE_ME values
# root-password and repl-password must be different from each other

kubeseal --format yaml < apps/mariadb/secret-mariadb-root.yaml > apps/mariadb/sealedsecret-mariadb-root.yaml
rm apps/mariadb/secret-mariadb-root.yaml

git add apps/
git commit -m "Add shared MariaDB cluster with mariadb-operator"
git push
```

ArgoCD will sync in wave order: mariadb-operator-crds (wave -3) → mariadb-operator (wave -2) → MariaDB cluster (wave -1). The CRDs must be registered before the operator starts — the separate CRDs chart ensures this ordering. The cluster takes 2–3 minutes to initialize on first sync as it sets up replication.

Verify the cluster is healthy:

```bash
kubectl get mariadb -n mariadb
# NAME      READY   STATUS    PRIMARY POD    AGE
# mariadb   True    Running   mariadb-0      3m

kubectl get pods -n mariadb
# NAME        READY   STATUS    RESTARTS   AGE
# mariadb-0   1/1     Running   0          3m   ← primary
# mariadb-1   1/1     Running   0          2m   ← replica
```

---

## Adding a new application database

Use this workflow when deploying an application that needs a new MariaDB database.
All three CRDs (`Database`, `User`, `Grant`) go in the **app's own folder** with `namespace: mariadb`.

### Phase 1 — Provision the database

**1. Create the database, user, and grant manifests in the app folder:**

```yaml
# apps/APPNAME/database-APPNAME.yaml
apiVersion: k8s.mariadb.com/v1alpha1
kind: Database
metadata:
  name: APPNAME
  namespace: mariadb
spec:
  mariaDbRef:
    name: mariadb
  characterSet: utf8mb4
  collate: utf8mb4_unicode_ci
```

```yaml
# apps/APPNAME/user-APPNAME.yaml
apiVersion: k8s.mariadb.com/v1alpha1
kind: User
metadata:
  name: APPNAME
  namespace: mariadb
spec:
  mariaDbRef:
    name: mariadb
  passwordSecretKeyRef:
    name: APPNAME-db-credentials
    key: password
  # Allow connections from any pod in the cluster.
  host: "%"
  maxUserConnections: 20
```

```yaml
# apps/APPNAME/grant-APPNAME.yaml
apiVersion: k8s.mariadb.com/v1alpha1
kind: Grant
metadata:
  name: APPNAME
  namespace: mariadb
spec:
  mariaDbRef:
    name: mariadb
  privileges:
    - ALL PRIVILEGES
  database: APPNAME
  table: "*"
  username: APPNAME
  grantOption: false
```

```yaml
# apps/APPNAME/secret-APPNAME-db-credentials.yaml
# Fill in a strong password, then seal:
#   kubeseal --format yaml < apps/APPNAME/secret-APPNAME-db-credentials.yaml > apps/APPNAME/sealedsecret-APPNAME-db-credentials.yaml
#   rm apps/APPNAME/secret-APPNAME-db-credentials.yaml
apiVersion: v1
kind: Secret
metadata:
  name: APPNAME-db-credentials
  namespace: mariadb
type: Opaque
stringData:
  password: PLACEHOLDER_CHANGE_ME
```

> **Password duplication:** If the application pod reads its database password from a separate app-namespace secret (e.g. a combined `apps/APPNAME/secret-APPNAME.yaml` in the `APPNAME` namespace), the database password value must match what is in `sealedsecret-APPNAME-db-credentials` above. Kubernetes pods cannot reference secrets across namespaces, so the credential must appear in both the `mariadb`-namespace secret (for the User CRD) and the app-namespace secret (for the pod). Keep them in sync when rotating passwords.

**2. Create the ArgoCD Application manifest:**

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

**3. Seal the credentials, commit, and sync:**

```bash
# Create the mariadb namespace if it doesn't already exist — required before sealing.
# kubeseal hashes the namespace into the ciphertext; sealing before the namespace
# exists produces a secret the controller cannot decrypt.
kubectl create namespace mariadb --dry-run=client -o yaml | kubectl apply -f -

kubeseal --format yaml < apps/APPNAME/secret-APPNAME-db-credentials.yaml > apps/APPNAME/sealedsecret-APPNAME-db-credentials.yaml
rm apps/APPNAME/secret-APPNAME-db-credentials.yaml

git add apps/
git commit -m "Add APPNAME: provision MariaDB database and user"
git push
```

Sync ArgoCD and verify:

```bash
kubectl get database,user,grant -n mariadb
```

### Phase 2 — Deploy the application

Add the application's `Deployment`, `Service`, `IngressRoute`, and any other manifests to `apps/APPNAME/`. The connection string for the app:

```text
host:     mariadb-primary.mariadb.svc.cluster.local
port:     3306
database: APPNAME
user:     APPNAME
password: (from sealedsecret-APPNAME-db-credentials)
```

Commit, push, and sync. ArgoCD picks up the new manifests automatically.

### Phase 3 — Smoke test

Verify the application is healthy and can read/write its database. Once confirmed, the deployment is complete.

---

## Enabling backups (deferred)

mariadb-operator supports scheduled backups via the `Backup` CRD with S3-compatible storage. When an S3-compatible endpoint is available:

1. Create and seal credentials for the S3 endpoint
2. Add a `Backup` CRD to `apps/mariadb/` referencing the endpoint and a schedule
3. Document the restore procedure in `docs/disaster-recovery.md`

---

## Expanding the cluster storage

Longhorn supports online PVC expansion without downtime:

```bash
# Patch the MariaDB resource to request more storage
kubectl patch mariadb mariadb -n mariadb --type=merge \
  -p '{"spec":{"storage":{"size":"50Gi"}}}'

# Longhorn will expand the underlying volumes automatically.
# Verify the new size:
kubectl get pvc -n mariadb
```

---

## Troubleshooting

### Cluster not reaching Ready state

```bash
kubectl describe mariadb mariadb -n mariadb
kubectl get events -n mariadb --sort-by='.lastTimestamp'

# Operator logs — installed in the mariadb-operator namespace (see apps/manifests/mariadb-operator.yaml).
# If unsure, locate the operator pod first with the portable label selector:
#   kubectl get pods -A -l app.kubernetes.io/name=mariadb-operator
kubectl logs -n mariadb-operator -l app.kubernetes.io/name=mariadb-operator
```

### Replication lag or replica not syncing

```bash
kubectl get mariadb mariadb -n mariadb -o jsonpath='{.status}' | jq
```

### User or Grant not applying

```bash
kubectl describe user APPNAME -n mariadb
kubectl describe grant APPNAME -n mariadb
# Check that the sealedsecret was decrypted successfully:
kubectl get secret APPNAME-db-credentials -n mariadb
```

### SealedSecret exists but Secret was never created

Same troubleshooting steps as Postgres — see `docs/troubleshooting.md` and check the sealed-secrets controller logs:

```bash
kubectl logs -n kube-system -l name=sealed-secrets-controller
```
