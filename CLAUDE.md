# CLAUDE.md — homelab-k8s

This file instructs Claude Code on how to operate within this repository.
It is the authoritative source for conventions, patterns, and standards.

---

## Read Before Acting

Before implementing any change, read the relevant documentation first:

- **New app deployment or Postgres migration** → `docs/postgres-runbooks.md`
- **New app deployment with MariaDB database** → `docs/mariadb-runbooks.md`
- **Secrets workflow** → `docs/sealed-secrets.md`
- **Cluster recovery or node loss** → `docs/disaster-recovery.md`
- **DNS or networking issues** → `docs/troubleshooting.md`
- **External service routing** → `apps/traefik/external/README.md`
- **n8n HA migration (S3, queue mode, custom nodes)** → `docs/n8n-ha-migration.md`
- **ArgoCD HA migration (third node)** → `docs/argocd-ha-migration.md`

Do not assume context is current. Read the actual files.

---

## Project Scope

This repository manages all Kubernetes/GitOps work for Mike's homelab k3s cluster.

**In scope:** k3s cluster config, ArgoCD applications, Helm values, manifests,
Traefik ingress, cert-manager, MetalLB, Longhorn, Sealed Secrets, SMB/NFS storage,
and all workloads deployed into the cluster.

**Out of scope:** Ansible, LLM server configuration, Docker Compose files (unless
being migrated), pfSense, Unraid, or any non-Kubernetes homelab work.

---

## Cluster Overview

- **Platform:** k3s, 3-node HA (currently 2 nodes active; third node pending)
- **Node type:** All nodes are combined control-plane/worker mini PCs
- **GitOps:** ArgoCD manages everything post-bootstrap via app-of-apps pattern
- **Networking:** pfSense router, MetalLB (L2/ARP mode), Traefik as sole ingress
- **Internal domain:** `home.diceninjagaming.com`
- **Subnets:** `192.168.5.0/24` (VMs/LXCs), `192.168.6.0/24` (workstations)
- **DNS:** Route53 for public DNS and Let's Encrypt DNS-01 challenges
- **Secrets:** Sealed Secrets only — no plaintext secrets ever committed

**When the third node comes online:** increase the ArgoCD replica count and enable
HA mode per `docs/argocd-ha-migration.md`. Also increase the Longhorn replica count
to 3 (existing volumes do not gain a third replica automatically — update via
Longhorn UI or kubectl).

---

## Core Stack (bootstrap order)

| Component | Namespace | Install method | Sync wave |
|---|---|---|---|
| kube-vip | (pre-cluster, outside repo) | Manual | — |
| Sealed Secrets | `kube-system` | Static manifest | `-2` |
| cert-manager | `cert-manager` | Helm | `-2` |
| MetalLB | `metallb-system` | Helm | `-2` |
| NFS CSI Driver | `nfs-csi` | Helm | `-1` |
| SMB CSI Driver | `smb-csi` | Helm | `-1` |
| infrastructure (StorageClasses) | cluster-scoped | Static manifests | `-1` |
| Traefik | `traefik` | Helm | `-1` |
| ArgoCD | `argocd` | Static manifest | `0` |
| Longhorn | `longhorn-system` | Helm | `0` |
| CNPG operator | `cnpg-system` | Helm | `0` |
| Postgres cluster | `postgres` | CNPG CRDs | `1` |
| All app workloads | per-app namespace | Helm or static | `0` |

---

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
│   ├── infrastructure/
│   │   └── storage/              # StorageClass definitions (SMB, NFS)
│   ├── longhorn/                 # Longhorn Helm values + IngressRoute
│   ├── manyfold/                 # Manyfold 3D model manager
│   ├── mealie/                   # Mealie recipe manager
│   ├── metallb/                  # MetalLB Helm values + IPAddressPool
│   ├── nfs-csi/                  # NFS CSI driver Helm values
│   ├── postgres/                 # CNPG Cluster CRD + managed roles
│   ├── sealed-secrets/           # Sealed Secrets controller manifest
│   ├── smb-csi/                  # SMB CSI driver Helm values + credentials
│   └── traefik/                  # Helm values + middlewares + IngressRoutes + certs
│       └── external/             # Routes to non-Kubernetes services (see below)
├── docs/
│   ├── argocd-ha-migration.md    # Steps to enable ArgoCD HA when third node arrives
│   ├── disaster-recovery.md      # Full cluster rebuild sequence
│   ├── migration-traefik-docker.md
│   ├── postgres-runbooks.md      # New app + migration workflows for CNPG
│   ├── sealed-secrets.md         # Full sealed secrets workflow
│   └── troubleshooting.md        # DNS, networking, and known gotchas
└── README.md
```

---

## Behavior Instructions

### Research and correctness
- **Always read the relevant docs/ file before implementing** — see the
  "Read Before Acting" section at the top of this file.
- **Always check latest docs** before writing any manifest, CRD, or Helm values —
  versions change and schemas evolve. Use web search to verify current release
  versions and field names.
- **Research before suggesting** — do not suggest a step and then contradict it
  later in the same response. Verify first.
- **Research best practices first** — check whether an established best practice
  exists before proposing a custom solution.
- **Don't repeat failed steps** — if something didn't work, think through what is
  actually different before proposing a next step.

### Communication
- **Only render changed sections of documentation** — when updating existing docs,
  present only the changed section with a placement annotation rather than the
  entire document.
- **When architecture changes, provide remediation steps** — if a design decision
  changes how things are set up, provide the full set of steps to bring the
  existing cluster in line, not just the file changes.
- **Ask, don't assume** — when something is unclear, ask rather than guess.
- **Sequence before execute** — think through architecture and dependencies fully
  before writing any config or code.
- **Only work on the phase explicitly requested** — for phased migrations (e.g.
  postgres runbook phases 1→2→3), do not create files for future phases until the
  user asks. Extra files create noise in their staging area.

### Values and secrets
- **Private values stay private** — hostnames, internal IPs, and domain-specific
  values are real values in manifests. Do not suggest placeholder values for things
  that are already implemented.
- **Single source of truth** — avoid situations where the same value exists in two
  places. Always identify the canonical location and reference it from there. This
  applies to versions in documentation: do not hardcode app or chart versions in
  runbooks or docs — reference the `image` tag in the deployment/CRD manifest or
  `targetRevision` in `apps/manifests/<app-name>.yaml` instead. Hardcoded versions
  drift the moment the manifest is updated.

---

## Comment Standards

Write comments for "future Mike reading this at 2am" — assume the reader knows
Kubernetes basics but may not remember why a specific decision was made.

- Explain non-obvious decisions and the "why" behind configuration choices
- Note version management approach and upgrade caveats
- Document gotchas that would save time during future troubleshooting
- Every non-trivial field that could reasonably be set differently should have a
  comment explaining why it is set the way it is
- Cross-reference related files inline (e.g. note which file creates a secret
  that an IngressRoute references)

---

## GitOps Workflow

- `main` is always the live cluster state — never push broken manifests directly
- All changes via feature branches → PR → merge to `main` → ArgoCD reconciles
- `app-of-apps.yaml` is a bootstrap artifact — not managed by ArgoCD, must be
  applied manually if changed

### Adding a new app (no database)
1. Create `apps/<app-name>/` with all manifests
2. Create `apps/manifests/<app-name>.yaml` as the ArgoCD Application manifest
3. ArgoCD picks it up automatically on next sync

### Adding a new app (with PostgreSQL)
Follow the phased workflow in `docs/postgres-runbooks.md`. Do not skip phases —
the database must be provisioned and verified before the Deployment is created.

### Removing an app
1. Delete `apps/manifests/<app-name>.yaml` — ArgoCD prunes everything
2. Optionally delete `apps/<app-name>/` afterward

---

## Secrets

All secrets use Sealed Secrets (`kubeseal`). See `docs/sealed-secrets.md` for the
full workflow including creating, updating, rotating, and backing up secrets.

**Key rules:**
- `secret-*.yaml` is gitignored (plaintext). `sealedsecret-*.yaml` is committed.
- Never commit plaintext secrets. No exceptions.
- Sealed secrets are namespace-scoped — a secret sealed for namespace `foo` cannot
  be decrypted in namespace `bar`.
- When creating a new secret, write the plain `secret-*.yaml` with placeholder
  values and provide the `kubeseal` command alongside it. Do not fill in real
  values — the user fills those in before sealing.
- Placeholder values must not contain dots (`.`) or dashes (`-`) — use underscores
  only (e.g. `your_sonarr_api_key_here`). Dots and dashes break word-selection in
  editors and terminals, making copy-paste harder.
- The `kubeseal` command must always be written as a single line. Never split it
  with backslash continuations — it needs to be copy-paste friendly.
- Apps that use PostgreSQL require the database password in **two** secrets: one in
  the `postgres` namespace (for CNPG to set the role password) and one in the app
  namespace (for the pod to connect). Both must have identical values. See
  `docs/postgres-runbooks.md` for the exact structure.

---

## Certificates

- cert-manager handles all TLS via Let's Encrypt DNS-01 (Route53)
- **Wildcard certs** live in the `traefik` namespace so `IngressRoute` resources
  in that namespace can reference them directly
- **Per-app explicit certs** live in the app's own namespace alongside its
  `IngressRoute` — required for any publicly exposed app
- ClusterIssuers: `letsencrypt-diceninjagaming-prod` and
  `letsencrypt-diceninjagaming-staging`

---

## IngressRoutes

- Apps using the **wildcard cert** have their `IngressRoute` in the `traefik`
  namespace; the file lives in the app directory for discoverability but sets
  `namespace: traefik`
- Apps with a **per-app cert** (public-facing) have their `IngressRoute` in their
  own namespace, alongside the Certificate resource
- Always specify `tls.secretName` explicitly — never rely on TLSStore default
- `allowCrossNamespace: true` enables cross-namespace Middleware references (e.g.
  referencing `traefik/default-whitelist` from an app namespace IngressRoute), but
  does **not** apply to Kubernetes Secrets — secrets must be in the same namespace
  as the `IngressRoute`

### Middleware reference
| Middleware | Namespace | Effect |
|---|---|---|
| `default-headers` | `traefik` | Security headers only — use on public routes |
| `default-whitelist` | `traefik` | Internal subnet restriction + headers — use on internal-only routes |
| `authentik` | `traefik` | Authentik forward-auth SSO |

---

## External Services (Non-Kubernetes Workloads)

Traefik routes to services outside the cluster (Docker, VMs, LXCs) using
`ExternalName` Services with raw IP addresses. This works because Traefik reads
`externalName` directly from the Kubernetes API, bypassing CoreDNS entirely —
raw IPs are valid values. See `apps/traefik/external/README.md` for the full
pattern and a working template.

All external route files live in `apps/traefik/external/<service-name>.yaml` and
contain both the `Service` and `IngressRoute` resource. The `IngressRoute` uses
the shared wildcard cert and lives in the `traefik` namespace.

**Important:** `allowExternalNameServices: true` must remain set in
`apps/traefik/values.yaml` — do not remove it.

---

## Traefik-Specific Notes

- HTTP→HTTPS redirect is handled at the entrypoint level, not per-route middleware
- `forwardedHeaders.trustedIPs: 10.0.0.0/8` is required for IP allowlist
  middleware to see real client IPs in k3s
- `HostRegexp` catch-all pattern in Traefik v3: `` HostRegexp(`.+`) ``
  (not `^.+$`) — relevant for the legacy Docker Traefik configuration during
  Docker→Kubernetes migration
- Dashboard BasicAuth credentials generated with:
  `echo "USER:$(openssl passwd -apr1 PASSWORD)"`

---

## Storage

### Longhorn
- Used for persistent, replicated storage for stateful app config and data
- StorageClass: `longhorn` — opt-in via `storageClassName: longhorn`. Not the
  k3s default (`local-path` remains the default).
- Replica count: 2 (matches current 2-node cluster)
- `csi.kubeletRootDir: /var/lib/kubelet` — do not change this back to the old
  k3s path. This was the root cause of a multi-hour troubleshooting session.
- `open-iscsi` must be installed on all nodes before Longhorn is deployed

**Single-replica deployments with Longhorn RWO volumes must use `strategy: Recreate`.**
The default `RollingUpdate` strategy creates the new pod before terminating the
old one. If the new pod lands on a different node, it cannot attach the RWO volume
because the old pod still holds it. `Recreate` terminates the old pod first,
releasing the attachment. This applies to all single-replica apps — arr-stack,
Mealie, and any future single-replica app with a Longhorn RWO PVC.

### SMB CSI Driver (`csi-driver-smb`)
- Installed via Helm through ArgoCD, managed by `apps/manifests/smb-csi.yaml`
- Provides dynamic SMB provisioning — no manual PVs required
- SMB server: Unraid NAS (`firebird.lan`)
- Credentials in `apps/smb-csi/sealedsecret-smb-creds.yaml`

### NFS CSI Driver (`csi-driver-nfs`)
- Installed via Helm through ArgoCD, managed by `apps/manifests/nfs-csi.yaml`
- NFS server: `firebird.lan` (Unraid NAS)

### StorageClasses

**`longhorn`** — replicated block storage for app config/data (RWO)

**`smb-backups`** — SMB-backed backup storage (RWX)
- Dynamic `subDir` per PVC: `${pvc.metadata.namespace}/${pvc.metadata.name}`
- Each app gets an isolated subdirectory on the Unraid Backups share
- `reclaimPolicy: Retain` — deleting a PVC never deletes backup data
- Use this for all app backup volumes

**`nfs-multimedia`** — NFS-backed media library (RWX)
- Mounts the Unraid Multimedia share root directly — no `subDir`
- `reclaimPolicy: Retain` — never deletes media library contents
- Do not add a `subDir` parameter — it would break the existing directory
  structure that Sonarr, Radarr, and other apps depend on

---

## Naming Conventions

| Resource type | Convention | Example |
|---|---|---|
| Certificate files | `certificate-<name>.yaml` | `certificate-mealie.yaml` |
| ClusterIssuers | `clusterissuer-<domain-shortname>-<env>.yaml` | `clusterissuer-dng-prod.yaml` |
| Middleware files | `middleware-<purpose>.yaml` | `middleware-authentik.yaml` |
| ArgoCD Application manifests | Named after the app directory | `traefik.yaml` |
| Kubernetes manifests | `<kind>-<resource-name>.yaml` | `secret-basic-auth.yaml` |
| External route files | `<service-name>.yaml` | `unraid.yaml` |
| Sealed secrets (committed) | `sealedsecret-*.yaml` | `sealedsecret-basic-auth.yaml` |
| Plaintext secrets (gitignored) | `secret-*.yaml` | `secret-basic-auth.yaml` |

---

## Helm-Based Apps

- Chart version is the single source of truth in `apps/manifests/<app-name>.yaml`
  `targetRevision`
- Bootstrap install extracts version programmatically:
  ```bash
  grep -A1 "chart: <n>" apps/manifests/<app-name>.yaml \
    | grep "targetRevision:" | awk '{print $2}'
  ```

## Manifest-Based Apps (No Helm)

- Version is frozen in the image tag in the Deployment manifest
- Upgrade: update the image tag, commit and push — ArgoCD applies it

---

## *arr Stack

All *arr media automation apps and related tools live in the `arr-stack` namespace
and are managed by a single ArgoCD Application (`apps/manifests/arr-stack.yaml`).

Each app under `apps/arr-stack/<app-name>/` follows this structure:
- `deployment.yaml` — Deployment spec with `strategy: Recreate`
- `service-<app-name>.yaml` — ClusterIP Service
- `ingressroute-<app-name>.yaml` — file lives in app dir, deploys to `traefik`
  namespace (wildcard cert)
- `persistentvolumeclaim-<app-name>-config.yaml` — Longhorn RWO PVC for app config
- `persistentvolumeclaim-<app-name>-backups.yaml` — `smb-backups` PVC

Standard volume mounts:
- `/config` — Longhorn PVC (app-specific config and state)
- `/backups` — SMB PVC (`smb-backups` StorageClass, isolated subdir per app)
- `/multimedia` — NFS PVC (`nfs-multimedia` StorageClass, full share root)

---

## Authentik

Authentik is the primary SSO layer, deployed as raw manifests in `apps/authentik/`.

| Component | Replicas | Notes |
|---|---|---|
| Server | 2 | Rolling updates with zero auth downtime |
| Worker | 1 | Workers coordinate through DB; multiple workers cause task duplication |
| Redis | 1 | Session cache |
| LDAP outpost | 1 | Exposes LDAP interface for non-OIDC apps |

- PostgreSQL: shared CNPG cluster (`postgres` namespace)
- Auth for protected routes: `authentik` forward-auth middleware in `traefik`
  namespace — reference it as `name: authentik, namespace: traefik` in an
  IngressRoute
- Publicly exposed apps handle OIDC directly (e.g. Mealie, Manyfold) — no
  Traefik auth middleware needed on their routes

---

## Shared PostgreSQL (CloudNativePG)

The shared Postgres instance is managed by CloudNativePG (CNPG). See
`docs/postgres-runbooks.md` for all operational procedures.

| Detail | Value |
|---|---|
| Operator | CloudNativePG (CNPG) |
| Version | PostgreSQL 18 |
| Instances | 2 (primary + replica) |
| Storage | `local-path` PVCs — CNPG replication provides redundancy |
| App connection | `postgres-pooler.postgres.svc.cluster.local:5432` (PgBouncer) |
| Direct connection | `postgres-rw.postgres.svc.cluster.local:5432` (bypass pooler only when needed — e.g. apps using advisory locks or running Alembic migrations) |

Every app gets its own database and role. Roles are declared in
`apps/postgres/cluster-postgres.yaml` under `spec.managed.roles`.

**For new apps or migrations, follow `docs/postgres-runbooks.md` exactly.**

---

## Shared MariaDB (mariadb-operator)

The shared MariaDB instance is managed by mariadb-operator. See
`docs/mariadb-runbooks.md` for all operational procedures.

| Detail | Value |
|---|---|
| CRD chart | mariadb-operator-crds (Helm chart v26.3.0, wave -3) |
| Operator | mariadb-operator (Helm chart v26.3.0, wave -2) |
| Version | MariaDB 12.2.2 |
| Instances | 2 (primary + replica, async replication with GTID) |
| Storage | `longhorn` PVCs — see mariadb-runbooks.md for why Longhorn not local-path |
| Write connection | `mariadb-primary.mariadb.svc.cluster.local:3306` |
| Read connection | `mariadb-secondary.mariadb.svc.cluster.local:3306` |

Every app gets its own database, user, and grant. Unlike Postgres (where roles are forced into the Cluster spec), MariaDB uses standalone `Database`, `User`, and `Grant` CRDs — these live in **the app's own folder** (e.g. `apps/wordpress-sitename/`) with `namespace: mariadb` on each resource. The app's ArgoCD Application deploys them to the `mariadb` namespace automatically.

**For new apps, follow `docs/mariadb-runbooks.md` exactly.**

---

## WordPress Sites (Planned)

Not yet implemented. Intended pattern when deployed:
- One namespace per site: `wordpress-<sitename>`
- Bitnami WordPress Helm chart via ArgoCD (OCI source)
- MariaDB backend
- `server.ingress.enabled: false` — IngressRoute written manually
- Public-facing sites use per-app explicit certs, not the wildcard

---

## Troubleshooting Reference

For DNS issues and networking gotchas, see `docs/troubleshooting.md`.

### ArgoCD Application stuck deleting

```bash
kubectl patch application <app-name> -n argocd \
  -p '{"metadata":{"finalizers":[]}}' --type=merge
```

### SealedSecret exists but Secret was never created

1. **Wrong cluster key** — re-seal with `kubeseal` using the current cluster's key
2. **Controller not running** —
   `kubectl get pods -n kube-system -l name=sealed-secrets-controller`
3. **Namespace mismatch** — the SealedSecret must be in the namespace it was sealed for

```bash
kubectl logs -n kube-system -l name=sealed-secrets-controller
```

### Pod stuck in CreateContainerConfigError

Almost always a missing Secret or ConfigMap:

```bash
kubectl describe pod -n <namespace> <pod-name>
kubectl get secret -n <namespace>
```

### Deployment not picking up Secret changes

```bash
kubectl rollout restart deployment -n <namespace> <deployment-name>
```

### Longhorn PVC stuck in Pending

1. Confirm `open-iscsi` is installed on all nodes
2. Confirm `csi.kubeletRootDir` in `apps/longhorn/values.yaml` is `/var/lib/kubelet`
3. Check CSI driver pods: `kubectl get pods -n longhorn-system`
4. Check PVC events: `kubectl describe pvc -n <namespace> <pvc-name>`
5. Confirm Longhorn's CSI socket is registered:
   ```bash
   sudo ls /var/lib/kubelet/plugins_registry/
   # Should include driver.longhorn.io-reg.sock
   ```
