---
name: add-app
description: Deploying a new application to the cluster. Covers the full workflow from manifests to ArgoCD sync, including security context, storage, and ingress gotchas.
triggers:
  - "add app"
  - "deploy app"
  - "new app"
  - "new service"
edges:
  - target: context/conventions.md
    condition: when checking naming conventions, sync wave rules, or security context requirements
  - target: context/architecture.md
    condition: when understanding how ArgoCD, Traefik, or storage connect
  - target: patterns/seal-secret.md
    condition: when the app needs secrets
  - target: patterns/add-database-app.md
    condition: when the app needs a database
last_updated: 2026-06-16
---

# Add App

## Context

Read `docs/postgres-runbooks.md`, `docs/mariadb-runbooks.md`, or `docs/mongodb-runbooks.md` first if the app needs a database. Read `context/conventions.md` for naming, sync wave, and security context rules.

## Steps

1. Create `apps/<app-name>/` directory
2. Create manifests:
   - `deployment-<name>.yaml` — include full security context audit (see Gotchas)
   - `service-<name>.yaml` — ClusterIP
   - `ingressroute-<name>.yaml` — see Gotchas for namespace placement
   - `persistentvolumeclaim-<name>-config.yaml` — Longhorn RWO if stateful
3. Create `apps/manifests/<app-name>.yaml` — ArgoCD Application manifest
4. Add SealedSecrets if needed (see `patterns/seal-secret.md`)
5. Commit and push — ArgoCD picks it up on next sync (default 3-minute polling)

## Gotchas

### Security context (every Deployment, no exceptions)

Run the image audit before writing the Deployment:
```bash
.claude/skills/homelab-image-audit/audit.sh --image <image> --type <type>
```

If the image isn't in the KB, fetch the Dockerfile to determine USER, required capabilities, and listen port. Never assume port 80 for non-root containers — non-root cannot bind < 1024.

Required fields on every Deployment:
- `spec.template.spec.securityContext.seccompProfile: { type: RuntimeDefault }`
- Container `securityContext.allowPrivilegeEscalation: false`
- Container `securityContext.capabilities.drop: [ALL]`
- If non-root: `runAsNonRoot: true`, `runAsUser`/`runAsGroup` set to image UID/GID
- If root: omit `runAsNonRoot`, lock down with seccomp + no caps + no escalation

### IngressRoute namespace placement

- Apps using the wildcard cert (`*.home.diceninjagaming.com`): IngressRoute file lives in the app directory but sets `namespace: traefik`
- Public-facing apps with per-app cert: IngressRoute stays in the app's own namespace alongside the Certificate resource
- Always specify `tls.secretName` explicitly — never rely on TLSStore default

### Storage and strategy

- Longhorn RWO + single replica → must use `strategy: Recreate` (not RollingUpdate)
- Longhorn RWO + non-root container → must set `fsGroup` to container GID in pod `securityContext`
- Longhorn RWO + root container → do NOT set `fsGroup`
- Backup PVCs use `smb-backups` storage class with dynamic `subDir`

### Sync waves

Most resources are wave 0 (default, no annotation needed). Only annotate:
- App-level SealedSecrets: wave `-1` (in BOTH `metadata.annotations` AND `spec.template.metadata.annotations`)
- Database CRDs: wave `-1`
- Resources referencing cross-namespace Secrets: wave `-2`

## Verify

- [ ] Image audit run or Dockerfile fetched — security context is per-image, not copied
- [ ] Non-root port verified (not assumed 80)
- [ ] Sync-wave annotations in correct locations
- [ ] IngressRoute in correct namespace for cert type
- [ ] fsGroup set correctly (non-root + Longhorn) or omitted (root)
- [ ] `strategy: Recreate` if single replica + Longhorn RWO
- [ ] No `:latest` image tags
- [ ] `/homelab-validate` passes

## Debug

- **Pod in CreateContainerConfigError:** missing Secret or ConfigMap. `kubectl describe pod -n <namespace> <pod-name>`
- **PVC stuck Pending:** check `open-iscsi` on nodes, check `csi.kubeletRootDir`, check CSI pods in `longhorn-system`
- **IngressRoute 404 or TLS error:** check namespace placement, check `tls.secretName`, check cert exists in correct namespace
- **ArgoCD not syncing:** check Application status with `kubectl get applications -n argocd`

## Update Scaffold

- [ ] Update `.mex/ROUTER.md` "Current Project State" if what's working/not built has changed
- [ ] Update any `.mex/context/` files that are now out of date
- [ ] If this is a new task type without a pattern, create one in `.mex/patterns/` and add to `INDEX.md`
