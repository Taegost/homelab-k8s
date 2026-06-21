---
title: "mex checkPaths produces false positives for non-path inline code in markdown"
date: 2026-06-16
category: tooling-decisions
module: mex
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "Using mex (agent memory system) with infrastructure-as-code repos"
  - "Using mex with documentation-heavy projects where backticks denote config values, commands, or inline code"
  - "Any repo where the linter's path-resolution heuristic does not match the domain's conventions"
tags:
  - mex
  - checkpaths
  - false-positives
  - agent-memory
  - documentation-linting
  - backticks
---

# mex checkPaths produces false positives for non-path inline code in markdown

## Context

The homelab-k8s project integrated mex v0.6.1 — an agent memory system that manages `.mex/` markdown files containing routing tables, conventions, and design documents. After integration, `mex check` reported a score of 0/100. The root cause: the `checkPaths` drift checker scans all `.mex/` markdown files, extracts every backtick-wrapped string via the regex `/`([^`]+)`/g`, and attempts to resolve each one as a filesystem path. If none of its resolution strategies succeed (project root, scaffold root, `.mex/` prefix, or glob expansion), it emits a `MISSING_PATH` error at -10 points each.

In an infrastructure/Kubernetes documentation context, backticks are used pervasively for config values, annotation keys, IP addresses, example filenames, glob patterns, and template placeholders — none of which are file paths.

## Guidance

The checker's core assumption — that backtick-wrapped strings in markdown almost always refer to file paths — is accurate for code repositories but breaks down for infrastructure and documentation-heavy repos. The mex source code (`src/checkers/checkPaths.ts`) does not distinguish between strings that look like paths (contain `/` or end in known extensions) and strings that are clearly configuration values, network addresses, or inline examples.

The 18 false positives fell into six categories:

1. **Kubernetes config values** (7 errors): strings like `csi.kubeletRootDir: /var/lib/kubelet` and `forwardedHeaders.trustedIPs: 10.0.0.0/8` — valid Kubernetes YAML keys/values wrapped in backticks for documentation clarity
2. **Kubernetes annotation keys** (2 errors): `argocd.argoproj.io/sync-wave` — domain-qualified strings that contain slashes but are not file paths
3. **IP addresses and subnets** (2 errors): `192.168.5.0/24`, `10.0.0.0/8` — network notation using slashes
4. **Example filenames in naming convention tables** (3 errors): `clusterissuer-dng-prod.yaml`, `secret-basic-auth.yaml` — illustrative examples within tables, not files the repo contains at the root
5. **File extensions and glob patterns** (3 errors): `.yaml`, `.yml`, `apps/manifests/*.yaml` — extension references and glob syntax that the checker cannot resolve against the filesystem
6. **Template placeholders** (1 error + 7 warnings): `.mex/sync.sh` and placeholder links in INDEX.md — content that references future or templated files not yet materialized on disk (mex's own template issues, not project content)

Five resolution options were evaluated: (A) file an upstream issue and wait, (B) accept the checker is broken and use mex only for routing, (C) fork mex and fix locally, (D) restructure documentation to avoid backticks — rejected as it degrades readability — and (E) revert mex entirely. The upstream issue was filed requesting that `checkPaths` be scoped to paths mex itself uses, rather than treating all backtick strings as path claims.

## Why This Matters

A checker that returns 0/100 due to false positives trains operators to ignore its output entirely. When every violation looks the same, genuine drift — actual missing files, broken references, or stale paths — becomes invisible in the noise. This undermines the core value proposition of mex: trustworthy memory and conventions that agents and humans can rely on. The tool's authority erodes, and the operator learns that `mex check` is decorative rather than diagnostic. (session history)

## When to Apply

This guidance applies when using mex (or any documentation linter) with:

- **Infrastructure-as-code repos** where markdown documents Kubernetes manifests, Helm values, network configs, or cloud resource definitions
- **Documentation-heavy projects** where backticks denote config values, command examples, or inline code — not file paths
- **Any repo where the linter's path-resolution heuristic does not match the domain's conventions**

The broader lesson: before adopting a documentation linter, verify its false-positive rate against your actual content. A checker with the wrong assumption about what backticks mean in your domain will produce noise that trains people to ignore it.

## Examples

| Category | Example false positive | Why it triggered | Why it is not a path |
|---|---|---|---|
| K8s config value | `csi.kubeletRootDir: /var/lib/kubelet` | Contains `/`, looks path-like | Kubernetes YAML key:value pair |
| K8s annotation key | `argocd.argoproj.io/sync-wave` | Contains `/` | Domain-qualified annotation, not a file |
| IP subnet | `192.168.5.0/24` | Contains `/` | Network CIDR notation |
| Example filename | `clusterissuer-dng-prod.yaml` | Ends in `.yaml` | Illustrative example in a naming convention table |
| Glob pattern | `apps/manifests/*.yaml` | Contains `/` and `*` | Glob syntax for manifest discovery |
| Template placeholder | `.mex/sync.sh` | Resolves to a path-like structure | Future file referenced in a scaffold template, not yet on disk |

### What didn't work (session history)

- **Fixing documentation content to satisfy the checker** — changing script name references to full paths fixed 2 errors but the core problem remained: the checker treats all backtick-wrapped strings as path claims
- **Wrapping non-path strings in code fences or restructuring documentation** — the user correctly identified this as "changing documentation style to work around a tool bug" and rejected it

## Related

- Detailed analysis with full evidence: `docs/brainstorms/2026-06-16-mex-checkpaths-false-positives.md`
- mex integration plan: `docs/plans/2026-06-16-002-feat-mex-integration-plan.md`
- Upstream mex repo: https://github.com/theDakshJaitly/mex
