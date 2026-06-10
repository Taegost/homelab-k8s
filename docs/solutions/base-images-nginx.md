# Nginx Security Context

## Image patterns

- `nginx`, `nginx:` — any explicit nginx image
- `nginx:*`, `*/nginx:*` — any registry-prefixed nginx image
- `makeplane/plane-admin` — derived, nginx:1.29-alpine base
- `makeplane/plane-frontend` — derived, nginx:1.29-alpine base
- `leantime/leantime` — serversideup/php base, bundles nginx internally
- `ghcr.io/open-webui/open-webui` — bundles nginx internally (capability needs unverified, see gotchas)

## Required capabilities (when `drop: [ALL]`)

| Capability | Why |
|---|---|
| `CHOWN` | nginx master chowns `/var/cache/nginx/client_temp` to the nginx user at startup |
| `SETGID` | worker processes call `setgid()` to drop from root to nginx user |
| `SETUID` | worker processes call `setuid()` to drop from root to nginx user |

`NET_BIND_SERVICE` is required only when nginx binds to privileged ports (<1024). The official nginx image listens on port 80 and needs it. Derived images (makeplane/plane-*, leantime) commonly remap to port 8080 and do not need it.

## Privilege model

nginx master process starts as root, spawns worker processes, then workers call `setgid()` and `setuid()` to drop to a non-root user (typically UID 101 for the official image). Without `SETGID` and `SETUID`, workers crash with:

```
setgid(101) failed (1: Operation not permitted)
```

## Port

- Official `nginx` image: port 80 (privileged). Needs `NET_BIND_SERVICE` if `drop: [ALL]`.
- Derived images (makeplane/plane-*, leantime): typically port 8080 (non-privileged). No `NET_BIND_SERVICE` needed.
- Always cross-reference the Deployment's `containerPort` to determine which applies.

## Gotchas

- Derived images like `makeplane/plane-admin` do not contain "nginx" in their image field — substring matching misses them
- The `leantime/leantime` image bundles nginx via `serversideup/php` but runs fully as non-root (UID 1000) with no root-to-user drop at runtime — it does NOT need `SETGID`/`SETUID` despite bundling nginx
- `ghcr.io/open-webui/open-webui` bundles nginx internally but its entrypoint behavior is unverified — capability needs unknown
- If the entrypoint runs nginx as a fixed non-root user without `setgid()`/`setuid()` calls, no capabilities are needed (Leantime pattern)
- WordPress images use Apache + PHP, not nginx — they are not covered by this entry

## Source

- `docs/troubleshooting/troubleshooting-plane.md` — nginx worker crash debugging
- `apps/plane/deployment-plane-admin.yaml` — capability comments
- `apps/plane/deployment-plane-web.yaml` — capability comments
- `apps/leantime/deployment-leantime.yaml` — non-root nginx pattern
