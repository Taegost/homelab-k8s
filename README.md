# homelab-k8s

A production-style Kubernetes homelab built on [k3s](https://k3s.io/), managed via GitOps with [ArgoCD](https://argo-cd.readthedocs.io/). This repository is intended to be a learning resource as much as a working infrastructure — every design decision is documented inline.

---

## Table of Contents

- [homelab-k8s](#homelab-k8s)
  - [Table of Contents](#table-of-contents)
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
| [ArgoCD](https://argo-cd.readthedocs.io/) | GitOps — syncs this repo to the cluster | `argocd` |
| [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) | Encrypted secrets safe for public repos | `sealed-secrets` |
| [Longhorn](https://longhorn.io/) | Replicated persistent storage | `longhorn-system` |

> **Why these choices?**
> - **MetalLB over kube-vip for services**: kube-vip handles the _control plane_ VIP; MetalLB handles _LoadBalancer-type services_ (like Traefik's external IP). They serve different layers.
> - **Traefik over NGINX**: Traefik has native Kubernetes CRD support (`IngressRoute`), built-in Let's Encrypt support (including DNS-01 via Route53), and a built-in dashboard. Because Traefik manages the full ACME lifecycle itself, cert-manager is not needed in this stack.
> - **Sealed Secrets over External Secrets Operator**: ESO requires an external secret store (Vault, AWS SSM, etc.). Sealed Secrets keeps everything self-contained and is ideal for a public portfolio repo where you want to commit encrypted secrets directly.

---

## Repository Structure

```
homelab-k8s/
│
├── apps/                         # One directory per application
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
└── README.md                     # You are here
```

**Why is each app in its own directory instead of using Helm chart values files?**
Each app directory contains raw Kubernetes manifests and/or Helm `values.yaml` overrides managed by ArgoCD's `Application` CRD. This gives you full visibility into what is deployed without requiring Helm to be installed locally. Helm is used as a rendering engine by ArgoCD where appropriate, but you never need to run `helm install` manually.

---

## Bootstrap Order

The cluster components have hard dependencies on each other. They must be bootstrapped in this order:

```
1. kube-vip          ← Already installed. Managed outside this repo.
2. Sealed Secrets    ← Must exist before any SealedSecret manifest is applied.
3. MetalLB           ← Must exist before Traefik requests a LoadBalancer IP.
4. Traefik           ← Must exist before any Ingress/IngressRoute is created.
5. ArgoCD            ← Bootstrapped manually, then takes over managing itself.
6. Everything else   ← ArgoCD syncs from this repo automatically.
```

Detailed step-by-step instructions for each phase are in [bootstrap/README.md](bootstrap/README.md).

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
2. Add your manifests (or a `Chart.yaml` + `values.yaml` for Helm-based apps).
3. Create an ArgoCD `Application` manifest pointing to that directory.
4. Commit and push — ArgoCD will detect and sync the new app automatically.

Each app lives in its own namespace. Namespaces are created automatically by ArgoCD via the `CreateNamespace=true` sync option — you do not need to create them manually.

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