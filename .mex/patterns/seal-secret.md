---
name: seal-secret
description: Creating, sealing, and managing Kubernetes secrets via SealedSecrets. Covers namespace scoping, placeholder format, dual-location sync-wave annotations, and the kubeseal workflow.
triggers:
  - "secret"
  - "seal"
  - "kubeseal"
  - "sealed secret"
  - "credentials"
  - "password"
  - "api key"
edges:
  - target: context/conventions.md
    condition: when checking placeholder format rules or sync wave requirements
  - target: context/decisions.md
    condition: when understanding why Sealed Secrets was chosen over alternatives
last_updated: 2026-06-16
---

# Seal Secret

## Context

Sealed Secrets is the sole secrets mechanism. Plaintext `secret-*.yaml` files are gitignored; `sealedsecret-*.yaml` files are committed. The controller in `kube-system` decrypts at sync time.

## Steps

1. Create `secret-<name>.yaml` with placeholder values
2. Provide the `kubeseal` command as a single line (never split with backslash continuations)
3. User fills in real values and runs `kubeseal`
4. Commit `sealedsecret-<name>.yaml`; `secret-<name>.yaml` stays gitignored

## Gotchas

### Namespace scoping

A SealedSecret is encrypted for a specific namespace. A secret sealed for namespace `foo` cannot decrypt in namespace `bar`. If an app needs a secret in a different namespace (e.g., MariaDB User CRD references a password secret in `mariadb` namespace), seal it separately for that namespace.

### Placeholder format

Placeholder values must not contain dots (`.`) or dashes (`-`) — use underscores only:
- ✅ `your_api_key_here`
- ❌ `your-api-key-here`
- ❌ `your.api.key.here`

Dots and dashes break word-selection in editors and terminals.

### Dual-location sync-wave annotations (critical)

SealedSecrets require the `argocd.argoproj.io/sync-wave` annotation in TWO places:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"    # ← ArgoCD reads THIS for ordering
spec:
  template:
    metadata:
      annotations:
        argocd.argoproj.io/sync-wave: "-1"  # ← propagates to decrypted Secret
```

If the annotation only exists in `spec.template.metadata.annotations`, ArgoCD treats the SealedSecret as wave 0 regardless of value. Diagnosis:
```bash
grep -n "sync-wave" apps/<app>/sealedsecret-*.yaml
```
If hits are deeply indented (under `spec:`), the annotation is in the wrong place.

### kubeseal command format

Always write as a single line:
```bash
kubeseal --format yaml --controller-namespace kube-system --controller-name sealed-secrets-controller < secret-basic-auth.yaml > sealedsecret-basic-auth.yaml
```

Never split with backslash continuations.

### PostgreSQL double-secret

PostgreSQL apps require the database password in two secrets with identical values:
- One in `postgres` namespace (for CNPG role password)
- One in the app namespace (for the pod to connect)

Both must be sealed separately (different namespaces = different encryption).

## Verify

- [ ] `secret-*.yaml` is gitignored (not staged)
- [ ] Placeholder values use underscores only (no dots/dashes)
- [ ] `kubeseal` command is a single line
- [ ] Sync-wave in `metadata.annotations` (not only in `spec.template`)
- [ ] SealedSecret sealed for the correct namespace
- [ ] For Postgres: two secrets with identical password, one per namespace

## Debug

- **Secret never created from SealedSecret:** wrong cluster key (re-seal), controller not running (`kubectl get pods -n kube-system -l name=sealed-secrets-controller`), or namespace mismatch
- **Pod can't find secret:** check namespace — SealedSecret must be in the namespace it was sealed for
- **Sync wave ignored:** check both annotation locations (see dual-location gotcha above)

## Update Scaffold

- [ ] Update `.mex/ROUTER.md` "Current Project State" if what's working/not built has changed
- [ ] Update any `.mex/context/` files that are now out of date
- [ ] If this is a new task type without a pattern, create one in `.mex/patterns/` and add to `INDEX.md`
