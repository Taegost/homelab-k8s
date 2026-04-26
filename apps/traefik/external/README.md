# external

`Service`, `Endpoints`, and `IngressRoute` resources for applications hosted outside Kubernetes.

Each file is named after the application and contains all three resources needed to proxy traffic through Traefik to an external IP. Some entries are permanent (infrastructure that will never move into the cluster); others are temporary placeholders that will be removed once the application is migrated to Kubernetes.
