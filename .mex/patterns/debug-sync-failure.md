---
name: debug-sync-failure
description: Diagnosing ArgoCD sync failures, stuck resources, and reconciliation issues. Covers SealedSecret ordering, missing dependencies, PVC problems, and app lifecycle.
triggers:
  - "sync failed"
  - "argocd"
  - "stuck"
  - "not deploying"
  - "not syncing"
  - "reconciliation"
edges:
  - target: context/setup.md
    condition: when checking common commands or recovery procedures
  - target: context/conventions.md
    condition: when checking sync wave rules or pre-commit validation
  - target: patterns/seal-secret.md
    condition: when the failure involves SealedSecrets
last_updated: 2026-06-16
---

# Debug Sync Failure

## Context

ArgoCD reconciles from git on a 3-minute polling interval. If a resource isn't deploying, the cause is almost always one of: missing dependency, wrong sync wave order, namespace mismatch, or a failing health check.

## Diagnosis Flow

### 1. Check Application status

```bash
kubectl get applications -n argocd <app-name> -o yaml
```

Look at `status.sync.status` and `status.health.status`. Common states:
- `OutOfSync` — git state differs from cluster (normal before sync)
- `SyncFailed` — sync attempted but failed (check `status.operationState.message`)
- `Degraded` — a resource is unhealthy (check individual resource statuses)

### 2. Check resource events

```bash
kubectl describe <resource-type> -n <namespace> <name>
```

Events section shows the most recent errors — missing secrets, image pull failures, scheduling failures.

### 3. Check pod logs

```bash
kubectl logs -n <namespace> <pod-name>
```

If the pod is CrashLooping, check the previous container's logs:
```bash
kubectl logs -n <namespace> <pod-name> --previous
```

## Common Failures

### SealedSecret wave ordering

**Symptom:** App Deployment fails with missing Secret, but the SealedSecret exists.

**Root cause:** Sync-wave annotation only in `spec.template.metadata.annotations` (not in `metadata.annotations`). ArgoCD treats it as wave 0, so it syncs at the same time as the Deployment that depends on it.

**Diagnosis:**
```bash
grep -n "sync-wave" apps/<app>/sealedsecret-*.yaml
```
If hits are deeply indented (under `spec:`), the annotation is in the wrong place.

**Fix:** Add `argocd.argoproj.io/sync-wave` to `metadata.annotations`.

### Missing Secret or ConfigMap

**Symptom:** Pod in `CreateContainerConfigError`.

**Root cause:** A Secret or ConfigMap referenced by the Deployment doesn't exist yet (wrong wave order) or was never created.

**Diagnosis:**
```bash
kubectl describe pod -n <namespace> <pod-name>
kubectl get secret -n <namespace>
kubectl get configmap -n <namespace>
```

### PVC stuck Pending

**Symptom:** Pod stuck in `Pending` or `ContainerCreating`.

**Root cause:** Longhorn can't attach the volume — usually missing `open-iscsi`, wrong `csi.kubeletRootDir`, or CSI driver not registered.

**Diagnosis:**
```bash
kubectl get pvc -n <namespace>
kubectl describe pvc -n <namespace> <pvc-name>
sudo ls /var/lib/kubelet/plugins_registry/  # should include driver.longhorn.io-reg.sock
```

### ArgoCD Application stuck deleting

**Symptom:** Application stuck in `Terminating` with finalizer.

**Fix:**
```bash
kubectl patch application <app-name> -n argocd -p '{"metadata":{"finalizers":[]}}' --type=merge
```

### Deployment not picking up Secret changes

**Symptom:** Updated a SealedSecret but the pod still has old values.

**Fix:** Restart the deployment to re-mount the secret:
```bash
kubectl rollout restart deployment -n <namespace> <deployment-name>
```

### IngressRoute 404 or TLS error

**Symptom:** App returns 404 or TLS handshake failure.

**Root cause:** IngressRoute in wrong namespace, missing `tls.secretName`, or cert doesn't exist in the expected namespace.

**Diagnosis:**
```bash
kubectl get ingressroute -n traefik <name>  # wildcard cert apps
kubectl get ingressroute -n <namespace> <name>  # per-app cert apps
kubectl get certificate -n <namespace>  # check cert status
```

## Verify

- [ ] Application status checked (`kubectl get applications -n argocd`)
- [ ] Resource events checked (`kubectl describe`)
- [ ] Pod logs checked (current and previous container)
- [ ] Sync-wave ordering verified (SealedSecrets before dependents)
- [ ] Secrets and ConfigMaps exist in the correct namespace

## Update Scaffold

- [ ] Update `.mex/ROUTER.md` "Current Project State" if what's working/not built has changed
- [ ] Update any `.mex/context/` files that are now out of date
- [ ] If this is a new task type without a pattern, create one in `.mex/patterns/` and add to `INDEX.md`
