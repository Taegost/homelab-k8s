---
name: stack
description: Technology stack, library choices, and the reasoning behind them. Load when working with specific technologies or making decisions about libraries and tools.
triggers:
  - "library"
  - "package"
  - "dependency"
  - "which tool"
  - "technology"
edges:
  - target: context/decisions.md
    condition: when the reasoning behind a tech choice is needed
  - target: context/conventions.md
    condition: when understanding how to use a technology in this codebase
last_updated: 2026-06-16
---

# Stack

## Core Technologies

- **k3s** — lightweight Kubernetes distribution; 3 combined control-plane/worker nodes, additional worker-only nodes may be added
- **ArgoCD** — GitOps controller, app-of-apps pattern, sync waves for ordering
- **Traefik** — sole ingress controller (Helm-installed, `apps/traefik/values.yaml`)
- **Helm** — chart version in `targetRevision` is single source of truth; bootstrap extracts with `grep -A1 "chart: <n>" apps/manifests/<app>.yaml | grep "targetRevision:" | awk '{print $2}'`
- **Raw Kubernetes manifests** — static-manifest apps (Arr-stack, Authentik, WordPress, etc.) versioned by image tag in Deployment

## Per-App Patterns

### *arr Stack (`apps/arr-stack/`)

All media automation apps in `arr-stack` namespace, single ArgoCD Application.

Each app: `deployment-<name>.yaml` (strategy Recreate), `service-<name>.yaml` (ClusterIP), `ingressroute-<name>.yaml` (file in app dir, deploys to `traefik` namespace), `persistentvolumeclaim-<name>-config.yaml` (Longhorn RWO), `persistentvolumeclaim-<name>-backups.yaml` (`smb-backups`).

Standard volume mounts: `/config` (Longhorn PVC), `/backups` (SMB PVC, isolated subdir per app), `/multimedia` (static PV + PVC binding via `persistentvolume-arr-stack-multimedia.yaml`).

### Authentik (`apps/authentik/`)

Primary SSO, raw manifests (not Helm). 2 server replicas (rolling updates, zero auth downtime), 1 worker, 1 Redis, 1 LDAP outpost. PostgreSQL: shared CNPG cluster. Protect routes via `authentik` forward-auth middleware in `traefik` namespace. Public apps handle OIDC directly.

### WordPress Sites (`apps/wordpress-<sitename>/`)

One namespace per site. Raw manifests only (Deployment, Service, IngressRoute, PVC, Certificate, ConfigMap, SealedSecrets). Image: official `wordpress:*-apache`, version pinned in image tag (do not use WordPress Admin "Update WordPress" button). MariaDB backend via Database/User/Grant CRDs in app folder (namespace `mariadb`). Only `wp-content` mounted on Longhorn RWX PVC; core WordPress files ephemeral. Public-facing sites use per-app explicit certs. `fsGroup: 33` (www-data) required. Loopback plugin (`configmap-wordpress-loopback-plugin.yaml`) rewrites self-requests to stay inside cluster. Shared WordPress secret keys (auth salts) managed as SealedSecret. See `apps/wordpress-dng/` for working example.

### Shared PostgreSQL — CNPG (`apps/postgres/`)

PostgreSQL 18, 2 instances (primary + replica), `local-path` PVCs. App connection: `postgres-pooler.postgres.svc.cluster.local:5432` (PgBouncer). Direct: `postgres-rw.postgres.svc.cluster.local:5432` (use only for advisory locks or Alembic migrations). Roles declared in `apps/postgres/cluster-postgres.yaml` under `spec.managed.roles`. New apps/migrations: follow `docs/postgres-runbooks.md`.

### Shared MariaDB — mariadb-operator (`apps/mariadb/`)

MariaDB 12.2.2, 2 instances (primary + replica, async GTID replication), `longhorn` PVCs. Write: `mariadb-primary.mariadb.svc.cluster.local:3306`. Read: `mariadb-secondary.mariadb.svc.cluster.local:3306`. Standalone Database/User/Grant CRDs in app's own folder, `namespace: mariadb`. New apps: follow `docs/mariadb-runbooks.md`.

### Shared MongoDB — PSMDB (`apps/percona-mongodb/`)

Percona Server for MongoDB, managed by Percona MongoDB Operator. Cluster CRD + sealed secrets. New apps: follow `docs/mongodb-runbooks.md`.

## Container Images

- No `:latest` tags — pre-commit hook blocks unpinned image tags (override requires `HOMELAB_ALLOW_LATEST=1`, which Claude must never set)
- Security context must be audited per image before writing a Deployment: run `.claude/skills/homelab-image-audit/audit.sh --image <image> --type <type>` to get recommended capabilities, privilege model, and port
- For images not in the KB: fetch Dockerfile and entrypoint to determine USER, root-to-non-root drops (gosu, su-exec), and required capabilities (CHOWN, DAC_OVERRIDE, SETUID, SETGID). Use minimum necessary; fully non-root images with no runtime drops: drop ALL capabilities
- Never assume port 80 for non-root containers — non-root cannot bind to ports < 1024. Check Dockerfile for actual listen port (commonly 8080, 8000, 3000, 9000); set `containerPort`, Service `targetPort`, and health probe ports to match

## What We Deliberately Do NOT Use

- `kubectl apply` — direct cluster changes bypass audit trail, pre-commit validation, and sync wave ordering; all changes go through git and ArgoCD
- Helm for every app — Arr-stack, Authentik, WordPress, and many others use raw manifests; Helm is only for operator-managed infrastructure (Longhorn, MetalLB, cert-manager, CSI drivers, etc.)
- `git commit --amend` — rewrites commit hash, causes merge conflicts

## LibreChat NetworkPolicy Note

The meilisearch and redis NetworkPolicies in `apps/librechat/` use `podSelector` without `namespaceSelector` in their `from` entries. These are same-namespace policies and work correctly, but do not comply with the updated `.claude/skills/homelab-validate/scripts/networkpolicy-check.sh` rule. Files to update: `apps/librechat/networkpolicy-meilisearch.yaml`, `apps/librechat/networkpolicy-redis.yaml`. Fix: add `namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: librechat } }` alongside each `podSelector`.

## Version Constraints

- PostgreSQL 18 (CNPG)
- MariaDB 12.2.2 (mariadb-operator)
- Traefik v3 — `HostRegexp` syntax changed: `` HostRegexp(`.+`) `` not `^.+$`
- `csi.kubeletRootDir: /var/lib/kubelet` — do not change back to the old k3s path (root cause of multi-hour troubleshooting)
- ArgoCD HA migration pending — all nodes active, follow `docs/argocd-ha-migration.md`; increase Longhorn replica count for existing volumes manually
