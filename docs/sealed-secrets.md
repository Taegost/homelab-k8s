# Sealed Secrets

This document explains how to create, use, and maintain Sealed Secrets in this cluster.

## What is a Sealed Secret?

A [Sealed Secret](https://github.com/bitnami-labs/sealed-secrets) is a Kubernetes custom resource that contains an **encrypted** version of a standard `Secret`. The encryption is asymmetric:

- The **public key** is used by `kubeseal` to encrypt secrets locally. It is safe to share and is committed to this repo.
- The **private key** lives only in the cluster, managed by the Sealed Secrets controller. It is never committed anywhere.

Only the controller running in your cluster can decrypt a `SealedSecret` back into a usable `Secret`.

---

## Initial Setup

### Install the kubeseal CLI

```bash
# macOS
brew install kubeseal

# Linux (replace VERSION with latest from GitHub releases)
VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep tag_name | cut -d '"' -f 4)
curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/${VERSION}/kubeseal-linux-amd64" -o kubeseal
chmod +x kubeseal
sudo mv kubeseal /usr/local/bin/
```

### Fetch the Public Key

After the Sealed Secrets controller is deployed, fetch its public key and commit it to this repo:

```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > pub-cert.pem
```

> The public key (`pub-cert.pem`) is safe to commit. Anyone can use it to encrypt secrets for your cluster, but only your cluster can decrypt them.

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
kubeseal \
  --cert pub-cert.pem \
  --format yaml \
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

**Back up the private key immediately after the controller is first deployed.**

```bash
# Export the private key
kubectl get secret \
  -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master-key.yaml
```

Store `sealed-secrets-master-key.yaml` in a secure location **outside** this repository (e.g. a password manager like Bitwarden, or an encrypted offline backup). Delete the local copy after storing it securely.

---

## Restoring the Private Key After a Cluster Rebuild

If you rebuild your cluster, restore the private key **before** applying any `SealedSecret` manifests:

```bash
# Apply the backed-up key
kubectl apply -f sealed-secrets-master-key.yaml

# Restart the controller so it picks up the restored key
kubectl rollout restart deployment sealed-secrets -n sealed-secrets
```

After the controller restarts, all existing `SealedSecret` resources will decrypt successfully.

---

## Scope and Namespace Binding

By default, `kubeseal` creates secrets that are **namespace-scoped** — a `SealedSecret` encrypted for namespace `my-app` cannot be decrypted in namespace `other-app`. This is a security feature.

If you need a cluster-scoped secret (rare), use `--scope cluster-wide`:

```bash
kubeseal --scope cluster-wide --cert pub-cert.pem --format yaml < secret.yaml > sealed-secret.yaml
```

For most use cases, the default namespace scope is correct and preferred.