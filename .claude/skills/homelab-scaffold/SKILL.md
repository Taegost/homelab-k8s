---
name: homelab-scaffold
description: Use when creating new Kubernetes manifests, scaffolding apps, or sealing secrets in the homelab-k8s repo. Triggers on "scaffold a new app", "create manifests for", "seal this secret", "add a new deployment".
---

# Homelab Scaffold

New app scaffolding and sealed secret workflow for the homelab-k8s GitOps repo.

## 1. New App Scaffold

### Step 1: Determine database type

| Signal | Database |
|---|---|
| "Postgres", "CNPG" | Postgres |
| "MariaDB", "MySQL" | MariaDB |
| "MongoDB", "Mongo" | MongoDB |
| No DB mentioned | Stateless |

### Step 2: Choose visibility

| Visibility | IngressRoute namespace | TLS | Middleware | Needs Certificate? |
|---|---|---|---|---|
| Internal | `traefik` | Wildcard cert from `apps/traefik/certificates/` | `default-whitelist` (traefik namespace) | No |
| Public | App namespace | Per-app explicit Certificate | `default-headers` (no whitelist) | Yes |

Override middleware only when user explicitly directs otherwise.

### Step 3: Generate files

**Every app:**
```
apps/<appname>/
├── deployment-<appname>.yaml
apps/manifests/
└── <appname>.yaml  (ArgoCD Application, wave 0)
```

**Service** (only when reached by IngressRoute or other in-cluster services):
```
apps/<appname>/
└── service-<appname>.yaml
```

**Internal IngressRoute:**
```
apps/<appname>/
└── ingressroute-<appname>.yaml  (namespace: traefik, wildcard cert, default-whitelist)
```

**Public IngressRoute:**
```
apps/<appname>/
├── certificate-<appname>.yaml
└── ingressroute-<appname>.yaml  (namespace: <appname>, per-app cert, default-headers, no whitelist)
```

**Database resources — Postgres:**
```
apps/<appname>/
├── database-<appname>.yaml                 (namespace: postgres)
├── secret-<appname>-db-credentials.yaml     (namespace: postgres, wave -3)
└── sealedsecret-<appname>-db-credentials.yaml (after sealing)
# Also MODIFY: apps/postgres/cluster-postgres.yaml (add role to spec.managed.roles)
```

**Database resources — MariaDB:**
```
apps/<appname>/
├── database-<appname>.yaml                 (namespace: mariadb, wave -1)
├── user-<appname>.yaml                     (namespace: mariadb, wave -2)
├── grant-<appname>.yaml                    (namespace: mariadb, wave -2)
├── secret-<appname>-db-credentials.yaml     (namespace: mariadb, wave -3)
└── sealedsecret-<appname>-db-credentials.yaml (after sealing)
```

**Database resources — MongoDB:**
```
apps/<appname>/
├── secret-<appname>-db-credentials.yaml     (namespace: mongodb, wave -3)
└── sealedsecret-<appname>-db-credentials.yaml (after sealing)
# Also MODIFY: apps/percona-mongodb/perconaservermongodb-mongodb.yaml (add user to spec.users)
```

### Step 4: Sync wave pre-fill

Annotate each resource with `argocd.argoproj.io/sync-wave` in `metadata.annotations`:

| Resource type | Wave |
|---|---|
| SealedSecret (any namespace) | `-3` |
| User, Grant (MariaDB) | `-2` |
| Database CRD | `-1` |
| Deployment, Service, IngressRoute, Certificate, PVC | `0` (omit annotation) |

SealedSecrets must have the annotation in BOTH `metadata.annotations` AND `spec.template.metadata.annotations`.

### Step 5: Conventions (from CLAUDE.md)

- Placeholder values: underscores only, no dots or dashes (`your_api_key_here`)
- Longhorn PVCs + non-root container → `fsGroup` in pod `securityContext`. Root containers don't need it.
- Non-root containers: check Dockerfile for UID/GID, drop ALL capabilities
- `Recreate` strategy for single-replica Deployments with RWO PVCs
- `kubeseal` commands: single line, never split with backslash continuations

### Step 6: Template files

- Deployment: `apps/mealie/deployment-mealie.yaml`
- Internal IngressRoute: `apps/arr-stack/bazarr/ingressroute-bazarr.yaml`
- Public IngressRoute: `apps/mealie/ingressroute-mealie.yaml`
- ArgoCD Application: `apps/manifests/mealie.yaml`

---

## 2. Sealed Secret Workflow

### Namespace must exist first

```bash
kubectl create namespace <namespace> --dry-run=client -o yaml | kubectl apply -f -
```

### Key generation

MongoDB keyfile (756 bytes):
```bash
openssl rand -base64 756 | tr -d '\n' | base64 -w0
```

MongoDB encryption key (32 bytes):
```bash
openssl rand -base64 32 | tr -d '\n' | base64 -w0
```

Alphanumeric password (MongoDB-safe, no URL-encoding):
```bash
openssl rand -base64 32 | tr -dc 'a-zA-Z0-9'
```

### Seal (single line, copy-paste friendly)

```bash
kubeseal --format yaml < apps/<app>/secret-<name>.yaml > apps/<app>/sealedsecret-<name>.yaml
```

### Cleanup

```bash
rm apps/<app>/secret-<name>.yaml
git add apps/<app>/sealedsecret-<name>.yaml
```

### Password duplication (Postgres, MariaDB, MongoDB)

When a DB password appears in two namespaces (DB namespace for the operator + app namespace for the pod): generate ONE password, place identical value in both plaintext secrets, seal both, delete both plaintexts.
