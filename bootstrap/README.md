# Bootstrap

This directory contains reference manifests and step-by-step instructions for the **one-time manual bootstrap** of the cluster. Once ArgoCD is running and connected to this repository, it takes over management of all resources — including itself. You should never need to run these steps again unless rebuilding from scratch.

---

## Why a Separate Bootstrap Phase?

ArgoCD cannot manage resources that don't exist yet. The bootstrap phase installs the minimum set of components in the correct order so that each one is ready before the next depends on it:

- **kube-vip** must exist before the cluster is fully operational — it provides the control plane VIP that everything else connects through.
- **Sealed Secrets** must exist before any `SealedSecret` resource is applied, so the controller is ready to decrypt them.
- **MetalLB** must exist before Traefik requests a `LoadBalancer` IP — without it, the service would remain in `<pending>` indefinitely.
- **Traefik** must exist before any `Ingress` or `IngressRoute` resources are created, including ArgoCD's own UI ingress.
- **ArgoCD** is the last to be bootstrapped manually, after which it immediately takes over managing all resources going forward.

---

## Prerequisites

### Cluster

- A fresh k3s cluster — installation guide: https://docs.k3s.io/quick-start
- All nodes reachable on the network

### IP Planning

Before applying any manifests, decide on your IP ranges. Three components need reserved IPs and they must not overlap with each other or your DHCP range:

| Component | Type | Example | Notes |
|-----------|------|---------|-------|
| kube-vip | Single IP | 192.168.1.10 | The control plane VIP — must be reachable by all nodes and your local machine |
| MetalLB | IP range | 192.168.1.11-20 |Pool of IPs MetalLB can assign to `LoadBalancer` services |
| Traefik | Single IP | 192.168.1.11 |The first IP in your MetalLB pool, reserved for Traefik's ingress service |

> **Tip:** A clean way to manage this is to carve a static block out of your local subnet (e.g. the top or bottom of the range) and split it: one IP for kube-vip, the rest as the MetalLB pool. Configure your router's DHCP server to exclude this entire block from dynamic assignment.

### Local Tooling

All required tools are pre-installed in the [DevOps Toolbox](https://github.com/Taegost/DevOps-Toolbox) dev container (`taegost/devops-toolbox:latest`). Open this repository inside that container before running any commands below.

If you are not using the DevOps Toolbox, you will need the following installed locally:

| Tool | Installation |
|------|-------------|
| `kubectl` | https://kubernetes.io/docs/tasks/tools/ |
| `kubeseal` | https://github.com/bitnami-labs/sealed-secrets#installation |
| `helm` | https://helm.sh/docs/intro/install/ |

### kubectl Configuration

Copy the kubeconfig from your k3s control plane to your local machine. The kubeconfig is generated at `/etc/rancher/k3s/k3s.yaml` on the control plane node — replace `127.0.0.1` with your kube-vip virtual IP before copying.

```bash
# On the control plane node — replace <VIP> with your kube-vip address
sudo sed 's/127.0.0.1/<VIP>/g' /etc/rancher/k3s/k3s.yaml
```

Copy the output into `~/.kube/config` on your local machine (or the DevOps Toolbox container via its mount). Verify connectivity:

```bash
kubectl get nodes
# All nodes should appear with status Ready
```

> If you are rebuilding after a disaster, restore the Sealed Secrets private key **before** proceeding past Step 2. See [docs/disaster-recovery.md](../docs/disaster-recovery.md).

---

## Bootstrap Order

Run the steps below in order. Do not skip ahead — each step is a dependency of the next.

---

### Step 0 — kube-vip (pre-cluster)

kube-vip provides the virtual IP (VIP) for the k3s control plane API server, enabling high availability across multiple control plane nodes. It must be installed **before** additional control plane nodes are joined and **before** `kubectl` can be used reliably, which is why it cannot be managed by ArgoCD.

Reference manifests for this cluster's kube-vip configuration are in [`kube-vip/`](kube-vip/):

| File | Purpose |
|------|---------|
| `kube-vip/rbac.yaml` | RBAC rules required by the kube-vip DaemonSet — no changes needed |
| `kube-vip/daemonset.yaml` | The kube-vip DaemonSet itself — two values must be updated |

**What to change in `kube-vip/daemonset.yaml` before applying:**

1. **`vip_address`** — the virtual IP for your control plane. Must be an unused IP on your local network, outside your DHCP range and outside the MetalLB pool.
   ```yaml
   - name: vip_address
     value: "192.168.5.XXX"   # <-- replace with your VIP
   ```

2. **`vip_interface`** — the network interface name on your control plane nodes.
   ```yaml
   - name: vip_interface
     value: "ens18"           # <-- replace with your interface name
   ```

   To find the correct interface name on a node:
   ```bash
   ip -o link show | awk '{print $2}' | tr -d ':'
   ```

See the [official kube-vip DaemonSet installation guide](https://kube-vip.io/docs/installation/daemonset/) for full installation steps. Confirm the VIP is reachable before continuing.

---

### Step 1 — Sealed Secrets

Sealed Secrets must be deployed first so the controller is available to decrypt any `SealedSecret` resources applied by later steps.

```bash
kubectl apply -f ../apps/sealed-secrets/
```

Wait for the controller to be ready:

```bash
kubectl rollout status deployment sealed-secrets -n sealed-secrets
```

**Back up the private key immediately** — this is your only opportunity before other sealed secrets are created. See [docs/sealed-secrets.md](../docs/sealed-secrets.md#backing-up-the-private-key) for instructions. Store the key in Bitwarden before continuing.

Fetch and commit the public key so it can be used to encrypt secrets locally:

```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > pub-cert.pem

git add pub-cert.pem
git commit -m "chore: add sealed secrets public cert"
git push
```

---

### Step 2 — MetalLB

MetalLB provides `LoadBalancer`-type service IPs from your local network. Traefik will request one in the next step.

```bash
kubectl apply -f ../apps/metallb/
```

Wait for MetalLB to be ready:

```bash
kubectl rollout status deployment controller -n metallb-system
```

---

### Step 3 — Traefik

Traefik is the cluster's ingress controller. It will be assigned the first IP in the MetalLB pool (reserved for Traefik during IP planning) and will handle all external traffic into the cluster.

```bash
kubectl apply -f ../apps/traefik/
```

Wait for Traefik to be ready:

```bash
kubectl rollout status deployment traefik -n traefik
```

Verify Traefik received its external IP:

```bash
kubectl get svc -n traefik
# The EXTERNAL-IP column should show your reserved Traefik IP
```

At this point, your Traefik dashboard hostname should be reachable from your network (assuming DNS is pointed at your Traefik IP).

---

### Step 4 — ArgoCD

ArgoCD is the GitOps controller that will manage all future deployments — including managing itself after this step.

```bash
kubectl apply -f ../apps/argocd/
```

Wait for ArgoCD to be ready:

```bash
kubectl rollout status deployment argocd-server -n argocd
```

Retrieve the initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Log in to the ArgoCD UI at your ArgoCD hostname with username `admin` and the password above.

> **Change the admin password** after first login via **User Info → Update Password**. Then delete the initial secret:
> ```bash
> kubectl delete secret argocd-initial-admin-secret -n argocd
> ```

---

### Step 5 — Connect ArgoCD to This Repository

Apply the root `Application` manifest that activates the app-of-apps pattern:

```bash
kubectl apply -f ../apps/argocd/app-of-apps.yaml
```

ArgoCD will now discover and sync all applications defined in this repository automatically. From this point forward, all changes are made by committing to the `main` branch — no more manual `kubectl apply` commands.

---

## Verification Checklist

After completing all steps, confirm the following:

- [ ] All nodes show `Ready` in `kubectl get nodes`
- [ ] kube-vip VIP is reachable (try `curl -k https://<your-vip>:6443`)
- [ ] MetalLB controller pod is running in `metallb-system`
- [ ] Traefik pods are running in `traefik` with your reserved external IP
- [ ] ArgoCD UI is accessible at your ArgoCD hostname
- [ ] All ArgoCD applications show `Synced` and `Healthy`
- [ ] Sealed Secrets private key is stored in Bitwarden
- [ ] `pub-cert.pem` is committed to the repository