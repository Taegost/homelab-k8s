---
name: decisions
description: Key architectural and technical decisions with reasoning. Load when making design choices or understanding why something is built a certain way.
triggers:
  - "why do we"
  - "why is it"
  - "decision"
  - "alternative"
  - "we chose"
edges:
  - target: context/architecture.md
    condition: when a decision relates to system structure
  - target: context/stack.md
    condition: when a decision relates to technology choice
last_updated: 2026-06-16
---

# Decisions

## Decision Log

### Use kube-vip for control-plane load balancing
**Status:** Active
**Decision:** kube-vip handles the Kubernetes API server load balancer IP, installed manually pre-cluster (outside this repo).
**Reasoning:** Provides a floating VIP for the k3s API server across all nodes without requiring an external LB appliance. Runs as a DaemonSet with BGP or ARP mode.
**Consequences:** Must be installed before k3s bootstrap; not managed by ArgoCD or this repo.

### MetalLB (L2/ARP mode) for LoadBalancer services
**Status:** Active
**Decision:** MetalLB allocates LoadBalancer IPs from an IPAddressPool in L2/ARP mode.
**Reasoning:** k3s bare-metal cluster has no cloud provider; MetalLB fills the LoadBalancer gap. L2/ARP mode works with pfSense-routered subnets (`192.168.5.0/24`).
**Consequences:** Services get external IPs on the local network; no BGP complexity needed.

### Traefik as sole ingress controller
**Status:** Active
**Decision:** Traefik is the only ingress controller; all HTTP/HTTPS traffic routes through it.
**Reasoning:** Single ingress point simplifies middleware management, TLS termination, and routing rules. Traefik's IngressRoute CRD is more expressive than Ingress for this use case. HTTP-to-HTTPS redirect handled at entrypoint level, not per-route middleware.
**Consequences:** All apps must use IngressRoute resources. Traefik's `forwardedHeaders.trustedIPs: 10.0.0.0/8` required for real client IPs in k3s.

### Sealed Secrets (not External Secrets Operator)
**Status:** Active
**Decision:** All cluster secrets use Sealed Secrets (`kubeseal`); no External Secrets Operator, no Vault, no plaintext.
**Reasoning:** Simplest model for a single-cluster homelab — no external secrets store to operate. Secrets are encrypted at rest in git, decrypted by controller in `kube-system`.
**Consequences:** Sealed secrets are namespace-scoped; a secret sealed for namespace `foo` cannot decrypt in `bar`. PostgreSQL apps require two identical secrets (one in `postgres` namespace, one in app namespace). Claude must never set bypass env vars (`HOMELAB_ALLOW_LATEST`, `HOMELAB_ALLOW_MAIN`).

### Longhorn for replicated app storage (not local-path)
**Status:** Active
**Decision:** Longhorn provides RWO block storage for stateful app config/data; `local-path` remains the k3s default but is opt-in via `storageClassName: longhorn`.
**Reasoning:** Longhorn replicates volumes across nodes, surviving individual node loss. `local-path` is node-local with no replication — fine for CNPG (which replicates at the database level) but not for app config.
**Consequences:** `open-iscsi` required on all nodes pre-deployment. `csi.kubeletRootDir: /var/lib/kubelet` — changing this was root cause of a multi-hour troubleshooting session. Single-replica apps must use `strategy: Recreate` because RWO volumes cannot be attached to two nodes simultaneously.

### local-path for CNPG storage
**Status:** Active
**Decision:** CNPG PostgreSQL uses `local-path` PVCs, not Longhorn.
**Reasoning:** CNPG provides its own replication (primary + replica), so node-local storage avoids the overhead of Longhorn replication on top of database replication. Simpler, faster.
**Consequences:** If the node hosting the primary PVC is lost, CNPG promotes the replica; the PVC must be recreated on a surviving node.

### Wildcard cert in traefik namespace; per-app cert for public-facing apps
**Status:** Active
**Decision:** Wildcard TLS cert (`*.home.diceninjagaming.com`) lives in the `traefik` namespace so IngressRoutes in that namespace can reference it directly. Publicly exposed apps (WordPress, Mealie, Manyfold) use per-app explicit certs in their own namespace.
**Reasoning:** Internal apps share the wildcard for simplicity; public apps need their own cert for domain-specific TLS and browser trust. `allowCrossNamespace: true` enables cross-namespace Middleware references but not cross-namespace Secrets.
**Consequences:** IngressRoute files for wildcard-cert apps live in the app directory but deploy to `traefik` namespace. Public apps must include Certificate resources alongside IngressRoute.

### ArgoCD app-of-apps pattern
**Status:** Active
**Decision:** One root `app-of-apps.yaml` Application points at `apps/manifests/`, which contains one ArgoCD Application manifest per app. Adding a new app = adding a new file to `apps/manifests/`.
**Reasoning:** Scales cleanly — each app is independently managed, can be synced/pruned individually. Root Application is not managed by ArgoCD itself (bootstrap artifact).
**Consequences:** Removing an app = deleting `apps/manifests/<app>.yaml` (ArgoCD prunes everything). `app-of-apps.yaml` must be applied manually if changed.

### Raw manifests (not Helm) for app workloads
**Status:** Active
**Decision:** Application-level workloads (Arr-stack, Authentik, WordPress, etc.) use raw Kubernetes manifests; Helm is reserved for operator-managed infrastructure (Longhorn, MetalLB, cert-manager, CSI drivers, CNPG).
**Reasoning:** Raw manifests give full control over every field, make security context and resource requirements explicit, and avoid Helm template complexity. Chart version in `targetRevision` is single source of truth for Helm-based apps.
**Consequences:** Image upgrades are done by updating the image tag in the Deployment manifest and pushing to git.

### Strategy: Recreate for single-replica Longhorn apps
**Status:** Active
**Decision:** All single-replica Deployments with Longhorn RWO volumes must use `strategy: Recreate`.
**Reasoning:** Default `RollingUpdate` creates a new pod before terminating the old one. If the new pod lands on a different node, it cannot attach the RWO volume because the old pod still holds it. `Recreate` terminates the old pod first, releasing the attachment.
**Consequences:** Brief downtime during rollouts. Applies to Arr-stack, Mealie, and any future single-replica app with a Longhorn RWO PVC.

### ArgoCD HA migration pending
**Status:** Active
**Decision:** All 3 nodes are currently active. ArgoCD HA migration is pending.
**Reasoning:** HA ArgoCD requires all nodes to be healthy and Longhorn replica count increased for existing volumes.
**Consequences:** Follow `docs/argocd-ha-migration.md` to switch. Increase Longhorn replica count manually via UI or kubectl for existing volumes; new volumes pick up the default automatically.
