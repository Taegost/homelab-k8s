---
name: router
description: Session bootstrap and navigation hub for a persistent AI agent workspace.
edges:
  - target: context/architecture.md
    condition: when working on services, infrastructure, automations, or system shape
  - target: context/stack.md
    condition: when checking tools, models, runtimes, versions, or hardware
  - target: context/conventions.md
    condition: when operating on the system or applying safety rules
  - target: context/decisions.md
    condition: when asking why something is configured a certain way
  - target: context/setup.md
    condition: when debugging, restarting, recovering, or inspecting services
  - target: HEARTBEAT.md
    condition: when handling a scheduled heartbeat
last_updated: 2026-06-16
---

# Session Bootstrap

Read `AGENTS.md` first if it is not already loaded. Then read this file.

## Current Operational State

**Cluster:** k3s on 3 combined control-plane/worker nodes. All workloads managed by ArgoCD (app-of-apps pattern).

**Running:**
- Core infra: Traefik (ingress), MetalLB (L2/ARP), cert-manager (Let's Encrypt DNS-01), Longhorn (storage), Sealed Secrets, SMB CSI Driver
- Data tier: CNPG PostgreSQL (2 instances, PgBouncer), MariaDB (2 instances, async GTID), Percona MongoDB (1 instance)
- SSO: Authentik (2 server replicas, 1 worker, Redis, LDAP outpost)
- Apps: Arr-stack, Authentik, AWS DDNS, Firefly3, Leantime, LibreChat, LiteLLM, Manyfold, Mealie, n8n, Open WebUI, Plane, SearXNG, WordPress (dng, taegost)

**Pending:**
- ArgoCD HA migration — all 3 nodes active, follow `docs/argocd-ha-migration.md`
- LibreChat NetworkPolicy hardening — meilisearch and redis policies need `namespaceSelector` added (see `context/stack.md`)
- Pre-commit hook one-time setup per clone: `ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit`

**External dependencies (not managed in this repo):**
- pfSense (network edge), Unraid NAS `firebird.lan` (SMB/NFS), Route53 (DNS), kube-vip (control-plane VIP)

## Routing Table

### Context Files

| Task type | Load |
|-----------|------|
| System architecture or service topology | `context/architecture.md` |
| Models, tools, hardware, versions, storage | `context/stack.md` |
| Operational rules, naming, safety habits | `context/conventions.md` |
| Why a decision was made | `context/decisions.md` |
| Run, inspect, restart, recover | `context/setup.md` |
| Scheduled heartbeat | `HEARTBEAT.md` |
| Recurring task | `patterns/INDEX.md` |

### User-Facing Documentation

| Task type | Load |
|-----------|------|
| Deploying a new app with Postgres | `docs/postgres-runbooks.md` |
| Deploying a new app with MariaDB | `docs/mariadb-runbooks.md` |
| Deploying a new app with MongoDB | `docs/mongodb-runbooks.md` |
| Sealed secrets workflow | `docs/sealed-secrets.md` |
| Cluster recovery or node loss | `docs/disaster-recovery.md` |
| DNS or networking issues | `docs/troubleshooting.md` |
| Storage utilisation or trim jobs | `docs/storage.md` |
| n8n HA migration (S3, queue mode) | `docs/n8n-ha-migration.md` |
| ArgoCD HA migration | `docs/argocd-ha-migration.md` |
| External service routing | `apps/traefik/external/README.md` |
| Bootstrap from scratch | `bootstrap/README.md` |
| Pre-commit validation scripts | `.claude/skills/homelab-validate/SKILL.md` |
| Image security context audit | `.claude/skills/homelab-image-audit/SKILL.md` |
| Planning artifacts | `docs/plans/`, `docs/brainstorms/` |

## Behavioural Contract

1. **CONTEXT** — Load only the files relevant to the task.
2. **ACT** — Do the requested work using the current operational state.
3. **VERIFY** — Check the real system state before claiming success.
4. **DEBUG** — If reality disagrees with the scaffold, trust reality and repair the scaffold.
5. **GROW** — Ground, Record, Orient, Write:
   - Ground: name what changed in reality.
   - Record: update current truth in `ROUTER.md` or `context/`.
   - Orient: create/update a `patterns/` runbook for recurring work.
   - Write: bump `last_updated` and run `mex log` for decisions, risks, todos, or useful notes.
