---
title: "Security Context Audit — Never Copy Between Apps"
date: 2026-06-21
category: best-practices
module: homelab
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - "Deploying a new container image with securityContext"
  - "Adding capabilities drop ALL to an existing deployment"
  - "An image is not in the base-image knowledge base"
tags:
  - security-context
  - capabilities
  - container-security
  - audit
  - knowledge-base
---

# Security Context Audit — Never Copy Between Apps

## Context

Every container image has a different privilege model. The security context a Deployment needs depends entirely on what the image's entrypoint does at runtime. Copying nginx's `securityContext` to a Redis Deployment adds unnecessary capabilities. Copying Redis's (drop ALL, no adds) to nginx crashes workers. Each image type requires its own analysis.

## Guidance

### 1. Run the audit script before writing any securityContext

```bash
.claude/skills/homelab-image-audit/audit.sh --image <image> --type <type>
```

The script cross-references the base-image knowledge base and outputs recommended capabilities, privilege model, and port.

### 2. Known image capability requirements

| Image Type | Required Capabilities | Notes |
|-----------|----------------------|-------|
| nginx | CHOWN, SETGID, SETUID | Workers drop from root to UID 101. Conditional NET_BIND_SERVICE for port <1024 |
| RabbitMQ | CHOWN, DAC_OVERRIDE, SETGID, SETUID | DAC_OVERRIDE needed for root to read mode-0600 Erlang cookie |
| Redis/Valkey | None | Fully non-root, drop ALL with no adds |
| Generic/root | Varies | Check Dockerfile for gosu/su-exec patterns |

### 3. For unknown images, inspect the Dockerfile

Check for:
- `USER` directive — what UID/GID does the process run as?
- Entrypoint privilege drops — `gosu`, `su-exec`, `chroot` patterns?
- `EXPOSE` — what port? Non-root can't bind <1024
- Whether root operations (`chown`, `chmod`) happen at startup

### 4. Knowledge base is auto-discovered

Adding support for a new image type requires only creating `docs/solutions/base-images-<type>.md` — the audit script and capability-check pre-commit hook pick it up automatically.

## Why This Matters

- **Nginx worker crash**: `drop: ALL` without `CHOWN`, `SETGID`, `SETUID` → `setgid(101) failed (1: Operation not permitted)`
- **RabbitMQ silent failure**: Missing `DAC_OVERRIDE` → Erlang cookie read fails, probes fail, pod crash-loops
- **Redis over-capabilities**: Adding capabilities to a fully non-root image increases attack surface for no benefit

## When to Apply

- Every new Deployment that uses `securityContext.capabilities`
- When adding `drop: [ALL]` to an existing container
- When the image is not yet in the base-image knowledge base

## Examples

### Correct: RabbitMQ

```yaml
securityContext:
  capabilities:
    drop: [ALL]
    add: [CHOWN, SETGID, SETUID, DAC_OVERRIDE]
```

### Correct: Redis/Valkey

```yaml
securityContext:
  capabilities:
    drop: [ALL]
```

### Wrong: Copying nginx context to RabbitMQ

Would miss `DAC_OVERRIDE` — Erlang cookie read fails silently.

## Related

- `docs/solutions/base-images-nginx.md` — nginx capability reference
- `docs/solutions/base-images-rabbitmq.md` — RabbitMQ capability reference
- `docs/solutions/base-images-redis-valkey.md` — Redis/Valkey capability reference
- `docs/solutions/base-images-root-generic.md` — generic image guidance
- `.claude/skills/homelab-image-audit/audit.sh` — audit script
- `.claude/skills/homelab-validate/scripts/capability-check.sh` — pre-commit validation
