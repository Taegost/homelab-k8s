---
name: architecture
description: How the major pieces of this project connect and flow. Load when working on system design, integrations, or understanding how components interact.
triggers:
  - "architecture"
  - "system design"
  - "how does X connect to Y"
  - "integration"
  - "flow"
edges:
  - target: context/stack.md
    condition: when specific technology details are needed
  - target: context/decisions.md
    condition: when understanding why the architecture is structured this way
  - target: patterns/add-app.md
    condition: when adding a new app to the cluster
  - target: patterns/debug-sync-failure.md
    condition: when diagnosing sync or reconciliation issues
last_updated: 2026-06-16
---

# Architecture

## System Overview

Git commit pushed to `main` triggers ArgoCD reconciliation. ArgoCD reads the
app-of-apps pattern: one root Application points at `apps/manifests/*.yaml`,
each of which points at a directory of manifests or a Helm chart. Helm-based
apps resolve chart versions from `targetRevision` in the Application manifest.
Static-manifest apps have version frozen in image tags.

Within the cluster: pfSense handles routing at the network edge; MetalLB
provides L2/ARP LoadBalancer IPs; Traefik is the sole ingress controller,
terminating TLS via cert-manager (Let's Encrypt DNS-01 over Route53). Apps
expose themselves as IngressRoutes; external (non-Kubernetes) services use
ExternalName Services with raw IPs, also routed through Traefik.

Data tier: shared CNPG PostgreSQL (2 instances, PgBouncer pooler), shared
mariadb-operator MariaDB (2 instances, async GTID replication), Percona MongoDB
(1 instance). Each app gets its own database/role per database engine. Secrets
are SealedSecrets only, decrypted by the controller in `kube-system` before
dependent resources deploy (sync-wave ordering).

Storage tier: Longhorn provides replicated RWO block storage for app config.
SMB CSI (`csi-driver-smb`) provides RWX backup volumes on Unraid. NFS CSI
exists as reference-only. `local-path` backs CNPG (replication provides
redundancy). Single-replica apps use `strategy: Recreate` on Longhorn volumes.

## Key Components

- **ArgoCD** (namespace `argocd`) — GitOps controller, syncs all workloads from git. Root Application (`app-of-apps.yaml`) bootstraps; not managed by ArgoCD itself.
- **Traefik** (namespace `traefik`) — sole ingress controller, handles HTTP-to-HTTPS redirect at entrypoint level, uses `forwardedHeaders.trustedIPs: 10.0.0.0/8` for real client IPs. HostRegexp catch-all: `` HostRegexp(`.+`) `` (Traefik v3 syntax).
- **Sealed Secrets** (namespace `kube-system`) — sole secrets mechanism; plaintext secrets are never committed. `secret-*.yaml` is gitignored; `sealedsecret-*.yaml` is committed.
- **CloudNativePG (CNPG)** (namespace `cnpg-system`) — operator for shared PostgreSQL 18 cluster (2 instances). Roles declared in `apps/postgres/cluster-postgres.yaml`.
- **mariadb-operator** (namespace `mariadb`) — operator for shared MariaDB 12.2.2 cluster (2 instances, async GTID). Standalone Database/User/Grant CRDs live in the app's own folder.
- **Percona MongoDB Operator** (namespace `psmdb-operator`) — manages PSMDB CRD for MongoDB cluster.
- **Longhorn** (namespace `longhorn-system`) — replicated RWO storage. `csi.kubeletRootDir: /var/lib/kubelet` (do not change). Opt-in via `storageClassName: longhorn`.
- **MetalLB** (namespace `metallb-system`) — L2/ARP mode LoadBalancer IP allocation.
- **cert-manager** (namespace `cert-manager`) — Let's Encrypt DNS-01 via Route53. ClusterIssuers: `letsencrypt-diceninjagaming-prod` and `letsencrypt-diceninjagaming-staging`.
- **Authentik** (namespace `authentik`) — primary SSO layer, 2 server replicas, 1 worker, Redis, LDAP outpost. Forward-auth middleware in traefik namespace.
- **SMB CSI Driver** (`apps/manifests/smb-csi.yaml`) — dynamic SMB provisioning to Unraid (`firebird.lan`), credentials in `apps/smb-csi/sealedsecret-smb-creds.yaml`.

## External Dependencies

- **pfSense** — network edge router, not managed in this repo
- **Unraid NAS** (`firebird.lan`) — SMB and NFS storage target for `csi-driver-smb` and `csi-driver-nfs`
- **Route53** — public DNS and Let's Encrypt DNS-01 challenge solver
- **kube-vip** — pre-cluster load balancer, installed manually outside this repo

## What Does NOT Exist Here

- Ansible, LLM server configuration, Docker Compose files (unless being migrated), pfSense config, Unraid config, or any non-Kubernetes homelab work
- Direct `kubectl apply` usage — all cluster changes must go through git commits and ArgoCD sync (never bypass the GitOps pipeline)
- `git commit --amend` — forbidden; rewrites commit hash, causes merge conflicts
- Bypass env vars (`HOMELAB_ALLOW_LATEST`, `HOMELAB_ALLOW_MAIN`) — Claude must never set these; flag to user if a bypass is needed
