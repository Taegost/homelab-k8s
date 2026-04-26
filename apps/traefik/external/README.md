# external

`Service` (type `ExternalName`) and `IngressRoute` resources for applications hosted outside Kubernetes.

Each file is named after the application and contains both resources needed to proxy traffic through Traefik to an external IP. Some entries are permanent fixtures (infrastructure that will never move into the cluster); others are temporary placeholders that will be removed once the application is migrated to Kubernetes.

## Why ExternalName with raw IP addresses?

Standard Kubernetes `ExternalName` services are documented as requiring a DNS hostname — using a raw IP address technically violates the Kubernetes spec and does not work for in-cluster pod DNS resolution via CoreDNS.

**This works here because Traefik does not use CoreDNS to resolve ExternalName services.** Traefik reads the `externalName` field directly from the Kubernetes API and opens the backend connection itself, bypassing the cluster's DNS entirely. This means raw IP addresses are valid `externalName` values as far as Traefik is concerned.

This behaviour requires `allowExternalNameServices: true` in `apps/traefik/values.yaml` (disabled by default since Traefik 2.5.x). Do not remove that flag.

> **Important:** This is a Traefik-specific pattern. If this cluster's ingress controller were ever replaced with NGINX, HAProxy, or another controller that resolves ExternalName via CoreDNS, all entries in this folder would stop working. See the root `README.md` for context on why Traefik was chosen.

## Pattern

Each file follows this structure:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <app>
  namespace: traefik
spec:
  type: ExternalName
  externalName: 192.168.x.x   # target IP — resolved by Traefik, not CoreDNS
  ports:
    - port: <port>
      targetPort: <port>
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <app>
  namespace: traefik
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`<hostname>`)
      kind: Rule
      middlewares:
        - name: default-whitelist
          namespace: traefik
      services:
        - name: <app>
          port: <port>
          # scheme: https   # add this for backends that serve HTTPS (e.g. Proxmox)
  tls:
    secretName: wildcard-home-diceninjagaming-com-tls   # or wildcard-diceninjagaming-com-tls
```
