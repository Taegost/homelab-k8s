# Redis / Valkey Security Context

## Image patterns

- `redis`, `redis:` — any explicit Redis image
- `valkey`, `valkey:` — any explicit Valkey image
- `*/redis:*`, `*/valkey:*` — any registry-prefixed image

## Required capabilities (when `drop: [ALL]`)

None. Both Redis and Valkey official images run as a non-root user (typically UID 999) from the start. There is no root-to-user privilege drop at runtime. All capabilities can be safely dropped.

## Privilege model

Fully non-root. The image entrypoint launches the server process directly as UID 999. No `setuid()` or `setgid()` calls occur at runtime. `runAsNonRoot: true` can be set but is not strictly required — the image already runs as non-root.

## Port

- Default: 6379
- Non-privileged. No `NET_BIND_SERVICE` required.

## Gotchas

- The Redis→Valkey rename (2024) means both image names appear in clusters. The security context is identical for both
- Some Redis images include `redis-cli` for health checks — this runs as the same non-root user and does not need capabilities
- If using a custom-built Redis image or a wrapper entrypoint, verify it does not introduce root-level operations

## Source

- Confirmed across 5 Deployments in the repo: `apps/plane/deployment-valkey.yaml`, `apps/authentik/deployment-redis.yaml`, `apps/librechat/deployment-redis.yaml`, `apps/manyfold/deployment-redis.yaml`, `apps/litellm/deployment-redis.yaml`
