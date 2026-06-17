---
name: conventions
description: How code is written in this project — naming, structure, patterns, and style. Load when writing new code or reviewing existing code.
triggers:
  - "convention"
  - "pattern"
  - "naming"
  - "style"
  - "how should I"
  - "what's the right way"
edges:
  - target: context/architecture.md
    condition: when a convention depends on understanding the system structure
last_updated: 2026-06-16
---

# Conventions

## Naming

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

## Structure

- `apps/<app-name>/` contains all manifests for an app; `apps/manifests/<app-name>.yaml` is the ArgoCD Application manifest
- IngressRoute files live in the app directory for discoverability, but set `namespace: traefik` when using the wildcard cert
- Apps with a per-app cert (public-facing) have IngressRoute in their own namespace alongside the Certificate resource
- MariaDB Database/User/Grant CRDs live in the app's own folder (e.g. `apps/wordpress-dng/`) with `namespace: mariadb`
- External service routes live in `apps/traefik/external/<service-name>.yaml` and contain both the Service and IngressRoute
- `app-of-apps.yaml` is a bootstrap artifact — not managed by ArgoCD, must be applied manually if changed

## Patterns

### Secrets Workflow

- `secret-*.yaml` is gitignored (plaintext); `sealedsecret-*.yaml` is committed
- Never commit plaintext secrets — no exceptions
- Sealed secrets are namespace-scoped — a secret sealed for namespace `foo` cannot decrypt in namespace `bar`
- When creating a new secret, write `secret-*.yaml` with placeholder values and provide the `kubeseal` command alongside; user fills in real values before sealing
- Placeholder values must not contain dots (`.`) or dashes (`-`) — use underscores only (e.g. `your_sonarr_api_key_here`)
- `kubeseal` command must always be written as a single line — never split with backslash continuations
- PostgreSQL apps require the database password in two secrets: one in `postgres` namespace (for CNPG role password) and one in the app namespace (for pod to connect); both must have identical values. See `docs/postgres-runbooks.md`

### Sync Wave Reference

Only resources needing non-default sync order require `argocd.argoproj.io/sync-wave` annotations. Wave `0` is ArgoCD's default — resources at wave 0 can omit the annotation.

Resources requiring explicit annotations:

- **Infrastructure SealedSecrets** (consumed by cluster CRDs via `passwordSecretRef`, e.g. MongoDB users, CNPG roles) — wave `-3` in both `metadata.annotations` and `spec.template.metadata.annotations`
- **App-level SealedSecrets** (consumed by Deployments via `secretKeyRef`) — wave `-1`
- **Database CRDs** — wave `-1`
- **Resources referencing a cross-namespace Secret** (User CRDs with `passwordSecretRef`) — wave `-2`

Resources that do NOT need an annotation (wave 0 default): Deployments, Services, IngressRoutes, PVCs, ConfigMaps, NetworkPolicies, Certificates.

Exception: if a ConfigMap or Secret is consumed by a resource at a non-default wave, that ConfigMap/Secret must also carry the same or earlier wave annotation.

**Critical (from feedback):** SealedSecrets require the annotation in TWO places — `metadata.annotations` (what ArgoCD reads for wave ordering) AND `spec.template.metadata.annotations` (propagates to decrypted Secret). ArgoCD ignores `spec.template.metadata.annotations` for wave ordering — a SealedSecret with the annotation only in `spec.template` is treated as wave 0 regardless of value. Diagnosis: `grep -n "sync-wave" apps/<app>/sealedsecret-*.yaml` — if the only hits are deeply indented (under `spec:`), the annotation is in the wrong place.

### IngressRoutes

- Apps using wildcard cert: IngressRoute in `traefik` namespace (file in app dir, sets `namespace: traefik`)
- Apps with per-app cert (public-facing): IngressRoute in own namespace alongside Certificate
- Always specify `tls.secretName` explicitly — never rely on TLSStore default
- `allowCrossNamespace: true` enables cross-namespace Middleware references but does NOT apply to Kubernetes Secrets (secrets must be in same namespace as IngressRoute)

### Middleware Reference

| Middleware | Namespace | Effect |
|---|---|---|
| `default-headers` | `traefik` | Security headers only — use on public routes |
| `default-whitelist` | `traefik` | Internal subnet restriction + headers — use on internal-only routes |
| `authentik` | `traefik` | Authentik forward-auth SSO |

### Storage Patterns

- **Longhorn** (`storageClassName: longhorn`) — opt-in, replicated RWO for app config/data. Single-replica apps: must use `strategy: Recreate` (not RollingUpdate) on Longhorn RWO volumes. `fsGroup` in pod `securityContext` required when container runs as non-root; set to container's GID (check Dockerfile). Root-running containers: NO `fsGroup`. `open-iscsi`, `nfs-common`, and `cifs-utils` must be installed on all nodes at OS level.
- **smb-backups** — SMB-backed RWX backup storage, dynamic `subDir` per PVC (`${pvc.metadata.namespace}/${pvc.metadata.name}`), `reclaimPolicy: Retain`. Use for all app backup volumes.
- **nfs-backups** — NFS-backed RWX, reference-only, not used by any deployed app. `smb-backups` is the default.
- **local-path** — k3s default; used by CNPG (replication provides redundancy).

### Comment Standards

Write comments for "future Mike reading this at 2am" — assume the reader knows Kubernetes basics but may not remember why a specific decision was made.

- Explain non-obvious decisions and the "why" behind configuration choices
- Note version management approach and upgrade caveats
- Document gotchas that would save time during future troubleshooting
- Every non-trivial field that could reasonably be set differently should have a comment explaining why it is set the way it is
- Cross-reference related files inline (e.g. note which file creates a secret that an IngressRoute references)

### Research Discipline (Before Implementing)

- **Always read the relevant docs/ file first** — see "Read Before Acting" section
- **Research container security context per app** — never copy `securityContext` from an existing app. Run the image audit script or fetch Dockerfile to determine required capabilities
- **Never assume port 80 for non-root containers** — check Dockerfile for actual listen port
- **Research app configuration per app** — tiered research order: (1) Dockerfile, (2) example config file, (3) Helm values.yaml / docker-compose.yml, (4) config source code
- **Verify CRD field formats** against operator documentation or existing working examples; never guess nesting

### Rename/Refactor Discipline (from feedback)

Before any rename or refactor: grep for every occurrence first, change all instances in one pass, verify the full `git diff`, then commit once. Do not commit incrementally while changes are still incomplete.

1. `grep -r "<old-term>" <scope>` before touching any file
2. Change all instances (filenames, content, comments) in one pass
3. `git diff` the full working tree to verify nothing missed
4. Single commit covering the complete rename

### GitOps Workflow (from feedback — no kubectl apply)

- `main` is always the live cluster state — never push broken manifests directly
- All changes via feature branches -> PR -> merge to `main` -> ArgoCD reconciles
- Never use `kubectl apply` directly — direct cluster changes bypass audit trail, pre-commit validation, and sync wave ordering; ArgoCD will overwrite them anyway
- If urgent testing needed: commit and push — ArgoCD syncs within 3 minutes (default polling interval)

### Planning & Review Session Discipline (from feedback)

During any planning session (ce-plan, ce-doc-review, ce-brainstorm, or multi-step walkthrough):

1. **User directive = action now.** When the user gives any directive, the only valid responses are (a) apply the fix immediately, or (b) present a walkthrough question. Never reclassify to a later phase or silently downgrade to Skip.
2. **Design-change cascade.** When a walkthrough decision changes document structure, immediately surface every downstream section that now contradicts the new design BEFORE advancing.
3. **Completion-report checkpoint.** Before presenting the completion report, scan every user directive from the session — each must have been applied or explicitly deferred/skipped by the user.
4. **Nothing ignored, everything documented.** Every concern the user raises must appear in the final state as a document edit, Deferred/Open Questions entry, residual concern with explicit owner, or explicit user Skip. Silence is not acceptable.

### Security Context Audit (from feedback)

Every new Deployment must pass a security context audit before commit. Never batch-create Deployments and skip individual review.

Per-Deployment checklist:
- Pod `spec.securityContext.seccompProfile: { type: RuntimeDefault }`
- Container `securityContext.allowPrivilegeEscalation: false`
- Container `securityContext.capabilities.drop: [ALL]`
- If non-root: `runAsNonRoot: true`, `runAsUser`/`runAsGroup` set to image UID/GID
- If root (no USER in Dockerfile): `runAsNonRoot` omitted, container locked down with seccomp + no caps + no escalation
- If mounting Longhorn PVC AND non-root: `fsGroup` set to container GID. If root: NO `fsGroup`
- If mounting Longhorn PVC AND single replica: `strategy: Recreate`

Run `/homelab-validate` before every commit that touches YAML files.

## Pre-Commit Verification

A git pre-commit hook at `.githooks/pre-commit` runs the full validation suite on every commit that touches `.yaml`/`.yml` files.

One-time setup per clone:
```bash
ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
```

Checks (scripts at `.claude/skills/homelab-validate/scripts/`):

| Check | Script | What it catches |
|---|---|---|
| Sync waves | `sync-wave-check.sh` | Missing/misplaced wave annotations |
| YAML validity | `yaml-validity.sh` | Invalid YAML syntax |
| Plaintext secrets | `plaintext-secret-guard.sh` | Accidentally staged `secret-*.yaml` files |
| IngressRoute | `ingressroute-check.sh` | Wrong namespace, missing middleware, cert issues |
| Longhorn fsGroup | `longhorn-fsgroup-check.sh` | Missing fsGroup on non-root + Longhorn, fsGroup in wrong location |
| Secret templates | `secret-template-verify.sh` | Missing sync-wave annotations, bad placeholder format |
| :latest tag guard | inline in hook | Unpinned image tags |
| NetworkPolicy | `networkpolicy-check.sh` | Missing `namespaceSelector` on `podSelector`, deny-all policies |
| Probe timeout | `probe-timeout-check.sh` | Exec probes with default/too-short `timeoutSeconds` on known-slow CLIs |
| Capabilities | `capability-check.sh` | Missing capabilities for images that drop ALL |
| Env injection | `env-check.sh` | Deployments missing `envFrom`/`env` blocks (WARN only) |

Manual invocation: `/homelab-validate`. Conditional checks (IngressRoute, fsGroup, NetworkPolicy, probe timeout, capabilities, env injection) only fire when matching file types are staged — a "SKIP" on unrelated commits is expected, not a failure.

## Read Before Acting

| Task | Documentation |
|---|---|
| New app or Postgres migration | `docs/postgres-runbooks.md` |
| New app with MariaDB | `docs/mariadb-runbooks.md` |
| New app with MongoDB | `docs/mongodb-runbooks.md` |
| Secrets workflow | `docs/sealed-secrets.md` |
| Cluster recovery / node loss | `docs/disaster-recovery.md` |
| DNS or networking issues | `docs/troubleshooting.md` |
| Storage utilisation / trim | `docs/storage.md` |
| External service routing | `apps/traefik/external/README.md` |
| n8n HA migration | `docs/n8n-ha-migration.md` |
| ArgoCD HA migration | `docs/argocd-ha-migration.md` |

Do not assume context is current — read the actual files.

## Verify Checklist

Before presenting any work:
- [ ] Relevant docs/ file was read before implementing
- [ ] Container security context was audited per image (not copied from another app)
- [ ] Non-root container ports verified (not assumed port 80)
- [ ] Sync-wave annotations present and in correct location (both `metadata.annotations` and `spec.template.metadata.annotations` for SealedSecrets)
- [ ] `kubeseal` commands written as single lines; placeholder values use underscores only (no dots/dashes)
- [ ] No plaintext secrets staged (`secret-*.yaml` files not in git add)
- [ ] Longhorn single-replica apps use `strategy: Recreate`
- [ ] fsGroup set correctly (to container GID for non-root; omitted for root)
- [ ] No `:latest` image tags; all images version-pinned
- [ ] CRD field formats verified against operator docs or existing working examples
- [ ] All changes go through git (no `kubectl apply`)
