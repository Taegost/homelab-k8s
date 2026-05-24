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
```

---

## 1. Sync Wave Check

**Script:** `scripts/sync-wave-check.sh`

Reports staged YAML files missing `sync-wave` annotations.

For each file listed, decide:
- References a Secret (`secretKeyRef`, `passwordSecretRef`, `secretName`)? → Needs wave annotation.
- Is a CRD that consumes a SealedSecret? → Needs wave annotation.
- Is a SealedSecret itself? → Needs wave in BOTH `metadata.annotations` (ArgoCD reads this) AND `spec.template.metadata.annotations` (passthrough).
- Pure config, no dependencies? → Safe to omit.

### Wave ordering

| Resource type | Wave |
|---|---|
| SealedSecret (any namespace) | `-3` |
| CRD consumer of a secret (User, Grant, PerconaServerMongoDB) | `-2` |
| Database CRD, app-level SealedSecrets | `-1` |
| Deployment, Service, IngressRoute, PVC, Certificate | `0` (omit annotation) |

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
