---
name: agents
description: Always-loaded operating contract for a persistent AI agent workspace.
last_updated: 2026-06-16
---

# homelab-k8s

## What This Is

A GitOps-managed Kubernetes homelab cluster (k3s, 3 nodes) where all workloads are declared in git and reconciled by ArgoCD.

## Non-Negotiables

- Never commit plaintext secrets — no exceptions
- Never set `HOMELAB_ALLOW_LATEST` or `HOMELAB_ALLOW_MAIN` — these are for the human operator only
- Never use `git commit --amend` — it rewrites the commit hash, causing merge conflicts
- All cluster changes go through git and ArgoCD — never use `kubectl apply` directly
- Pre-commit hook must be installed per clone: `ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit`

## Commands

| Purpose | Command |
|---------|---------|
| Run validation suite | `/homelab-validate` |
| Audit container security context | `.claude/skills/homelab-image-audit/audit.sh --image <image> --type <type>` |
| Check ArgoCD app status | `kubectl get applications -n argocd` |
| Check pod status | `kubectl get pods -n <namespace>` |
| Restart a deployment | `kubectl rollout restart deployment -n <namespace> <name>` |
| Unstick deleting ArgoCD app | `kubectl patch application <app> -n argocd -p '{"metadata":{"finalizers":[]}}' --type=merge` |
| Check Longhorn volumes | `kubectl get volumes -n longhorn-system` |
| Check SealedSecret controller | `kubectl get pods -n kube-system -l name=sealed-secrets-controller` |
| mex drift check | `mex check` |
| mex interactive resync | `.mex/sync.sh` |

## GROW

After meaningful work:
- Ground: what changed in reality?
- Record: update `ROUTER.md` and relevant `context/` files
- Orient: create/update a `patterns/` runbook if this can recur
- Write: bump `last_updated` and run `mex log` when rationale matters

## Heartbeat

When invoked for a heartbeat, read `HEARTBEAT.md`. If all checks pass, respond with exactly `HEARTBEAT_OK`.

## Navigation

At the start of every normal session, read `ROUTER.md` before doing anything else.
