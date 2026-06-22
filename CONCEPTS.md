# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## GitOps Resources

### SealedSecret
A Kubernetes CRD that stores an encrypted Secret. The Sealed Secrets controller decrypts it into a regular Secret at sync time. SealedSecrets are namespace-scoped — a secret sealed for namespace `foo` cannot be decrypted in `bar`. The plaintext form (`secret-*.yaml`) is gitignored; only the sealed form (`sealedsecret-*.yaml`) is committed.

### Sync Wave
An ArgoCD annotation (`argocd.argoproj.io/sync-wave`) that controls the order resources are applied. Negative waves sync first (infrastructure before apps), wave 0 is the default. SealedSecrets at wave -3 must decrypt before CRDs at wave -2 that consume them. Missing annotations cause race conditions where operators read empty secrets.

### IngressRoute
Traefik's CRD for HTTP routing. Replaces the standard Kubernetes Ingress resource. Lives in the `traefik` namespace when using the wildcard cert, or in the app's own namespace when using a per-app cert. Cross-namespace middleware references require `allowCrossNamespace: true`.

### ArgoCD Application
A CRD that declares what to deploy and where. Points at a directory in this repo; ArgoCD reconciles the cluster state to match. The app-of-apps pattern uses a root Application that points at `apps/manifests/`, which contains one Application per app.

## Storage

### Longhorn
The replicated block storage system used for stateful app data. StorageClass `longhorn` — opt-in, not the k3s default. Single-replica deployments must use `strategy: Recreate` to avoid RWO attachment conflicts. Volumes provisioned owned by root; non-root containers need `fsGroup` in pod securityContext.

### fsGroup
A Kubernetes pod securityContext field that causes the kubelet to recursively chown mounted volumes to the specified GID. Solves the "non-root container can't write to root-owned PVC" problem but has a critical side effect: it overwrites strict file permissions (mode 0600) on every mount, breaking applications like RabbitMQ that require owner-only access to cookie files. When `fsGroup` is incompatible, use an init container to set ownership instead.

### multipathd
A Linux daemon that claims block devices for multi-path I/O in enterprise SAN environments. Enabled by default on Ubuntu even on single-path hardware. Aggressively claims Longhorn's iSCSI-backed volumes via device-mapper, preventing the CSI driver from mounting them. Must be disabled on all cluster nodes before deploying Longhorn.

## Operators

### CNPG (CloudNativePG)
The PostgreSQL operator managing the shared Postgres cluster. Uses CRDs: `Cluster` (instances, storage), `Database` (database creation), `Role` (managed roles declared in the Cluster spec). App connections go through PgBouncer at `postgres-pooler.postgres.svc.cluster.local:5432`.

### Percona MongoDB Operator
The MongoDB operator managing the shared MongoDB cluster. Uses `PerconaServerMongoDB` CRD. Reads credentials from SealedSecrets at creation time — if secrets aren't decrypted yet (wrong sync wave), the operator generates random credentials that persist across syncs.

### mariadb-operator
The MariaDB operator managing the shared MariaDB cluster. Uses standalone CRDs: `Database`, `User`, `Grant` — these live in the app's own folder with `namespace: mariadb`. Unlike Postgres (where roles are in the Cluster spec), MariaDB uses separate CRDs per app.

## Deployment Patterns

### SSH Sandbox
A deployment pattern where an AI agent executes code in an isolated pod via SSH. The agent and sandbox run as separate Deployments in the same namespace. The sandbox runs sshd with specific capabilities (SETUID, SETGID, SYS_CHROOT, CHOWN, AUDIT_WRITE) and `allowPrivilegeEscalation: true`. NetworkPolicy isolates the sandbox: ingress restricted to the agent pod, egress limited to DNS and open internet (cluster CIDR and local network blocked via `ipBlock.except`). SSH keypairs authenticate the agent to the sandbox; the host keypair must be generated first because `known_hosts` derives from it.

### Base-Image Knowledge Base
A set of markdown files in `docs/solutions/base-images-*.md` that map container image types to their required Linux capabilities, privilege models, and port conventions. The pre-commit capability-check and the image-audit script auto-discover entries from this KB. Adding support for a new image type requires only creating a new KB file.

### Pre-Commit Validation Suite
Eleven automated checks in `.githooks/pre-commit` that run on every YAML commit. Five always-on (sync waves, YAML validity, plaintext secrets, secret templates, :latest tag guard) and six conditional (IngressRoute, Longhorn fsGroup, NetworkPolicy, probe timeout, capability, env injection). The `/homelab-validate` skill runs the same suite manually.

### MU Plugin (Must-Use Plugin)
A WordPress plugin in `wp-content/mu-plugins/` that loads before regular plugins and cannot be deactivated through the admin UI. Used in this project for the internal loopback rewriter that prevents WordPress self-requests from leaving the cluster.

## Relationships

- **SealedSecrets** must decrypt (wave -3) before **Percona MongoDB Operator** or **mariadb-operator** CRDs (wave -2) read them
- **CNPG Database** CRDs (wave -1) must exist before application Deployments (wave 0) connect
- **Longhorn** volumes require **fsGroup** for non-root containers, but **fsGroup** is incompatible with **RabbitMQ**'s Erlang cookie (use init container instead)
- **multipathd** must be disabled before **Longhorn** can attach iSCSI volumes

## Flagged Ambiguities

- "probe" refers to Kubernetes health probes (liveness, readiness, startup) — not network probes or database connection probes
- "secret" in this repo means either a Kubernetes Secret resource or a SealedSecret — context determines which; the plaintext `secret-*.yaml` files are gitignored artifacts
