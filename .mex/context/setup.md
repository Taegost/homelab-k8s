---
name: setup
description: Dev environment setup and commands. Load when setting up the project for the first time or when environment issues arise.
triggers:
  - "setup"
  - "install"
  - "environment"
  - "getting started"
  - "how do I run"
  - "local development"
edges:
  - target: context/stack.md
    condition: when specific technology versions or library details are needed
  - target: context/architecture.md
    condition: when understanding how components connect during setup
  - target: patterns/debug-sync-failure.md
    condition: when troubleshooting deployment or sync issues
  - target: patterns/add-app.md
    condition: when adding a new app to the cluster
last_updated: 2026-06-16
---

# Setup

## Prerequisites

- k3s cluster running on 3 nodes (combined control-plane/worker)
- `open-iscsi` installed on all nodes (required by Longhorn)
- `nfs-common` (NFS client) and `cifs-utils` (SMB/CIFS client) installed on all nodes (required by Longhorn RWX volumes and SMB CSI mounts)
- `kubectl` access configured for the cluster
- Unraid NAS (`firebird.lan`) accessible for SMB/NFS storage
- Route53 access for DNS and Let's Encrypt DNS-01 challenges

## First-time Setup

1. Install kube-vip manually (pre-cluster, outside this repo)
2. Bootstrap k3s on all nodes
3. Install core stack via ArgoCD app-of-apps pattern (see "Core Stack bootstrap order" below)
4. Apply `app-of-apps.yaml` manually to bootstrap ArgoCD:
   ```bash
   kubectl apply -f app-of-apps.yaml
   ```
5. Install pre-commit hook in the local clone:
   ```bash
   ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
   ```

### Core Stack bootstrap order (sync waves)

| Component | Namespace | Install method | Sync wave |
|---|---|---|---|
| kube-vip | (pre-cluster, outside repo) | Manual | — |
| mariadb-operator CRDs | cluster-scoped | Helm | `-3` |
| Percona MongoDB Operator CRDs | cluster-scoped | Helm | `-3` |
| Sealed Secrets | `kube-system` | Static manifest | `-2` |
| cert-manager | `cert-manager` | Helm | `-2` |
| MetalLB | `metallb-system` | Helm | `-2` |
| mariadb-operator | `mariadb` | Helm | `-2` |
| Percona MongoDB Operator | `psmdb-operator` | Helm | `-2` |
| NFS CSI Driver | `nfs-csi` | Helm | `-1` |
| SMB CSI Driver | `smb-csi` | Helm | `-1` |
| infrastructure (StorageClasses) | cluster-scoped | Static manifests | `-1` |
| Traefik | `traefik` | Helm | `-1` |
| ArgoCD | `argocd` | Static manifest | `0` |
| Longhorn | `longhorn-system` | Helm | `0` |
| CNPG operator | `cnpg-system` | Helm | `0` |
| Postgres cluster | `postgres` | CNPG CRDs | `1` |
| MariaDB cluster | `mariadb` | mariadb-operator CRDs | `1` |
| MongoDB cluster | `mongodb` | PSMDB CRD | `-1` |
| All app workloads | per-app namespace | Helm or static | `0` |

## Repository Structure

```
homelab-k8s/
├── app-of-apps.yaml              # Root ArgoCD Application — bootstrap entry point
├── apps/
│   ├── manifests/                # One ArgoCD Application manifest per app
│   ├── argocd/                   # ArgoCD install manifest + IngressRoute + ConfigMap
│   ├── arr-stack/                # *arr media stack (Bazarr, NeutArr, Prowlarr, etc.)
│   ├── authentik/                # Authentik SSO — server, worker, Redis, LDAP outpost
│   ├── aws-ddns/                 # AWS Dynamic DNS updater
│   ├── cert-manager/             # Helm values + ClusterIssuers
│   ├── cnpg/                     # CloudNativePG operator Helm values
│   ├── firefly3/                 # Firefly III personal finance manager
│   ├── infrastructure/
│   │   └── storage/              # StorageClass definitions (SMB, NFS)
│   ├── leantime/                 # Leantime project management
│   ├── librechat/                # LibreChat AI chat — MongoDB, Meilisearch, Redis, RAG API
│   ├── litellm/                  # LiteLLM API proxy
│   ├── longhorn/                 # Longhorn Helm values + IngressRoute
│   ├── manyfold/                 # Manyfold 3D model manager
│   ├── mariadb/                  # MariaDB cluster CRDs (Cluster, ConfigMap)
│   ├── mariadb-operator/         # mariadb-operator Helm values
│   ├── percona-mongodb/           # MongoDB cluster CRD + sealed secrets
│   ├── percona-mongodb-operator/  # Percona MongoDB operator Helm values
│   ├── mealie/                   # Mealie recipe manager
│   ├── metallb/                  # MetalLB Helm values + IPAddressPool
│   ├── n8n/                      # n8n workflow automation
│   ├── nfs-csi/                  # NFS CSI driver Helm values
│   ├── open-webui/               # Open WebUI AI chat interface
│   ├── plane/                    # Plane CE — project management (issues, cycles, views)
│   ├── postgres/                 # CNPG Cluster CRD + managed roles
│   ├── sealed-secrets/           # Sealed Secrets controller manifest
│   ├── searxng/                  # SearXNG meta search engine
│   ├── smb-csi/                  # SMB CSI driver Helm values + credentials
│   ├── traefik/                  # Helm values + middlewares/ + certificates/ + IngressRoutes
│   │   └── external/             # Routes to non-Kubernetes services
│   ├── wordpress-dng/            # DiceNinjaGaming WordPress site (diceninjagaming.com)
│   └── wordpress-taegost/        # Mike's portfolio/blog (taegost.com)
├── archived/                     # Removed configs kept for reference
├── bootstrap/                    # Manual bootstrap guide (README.md)
├── docs/
│   ├── argocd-ha-migration.md
│   ├── disaster-recovery.md
│   ├── mariadb-runbooks.md
│   ├── migration-traefik-docker.md
│   ├── mongodb-runbooks.md
│   ├── n8n-ha-migration.md
│   ├── postgres-runbooks.md
│   ├── sealed-secrets.md
│   ├── storage.md
│   ├── troubleshooting.md
│   ├── brainstorms/
│   └── plans/
└── README.md
```

## Common Commands

### Adding a new app (no database)
1. Create `apps/<app-name>/` with all manifests
2. Create `apps/manifests/<app-name>.yaml` as the ArgoCD Application manifest
3. ArgoCD picks it up automatically on next sync

### Adding a new app (with PostgreSQL)
Follow the phased workflow in `docs/postgres-runbooks.md`. Do not skip phases — the database must be provisioned and verified before the Deployment is created.

### Adding a new app (with MariaDB)
Follow `docs/mariadb-runbooks.md`. Database, User, and Grant CRDs go in the app's own folder with `namespace: mariadb`.

### Adding a new app (with MongoDB)
Follow `docs/mongodb-runbooks.md`.

### Removing an app
1. Delete `apps/manifests/<app-name>.yaml` — ArgoCD prunes everything
2. Optionally delete `apps/<app-name>/` afterward

### Helm-based apps — version management
Chart version is the single source of truth in `apps/manifests/<app-name>.yaml` `targetRevision`. Bootstrap extract:
```bash
grep -A1 "chart: <n>" apps/manifests/<app-name>.yaml | grep "targetRevision:" | awk '{print $2}'
```

### Manifest-based apps — version management
Version is frozen in the image tag in the Deployment manifest. Upgrade: update the image tag, commit and push — ArgoCD applies it.

### Run validation suite manually
```bash
/homelab-validate
```

### Audit container security context
```bash
.claude/skills/homelab-image-audit/audit.sh --image <image> --type <type>
```

## Common Issues

**ArgoCD Application stuck deleting:**
```bash
kubectl patch application <app-name> -n argocd -p '{"metadata":{"finalizers":[]}}' --type=merge
```

**SealedSecret exists but Secret was never created:** Wrong cluster key (re-seal with `kubeseal`), controller not running (`kubectl get pods -n kube-system -l name=sealed-secrets-controller`), or namespace mismatch (SealedSecret must be in the namespace it was sealed for). Check controller logs: `kubectl logs -n kube-system -l name=sealed-secrets-controller`.

**Pod stuck in CreateContainerConfigError:** Almost always a missing Secret or ConfigMap. `kubectl describe pod -n <namespace> <pod-name>` and `kubectl get secret -n <namespace>`.

**Deployment not picking up Secret changes:**
```bash
kubectl rollout restart deployment -n <namespace> <deployment-name>
```

**Longhorn PVC stuck in Pending:** Confirm `open-iscsi` on all nodes, confirm `csi.kubeletRootDir: /var/lib/kubelet` in `apps/longhorn/values.yaml`, check CSI pods (`kubectl get pods -n longhorn-system`), check PVC events, confirm CSI socket registered: `sudo ls /var/lib/kubelet/plugins_registry/` (should include `driver.longhorn.io-reg.sock`).

**SealedSecret sync wave ordering bug:** If a SealedSecret was committed with the annotation only in `spec.template.metadata.annotations` (not in `metadata.annotations`), ArgoCD treats it as wave 0. Fix: add `argocd.argoproj.io/sync-wave` to `metadata.annotations`. Diagnosis: `grep -n "sync-wave" apps/<app>/sealedsecret-*.yaml` — if hits are deeply indented under `spec:`, annotation is in the wrong place.
