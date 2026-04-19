# Migrating from Docker Traefik to Kubernetes Traefik

This document covers the process of migrating from a Docker-based Traefik instance to the Kubernetes Traefik deployment in this cluster. The Kubernetes Traefik becomes the **single ingress point** for all traffic — both for services migrating to Kubernetes and for services that will continue running outside the cluster (on Docker or bare metal).

The approach is designed for zero-downtime migration. During the transition, Kubernetes Traefik forwards unrecognised requests to the Docker Traefik instance, so you can migrate services one at a time at your own pace without taking anything offline. Once all routing is handled by Kubernetes Traefik, the Docker Traefik instance is decommissioned entirely.

---

## Overview

The migration happens in four phases:

```
Phase 1: Prepare     — Issue certs from the new cluster before cutting over DNS
Phase 2: Cut over    — Point DNS at the Kubernetes cluster, enable forwarding to Docker Traefik
Phase 3: Migrate     — Move each service's routing to Kubernetes Traefik one at a time
Phase 4: Clean up    — Remove Docker Traefik forwarding and decommission the Docker instance
```

Because this stack uses **DNS-01 challenges** (not HTTP-01), cert-manager communicates with Let's Encrypt entirely through Route53 — no HTTP traffic is involved in the ACME challenge. This means you can issue certificates from the new cluster *before* you cut over DNS, eliminating any TLS gap during the transition.

---

## Prerequisites

Before starting:

- The Kubernetes cluster is running with MetalLB, cert-manager, and Traefik deployed
- cert-manager has successfully issued certificates for all required domains (verify with `kubectl get certificates -A`)
- You know the IP address of your Docker Traefik host
- You have a list of all services currently routing through Docker Traefik

---

## Phase 1: Issue Certificates Before DNS Cutover

Because DNS-01 challenges do not require incoming HTTP traffic, cert-manager can request and renew certificates before you change a single DNS record. The challenge flows directly: cert-manager → Route53 → Let's Encrypt, with no dependency on who currently holds the domain's A record.

Deploy your `Certificate` resources (see `apps/cert-manager/`) and verify they are ready before proceeding:

```bash
kubectl get certificates -A
# All certificates should show READY=True before proceeding to Phase 2
```

---

## Phase 2: DNS Cutover and Enable Forwarding

### Step 1 — Update DNS

Point your domain(s) at the Kubernetes Traefik IP (the first IP in your MetalLB pool, reserved for Traefik — see `apps/metallb/ipaddresspool.yaml`):

| Record | Type | Value |
|--------|------|-------|
| `*.home.yourdomain.com` | A | Kubernetes Traefik IP |
| `*.yourdomain.com` | A | Kubernetes Traefik IP |

Allow DNS propagation before continuing. Verify with:

```bash
dig +short *.home.yourdomain.com
# Should return the Kubernetes Traefik IP
```

### Step 2 — Create the Docker Traefik forwarding service

This creates a Kubernetes Service and EndpointSlice that point directly at your Docker Traefik host's IP, allowing Kubernetes Traefik to forward requests to it during the migration period.

> **Why not ExternalName?** `ExternalName` services work via CNAME DNS resolution, which breaks for HTTPS backends because the TLS handshake cannot complete against a CNAME. A headless Service with an explicit `EndpointSlice` points directly at the IP and works correctly for HTTPS traffic.

```yaml
# apps/traefik/docker-traefik-forward.yaml
apiVersion: v1
kind: Service
metadata:
  name: docker-traefik
  namespace: traefik
spec:
  ports:
    - port: 443
      targetPort: 443
      protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: docker-traefik
  namespace: traefik
  labels:
    kubernetes.io/service-name: docker-traefik
addressType: IPv4
ports:
  - port: 443
    protocol: TCP
endpoints:
  - addresses:
      - DOCKER_HOST_IP   # <-- replace with your Docker host IP address
```

### Step 3 — Create the catch-all IngressRoute

This catches any request that does not match a Kubernetes-managed route and forwards it to Docker Traefik. It uses an explicit priority of `1` — the lowest possible value — to ensure any specific Kubernetes `IngressRoute` always takes precedence.

> **Note on default priority:** When no priority is set, Traefik calculates priority from the length of the rule string. Longer, more specific rules naturally outrank shorter ones. The explicit `priority: 1` here is belt-and-suspenders to guarantee the catch-all always loses to every other route, regardless of rule length.

```yaml
# apps/traefik/docker-traefik-catchall.yaml
#
# Temporary catch-all IngressRoute that forwards unrecognised requests to
# the Docker Traefik instance during the migration period.
# This is removed in Phase 4 once all routing has been migrated.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: docker-traefik-catchall
  namespace: traefik
spec:
  entryPoints:
    - websecure
  routes:
    - match: HostRegexp(`.+`)
      kind: Rule
      priority: 1
      services:
        - name: docker-traefik
          port: 443
          scheme: https
          # passHostHeader ensures the original Host header reaches Docker Traefik
          # so it can route the request to the correct backend.
          passHostHeader: true
  tls: {}
```

Apply both:

```bash
kubectl apply -f apps/traefik/docker-traefik-forward.yaml
kubectl apply -f apps/traefik/docker-traefik-catchall.yaml
```

At this point:
- Any service already configured in Kubernetes is served by Kubernetes Traefik
- Everything else is transparently forwarded to Docker Traefik
- Users experience no interruption

---

## Phase 3: Migrating Service Routing

For each service, create the appropriate `IngressRoute` in Kubernetes Traefik. Services fall into two categories:

### Category A — Services migrating to Kubernetes

For services that are moving their workloads into the cluster, create the full deployment manifests alongside this routing config.

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
        - name: <service-name>        # Kubernetes Service name in the same namespace
          port: <service-port>
  tls:
    secretName: <tls-secret-name>     # Secret created by cert-manager for this hostname
```

### Category B — Services staying outside Kubernetes

For services that will continue running on Docker or bare metal outside the cluster, Kubernetes Traefik routes requests directly to the application's IP and port — **not** to the Docker Traefik instance. The Docker Traefik instance is being decommissioned; these applications are accessed directly.

```yaml
# Template: apps/traefik/external-routes/<service-name>-route.yaml
#
# IngressRoute for an application that runs outside the Kubernetes cluster
# and will not be migrated. Traffic is forwarded directly to the application,
# bypassing Docker Traefik entirely.
#
# Store these in apps/traefik/external-routes/ to keep them organised.
# Unlike the forwarding resources (Phase 2), these are permanent and stay
# in the repo after Docker Traefik is decommissioned.
#
# Replace all <PLACEHOLDER> values before applying.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <service-name>-external
  namespace: traefik
  annotations:
    # Document that this service intentionally runs outside the cluster
    homelab/workload-location: "external"
    homelab/external-host: "<application-host-ip>:<port>"
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`<service-hostname>`)   # e.g. Host(`myservice.home.yourdomain.com`)
      kind: Rule
      services:
        - name: <service-name>-external-svc
          port: <application-port>
  tls:
    secretName: <tls-secret-name>
---
# Headless Service + EndpointSlice pointing directly at the application.
# ExternalName is not used here because it relies on CNAME resolution
# which breaks for HTTPS backends.
apiVersion: v1
kind: Service
metadata:
  name: <service-name>-external-svc
  namespace: traefik
spec:
  ports:
    - port: <application-port>           # Port the application listens on
      targetPort: <application-port>
      protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: <service-name>-external-svc
  namespace: traefik
  labels:
    kubernetes.io/service-name: <service-name>-external-svc
addressType: IPv4
ports:
  - port: <application-port>
    protocol: TCP
endpoints:
  - addresses:
      - <application-host-ip>   # IP of the host running the application
```

As you migrate each service's routing to Kubernetes, the catch-all rule stops forwarding requests for that hostname because the specific `IngressRoute` rule takes precedence automatically.

---

## Phase 4: Clean Up

Once all services have been given explicit `IngressRoute` resources — either pointing at Kubernetes workloads or directly at external applications — the Docker Traefik forwarding resources are no longer needed and the Docker Traefik instance can be shut down.

### Pre-cleanup checklist

- [ ] Every service that was on Docker Traefik now has an `IngressRoute` in Kubernetes Traefik
- [ ] All external (non-Kubernetes) services route directly to their applications, not to Docker Traefik
- [ ] Docker Traefik access logs show no incoming traffic
- [ ] ArgoCD shows all applications `Synced` and `Healthy`

### Remove the forwarding resources via ArgoCD

Since ArgoCD is managing the cluster at this point, the correct way to remove resources is to delete them from the repository and let ArgoCD sync the deletion — **not** to run `kubectl delete` directly. This keeps the Git repo as the source of truth.

**Step 1 — Remove the forwarding files from the repository:**

```bash
git rm apps/traefik/docker-traefik-catchall.yaml
git rm apps/traefik/docker-traefik-forward.yaml
git commit -m "chore(traefik): remove Docker Traefik forwarding — migration complete"
git push
```

**Step 2 — Verify ArgoCD syncs the deletion:**

ArgoCD will detect that these resources are no longer in Git and, because `prune: true` is set on the Traefik application, will automatically delete them from the cluster. Monitor the sync:

```bash
# Watch the ArgoCD application status
kubectl get application traefik -n argocd -w

# Or check in the ArgoCD UI — the app should sync and show Healthy
```

**Step 3 — Confirm the resources are gone:**

```bash
kubectl get ingressroute docker-traefik-catchall -n traefik
# Should return: Error from server (NotFound)

kubectl get svc docker-traefik -n traefik
# Should return: Error from server (NotFound)
```

### Decommission Docker Traefik

Once the Kubernetes-side cleanup is confirmed:

1. Stop and remove the Docker Traefik container from your Docker host
2. Remove the Traefik service from your Docker Compose stack
3. Remove any Traefik-specific Docker volumes (certificates, acme.json)
4. Update any firewall rules that were allowing inbound 80/443 to the Docker host if that host is no longer serving web traffic

### Final repository cleanup

If you created any temporary notes or placeholder files during the migration, clean those up too:

```bash
git add -A
git commit -m "chore: post-migration cleanup"
git push
```

ArgoCD will sync any remaining changes automatically.

---

## Troubleshooting

**Requests are not forwarding to Docker Traefik:**
- Confirm the Service and EndpointSlice exist: `kubectl get svc docker-traefik -n traefik` and `kubectl get endpointslice docker-traefik -n traefik`
- Confirm the Docker host IP is reachable from within a Traefik pod: `kubectl exec -n traefik -it $(kubectl get pod -n traefik -o name | head -1) -- wget -qO- --no-check-certificate https://DOCKER_HOST_IP --header "Host: YOURHOSTNAME"`
- Check Traefik logs: `kubectl logs -n traefik -l app.kubernetes.io/name=traefik`

**A service is still hitting Docker Traefik after creating its IngressRoute:**
- Confirm the `IngressRoute` was applied: `kubectl get ingressroute -n <namespace>`
- Check for typos in the `Host()` matcher — it must exactly match the incoming hostname

**TLS errors after DNS cutover:**
- Verify the cert-manager `Certificate` is `Ready`: `kubectl get certificate -n <namespace>`
- Check the TLS Secret exists: `kubectl get secret <tls-secret-name> -n <namespace>`
- Confirm the `secretName` in the `IngressRoute` matches the `secretName` in the `Certificate` spec