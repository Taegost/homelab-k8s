# middlewares

Traefik `Middleware` CRDs defining reusable request-processing rules.

All middlewares live in the `traefik` namespace and are referenced by name from `IngressRoute` resources across the cluster (cross-namespace is permitted via `allowCrossNamespace: true` in the Helm values). New middlewares belong here regardless of which applications use them.
