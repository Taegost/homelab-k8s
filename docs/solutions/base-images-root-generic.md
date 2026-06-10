# Root / Generic Image Security Context

## Image patterns

Any image not covered by a specific base-image entry (nginx, RabbitMQ, Redis/Valkey). Common examples:

- `busybox`, `busybox:*` — init containers
- `alpine`, `alpine:*` — base images for custom containers
- `ubuntu`, `debian:*` — general-purpose base images

## Required capabilities (when `drop: [ALL]`)

**WARN if**: the image entrypoint uses a known privilege-drop mechanism (`gosu`, `su-exec`, `su`, `chroot`) AND `runAsUser` is not set AND `runAsNonRoot: true` is not set.

| Capability | Why |
|---|---|
| `SETGID` | entrypoint calls `gosu`/`su-exec` to drop group privileges |
| `SETUID` | entrypoint calls `gosu`/`su-exec` to drop user privileges |

This is a WARN, not a FAIL — the script cannot read the Dockerfile and may not detect all privilege-drop mechanisms.

**No WARN if**: `runAsUser` is explicitly set, or `runAsNonRoot: true` is set. These indicate the operator has already configured non-root execution.

## Privilege model

Unknown without reading the Dockerfile. This entry covers the generic case where the image's behavior is not documented in a specific KB entry.

## Port

Unknown. Always check the image's `EXPOSE` directive and the Deployment's `containerPort`.

## Gotchas

- `busybox` init containers (`docker.io/library/busybox:1.36`) typically run a single `chown` or `mkdir` command as root and exit — they do NOT need `SETUID`/`SETGID` because they never drop privileges. Add `runAsUser: 0` explicitly to suppress the WARN
- The presence of `gosu` or `su-exec` in the image does not guarantee it is used at runtime — some images include it but use a different entrypoint path
- This entry is intentionally conservative (WARN, not FAIL) because the script cannot determine the actual entrypoint behavior without reading the Dockerfile

## Source

- Generic pattern derived from auditing all Deployment security contexts in the repo
- `apps/plane/deployment-rabbitmq.yaml` — busybox init container with `runAsUser: 0`
