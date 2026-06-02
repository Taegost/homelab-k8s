---
name: homelab-k8s
last_updated: 2026-06-02
---

# homelab-k8s Strategy

## Target problem

Running personal services (media, AI, SSO, and more) at home while committing to
production-grade Kubernetes patterns — even when shortcuts would be faster. The hard
part is that the infrastructure has to actually work daily AND every decision has to
be explainable, because the cluster itself is the learning artifact.

## Our approach

Document every design decision inline so the repo teaches as much as it deploys.
Production patterns and GitOps discipline are chosen because they're worth teaching —
"can I explain this decision?" is the quality gate on every configuration choice.

## Who it's for

**Primary:** Anyone who knows Kubernetes basics but needs the *why* — whether that's
future-Mike at 2am during an incident, or an external engineer reading the repo as a
portfolio artifact. Same reader, different moments. They're hiring this repo to
understand not just how to deploy X on Kubernetes, but why the decisions that make it
work in production were the right ones.

## Key metrics

- **Cluster health** — all pods and resources scheduled and healthy; checked via
  ArgoCD and kubectl
- **Resource utilization** — CPU, memory, and storage within acceptable ranges;
  measured via the monitoring stack (varies per app)
- **Manifest documentation coverage** — non-trivial configuration has inline comments
  explaining the decision, not just the value; qualitative review
- **Runbook completeness** — extended docs exist for any topic warranting deeper
  discussion; qualitative review
- **Real-world tool adoption** — stack incorporates production Kubernetes tooling as
  it becomes relevant (worth outcome-framing on next run)

## Tracks

### Documentation currency **[COMPLETE — 2026-05-22]**

Close the gap between the live cluster and what's written: migration is complete, the
third node is online, and the docs need to reflect reality.

_Why it serves the approach:_ The repo can't teach if it describes a cluster that no
longer exists.

### Personal portfolio WordPress **[COMPLETE — 2026-05-22]**

Add a WordPress site for Mike's personal portfolio and blog, using the same
production patterns as other WordPress deployments in the cluster.

_Why it serves the approach:_ Demonstrates the MariaDB + Helm WordPress pattern while
serving the "Production-Grade Homelabbing" content niche directly.

### Observability

Deploy Prometheus and Grafana to provide visibility into cluster and app metrics
(CPU, memory, storage utilization).

_Why it serves the approach:_ Production clusters have observability; adding it makes
the homelab complete as a teaching artifact and closes the gap in metric #2.

### Backup capabilities

Add off-cluster backup: Postgres WAL archiving to an S3 endpoint, Longhorn volume
snapshots.

_Why it serves the approach:_ Disaster recovery is only real when it's been
configured. Backups are the production pattern that separates a working homelab from
a toy one.

### Documentation maintenance

Keep all documentation — CLAUDE.md, README, runbooks, app READMEs — consistent with
the live cluster. When apps are added, removed, or reconfigured, update the
corresponding docs in the same commit. Run periodic audits (this is the first one)
to catch drift that accumulates across feature branches.

_Why it serves the approach:_ Documentation drift undermines the repo's value as a
teaching artifact. A doc that describes a cluster that no longer exists is worse
than no doc at all — it teaches the wrong thing with the authority of being written
down.

## Marketing

**One-liner:** Production-Grade Homelabbing — a k3s cluster where every decision is
documented and nothing is skipped.
