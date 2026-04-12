# Disaster Recovery

This document covers how to fully restore this cluster from scratch using only this repository and your secure backups.

## What This Repo Can Restore

ArgoCD manages all application state from this Git repository. As long as you have:

1. This repository (public on GitHub — always available)
2. The Sealed Secrets private key (stored securely in your password manager)
3. A working k3s cluster with kube-vip installed

...you can restore the entire stack with no manual re-configuration.

What is **not** restored automatically:
- Persistent volume data (Longhorn snapshots / NFS data must be backed up separately)
- The Sealed Secrets private key itself (you must restore this from external backup)

---

## Recovery Procedure

### Step 1 — Provision a new k3s cluster with kube-vip

Follow your standard cluster provisioning process. kube-vip is managed outside this repo. Reference manifests for the kube-vip DaemonSet used in this cluster are in [`bootstrap/kube-vip/`](../bootstrap/kube-vip/) — see [`bootstrap/README.md`](../bootstrap/README.md) for which values need to be updated for your environment before applying. Confirm the API server VIP is reachable before continuing.

### Step 2 — Deploy the Sealed Secrets controller

The controller must be deployed before the private key can be restored, because the key is stored as a Kubernetes `Secret` in the `sealed-secrets` namespace — which doesn't exist until the controller creates it.

```bash
kubectl apply -f apps/sealed-secrets/
kubectl rollout status deployment sealed-secrets -n sealed-secrets
```

### Step 3 — Restore the Sealed Secrets private key

With the controller running, apply your backed-up private key. This must happen **before** ArgoCD syncs any `SealedSecret` resources, otherwise the controller will attempt to decrypt them with a newly generated key and fail permanently.

```bash
# Retrieve your backed-up key from Bitwarden and save it locally as:
# sealed-secrets-master-key.yaml  (do NOT commit this file)

kubectl apply -f sealed-secrets-master-key.yaml
```

Then restart the controller so it loads the restored key instead of any auto-generated one:

```bash
kubectl rollout restart deployment sealed-secrets -n sealed-secrets
kubectl rollout status deployment sealed-secrets -n sealed-secrets
```

Verify the key was loaded correctly — the controller logs should show it found an existing key rather than generating a new one:

```bash
kubectl logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets | grep -i key
# Look for: "found existing key" — not "generating new key"
```

Delete the local copy of the key file after confirming the restore succeeded:

```bash
rm sealed-secrets-master-key.yaml
```

### Step 4 — Re-run the remaining bootstrap steps

Follow [`bootstrap/README.md`](../bootstrap/README.md) to deploy MetalLB, Traefik, and ArgoCD in order.

Once ArgoCD is running, connect it to this GitHub repository. ArgoCD will sync all applications automatically from the current state of the `main` branch.

### Step 5 — Point ArgoCD at this repository and verify

Once ArgoCD is running, connect it to this GitHub repository. ArgoCD will sync all applications automatically from the current state of the `main` branch. Check that all applications reach `Synced` / `Healthy` status in the ArgoCD UI.

If any application fails to sync due to a `SealedSecret` decryption error, the most likely cause is that the private key restore in Step 3 did not complete correctly. Re-check the controller logs:

```bash
kubectl logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets | grep -i key
```

---

## Persistent Data

Longhorn handles replicated block storage for stateful applications. Longhorn's own backup and restore process (to S3 or NFS) is outside the scope of this document but should be configured for any stateful workload.

NFS-backed volumes (used for large media libraries) are not replicated by Kubernetes — their durability depends on the underlying NFS server.

---

## Key Contacts and Locations

| Item | Location |
|------|---------|
| Sealed Secrets private key | Bitwarden vault |
| GitHub repository | https://github.com/Taegost/homelab-k8s |
| Cluster node IPs | See docs/bootstrap.md |