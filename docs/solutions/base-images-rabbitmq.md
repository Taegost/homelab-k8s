# RabbitMQ Security Context

## Image patterns

- `rabbitmq`, `rabbitmq:` — any explicit RabbitMQ image
- `rabbitmq:*`, `*/rabbitmq:*` — any registry-prefixed RabbitMQ image

## Required capabilities (when `drop: [ALL]`)

| Capability | Why |
|---|---|
| `CHOWN` | RabbitMQ entrypoint chowns data directories (`/var/lib/rabbitmq`) at startup |
| `DAC_OVERRIDE` | `.erlang.cookie` is mode 0600 owned by the rabbitmq user; root cannot read it without this capability when `ALL` capabilities are dropped |
| `SETGID` | entrypoint drops group privileges to the rabbitmq user |
| `SETUID` | entrypoint drops user privileges to the rabbitmq user |

All four are required. Each was confirmed during the Plane debugging session — removing any one causes RabbitMQ to fail to start.

## Privilege model

The official RabbitMQ image starts as root, initializes directories and the Erlang cookie, then drops to the `rabbitmq` user (typically UID 999) for the actual broker process. The `DAC_OVERRIDE` requirement is non-obvious — even running as root, reading a mode 0600 file owned by another user requires this capability when `ALL` capabilities are dropped.

## Port

- AMQP: 5672
- Management UI: 15672
- Neither is privileged (<1024) — `NET_BIND_SERVICE` is not required.

## Gotchas

- `DAC_OVERRIDE` is easy to miss because the entrypoint runs as root — root can normally bypass permissions, but not when `ALL` capabilities are dropped
- Version-specific: Bitnami RabbitMQ images run as non-root by default and may not need capabilities. Always verify the image distribution
- Init containers that set up RabbitMQ (e.g., busybox chown scripts) do not need these capabilities — only the main RabbitMQ container

## Source

- `docs/troubleshooting/troubleshooting-plane.md` — RabbitMQ startup failure debugging
- `apps/plane/deployment-rabbitmq.yaml` — capability comments
