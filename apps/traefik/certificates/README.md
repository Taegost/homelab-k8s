# certificates

Traefik `Certificate` CRDs that request TLS certificates from cert-manager.

Each file defines a wildcard certificate for a DNS zone used in this cluster. Certificates are stored as Kubernetes Secrets in the `traefik` namespace and referenced by name in `IngressRoute` `tls.secretName` fields. New certificates belong here when a new DNS zone is added.
