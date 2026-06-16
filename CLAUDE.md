# CLAUDE.md — homelab-k8s

This file instructs Claude Code on how to operate within this repository.
It is the authoritative source for conventions, patterns, and standards.

See `~/.claude/CLAUDE.md` for global operator preferences (communication rules,
research discipline, response format). This file contains homelab-k8s-specific
conventions only.

---

## Bypass Rules (NEVER SELF-AUTHORIZE)

The pre-commit and pre-push hooks have bypass env vars for the human operator:

- `HOMELAB_ALLOW_LATEST=1` — allows `:latest` image tags
- `HOMELAB_ALLOW_MAIN=1` — allows direct pushes to main

**Claude must NEVER set these.** If a bypass is needed (e.g., Chainguard only
publishes `:latest`, or a break-fix must land on main), flag it to the user and
let them decide. The bypasses exist for the human operator, not for Claude.

**Claude must NEVER use `git commit --amend`.** It rewrites the commit hash,
causing merge conflicts when the user has local changes or tries to push.
Always create a normal commit instead.

---

## Planning & Review Sessions (MANDATORY CHECKPOINTS)

These rules apply during any planning session (ce-plan, ce-doc-review,
ce-brainstorm, or any multi-step decision walkthrough). They exist because
Claude defaults to optimizing for completion speed over fidelity to user
decisions, and has a track record of silently reclassifying user directives
as "deferred" rather than acting on them.

### Checkpoint 1: Every user directive must land

When the user gives any directive about the document or the work — whether
phrased as "address this," "fix this," "include X," "we need to," "make sure,"
"apply this," or any other imperative — that directive must produce one of
two outcomes before the session ends:

- **Applied:** An edit was made that fulfills the directive.
- **User-deferred:** The user explicitly chose Defer or Skip on a walkthrough
  question that presented the directive.

Silently dropping, reclassifying to a later phase, or converting a directive
to a "noted for next planning phase" bullet is a violation. If the user
wants it deferred, they will say so explicitly.

### Checkpoint 2: Design changes cascade immediately

When a walkthrough decision changes document structure (e.g., redesigning a
component, changing a data flow, altering scope), every downstream section
that now contradicts the new design must be surfaced as an explicit finding
BEFORE advancing to the next walkthrough question. Do not batch broken
cross-references to the completion report. The walkthrough exists so the
user decides at each step — hiding cascading breakage removes that choice.

### Checkpoint 3: Pre-completion directive scan

Before presenting any completion report or terminal question, scan every
user directive from the current session. Verify each one was either applied
(with a document edit) or explicitly deferred/skipped by the user via a
walkthrough question answer. If any directive was not resolved, surface it
and ask before presenting completion.

### Checkpoint 4: Nothing ignored, everything documented

Every concern the user raises, every question they ask, and every directive
they give during a planning session must be reflected somewhere in the final
state: either as a document edit, a Deferred / Open Questions entry, a
residual concern with explicit owner, or an explicit user Skip. If the user
said it, it exists in the output. Silence is not an acceptable response to
a user-raised concern.

---

## Read Before Acting

Before implementing any change, read the relevant documentation first:

- **New app deployment or Postgres migration** → `docs/postgres-runbooks.md`
- **New app deployment with MariaDB database** → `docs/mariadb-runbooks.md`
- **New app deployment with MongoDB database** → `docs/mongodb-runbooks.md`
- **Secrets workflow** → `docs/sealed-secrets.md`
- **Cluster recovery or node loss** → `docs/disaster-recovery.md`
- **DNS or networking issues** → `docs/troubleshooting.md`
- **Storage utilisation or trim jobs** → `docs/storage.md`
- **External service routing** → `apps/traefik/external/README.md`
- **n8n HA migration (S3, queue mode, custom nodes)** → `docs/n8n-ha-migration.md`
- **ArgoCD HA migration** → `docs/argocd-ha-migration.md`

Do not assume context is current. Read the actual files.

---

## Pre-Commit Verification (MANDATORY)

A git pre-commit hook at `.githooks/pre-commit` runs the full validation
suite automatically. It fires on every commit that touches `.yaml` or `.yml`
files. The hook blocks the commit if any check fails.

**One-time setup (per clone):**
```bash
ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
```

The hook runs these checks (scripts at `.claude/skills/homelab-validate/scripts/`):

| Check | Script | What it catches |
|---|---|---|
| Sync waves | `sync-wave-check.sh` | Missing/misplaced wave annotations |
| YAML validity | `yaml-validity.sh` | Invalid YAML syntax |
| Plaintext secrets | `plaintext-secret-guard.sh` | Accidentally staged `secret-*.yaml` files |
| IngressRoute | `ingressroute-check.sh` | Wrong namespace, missing middleware, cert issues |
| Longhorn fsGroup | `longhorn-fsgroup-check.sh` | Missing fsGroup on non-root + Longhorn, fsGroup in wrong location |
| Secret templates | `secret-template-verify.sh` | Missing sync-wave annotations, bad placeholder format |
| :latest tag guard | inline in hook | Unpinned image tags (`image: ...:latest`) — must use a specific version |
| NetworkPolicy | `networkpolicy-check.sh` | Missing `namespaceSelector` on `podSelector`, deny-all policies |
| Probe timeout | `probe-timeout-check.sh` | Exec probes with default/too-short `timeoutSeconds` on known-slow CLIs |
| Capabilities | `capability-check.sh` | Missing capabilities for images that drop ALL (reads from KB) |
| Env injection | `env-check.sh` | Deployments missing `envFrom`/`env` blocks (WARN only) |

The same suite can be invoked manually: `/homelab-validate`

The IngressRoute, Longhorn fsGroup, NetworkPolicy, probe timeout, capability,
and env injection checks run conditionally — they only fire when `ingressroute`,
`persistentvolumeclaim`, `networkpolicy`, or `deployment` files are staged. The
other four checks (sync waves, YAML validity, plaintext secrets, secret
templates) run on every commit that touches `.yaml` or `.yml` files. A "SKIP"
for conditional checks on unrelated commits is expected and not a failure.

### Sync wave reference

Only resources that need a **non-default** sync order require an
`argocd.argoproj.io/sync-wave` annotation. Wave `0` is ArgoCD's default —
resources at wave 0 can safely omit the annotation.

Resources requiring explicit annotations:

- **Infrastructure SealedSecrets** (consumed by cluster CRDs via
  `passwordSecretRef`, e.g., MongoDB users, CNPG roles) — wave `-3` in both
  `metadata.annotations` and `spec.template.metadata.annotations`. Must decrypt
  before the operator reconciles the CRD.
- **App-level SealedSecrets** (consumed by Deployments via `secretKeyRef`) —
  wave `-1`. Must decrypt before the Deployment starts at wave `0`.
- **Database CRDs** — wave `-1`. Must deploy after the CNPG cluster CRD creates
  the role, but before application Deployments.
- **Resources referencing a cross-namespace Secret** (User CRDs with
  `passwordSecretRef`) — wave `-2`. Must deploy after the SealedSecret is
  decrypted.

Resources that do NOT need an annotation (wave 0 default):

- Deployments, Services, IngressRoutes, PVCs, ConfigMaps, NetworkPolicies,
  Certificates — all app-level resources that don't need to order before or
  after other resources. They sync at the default wave.

**Exception:** If a ConfigMap or Secret is consumed by a resource at a
non-default wave (e.g. a Job at wave -1 via `configMapRef` or
`secretKeyRef`), that ConfigMap/Secret must also carry the same or earlier
wave annotation. Otherwise the lower-wave resource starts before its
dependency exists.

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

- **Platform:** k3s — 3 combined control-plane/worker nodes; additional worker-only nodes may be added
- **GitOps:** ArgoCD manages everything post-bootstrap via app-of-apps pattern
- **Networking:** pfSense router, MetalLB (L2/ARP mode), Traefik as sole ingress
- **Internal domain:** `home.diceninjagaming.com`
- **Subnets:** `192.168.5.0/24` (VMs/LXCs), `192.168.6.0/24` (workstations)
- **DNS:** Route53 for public DNS and Let's Encrypt DNS-01 challenges
- **Secrets:** Sealed Secrets only — no plaintext secrets ever committed

> **ArgoCD HA migration is pending.** All nodes are active. Follow
> `docs/argocd-ha-migration.md` to switch ArgoCD to the HA manifest.
> Also increase the Longhorn replica count for existing volumes via the
> Longhorn UI or kubectl — new volumes pick up the default automatically.

### Node Labels

Label nodes with `memory-tier` to control scheduling of memory-heavy workloads:

```bash
kubectl label node <node-name> memory-tier=small
```

Nodes without the label are treated as having sufficient memory for all workloads.

### Node Affinity for Memory-Heavy Apps

All memory-heavy or critical workloads use a soft anti-affinity preference to avoid
nodes labeled `memory-tier=small`. This is a preference, not a hard requirement —
if all nodes carry the label, pods will still schedule there.

```yaml
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: memory-tier
              operator: NotIn
              values:
                - small
```

**When to add this affinity:**
- Any Deployment with a memory limit > 1Gi
- Any existing app that is OOMKilled or shows memory pressure

**When to skip:**
- Infrastructure components managed by operators (CNPG, mariadb-operator, Longhorn)
- Database clusters (their own anti-affinity rules govern placement)

---

## Core Stack (bootstrap order)

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
│   │   └── external/             # Routes to non-Kubernetes services (see below)
│   ├── wordpress-dng/            # DiceNinjaGaming WordPress site (diceninjagaming.com)
│   └── wordpress-taegost/        # Mike's portfolio/blog (taegost.com)
├── archived/                     # Removed configs kept for reference
├── bootstrap/                    # Manual bootstrap guide (README.md)
├── docs/
│   ├── argocd-ha-migration.md    # Steps to enable ArgoCD HA
│   ├── disaster-recovery.md      # Full cluster rebuild sequence
│   ├── mariadb-runbooks.md       # New app + migration workflows for MariaDB
│   ├── migration-traefik-docker.md
│   ├── mongodb-runbooks.md       # New app + migration workflows for MongoDB
│   ├── n8n-ha-migration.md       # n8n HA migration guide (S3, queue mode)
│   ├── postgres-runbooks.md      # New app + migration workflows for CNPG
│   ├── sealed-secrets.md         # Full sealed secrets workflow
│   ├── storage.md                # Longhorn PVC utilisation and trim job docs
│   ├── troubleshooting.md        # DNS, networking, and known gotchas
│   ├── brainstorms/              # Requirements and brainstorming documents
│   └── plans/                    # Implementation plans
└── README.md
```

---

## Behavior Instructions

### Research and correctness
- **Always read the relevant docs/ file before implementing** — see the
  "Read Before Acting" section at the top of this file.
- **Research container security context per app** — never copy `securityContext`
  from an existing app. Run `.claude/skills/homelab-image-audit/audit.sh --image <image> --type <type>` before writing the securityContext. The script cross-references the base-image knowledge base (`docs/solutions/`) and outputs the recommended capabilities, privilege model, and port. If the image type is unknown, run the script interactively. For images not covered by the KB, fall back to fetching the target image's Dockerfile and entrypoint
  to determine: what USER it runs as, whether it does a root→non-root drop at
  runtime (gosu, su-exec, etc.), and whether capabilities like `CHOWN`,
  `DAC_OVERRIDE`, `SETUID`, or `SETGID` are actually required. Use the minimum
  necessary; if the image is fully non-root with no runtime drops, drop ALL
  capabilities and add none.
- **Never assume port 80 for non-root containers** — processes running as
  non-root cannot bind to privileged ports (< 1024). Always check the image's
  Dockerfile for the actual listen port (commonly 8080, 8000, 3000, 9000).
  Set `containerPort` and the Service `targetPort` to that port. Health probe
  ports must also match the actual container port. Getting this wrong produces
  a 502 Bad Gateway with no obvious cause in the logs.
- **Research app configuration per app** — never assume env var names, config
  schema fields, health probe paths, or default values. Follow the tiered
  research order below; only proceed to the next tier if the current one is
  unclear or ambiguous:
  1. **Dockerfile** — check `USER`, `EXPOSE` (port), `WORKDIR`, and `ENV`
     defaults
  2. **Example config file** (e.g., `librechat.example.yaml`) — check schema
     field types, required fields, and defaults. An empty string is not the
     same as an omitted field; arrays may have min-length requirements
  3. **Helm values.yaml** or **docker-compose.yml** (when available) — check
     probe paths, resource defaults, recommended config, and env var names
  4. **Config source code** (e.g., `config.py`, `config.js`) — check env var
     names, default values, and feature flags. Use only when tiers 1–3 are
     unclear or silent on a specific value
- **Verify CRD field formats** against the operator documentation or existing
  working examples in the repo before committing. Never guess nesting (e.g.,
  `role: { name, db }` vs `name`/`db` at top level); check the schema

### Values and secrets
- The `kubeseal` command must always be written as a single line — never split
  with backslash continuations. It needs to be copy-paste friendly.
- Placeholder values in secret files must not contain dots (`.`) or dashes (`-`)
  — use underscores only (e.g. `your_sonarr_api_key_here`). Dots and dashes
  break word-selection in editors and terminals, making copy-paste harder.
- Apps that use PostgreSQL require the database password in **two** secrets: one
  in the `postgres` namespace (for CNPG to set the role password) and one in the
  app namespace (for the pod to connect). Both must have identical values. See
  `docs/postgres-runbooks.md` for the exact structure.

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
- Always test with the staging issuer first before switching to prod

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
- Replica count: one replica per cluster node (update `defaultReplicaCount` and
  `defaultClassReplicaCount` in `apps/longhorn/values.yaml` when topology changes)
- `csi.kubeletRootDir: /var/lib/kubelet` — do not change this back to the old
  k3s path. This was the root cause of a multi-hour troubleshooting session.
- `open-iscsi` must be installed on all nodes before Longhorn is deployed
- `nfs-common` (NFS client) and `cifs-utils` (SMB/CIFS client) are installed on
  all nodes as part of base image creation and reinforced by Ansible playbooks
  before Kubernetes is provisioned — Longhorn RWX volumes (NFSv4) and SMB CSI
  mounts both depend on these being present at the OS level

**Single-replica deployments with Longhorn RWO volumes must use `strategy: Recreate`.**
The default `RollingUpdate` strategy creates the new pod before terminating the
old one. If the new pod lands on a different node, it cannot attach the RWO volume
because the old pod still holds it. `Recreate` terminates the old pod first,
releasing the attachment. This applies to all single-replica apps — arr-stack,
Mealie, and any future single-replica app with a Longhorn RWO PVC.

**Deployments mounting Longhorn PVCs must set `fsGroup` in the pod `securityContext`.**
Fresh Longhorn volumes are provisioned owned by root. If the container runs as a
non-root user, it cannot write to the volume on first start. Setting `fsGroup` to
the container's GID causes Kubernetes to chown all mounted volumes to that group
before the container starts. The correct value depends on what GID the image runs
as — always check the image's Dockerfile (see Research and correctness rules).
Do not assume it matches any other app in the stack.

### SMB CSI Driver (`csi-driver-smb`)
- Installed via Helm through ArgoCD, managed by `apps/manifests/smb-csi.yaml`
- Provides dynamic SMB provisioning — no manual PVs required
- SMB server: Unraid NAS (`firebird.lan`)
- Credentials in `apps/smb-csi/sealedsecret-smb-creds.yaml`

### NFS CSI Driver (`csi-driver-nfs`)
- Installed via Helm through ArgoCD, managed by `apps/manifests/nfs-csi.yaml`
- NFS server: `firebird.lan` (Unraid NAS)
- Reference-only — not used by any deployed application. SMB (`smb-csi`) is the
  default for all storage.

### StorageClasses

**`longhorn`** — replicated block storage for app config/data (RWO)

**`smb-backups`** — SMB-backed backup storage (RWX)
- Dynamic `subDir` per PVC: `${pvc.metadata.namespace}/${pvc.metadata.name}`
- Each app gets an isolated subdirectory on the Unraid Backups share
- `reclaimPolicy: Retain` — deleting a PVC never deletes backup data
- Use this for all app backup volumes

**`nfs-backups`** — NFS-backed backup storage (RWX)
- Reference-only — kept for future flexibility, not used by any deployed app.
  `smb-backups` (above) is the default for all application backup volumes.
- Dynamic `subDir` per PVC: `${pvc.metadata.namespace}/${pvc.metadata.name}`
- `reclaimPolicy: Retain` — deleting a PVC never deletes backup data

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
- `deployment-<app-name>.yaml` — Deployment spec with `strategy: Recreate`
- `service-<app-name>.yaml` — ClusterIP Service
- `ingressroute-<app-name>.yaml` — file lives in app dir, deploys to `traefik`
  namespace (wildcard cert)
- `persistentvolumeclaim-<app-name>-config.yaml` — Longhorn RWO PVC for app config
- `persistentvolumeclaim-<app-name>-backups.yaml` — `smb-backups` PVC

Standard volume mounts:
- `/config` — Longhorn PVC (app-specific config and state)
- `/backups` — SMB PVC (`smb-backups` StorageClass, isolated subdir per app)
- `/multimedia` — static PV + PVC binding (`persistentvolume-arr-stack-multimedia.yaml` and `persistentvolumeclaim-multimedia.yaml`)

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
| CRD chart | mariadb-operator-crds (Helm chart, wave -3) |
| Operator | mariadb-operator (Helm chart, wave -2) |
| Version | MariaDB 12.2.2 |
| Instances | 2 (primary + replica, async replication with GTID) |
| Storage | `longhorn` PVCs — see mariadb-runbooks.md for why Longhorn not local-path |
| Write connection | `mariadb-primary.mariadb.svc.cluster.local:3306` |
| Read connection | `mariadb-secondary.mariadb.svc.cluster.local:3306` |

Every app gets its own database, user, and grant. Unlike Postgres (where roles are
forced into the Cluster spec), MariaDB uses standalone `Database`, `User`, and
`Grant` CRDs — these live in **the app's own folder** (e.g. `apps/wordpress-dng/`)
with `namespace: mariadb` on each resource. The app's ArgoCD Application deploys
them to the `mariadb` namespace automatically.

**For new apps, follow `docs/mariadb-runbooks.md` exactly.**

---

## WordPress Sites

Pattern in use — see `apps/wordpress-dng/` for a working example.

- One namespace per site: `wordpress-<sitename>`
- Raw manifests (Deployment, Service, IngressRoute, PVC, Certificate, ConfigMap,
  SealedSecrets) — not Helm. ArgoCD Application points at `apps/wordpress-<sitename>/`
- Image: official `wordpress:*-apache` — version pinned in the Deployment image tag;
  upgrade by bumping the tag
- MariaDB backend — `Database`, `User`, and `Grant` CRDs in the app folder,
  namespace `mariadb`
- Only `wp-content` is mounted on a Longhorn RWX PVC — themes, plugins, and uploads
  persist there; core WordPress files are ephemeral (rebuilt from the image on restart).
  All settings, posts, and options persist in MariaDB. **Do not use the WordPress
  Admin "Update WordPress" button** — upgrade core by changing the image tag instead.
- Public-facing sites use per-app explicit certs, not the wildcard
- Shared WordPress secret keys (auth salts) managed as a SealedSecret to avoid
  auth cookie mismatches across multiple replicas
- `fsGroup: 33` (www-data) required in pod `securityContext` — Longhorn volumes
  are provisioned owned by root; this causes Kubernetes to chown on first mount
- Loopback plugin (`configmap-wordpress-loopback-plugin.yaml`) rewrites WordPress
  self-requests to stay inside the cluster. Required to avoid wp-admin timeouts
  caused by public-domain round-trips. Copy the ConfigMap to new sites and update
  the two `define()` constants. See `docs/troubleshooting.md` → WordPress for
  background, diagnosis, and the plugin isolation binary-search workflow.

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
