---
title: "Pre-Commit Validation Suite — 11 Automated Checks"
date: 2026-06-21
category: tooling-decisions
module: homelab
problem_type: tooling_decision
component: tooling
severity: high
applies_when:
  - "Committing YAML changes to the homelab-k8s repo"
  - "Adding a new validation check to the pre-commit hook"
  - "Debugging why a commit was blocked by homelab-validate"
tags:
  - pre-commit
  - validation
  - gitops
  - automation
  - homelab-validate
---

# Pre-Commit Validation Suite — 11 Automated Checks

## Context

This is a GitOps repo where ArgoCD reconciles everything from committed YAML. A misconfigured manifest — missing sync-wave annotation, plaintext secret staged, `:latest` image tag, wrong middleware on an IngressRoute — breaks live services or introduces security gaps. The validation suite catches these at commit time.

## Guidance

### The 11 checks

**Always-on (run on every YAML commit):**

| # | Check | What It Catches |
|---|-------|-----------------|
| 1 | Sync Wave | Missing wave annotations, wave ordering violations |
| 2 | YAML Validity | Syntax errors (unclosed quotes, bad indentation) |
| 3 | Plaintext Secret Guard | Staged `secret-*.yaml` files (should be gitignored) |
| 6 | Secret Template Verify | Missing dual annotations, bad placeholder format |
| 7 | :latest Tag Guard | Unpinned image tags |

**Conditional (run when relevant files are staged):**

| # | Condition | Check | What It Catches |
|---|-----------|-------|-----------------|
| 4 | IngressRoute files | IngressRoute Consistency | Wrong namespace, missing middleware, cert issues |
| 5 | PVC files | Longhorn fsGroup | Missing fsGroup, fsGroup in wrong location |
| 8 | NetworkPolicy files | NetworkPolicy Consistency | Missing namespaceSelector, deny-all policies |
| 9 | Deployment files | Probe Timeout | Default/too-short timeoutSeconds on exec probes |
| 10 | Deployment files | Capability Check | Missing capabilities for drop-ALL containers |
| 11 | Deployment files | Env Injection | Containers with no envFrom/env (WARN only) |

### Installation

```bash
ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
```

### Manual invocation

```bash
.claude/skills/homelab-validate/scripts/sync-wave-check.sh
.claude/skills/homelab-validate/scripts/yaml-validity.sh
.claude/skills/homelab-validate/scripts/plaintext-secret-guard.sh
.claude/skills/homelab-validate/scripts/ingressroute-check.sh
.claude/skills/homelab-validate/scripts/longhorn-fsgroup-check.sh
.claude/skills/homelab-validate/scripts/networkpolicy-check.sh
.claude/skills/homelab-validate/scripts/probe-timeout-check.sh
.claude/skills/homelab-validate/scripts/capability-check.sh
.claude/skills/homelab-validate/scripts/env-check.sh
```

### Bypass variables

- `HOMELAB_ALLOW_LATEST=1` — allows `:latest` image tags
- `HOMELAB_ALLOW_MAIN=1` — allows direct pushes to main

**Claude must NEVER set these.** The bypasses exist for the human operator only.

## Why This Matters

- **Sync wave race** (MongoDB): Missing wave annotations caused operator to generate random credentials
- **Probe timeout kills** (RabbitMQ): Default 1s timeout killed healthy pods every ~180s
- **Capability failures** (nginx): Missing SETGID/SETUID crashed workers on first request
- **Plaintext secrets**: A single `secret-*.yaml` committed exposes credentials in git history

## When to Apply

- Every commit that touches `.yaml` or `.yml` files (automatic via pre-commit hook)
- When adding a new app or modifying existing manifests
- When debugging why a commit was blocked — check the specific script's output

## Examples

### Capability check catches missing DAC_OVERRIDE

A Deployment with `drop: [ALL]` using a RabbitMQ image but missing `DAC_OVERRIDE`:

```
FAIL: deployment-rabbitmq — container rabbitmq missing required capability DAC_OVERRIDE
(required by docs/solutions/base-images-rabbitmq.md)
```

### Probe timeout check catches default timeout

A Deployment with an exec probe and no `timeoutSeconds`:

```
FAIL: deployment-rabbitmq — exec probe timeoutSeconds not set (default 1s too short for rabbitmq-diagnostics)
```

## Related

- `CLAUDE.md` — Pre-Commit Verification section
- `.githooks/pre-commit` — the hook script
- `.claude/skills/homelab-validate/SKILL.md` — skill definition
- `docs/solutions/best-practices/security-context-audit-pattern.md` — capability audit workflow
