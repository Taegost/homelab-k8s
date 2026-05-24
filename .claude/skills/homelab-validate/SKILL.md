---
name: homelab-validate
description: Use when about to commit Kubernetes YAML changes in the homelab-k8s repo. Triggers on "pre-commit check", "validate my manifests", "check before commit", or when staging YAML files and about to commit.
---

# Homelab Validate

Pre-commit verification for the homelab-k8s GitOps repo. Run before every commit that touches `.yaml` or `.yml` files.

## 1. Sync Wave Check

```bash
git diff --cached --name-only | grep -E '\.(yaml|yml)$' | xargs grep -L "sync-wave" 2>/dev/null
```

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

## 2. YAML Validity

Run on every staged `.yaml` or `.yml` file:

```bash
python3 -c "import yaml; yaml.safe_load(open('FILE'))" 2>&1
```

## 3. Plaintext Secret Guard

```bash
git diff --cached --name-only | grep "secret-[^.]*\.yaml" && echo "BLOCKED: plaintext secret staged" || echo "CLEAN"
```

Plaintext `secret-*.yaml` is gitignored. If grep matches, unstage immediately.

## 4. IngressRoute Consistency

Three rules for every IngressRoute:

| Rule | Internal-only | Public |
|---|---|---|
| Certificate | Uses wildcard cert (in `traefik` namespace) | Has its own explicit Certificate in app namespace |
| IngressRoute namespace | `traefik` (to reference wildcard TLS secret) | App namespace |
| Middleware | MUST include `default-whitelist` (traefik namespace) | MUST NOT include any whitelist middleware |

Override only when the user explicitly directs otherwise for a specific route.

### Verify internal IngressRoutes

```bash
# Internal routes in traefik namespace — must have default-whitelist middleware
git diff --cached --name-only | xargs grep -l "namespace: traefik" 2>/dev/null | \
  xargs grep -L "default-whitelist" 2>/dev/null
# Any matches = missing middleware
```

```bash
# Public routes NOT in traefik namespace — must NOT have whitelist middleware
git diff --cached --name-only | xargs grep -l "kind: IngressRoute" 2>/dev/null | \
  xargs grep -L "namespace: traefik" 2>/dev/null | \
  xargs grep -l "whitelist" 2>/dev/null
# Any matches = whitelist on public route (remove it)
```

### Certificate consistency

```bash
# Internal routes should NOT have a per-app Certificate
git diff --cached --name-only | grep "certificate-.*\.yaml" 2>/dev/null
# For each: verify the matching IngressRoute is NOT in traefik namespace
```

## 5. Longhorn PVC fsGroup Check

`fsGroup` is required ONLY when the container runs as non-root. Root containers don't need it — they can write to root-owned Longhorn volumes directly.

```bash
# Find Longhorn PVCs
git diff --cached --name-only | xargs grep -l "storageClassName: longhorn" 2>/dev/null
```

For each: check the Deployment that mounts the PVC. If `securityContext.runAsNonRoot: true` or a non-zero `runAsUser`, verify `fsGroup` is present in `spec.template.spec.securityContext`.
