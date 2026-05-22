# Archived — Traefik Docker Migration Artifacts

This directory contains the two manifests that enabled gradual service-by-service
migration from a Docker Compose Traefik instance to the Kubernetes Traefik deployment.
They were live in `apps/traefik/` during the migration period and removed once the
migration was complete.

---

## What these files do

**`docker-traefik-forward.yaml`** — a headless Service and EndpointSlice pointing at the
Docker Traefik IP (`192.168.5.251`). The EndpointSlice bypasses CoreDNS entirely, allowing
Traefik to proxy HTTPS traffic directly to the Docker host. (ExternalName services were
not suitable here because Traefik requires a real IP for HTTPS backends — CNAME resolution
breaks TLS handshakes.)

**`docker-traefik-catchall.yaml`** — an IngressRoute with `priority: 1` (the lowest
possible) and a `HostRegexp(.+)` match-all rule. Any request that does not match a
Kubernetes-specific IngressRoute falls through to this rule and is forwarded to Docker
Traefik. This kept all Docker-hosted services accessible while they were migrated one
by one to Kubernetes IngressRoutes.

Together, they formed a forward proxy: Kubernetes Traefik received all traffic, forwarded
unrecognised hostnames to Docker Traefik, and let explicit IngressRoutes take precedence
as services were migrated.

---

## Why they were removed

The Docker→Kubernetes migration completed in April 2026. All services now have explicit
Kubernetes IngressRoutes and no longer rely on Docker Traefik. The catch-all route and
its upstream Service were removed in commit `6f7fcdf`. `git show 6f7fcdf^` is the last
commit that contained the live versions.

---

## Why they are kept

Anyone performing the same Docker→Kubernetes Traefik cutover can use these as a template.
The pattern — headless Service + EndpointSlice for the HTTPS upstream, priority-1 catch-all
IngressRoute — is not obvious and took iteration to get right. Keeping the files here
means the next person does not have to rediscover it.

See [docs/migration-traefik-docker.md](../../docs/migration-traefik-docker.md) for the
full migration guide, including the step-by-step cutover sequence and rollback procedure.
