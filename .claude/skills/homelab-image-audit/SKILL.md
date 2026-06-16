# homelab-image-audit

Audit a container image to determine the correct Kubernetes `securityContext`.

## Usage

**Interactive mode** (for human operators):

```bash
.claude/skills/homelab-image-audit/audit.sh
```

**Non-interactive mode** (for Claude or scripting):

```bash
.claude/skills/homelab-image-audit/audit.sh --image <image-name> --type <nginx|rabbitmq|redis|other>
```

## What it does

1. Takes an image name (e.g., `nginx:1.29-alpine`, `makeplane/plane-admin:v1.3.1`)
2. Matches the image against known patterns in the base-image knowledge base
3. Outputs the recommended `securityContext` (drop, add, runAsUser, runAsNonRoot, fsGroup if applicable)
4. Notes gotchas specific to the image type

## Knowledge base

The script reads entries from `docs/solutions/`:

| Entry | Covers |
|---|---|
| `base-images-nginx.md` | nginx, derived nginx images (makeplane/plane-*, leantime, open-webui) |
| `base-images-rabbitmq.md` | RabbitMQ |
| `base-images-redis-valkey.md` | Redis, Valkey |
| `base-images-root-generic.md` | Generic / root images (busybox, alpine, unknown) |

## When to use

- Adding a new Deployment to the cluster
- Auditing an existing Deployment's securityContext
- Researching what capabilities an image needs before writing a manifest

## When to skip

- If the image type is already covered by a KB entry in `docs/solutions/` — the audit script auto-discovers and applies it
- Infrastructure components managed by operators (CNPG, mariadb-operator, Longhorn) — their security contexts are operator-managed

## Example

```bash
# Non-interactive — known nginx image
$ audit.sh --image nginx:1.29-alpine --type nginx
# Outputs nginx KB entry with CHOWN, SETGID, SETUID requirements

# Non-interactive — derived nginx image
$ audit.sh --image makeplane/plane-admin:v1.3.1 --type nginx
# Pattern-matched as nginx-derived, outputs same KB entry with derived-image notes

# Interactive — unknown image
$ audit.sh
Image name? my-custom-app:latest
No known pattern match.
Base image type? [1-8]: 8
Entrypoint behavior? [1-3]: 2
# Outputs fully-non-root recommendation
```
