---
title: "ArgoCD Sync Wave Ordering Conventions"
date: 2026-06-21
last_updated: 2026-06-22
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
    argocd.argoproj.io/sync-wave: "-3"   # Controls when the SealedSecret CRD syncs
spec:
  template:
    metadata:
      annotations:
        argocd.argoproj.io/sync-wave: "-3"   # Controls the wave of the decrypted Secret
```

The top-level annotation controls when ArgoCD syncs the SealedSecret CRD. The template annotation controls what wave the resulting Secret should sync at after decryption. If only one is present, the other defaults to wave 0, which can cause the CRD to sync at the wrong time relative to its consumers.

#### Failure modes when one annotation is missing

**Missing `metadata.annotations`:** ArgoCD applies the SealedSecret at wave 0 (default). If a Deployment at wave 0 references the decrypted Secret, both attempt to sync simultaneously. If the Sealed Secrets controller has not yet decrypted the Secret, the Deployment enters `CreateContainerConfigError` and crash-loops until the next ArgoCD sync cycle.

**Missing `spec.template.metadata.annotations`:** The SealedSecret CRD syncs at the correct wave, but the decrypted Secret inherits wave 0. Any resource that depends on the Secret existing at a lower wave (e.g., a CNPG Database CRD at wave -1) will attempt to start before the Secret is available. This produces silent failures — the operator generates random credentials or refuses to start with no clear error.

#### Wave values by SealedSecret type

| SealedSecret location | Wave | Why |
|------------------------|------|-----|
| Infrastructure credentials consumed by operator CRDs (e.g., MongoDB users, CNPG roles via `passwordSecretRef`) | `-3` | Must decrypt before the operator reconciles the CRD |
| App-level credentials consumed by Deployments (via `secretKeyRef` or `envFrom`) | `-1` | Must decrypt before the Deployment starts at wave 0 |

### Before/after examples

#### Wrong — only `spec.template` annotated

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: my-app
  namespace: my-app
  # Missing: argocd.argoproj.io/sync-wave not here
spec:
  encryptedData:
    API_KEY: AgB...
  template:
    metadata:
      annotations:
        argocd.argoproj.io/sync-wave: "-1"
      name: my-app
      namespace: my-app
    type: Opaque
```

The SealedSecret CRD syncs at wave 0 (default), racing with the Deployment.

#### Correct — dual annotation

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: my-app
  namespace: my-app
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  encryptedData:
    API_KEY: AgB...
  template:
    metadata:
      annotations:
        argocd.argoproj.io/sync-wave: "-1"
      name: my-app
      namespace: my-app
    type: Opaque
```

Both the CRD and the decrypted Secret sync at wave -1, ensuring the Secret exists before the Deployment at wave 0.

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
