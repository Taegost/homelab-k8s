# ArgoCD HA Migration

This document covers switching ArgoCD from the non-HA to the HA install manifest
once a third cluster node is available.

---

## Background

ArgoCD was initially installed using the non-HA manifest (`install.yaml`) because
the cluster had only 2 nodes at the time. The HA manifest (`ha/install.yaml`)
requires a minimum of 3 nodes due to Redis HA's quorum requirements:

- Redis HA uses a Sentinel-based setup that needs at least 3 instances to establish
  quorum and elect a primary. With only 2 nodes, one Redis pod is permanently pending
  due to pod anti-affinity rules that prevent multiple replicas landing on the same node.
- Running Redis HA without quorum causes instability and potential data loss, so
  the non-HA install was the correct choice until a third node was available.

---

## Prerequisites

- The third cluster node is joined and shows `Ready` in `kubectl get nodes`
- ArgoCD is running and healthy (`Synced` and `Healthy` in the UI)
- You have the repo checked out locally in the DevOps Toolbox

---

## Migration Steps

Since ArgoCD is managing itself at this point, the switchover is a single Git
commit — no manual `kubectl apply` needed.

**Step 1 — Download the HA manifest:**

```bash
curl -sL https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.7/manifests/ha/install.yaml \
  -o apps/argocd/argocd.yaml
```

**Step 2 — Commit and push:**

```bash
git add apps/argocd/argocd.yaml
git commit -m "chore(argocd): switch to HA manifest now that third node is available"
git push
```

**Step 3 — Watch ArgoCD apply the change to itself:**

ArgoCD will detect the change in Git, sync the new manifest, and replace its own
pods with the HA versions. There will be a brief interruption while the application
controller is replaced — this is expected and ArgoCD will resume automatically once
the new pods are up.

Monitor the rollout in k9s or with:

```bash
kubectl get pods -n argocd --watch
```

**Step 4 — Verify:**

Once all pods are running, confirm in the ArgoCD UI that:
- All applications show `Synced` and `Healthy`
- The `argocd` self-management application itself shows `Synced` and `Healthy`

```bash
kubectl get pods -n argocd
# All pods should show Running with full READY counts (e.g. 3/3 for redis-ha-server)
```

---

## Post-Migration Cleanup

No cleanup is required. The HA manifest is a superset of the non-HA manifest —
all existing Applications, AppProjects, settings, and sync history are preserved
in Kubernetes CRDs and survive the transition automatically.