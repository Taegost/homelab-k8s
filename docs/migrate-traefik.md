# Migrating from Docker Traefik to Kubernetes Traefik

This document covers the process of migrating from a Docker-based Traefik instance to the Kubernetes Traefik deployment in this cluster. The approach is designed for zero-downtime migration — the Kubernetes Traefik forwards any unrecognized requests to your existing Docker Traefik, so you can migrate services one at a time at your own pace without taking anything offline.

---

## Overview

The migration happens in four phases:

```
Phase 1: Prepare     — Issue certs from the new cluster before cutting over DNS
Phase 2: Cut over    — Point DNS at the Kubernetes cluster, enable forwarding to Docker Traefik
Phase 3: Migrate     — Move services from Docker Traefik to Kubernetes one at a time
Phase 4: Clean up    — Remove the Docker Traefik forwarding once migration is complete
```

Because this stack uses **DNS-01 challenges** (not HTTP-01), cert-manager communicates with Let's Encrypt entirely through Route53 — no HTTP traffic is involved in the challenge. This means you can issue certificates from the new cluster before you cut over DNS, eliminating any TLS gap during the transition.

---

## Prerequisites

Before starting:

- The Kubernetes cluster is running with MetalLB, cert-manager, and Traefik deployed
- cert-manager has successfully issued at least one test certificate (verify with `kubectl get certificates -A`)
- You know the external IP of your Docker Traefik instance
- You have noted all services currently routing through Docker Traefik

---

## Phase 1: Issue Certificates Before DNS Cutover

Because DNS-01 challenges do not require incoming HTTP traffic, cert-manager can request and renew certificates from Let's Encrypt before you change a single DNS record. The challenge goes directly from cert-manager → Route53 → Let's Encrypt, with no dependency on who holds the domain's A record.

**Action:** Deploy your `Certificate` resources (see `apps/cert-manager/`) and verify they reach `Ready` status:

```bash
kubectl get certificates -A
# All certificates should show READY=True before proceeding
```

Do not proceed to Phase 2 until all certificates are ready.

---

## Phase 2: DNS Cutover and Enable Forwarding

### Step 1 — Update DNS

Point your domain(s) at the Kubernetes Traefik IP (`192.168.1.11` in the example config, or whatever you set in `apps/metallb/ipaddresspool.yaml`):

| Record | Type | Value |
|--------|------|-------|
| `*.home.yourdomain.com` | A | Kubernetes Traefik IP |
| `*.yourdomain.com` | A | Kubernetes Traefik IP |

Allow DNS propagation before continuing (use `dig` or `nslookup` to verify).

### Step 2 — Create the Docker Traefik forwarding service

This tells Kubernetes Traefik where to find your Docker Traefik instance so it can forward unrecognized requests. Replace `DOCKER_TRAEFIK_IP` with the actual IP of your Docker host.

```yaml
# apps/traefik/docker-traefik-forward.yaml
#
# ExternalName service pointing at the Docker Traefik instance.
# This is temporary — remove it in Phase 4 once migration is complete.
#
# Why ExternalName instead of a hardcoded IP endpoint?
# ExternalName lets Kubernetes resolve the target by hostname/IP cleanly
# and makes it easy to find and remove during cleanup.
apiVersion: v1
kind: Service
metadata:
  name: docker-traefik
  namespace: traefik
spec:
  type: ExternalName
  externalName: DOCKER_TRAEFIK_IP   # <-- replace with your Docker host IP
  ports:
    - port: 443
      targetPort: 443
```

### Step 3 — Create the catch-all IngressRoute

This catches any request that does not match a Kubernetes-managed route and forwards it to the Docker Traefik instance. It uses the lowest possible priority (`1`) so that any specific Kubernetes `IngressRoute` always wins.

```yaml
# apps/traefik/docker-traefik-catchall.yaml
#
# Catch-all IngressRoute that forwards unrecognised requests to the Docker
# Traefik instance. This allows the two Traefik deployments to coexist
# during migration — Kubernetes routes take precedence, everything else
# falls through to Docker Traefik.
#
# Priority 1 is the lowest possible value, ensuring any specific
# IngressRoute defined for a Kubernetes service will always match first.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: docker-traefik-catchall
  namespace: traefik
spec:
  entryPoints:
    - websecure
  routes:
    - match: HostRegexp(`^.+$`)
      kind: Rule
      priority: 1
      services:
        - name: docker-traefik
          port: 443
          scheme: https
          # PassHostHeader ensures the original Host header is forwarded
          # so Docker Traefik can route the request correctly.
          passHostHeader: true
  tls:
    secretName: ""   # TLS is terminated at the Docker Traefik end for these routes
```

Apply both files:

```bash
kubectl apply -f apps/traefik/docker-traefik-forward.yaml
kubectl apply -f apps/traefik/docker-traefik-catchall.yaml
```

At this point:
- Services already in Kubernetes are served by Kubernetes Traefik with the new certificates
- Everything else is transparently forwarded to Docker Traefik
- Users see no interruption

---

## Phase 3: Migrating Services

Migrate services from Docker Traefik to Kubernetes one at a time. For each service:

1. Create the Kubernetes `Deployment`, `Service`, and `IngressRoute` (see templates below)
2. Verify the service is reachable through Kubernetes Traefik
3. Remove the corresponding route from Docker Traefik (or leave it — the Kubernetes route will always win due to higher priority)

The catch-all forwarding continues to handle any services not yet migrated.

### IngressRoute Template

Use this template for services that **are** migrating to Kubernetes:

```yaml
# Template: apps/<app-name>/ingressroute.yaml
#
# Replace all <PLACEHOLDER> values before applying.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <app-name>
  namespace: <app-namespace>
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`<app-hostname>`)   # e.g. Host(`myapp.home.yourdomain.com`)
      kind: Rule
      services:
        - name: <service-name>        # must match the Kubernetes Service name
          port: <service-port>        # the port the Service exposes
  tls:
    secretName: <tls-secret-name>     # the Secret created by cert-manager for this hostname
```

### IngressRoute Template for Non-Migrating Services

Use this template for services that will **stay on Docker** permanently (e.g. services you have no plans to migrate to Kubernetes). This explicitly routes them to the Docker Traefik instance rather than relying on the catch-all, and documents the intent clearly.

```yaml
# Template: apps/traefik/docker-routes/<service-name>-route.yaml
#
# Explicit route for a service that remains on the Docker Traefik instance
# and will not be migrated to Kubernetes.
#
# Store these in apps/traefik/docker-routes/ to keep them organised and
# easy to find during cleanup.
#
# Replace all <PLACEHOLDER> values before applying.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <service-name>-docker
  namespace: traefik
  annotations:
    # Document why this service is not migrating, for future reference
    homelab/migration-status: "permanent-docker"
    homelab/migration-notes: "<reason this service stays on Docker>"
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`<service-hostname>`)   # e.g. Host(`myservice.home.yourdomain.com`)
      kind: Rule
      priority: 10   # Higher than catch-all (1) but lower than migrated services (default)
      services:
        - name: docker-traefik
          namespace: traefik
          port: 443
          scheme: https
          passHostHeader: true
  tls:
    secretName: ""
```

> **Tip:** Once you have explicit routes for all permanent Docker services, you can remove the catch-all `IngressRoute` (Phase 4) even before all services are migrated to Kubernetes.

---

## Phase 4: Clean Up

Once all services have been either migrated to Kubernetes or given explicit Docker routes, the catch-all forwarding and temporary resources can be removed.

### Checklist before cleaning up

- [ ] All services have been either migrated to Kubernetes or given an explicit `IngressRoute` pointing at Docker Traefik
- [ ] The catch-all `IngressRoute` is no longer needed (all traffic is accounted for)
- [ ] Docker Traefik is no longer serving any traffic (verify in its access logs)

### Remove the forwarding resources

```bash
# Remove the catch-all IngressRoute
kubectl delete -f apps/traefik/docker-traefik-catchall.yaml

# If Docker Traefik is fully decommissioned, remove the ExternalName service too
kubectl delete -f apps/traefik/docker-traefik-forward.yaml
```

Also delete the files from the repository so they are not accidentally re-applied:

```bash
rm apps/traefik/docker-traefik-catchall.yaml
rm apps/traefik/docker-traefik-forward.yaml
git add -A
git commit -m "chore(traefik): remove Docker Traefik forwarding resources"
git push
```

### If you decommission Docker Traefik entirely

Once Docker Traefik is shut down:

1. Remove any explicit `IngressRoute` resources from `apps/traefik/docker-routes/` that were pointing at it
2. Remove the `docker-traefik` ExternalName Service if not already done
3. Update any remaining DNS records that still pointed at the Docker host
4. Revoke or rotate the Docker Traefik Let's Encrypt account if it had its own ACME registration
5. Remove Docker Traefik from your Docker Compose stack

### Remove the docker-routes directory from the repository

```bash
rm -rf apps/traefik/docker-routes/
git add -A
git commit -m "chore(traefik): remove Docker Traefik permanent route configs"
git push
```

---

## Troubleshooting

**Requests are not being forwarded to Docker Traefik:**
- Confirm the `docker-traefik` ExternalName Service resolves correctly: `kubectl get svc docker-traefik -n traefik`
- Check Traefik logs: `kubectl logs -n traefik -l app.kubernetes.io/name=traefik`
- Verify the Docker host IP is reachable from within the cluster: `kubectl run -it --rm debug --image=busybox --restart=Never -- wget -qO- https://DOCKER_TRAEFIK_IP`

**A migrated service is still hitting Docker Traefik:**
- Confirm the Kubernetes `IngressRoute` has been applied: `kubectl get ingressroute -n <namespace>`
- The Kubernetes route priority must be higher than `1` (the catch-all). Default priority is sufficient.

**TLS errors after DNS cutover:**
- Verify the cert-manager `Certificate` resource is `Ready` before cutting over DNS
- Check the certificate's Secret exists: `kubectl get secret <tls-secret-name> -n <namespace>`