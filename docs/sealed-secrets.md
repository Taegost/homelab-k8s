# Sealed Secrets

This document explains how to create, use, and maintain Sealed Secrets in this cluster.

## What is a Sealed Secret?

A [Sealed Secret](https://github.com/bitnami-labs/sealed-secrets) is a Kubernetes custom resource that contains an **encrypted** version of a standard `Secret`. The encryption is asymmetric:

- The **public key** is used by `kubeseal` to encrypt secrets. It is embedded inside the private key backup and is fetched automatically by `kubeseal` when you have cluster access.
- The **private key** lives only in the cluster, managed by the Sealed Secrets controller in `kube-system`. It is never committed anywhere.

Only the controller running in your cluster can decrypt a `SealedSecret` back into a usable `Secret`.

---

## Initial Setup

### Install the kubeseal CLI

The `kubeseal` CLI is pre-installed in the [DevOps Toolbox](https://github.com/Taegost/DevOps-Toolbox) container. If you are working outside that container:

```bash
# macOS
brew install kubeseal

# Linux — check https://github.com/bitnami-labs/sealed-secrets/releases for the latest version
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.36.6/kubeseal-0.36.6-linux-amd64.tar.gz"
tar -xvzf kubeseal-0.36.6-linux-amd64.tar.gz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

### Do I Need to Fetch the Public Key?

Not usually. When you have a live connection to the cluster, `kubeseal` automatically fetches the public key from the controller. You only need to fetch it manually if you want to encrypt secrets **offline** (without cluster access):

```bash
# Only needed for offline workflows — skip this if you have cluster access
kubeseal --fetch-cert > pub-cert.pem
```

If you do use `pub-cert.pem` for offline sealing, be aware it will go stale when the controller rotates its keys (every 30 days — see [Key Rotation](#key-rotation) below).

---

## Creating a Sealed Secret

### Step 1 — Write a normal Secret manifest (do NOT commit this file)

```yaml
# my-app-secret.yaml  <-- local only, never commit
apiVersion: v1
kind: Secret
metadata:
  name: my-app-secret
  namespace: my-app
type: Opaque
stringData:
  API_KEY: "supersecretvalue"
  DB_PASSWORD: "anothersecretvalue"
```

### Step 2 — Encrypt it with kubeseal

Note the `-sealedsecret.yaml` suffix — this is the required naming convention for this repository. The `.gitignore` explicitly blocks `*-secret.yaml` (plaintext) while allowing `*-sealedsecret.yaml` (encrypted output), so using the correct suffix is what keeps you safe.

```bash
# With live cluster access (kubeseal fetches the cert automatically)
kubeseal --format yaml \
  < my-app-secret.yaml \
  > apps/my-app/my-app-sealedsecret.yaml

# Alternatively, using a locally fetched cert for offline use
kubeseal --cert pub-cert.pem --format yaml \
  < my-app-secret.yaml \
  > apps/my-app/my-app-sealedsecret.yaml
```

### Step 2.5 — Verify it is safe to commit

Before staging the file, confirm it contains a `SealedSecret` resource and not a plaintext `Secret`:

```bash
# Should output "SealedSecret" — if it outputs "Secret", do NOT commit the file
grep "kind:" apps/my-app/my-app-sealedsecret.yaml

# Optionally, validate the sealed secret against the live cluster
kubeseal --validate < apps/my-app/my-app-sealedsecret.yaml && echo "Valid"
```

### Step 3 — Commit the sealed secret

```bash
git add apps/my-app/my-app-sealedsecret.yaml
git commit -m "feat(my-app): add sealed secret"
git push
```

ArgoCD will sync the `SealedSecret` to the cluster. The controller will decrypt it into a standard `Secret` automatically.

---

## Updating a Sealed Secret

Re-create the plaintext secret locally with the new values and re-run `kubeseal`. The output file replaces the existing one. Commit and push — ArgoCD will apply the updated `SealedSecret` and the controller will update the underlying `Secret`.

---

## Backing Up the Private Key

> ⚠️ If you lose the private key and rebuild your cluster, all existing `SealedSecret` manifests become permanently unrecoverable. You would need to re-encrypt every secret from scratch.

**Back up the private key immediately after the controller is first deployed**, and again after each key rotation (see [Key Rotation](#key-rotation) below).

The backup file contains both the public and private keys together — there is no need to back them up separately.

```bash
kubectl get secret \
  -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > main.key
```

Store `main.key` in a secure location **outside** this repository (e.g. Bitwarden). Delete the local copy after storing it securely.

---

## Restoring the Private Key After a Cluster Rebuild

If you rebuild your cluster, restore the private key **before** applying any `SealedSecret` manifests. See [docs/disaster-recovery.md](disaster-recovery.md) for the full rebuild sequence.

Once the Sealed Secrets controller is running, apply the backup and restart the controller:

```bash
# Apply the backed-up key
kubectl apply -f main.key

# Force the controller to restart and load the restored key
# (delete the pod — the Deployment will immediately recreate it)
kubectl delete pod -n kube-system -l name=sealed-secrets-controller
```

Verify the controller loaded the restored key rather than generating a new one:

```bash
kubectl logs -n kube-system -l name=sealed-secrets-controller | grep -i key
# Look for: "registered private key" — not "new key written"
```

Delete the local copy of the key file after confirming the restore succeeded:

```bash
rm main.key
```

---

## Key Rotation

The Sealed Secrets controller automatically generates a new key pair every **30 days**. The old keys are retained and marked active, so existing `SealedSecret` resources continue to decrypt without any changes on your part.

However, this means your backup goes stale over time. **Re-run the backup command after each key rotation** to ensure your Bitwarden copy covers all active keys:

```bash
kubectl get secret \
  -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > main.key
```

The label selector captures *all* active keys in a single file, so there is no need to run it multiple times.

If you use `pub-cert.pem` for offline sealing, re-fetch it after each rotation as well — `kubeseal` will otherwise encrypt with a stale cert that may not match the current active key.

---

## Scope and Namespace Binding

By default, `kubeseal` creates secrets that are **namespace-scoped** — a `SealedSecret` encrypted for namespace `my-app` cannot be decrypted in namespace `other-app`. This is a security feature.

If you need a cluster-scoped secret (rare), use `--scope cluster-wide`:

```bash
kubeseal --scope cluster-wide --format yaml < secret.yaml > sealed-secret.yaml
```

For most use cases, the default namespace scope is correct and preferred.