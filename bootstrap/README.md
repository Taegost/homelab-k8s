# Bootstrap

This directory contains reference manifests and step-by-step instructions for the **one-time manual bootstrap** of the cluster. Once ArgoCD is running and connected to this repository, it takes over management of all resources — including itself. You should never need to run these steps again unless rebuilding from scratch.

---

## Why a Separate Bootstrap Phase?

ArgoCD cannot manage resources that don't exist yet. The bootstrap phase installs the minimum set of components in the correct order so that each one is ready before the next depends on it:

- **kube-vip** must exist before the cluster is fully operational — it provides the control plane VIP that everything else connects through.
- **Sealed Secrets** must exist before any `SealedSecret` resource is applied, so the controller is ready to decrypt them.
- **cert-manager** must exist before Traefik so TLS certificates are ready when Traefik starts routing traffic.
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

| Component | Type | Notes |
|-----------|------|-------|
| kube-vip | Single IP | The control plane VIP — must be reachable by all nodes and your local machine |
| MetalLB | IP range | Pool of IPs MetalLB can assign to `LoadBalancer` services |
| Traefik | Single IP | The first IP in your MetalLB pool, reserved for Traefik's ingress service |

> **Tip:** A clean way to manage this is to carve a static block out of your local subnet (e.g. the top of the range) and split it: one IP for kube-vip, the rest as the MetalLB pool. Configure your router's DHCP server to exclude this entire block from dynamic assignment.

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
kubectl apply -f apps/sealed-secrets/sealed-secrets-controller.yaml
```

Wait for the controller to be ready:

```bash
kubectl rollout status deployment sealed-secrets-controller -n kube-system
```

**Back up the private key immediately** and store it in Bitwarden before continuing. The backup file contains both the public and private keys — there is no need to back them up separately. See [docs/sealed-secrets.md](../docs/sealed-secrets.md#backing-up-the-private-key) for full details including key rotation.

```bash
kubectl get secret \
  -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > main.key
# Store main.key in Bitwarden, then delete the local copy
rm main.key
```

---

### Step 2 — cert-manager

cert-manager must be deployed before Traefik so that the TLS certificate infrastructure is in place when Traefik starts. The `--server-side` flag is required because cert-manager's CRDs exceed the annotation size limit for client-side apply.

```bash
kubectl apply -f apps/cert-manager/cert-manager.yaml --server-side
kubectl rollout status deployment cert-manager -n cert-manager
kubectl rollout status deployment cert-manager-webhook -n cert-manager
```

Next, apply the Route53 credentials and issuers:

```bash
kubectl apply -f apps/cert-manager/route53-credentials-sealedsecret.yaml
kubectl apply -f apps/cert-manager/clusterissuer-diceninjagaming-staging.yaml
kubectl apply -f apps/cert-manager/clusterissuer-diceninjagaming-prod.yaml
```

> **Note:** Wildcard certificates are managed in the `traefik` namespace rather than here.
> They are applied as part of Step 4.

---

### Step 3 — MetalLB

MetalLB provides `LoadBalancer`-type service IPs from your local network. Traefik will request one in the next step.

The manifest and config files must be applied in order — the CRDs in the main manifest must exist before the `IPAddressPool` and `L2Advertisement` resources can be created.

```bash
kubectl apply -f apps/metallb/metallb.yaml
kubectl rollout status deployment controller -n metallb-system
kubectl rollout status daemonset speaker -n metallb-system

kubectl apply -f apps/metallb/ipaddresspool.yaml
kubectl apply -f apps/metallb/l2advertisement.yaml
```

---

### Step 4 — Traefik

Traefik is deployed via Helm. The `values.yaml` file in `apps/traefik/` is used
both here and by ArgoCD after bootstrap, keeping configuration consistent.

Before applying, seal the dashboard credentials:

```bash
# Generate credentials using openssl
echo "YOUR_USERNAME:$(openssl passwd -apr1 YOUR_PASSWORD)"

# Paste the output into apps/traefik/dashboard-auth-secret.yaml, then seal it
kubeseal --format yaml < apps/traefik/dashboard-auth-secret.yaml \
  > apps/traefik/dashboard-auth-sealedsecret.yaml
rm apps/traefik/dashboard-auth-secret.yaml
```

Install Traefik and apply all supporting manifests:

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update

# Extract the chart version from values.yaml so there is a single source of truth.
# If you have upgraded the chart version in values.yaml, this command picks it up automatically.
TRAEFIK_VERSION=$(grep -A1 "chart: traefik" apps/traefik/argocd-app.yaml | grep "targetRevision:" | awk '{print $2}')
helm install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  --version $TRAEFIK_VERSION \
  --values apps/traefik/values.yaml

kubectl rollout status deployment traefik -n traefik

kubectl apply -f apps/traefik/dashboard-auth-sealedsecret.yaml
# Applies the various shared/default middlewares
kubectl apply -f apps/traefik/middleware-default-headers.yaml
kubectl apply -f apps/traefik/middleware-internal-whitelist.yaml
kubectl apply -f apps/traefik/middleware-default-whitelist.yaml
kubectl apply -f apps/traefik/middleware-https-redirect.yaml
kubectl apply -f apps/traefik/middleware-dashboard-auth.yaml

# Applies the certificates and default cert
kubectl apply -f apps/traefik/certificate-dng-home-wildcard.yaml
kubectl apply -f apps/traefik/certificate-dng-root-wildcard.yaml
kubectl apply -f apps/traefik/tlsstore.yaml

# IngressRoute for the Traefik dashboard itself
kubectl apply -f apps/traefik/ingressroute-dashboard.yaml

# Applies the temporary forwarding rules to the existing Traefik instance.
# These will be removed once all the routes are migrated into kubernetes.
kubectl apply -f apps/traefik/docker-traefik-forward.yaml
kubectl apply -f apps/traefik/docker-traefik-catchall.yaml
```

Verify Traefik received its external IP and the dashboard is reachable:

```bash
kubectl get svc -n traefik
# EXTERNAL-IP should show your reserved Traefik IP

# Dashboard should be reachable at:
# https://traefik-k8s.home.diceninjagaming.com
# (once DNS is pointed at your Traefik IP)
```



---

### Step 5 — ArgoCD

ArgoCD is the GitOps controller that will manage all future deployments — including managing itself after this step.

> **Note on HA vs non-HA:** The manifest committed to `apps/argocd/argocd.yaml` is the **non-HA** install. The HA manifest requires a minimum of 3 nodes due to Redis HA quorum requirements — running it on fewer nodes leaves pods permanently pending. Once a third node is available, follow the instructions in [docs/argocd-ha-migration.md](../docs/argocd-ha-migration.md) to switch over. Since ArgoCD will be managing itself at that point, the switchover is a single Git commit.

Install the manifest, then apply the supporting config:

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f apps/argocd/argocd.yaml

# Wait for ArgoCD to be ready
kubectl rollout status deployment argocd-server -n argocd
kubectl rollout status deployment argocd-repo-server -n argocd
kubectl rollout status statefulset argocd-application-controller -n argocd

# Apply server config (insecure mode for Traefik TLS termination) and IngressRoute
# It's normal to see a warning about a missing annotation when applying argocd-cmd-params-cm.yaml
kubectl apply -f apps/argocd/argocd-cmd-params-cm.yaml
kubectl apply -f apps/argocd/ingressroute.yaml

# Restart ArgoCD server to pick up the insecure mode config
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd
```

Retrieve the initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Log in to the ArgoCD UI at your ArgoCD hostname with username `admin` and the password above.

> **Important:** Change the admin password immediately after first login via **User Info → Update Password**. Then delete the initial secret:
> ```bash
> kubectl delete secret argocd-initial-admin-secret -n argocd
> ```

---

### Step 6 — Connect ArgoCD to This Repository

> ⚠️ **Warning:** Before applying `app-of-apps.yaml`, ensure all bootstrap changes have been merged into your default branch (`main`). The root Application points at `main` — if that branch does not contain the expected manifests, ArgoCD will sync against nothing and prune itself and all managed resources from the cluster. Merge first, then apply.

Apply the root app-of-apps manifest from the repo root. This activates autodiscovery — ArgoCD will read all Application manifests from `apps/manifests/` and create an Application for each one it finds:

```bash
kubectl apply -f app-of-apps.yaml
```

ArgoCD will immediately discover and sync all components — `cert-manager`, `metallb`, `sealed-secrets`, `traefik`, and `argocd` itself. Since these resources already exist in the cluster from the bootstrap steps, ArgoCD will adopt them rather than reinstalling them.

From this point forward, all changes are made by committing to the `main` branch — no more manual `kubectl apply` commands. To add a new application, create `apps/<app-name>/` with your manifests and `apps/manifests/<app-name>.yaml` pointing at it, then push — ArgoCD will discover and deploy it automatically.

> **Verify:** Open the ArgoCD UI and confirm all applications appear and reach `Synced` and `Healthy` status. If any application shows `OutOfSync`, review the diff in the UI before syncing — it may indicate a difference between the live cluster state and what is committed in `main`.

---

## Verification Checklist

After completing all steps, confirm the following:

- [ ] All nodes show `Ready` in `kubectl get nodes`
- [ ] kube-vip VIP is reachable (try `curl -k https://<your-vip>:6443`)
- [ ] cert-manager pods are running in `cert-manager`
- [ ] Both wildcard certificates show `READY=True` in `kubectl get certificate -n traefik`
- [ ] MetalLB controller pod is running in `metallb-system`
- [ ] Traefik pods are running in `traefik` with your reserved external IP
- [ ] ArgoCD UI is accessible at your ArgoCD hostname
- [ ] All ArgoCD applications show `Synced` and `Healthy`
- [ ] Sealed Secrets private key is stored in Bitwarden
- [ ] `pub-cert.pem` is committed to the repository