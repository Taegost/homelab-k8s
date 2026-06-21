---
title: "ArgoCD Sync Wave Ordering Conventions"
date: 2026-06-21
category: conventions
module: homelab
problem_type: convention
component: development_workflow
severity: high
applies_when:
  - "Adding a new app with SealedSecrets or database CRDs"
  - "Creating resources that reference cross-namespace secrets"
  - "Adding a ConfigMap or Secret consumed by a lower-wave resource"
tags:
  - argocd
  - sync-waves
  - gitops
  - sealed-secrets
  - ordering
---

# ArgoCD Sync Wave Ordering Conventions

## Context

ArgoCD applies all resources at wave 0 by default. When resources have ordering dependencies — a SealedSecret must decrypt before a database CRD references it, a database CRD must exist before a Deployment connects — missing or wrong sync-wave annotations cause race conditions. The worst case: an operator CRD applies before its backing secrets exist, silently generating random credentials.

## Guidance

### Wave reference

| Wave | Resources | Rationale |
|------|-----------|-----------|
| -3 | Infrastructure SealedSecrets (consumed by CRDs via `passwordSecretRef`) | Must decrypt before operator reconciles CRD |
| -2 | Cross-namespace secret consumers (User, Grant CRDs), operator Helm releases | Must exist after secrets, before database CRDs |
| -1 | Database CRDs (CNPG, MariaDB), app-level SealedSecrets | Must exist before Deployments at wave 0 |
| 0 | Deployments, Services, IngressRoutes, PVCs, ConfigMaps, NetworkPolicies, Certificates | Default — no annotation needed |

### Dual annotation on SealedSecrets

SealedSecrets require the wave annotation in **two** places:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  template:
    metadata:
      annotations:
        argocd.argoproj.io/sync-wave: "-3"
```

The top-level annotation controls when ArgoCD syncs the SealedSecret CRD. The template annotation controls what wave the resulting Secret should sync at after decryption.

### ConfigMap/Secret exception rule

If a ConfigMap or Secret is consumed by a resource at a non-default wave (e.g., a Job at wave -1 via `configMapRef`), the ConfigMap/Secret must also carry the same or earlier wave annotation. Otherwise the lower-wave resource starts before its dependency exists.

```yaml
# Job at wave -1 references configmap-plane
# configmap-plane MUST also be at wave -1 or earlier
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

### Full MariaDB app lifecycle example

| Wave | Kind | Purpose |
|------|------|---------|
| -3 | SealedSecret | DB credentials in mariadb namespace (dual annotation) |
| -2 | User | MariaDB user referencing wave -3 Secret |
| -2 | Grant | Privileges for the user |
| -1 | Database | MariaDB database (after user/grant) |
| -1 | SealedSecret | App-namespace DB credentials (dual annotation) |
| 0 | Deployment | Application pods |

## Why This Matters

- **MongoDB credentials race** (commit eb9faa2): CRD applied before secrets decrypted → operator generated random credentials → cluster bootstrapped with wrong passwords
- **Plane migrator Job** (commit 47a9cb7): Job at wave -1 consumed ConfigMap at wave 0 → Job started before configuration existed
- Both bugs are silent — no error messages, just wrong runtime behavior

## When to Apply

- Any new app with SealedSecrets or database CRDs
- Any resource that references a cross-namespace Secret
- Any ConfigMap or Secret consumed by a resource at a non-default wave
- The pre-commit hook (`sync-wave-check.sh`) catches violations automatically

## Examples

### MongoDB infrastructure

```yaml
# Wave -3: SealedSecrets
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
---
# Wave -2: Cluster CRD
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

### Plane ConfigMap exception

```yaml
# configmap-plane.yaml — normally wave 0, but migrator Job at wave -1 needs it
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

## Related

- `CLAUDE.md` — Sync wave reference section
- `.claude/skills/homelab-validate/scripts/sync-wave-check.sh` — validation script
- `docs/solutions/runtime-errors/librechat-deployment-cascade.md` — MongoDB sync ordering bug
