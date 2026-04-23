# homelab-k8s

A production-style Kubernetes homelab built on [k3s](https://k3s.io/), managed via GitOps with [ArgoCD](https://argo-cd.readthedocs.io/). This repository is intended to be a learning resource as much as a working infrastructure — every design decision is documented inline.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Core Stack](#core-stack)
- [Repository Structure](#repository-structure)
- [Bootstrap Order](#bootstrap-order)
- [Secrets Management](#secrets-management)
- [Adding a New Application](#adding-a-new-application)
- [Disaster Recovery](#disaster-recovery)
- [Prerequisites](#prerequisites)

---

## Architecture Overview

```
                        ┌─────────────────────────────────────────┐
                        │              k3s Cluster                │
                        │                                         │
                        │   ┌───────────┐    ┌───────────┐        │
                        │   │  Node 001 │    │  Node 002 │  ...   │
                        │   │ (cp+work) │    │ (cp+work) │        │
                        │   └───────────┘    └───────────┘        │
                        │                                         │
                        │   kube-vip (control plane VIP)          │
                        │   MetalLB  (LoadBalancer IPs)           │
                        │   Traefik  (Ingress / TLS)              │
                        │   ArgoCD   (GitOps controller)          │
                        │   Sealed Secrets (secret management)    │
                        |   Longhorn (Replicated storage)         |
                        └─────────────────────────────────────────┘
                                          │
                                    GitHub Repo
                              (this repo — source of truth)
```

The cluster runs **multiple combined control-plane/worker nodes** for high availability. [kube-vip](https://kube-vip.io/) provides a virtual IP for the control plane API server and is managed outside of this repo (installed at cluster provisioning time). Everything else is managed here.

---

## Core Stack

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| [kube-vip](https://kube-vip.io/) | Control plane VIP (HA API server) | `kube-system` |
| [MetalLB](https://metallb.universe.tf/) | LoadBalancer IP allocation (L2/ARP mode) | `metallb-system` |
| [Traefik](https://traefik.io/) | Ingress controller, TLS termination | `traefik` |
| [cert-manager](https://cert-manager.io/) | Automatic TLS via Let's Encrypt DNS-01 (Route53) | `cert-manager` |
| [ArgoCD](https://argo-cd.readthedocs.io/) | GitOps — syncs this repo to the cluster | `argocd` |
| [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) | Encrypted secrets safe for public repos | `sealed-secrets` |
| [Longhorn](https://longhorn.io/) | Replicated persistent storage | `longhorn-system` |

> **Why these choices?**
> - **MetalLB over kube-vip for services**: kube-vip handles the _control plane_ VIP; MetalLB handles _LoadBalancer-type services_ (like Traefik's external IP). They serve different layers.
> - **Traefik over NGINX**: Traefik has native Kubernetes CRD support (`IngressRoute`), a built-in dashboard, and excellent integration with cert-manager. It handles TLS termination using certificates managed by cert-manager.
> - **cert-manager for TLS**: Traefik Community Edition cannot handle Let's Encrypt challenges across multiple replicas — the challenge response must reach the specific instance that initiated it, which is impossible to guarantee in an HA setup. cert-manager solves this cleanly by handling the full ACME lifecycle independently via DNS-01 challenges (no HTTP traffic required), storing certificates as Kubernetes Secrets that Traefik reads directly.
> - **Sealed Secrets over External Secrets Operator**: ESO requires an external secret store (Vault, AWS SSM, etc.). Sealed Secrets keeps everything self-contained and is ideal for a public portfolio repo where you want to commit encrypted secrets directly.
>
> - **Certificate namespace strategy:** Wildcard certificates used by multiple services are issued into the `traefik` namespace.`IngressRoute` resources for those services will also live in the `traefik` namespace so they can reference the wildcard certificates directly. Per-app explicit certificates (e.g. for publicly exposed services) are issued into the app's own namespace alongside its `IngressRoute`, keeping that app fully self-contained. `cert-manager` itself lives in its own namespace and manages issuance for both patterns via `ClusterIssuer` resources.

---

## Repository Structure

```
homelab-k8s/
│
├── apps/                         # One directory per application
│   ├── manifests/                # ArgoCD Application manifests (one per app)
│   ├── argocd/                   # ArgoCD self-management manifests
│   ├── metallb/                  # MetalLB configuration
│   ├── traefik/                  # Traefik ingress controller
│   ├── sealed-secrets/           # Sealed Secrets controller
│   └── <app-name>/               # Add new apps here (see below)
│
├── bootstrap/                    # One-time manual bootstrap scripts/manifests
│   │                             # These are applied once to get ArgoCD running.
│   │                             # After that, ArgoCD takes over.
│   └── ...
│
├── docs/                         # Extended documentation
│   ├── sealed-secrets.md         # How to create and rotate sealed secrets
│   └── disaster-recovery.md     # What to do if you rebuild the cluster
│
├── .gitignore                    # Prevents accidental secret commits
├── app-of-apps.yaml              # Root ArgoCD Application — bootstraps autodiscovery
└── README.md                     # You are here
```

**Why is each app in its own directory instead of using Helm chart values files?**
Each app directory contains raw Kubernetes manifests and/or Helm `values.yaml` overrides managed by ArgoCD's `Application` CRD. This gives you full visibility into what is deployed without requiring Helm to be installed locally. Helm is used as a rendering engine by ArgoCD where appropriate, but you never need to run `helm install` manually.

---

## Bootstrap Order

The cluster components have hard dependencies on each other and must be bootstrapped in a specific order. See [bootstrap/README.md](bootstrap/README.md) for the full step-by-step instructions.

---

## Secrets Management

This repository is **public**. No plaintext secrets are ever committed here.

All secrets use [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets):

1. Create a normal Kubernetes `Secret` manifest locally (**do not commit this file**).
2. Encrypt it with `kubeseal`: `kubeseal --format yaml < my-secret.yaml > my-sealed-secret.yaml`
3. Commit `my-sealed-secret.yaml` — it is safe to store publicly.
4. The Sealed Secrets controller in the cluster decrypts it at apply time.

> ⚠️ **Important:** The Sealed Secrets controller's private key is tied to your cluster. If you rebuild your cluster, you must restore the private key from backup before any `SealedSecret` can be decrypted. See [docs/disaster-recovery.md](docs/disaster-recovery.md).

See [docs/sealed-secrets.md](docs/sealed-secrets.md) for full instructions including key backup and rotation.

---

## Adding a New Application

1. Create a directory under `apps/<app-name>/`.
2. Add your manifests (or a `values.yaml` for Helm-based apps).
3. Create `apps/manifests/<app-name>.yaml` — an ArgoCD `Application` manifest pointing at `apps/<app-name>/`.
4. Commit and push — ArgoCD will detect and sync the new app automatically.

Each app lives in its own namespace. Namespaces are created automatically by ArgoCD via the `CreateNamespace=true` sync option — you do not need to create them manually.

### Application Namespaces

Each application runs in its own namespace by default. However, tightly coupled
applications that are always deployed together and communicate with each other
may share a namespace. In that case, all manifests for those applications live
under a single shared directory in `apps/`, managed by a single ArgoCD
Application. The shared directory follows the same structure as a single-app
directory, with per-app subdirectories for organization.

When adding a new application, decide upfront whether it belongs in an existing
shared namespace or warrants its own. This decision is difficult to reverse
cleanly once storage and other namespace-scoped resources exist.

### Infrastructure Resources

Cluster-scoped resources (PersistentVolumes, StorageClasses, ClusterIssuers,
etc.) that are not owned by any single application live under `apps/infrastructure/`,
organized by function:

```
apps/infrastructure/
  storage/      — PersistentVolumes, StorageClasses
  networking/   — cluster-wide NetworkPolicies, etc. (reserved for future use)
```

This directory is managed by a dedicated `infrastructure` ArgoCD Application
(sync wave `-2`) with `recurse: true`, so new resources are picked up
automatically by dropping files into the appropriate subdirectory.

Do not put cluster-scoped resources inside an application's own directory —
they would be owned by that application's ArgoCD sync, making them fragile to
remove and misleading to future readers.

### Static NFS Volumes

NFS-backed storage uses the `nfs-static` StorageClass
(`apps/infrastructure/storage/storageclass-nfs-static.yaml`), which disables dynamic provisioning. All NFS PersistentVolumes must be declared manually in `apps/infrastructure/storage/`.

When creating a PVC that binds to an NFS PV, two fields are mandatory:

- `storageClassName: nfs-static` — routes the claim to a manually provisioned
  NFS volume rather than a dynamic provisioner like Longhorn
- `volumeName: <pv-name>` — pins the binding to a specific PV by name;
  without this, binding is non-deterministic when multiple NFS PVs exist

> The NFS PV is the single source of truth for the server hostname and export
path. Multiple namespaces can each hold a PVC binding to the same PV —
do not duplicate connection details across namespaces.
---

## Disaster Recovery

If you need to rebuild your cluster from scratch:

1. Restore the Sealed Secrets private key (from your secure backup) **before** applying any manifests.
2. Re-run the bootstrap steps in order.
3. Point ArgoCD at this repository — it will restore all applications automatically.

Full instructions: [docs/disaster-recovery.md](docs/disaster-recovery.md)

---

## Prerequisites

To work with this repository locally you will need:

| Tool | Purpose |
|------|---------|
| `kubectl` | Interact with the cluster |
| `kubeseal` | Encrypt secrets for this repo |
| `helm` | Render Helm charts locally for inspection (optional) |
| `argocd` CLI | Interact with ArgoCD (optional) |

You do **not** need Helm installed to deploy applications — ArgoCD handles chart rendering server-side.