---
name: homelab-validate
description: Use when about to commit Kubernetes YAML changes in the homelab-k8s repo. Triggers on "pre-commit check", "validate my manifests", "check before commit", or when staging YAML files and about to commit.
---

# Homelab Validate

Pre-commit verification for the homelab-k8s GitOps repo. Run before every commit that touches `.yaml` or `.yml` files.

Scripts live in `scripts/` — run them from the repo root:

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

---

## 1. Sync Wave Check

**Script:** `scripts/sync-wave-check.sh`

Reports staged YAML files missing `sync-wave` annotations.

Only resources needing a **non-default** sync order require the annotation.
Wave `0` is ArgoCD's default — resources at wave 0 should NOT carry it.

For each file listed, decide:
- Is a SealedSecret? → needs wave in BOTH `metadata.annotations` AND `spec.template.metadata.annotations`.
  - **Infrastructure** (consumed by cluster CRD via `passwordSecretRef`): wave `-3`
  - **App-level** (consumed by Deployment via `secretKeyRef`): wave `-1`
- Is a CRD that consumes a SealedSecret from a DIFFERENT namespace (e.g., `passwordSecretRef`)? → wave `-2`.
- Is a Database CRD (CNPG)? → wave `-1`.
- Is a Deployment, Service, IngressRoute, PVC, ConfigMap, NetworkPolicy, or Certificate? → wave `0` — **OMIT the annotation**.

### Wave ordering

| Resource type | Wave | Annotation? |
|---|---|---|
| Infrastructure SealedSecret (consumed by cluster CRD) | `-3` | Required in both metadata AND template |
| Cross-namespace secret consumer (User CRD, PerconaServerMongoDB) | `-2` | Required |
| App-level SealedSecret (consumed by Deployment) | `-1` | Required in both metadata AND template |
| Database CRD (CNPG) | `-1` | Required |
| Deployment, Service, IngressRoute, PVC, ConfigMap, NetworkPolicy, Certificate | `0` | **OMIT — default wave** |

---

## 2. YAML Validity

**Script:** `scripts/yaml-validity.sh`

Validates YAML syntax for every staged `.yaml` or `.yml` file using `python3 -c "import yaml; yaml.safe_load_all(...)"`.

---

## 3. Plaintext Secret Guard

**Script:** `scripts/plaintext-secret-guard.sh`

Plaintext `secret-*.yaml` is gitignored. If any are staged, unstage immediately.

---

## 4. IngressRoute Consistency

**Script:** `scripts/ingressroute-check.sh`

Three rules for every IngressRoute:

| Rule | Internal-only | Public |
|---|---|---|
| Certificate | Uses wildcard cert (in `traefik` namespace) | Has its own explicit Certificate in app namespace |
| IngressRoute namespace | `traefik` (to reference wildcard TLS secret) | App namespace |
| Middleware | MUST include `default-whitelist` (traefik namespace) | MUST NOT include any whitelist middleware |

Override only when the user explicitly directs otherwise for a specific route.

---

## 5. Plaintext Secret Template Verification

**Script:** `scripts/secret-template-verify.sh [directory]`

**MANDATORY** — run against all `secret-*.yaml` files before signing off on work. These files are gitignored, so the script scans the filesystem directly (not `git diff --cached`).

Verifies:
1. `sync-wave` present in `metadata.annotations`
2. `sync-wave` present in `spec.template.metadata.annotations` (propagates to sealed output)
3. Placeholder values use underscores only (no dots or dashes)
4. Required fields (`name`, `namespace`) present

### SealedSecret creation rule

**Never create `sealedsecret-*.yaml` files.** They are the output of `kubeseal`, which the user runs after filling in real values. Create only the plaintext `secret-*.yaml` template and provide the `kubeseal` command alongside it. The command must be a single line — never split with backslashes.

---

## 6. Longhorn PVC fsGroup Check

**Script:** `scripts/longhorn-fsgroup-check.sh`

`fsGroup` is required ONLY when the container runs as non-root. Root containers don't need it — they can write to root-owned Longhorn volumes directly. Checks each Longhorn PVC against the Deployment that mounts it.

---

## 7. NetworkPolicy Verification

**Script:** `scripts/networkpolicy-check.sh`

Two hard rules, both enforced as failures:

1. Every `from` entry with `podSelector` MUST also have `namespaceSelector` — even if the target pods are in the same namespace. Explicit is safer than implicit.
2. No deny-all policies — every `Ingress` policy MUST have at least one `from` block.

The script uses YAML-aware parsing (`yaml.safe_load_all()`). Grep-based heuristics won't work — every NetworkPolicy has `spec.podSelector` (policy's own target pods) which would false-match `from[].podSelector`.

---

## 8. Probe Timeout Check

**Script:** `scripts/probe-timeout-check.sh`

This check runs only when Deployment files are staged. On other commits it exits 0 with SKIP.

Catches exec probes with default (too-short) `timeoutSeconds`. Kubernetes defaults to 1s when omitted, which kills slow CLI commands before they complete.

| CLI pattern | Minimum timeout | Severity |
|---|---|---|
| `rabbitmq-diagnostics`, `rabbitmqctl`, `celery` | 5s | FAIL |
| `redis-cli`, `valkey-cli`, `pg_isready`, `mysqladmin`, `mongosh` | 2s | FAIL |
| Any other exec probe | >1s | WARN (non-blocking) |

Only checks `livenessProbe`, `readinessProbe`, and `startupProbe` with `exec` fields. `httpGet` and `tcpSocket` probes are not checked.

---

## 9. Capability Check

**Script:** `scripts/capability-check.sh`

This check runs only when Deployment files are staged. On other commits it exits 0 with SKIP.

Catches missing capabilities for well-known images when `drop` includes `ALL`. Reads capability requirements from `docs/solutions/` KB files — the KB is the single source of truth. No capability lists are hardcoded in the script.

| Condition | Severity |
|---|---|
| Image matches KB pattern + `drop: [ALL]` + required capabilities missing | FAIL |
| Image matches KB pattern + `drop: [ALL]` + required capabilities present | PASS |
| Image matches KB pattern + KB says no capabilities needed + `add` empty | PASS |
| Image not in KB | not checked (manual Dockerfile review required) |
| No `drop: [ALL]` | not checked |

Adding a new image type only requires adding a KB entry — the script picks it up automatically.

---

## 10. Env Injection Check

**Script:** `scripts/env-check.sh`

This check runs only when Deployment files are staged. On other commits it exits 0 with SKIP.

Warns when Deployments have no `envFrom` or `env` blocks. All findings are WARN — this check never blocks commits. It catches accidental omissions (e.g., a new Deployment created without copying the namespace-standard envFrom block).

Checks main containers only (`spec.containers`), not init containers — init containers legitimately have no env injection.
