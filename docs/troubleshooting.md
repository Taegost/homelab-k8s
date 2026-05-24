# Troubleshooting

Cluster-level diagnostics and known gotchas. Add a section here whenever you resolve something non-obvious.

---

## DNS

### TL;DR — what has actually gone wrong in this cluster

| Incident | Looked like | Actually was | Fix |
|----------|-------------|--------------|-----|
| Authentik migration (2026-04-28) — pod on `ubuntu-server` resolved `postgres-pooler.postgres.svc.cluster.local` to `192.168.5.202` | conntrack race condition | Node's `/etc/resolv.conf` had `search home.diceninjagaming.com`; with `ndots:5` this matched the Pi-hole wildcard before the absolute FQDN was tried | Set DNS Domain to `.` in Proxmox cloud-init; edit `/etc/netplan/50-cloud-init.yaml` |

If a pod is resolving a cluster-internal hostname to `192.168.5.202` (Traefik),
**check the pod's `resolv.conf` search domains first** before assuming conntrack.

---

### Architecture

| Component | Detail |
|-----------|--------|
| In-cluster DNS | CoreDNS — 1 replica, managed by k3s addon controller (`kube-system`) |
| ClusterIP | `10.43.0.10` (service name: `kube-dns`) |
| Upstream DNS | Pi-hole at `192.168.5.247` (primary) and `192.168.5.248` (secondary) |
| Pi-hole wildcard | `*.diceninjagaming.com` → `192.168.5.202` (Traefik ingress) — this is correct and expected |

**Query path (normal):** Pod → kube-proxy → CoreDNS ClusterIP (`10.43.0.10`) → CoreDNS forwards non-cluster domains to Pi-hole.

---

### Known issue: search domain causes wrong IP for cluster-internal hostnames

**Symptom:** A pod consistently resolves a cluster-internal hostname (e.g. `postgres-pooler.postgres.svc.cluster.local`) to `192.168.5.202` (the Traefik ingress IP) instead of the correct ClusterIP. The problem is deterministic on one node and absent on the other.

**Cause:** A node's `/etc/resolv.conf` contains an extra search domain (e.g. `home.diceninjagaming.com`) that gets propagated into pod `resolv.conf` by kubelet. With `ndots:5`, any hostname with fewer than 5 dots triggers search domain expansion before the absolute lookup. `postgres-pooler.postgres.svc.cluster.local` has 4 dots, so the resolver tries:

1. `postgres-pooler.postgres.svc.cluster.local.svc.cluster.local` → NXDOMAIN
2. `postgres-pooler.postgres.svc.cluster.local.cluster.local` → NXDOMAIN
3. `postgres-pooler.postgres.svc.cluster.local.home.diceninjagaming.com` → **Pi-hole wildcard matches → returns `192.168.5.202`**

The absolute lookup (step 4) is never reached.

**Diagnosis:**
```bash
# Check what search domains pods on each node are getting
kubectl exec -n <namespace> <pod> -- cat /etc/resolv.conf

# Check the node's own resolv.conf (SSH to the node)
cat /etc/resolv.conf
resolvectl status
```

**Fix:** Remove the rogue search domain from the node's network configuration. On nodes
provisioned via Proxmox cloud-init, set the **DNS Domain** field to `.` (a single dot) in
the cloud-init tab — this produces `search .` (no domain) on the node, matching the correct
behaviour. Edit `/etc/netplan/50-cloud-init.yaml` directly for an immediate fix without
re-running cloud-init:

```yaml
      nameservers:
        addresses:
          - 192.168.5.1
        search:
          - .
```

```bash
sudo netplan apply
resolvectl status    # confirm the search domain is gone
```

Then restart any affected pods to pick up the corrected `resolv.conf`.

**Prevention:** When provisioning new VMs via Proxmox cloud-init, always explicitly set the
DNS Domain field to `.` rather than leaving it as "use host settings". The Proxmox host's
domain setting propagates into VMs and will corrupt cluster DNS if it matches a Pi-hole
wildcard.

---

### Conntrack race condition (theoretical risk — not yet observed)

**What it is:** Linux conntrack has a race condition with concurrent UDP DNS queries. When a
pod fires A and AAAA record requests simultaneously, kube-proxy NATs both toward the CoreDNS
ClusterIP. If two queries from different pods share a similar 5-tuple at the same moment,
conntrack can deliver the response from one query to the other pod's socket — causing an
arbitrary IP to be returned for an unrelated hostname. Because `*.diceninjagaming.com` is
always in flight (it legitimately resolves to `192.168.5.202`), those responses are the most
common swap target when the race fires.

**Current status:** This cluster has not had a confirmed conntrack incident. The Authentik
migration incident (2026-04-28) initially appeared to match — one pod was consistently
returning `192.168.5.202` for a cluster-internal hostname — but investigation showed the
actual cause was the search domain issue documented above. Pods use `10.43.0.10` directly
through kube-proxy, so the theoretical risk exists but has not materialised in practice.

**What we tried:** NodeLocal DNSCache was deployed (lablabs Helm chart,
`lablabs.github.io/k8s-nodelocaldns-helm`) and ran successfully as a DaemonSet. However,
it did not resolve the incident and was subsequently removed. The reasons it was ineffective:

1. The lablabs chart sets up NOTRACK iptables rules for the link-local IP (`169.254.20.11`)
   but does **not** configure k3s to inject that IP into pod `resolv.conf`.
2. Both nodes' pods still showed `nameserver 10.43.0.10` — the agent was running but
   intercepting nothing.
3. Making it effective would require adding `cluster-dns=169.254.20.11` to
   `/etc/rancher/k3s/config.yaml` on every node and restarting k3s — an out-of-band,
   non-GitOps step.
4. The root cause turned out to be the search domain, not conntrack, so the fix wasn't needed.

The archived manifests live in `archived/nodelocaldns/` if this ever needs to be revisited.

**If conntrack does become a confirmed problem:** Deploy NodeLocal DNSCache and additionally
configure every k3s node's kubelet to use `169.254.20.11` as the cluster DNS:

```bash
# Add to /etc/rancher/k3s/config.yaml on every node, then restart k3s / k3s-agent
kubelet-arg:
  - "cluster-dns=169.254.20.11"
```

Without this kubelet change, pods still use `10.43.0.10` and the conntrack path is unchanged
regardless of whether the DaemonSet is running.

---

### Troubleshooting DNS resolution from inside a pod

Run a throwaway debug pod (uses `dnsutils` which includes `dig` and `nslookup`):

```bash
kubectl run dns-debug --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3 \
  --restart=Never -it --rm -- bash
```

Inside the pod:

```bash
# Check what DNS server the pod is using
cat /etc/resolv.conf

# Test cluster-internal resolution
nslookup kubernetes.default.svc.cluster.local

# Test external resolution
nslookup github.com

# Get full resolution path with timing (useful for diagnosing timeouts)
dig kubernetes.default.svc.cluster.local +stats

# Check which IP a hostname resolves to
dig +short sonarr.home.diceninjagaming.com
# Expected: 192.168.5.202 (Traefik) — this is correct for *.diceninjagaming.com
```

---

### Gotchas

**`*.diceninjagaming.com` always resolves to `192.168.5.202` — this is correct.**
Pi-hole has a wildcard DNS record pointing all `*.diceninjagaming.com` subdomains to the
Traefik ingress IP. Any pod querying a `diceninjagaming.com` hostname will receive
`192.168.5.202`. This is only a problem when a node search domain causes a cluster-internal
FQDN to be expanded into a `*.diceninjagaming.com` match before the absolute lookup is tried
(see search domain issue above).

**CoreDNS is managed by the k3s addon controller, not ArgoCD.**
The CoreDNS `Deployment` in `kube-system` is owned by k3s's `objectset.rio.cattle.io` addon
controller. Direct edits via `kubectl` or ArgoCD patches will be reverted. Changes to CoreDNS
configuration must go through a `coredns-custom` ConfigMap (for Corefile changes) or the
addon manifest on the server node at `/var/lib/rancher/k3s/server/manifests/`.

---

## ArgoCD Sync Wave / SealedSecrets

### SealedSecret deploys at wave 0 instead of its declared wave

**Symptom:** An app's first-ever sync fails. MariaDB `User` or `Grant` CRDs (wave `-2`)
report that the credentials `Secret` doesn't exist. Manually syncing the `SealedSecret`
alone lets everything else proceed. The `SealedSecret` manifest has
`argocd.argoproj.io/sync-wave: "-3"` in it but ArgoCD ignores it.

**Cause (confirmed — wordpress-taegost, 2026-05-22):** The sync-wave annotation was placed
inside `spec.template.metadata.annotations` rather than the `SealedSecret` resource's own
`metadata.annotations`. `spec.template.metadata.annotations` is kubeseal's passthrough
mechanism — it propagates to the decrypted `Secret`, not to the `SealedSecret` resource.
ArgoCD reads wave ordering only from the top-level `metadata.annotations` of the resource it
is syncing, so it treated every affected `SealedSecret` as wave `0`.

**Affected resources (fixed in this commit):**
- `apps/wordpress-taegost/sealedsecret-wordpress-taegost-db-credentials.yaml` — wave `-3`
- `apps/wordpress-taegost/sealedsecret-wordpress-taegost-keys.yaml` — wave `-1`
- `apps/wordpress-taegost/sealedsecret-wordpress-taegost.yaml` — wave `-1`
- `apps/wordpress-dng/sealedsecret-wordpress-dng-db-credentials.yaml` — wave `-3`
- `apps/wordpress-dng/sealedsecret-wordpress-dng.yaml` — wave `-1`
- `apps/wordpress-dng/sealedsecret-wordpress-dng-keys.yaml` — wave `-1`

**Fix:** Add `argocd.argoproj.io/sync-wave` to `metadata.annotations` directly on the
`SealedSecret` resource. The `spec.template.metadata.annotations` copy can remain — it
correctly propagates the wave to the underlying `Secret` and does no harm.

**Prevention:** See `docs/sealed-secrets.md` — "ArgoCD Sync Wave Ordering" section. When
creating any new `SealedSecret` that needs wave ordering, always add the annotation in both
locations.

**Diagnosis:**
```bash
# Check where the sync-wave annotation actually lives on a SealedSecret
grep -A5 "^metadata:" apps/<app>/sealedsecret-*.yaml | grep sync-wave
# If the only hit is indented under "spec:" → the annotation is in the wrong place
grep -n "sync-wave" apps/<app>/sealedsecret-*.yaml
```

---

## MongoDB 8 Pods Crash-Looping on Startup

### MongoDB 8 exits with SIGILL (Illegal instruction)

**Symptom:** MongoDB 8.x pods fail to start and enter `CrashLoopBackOff`. The
mongod container exits immediately — `kubectl logs` shows nothing or a truncated
startup line. The kernel logs on the node contain:

```
traps: mongod[<pid>] trap invalid opcode ip:<addr> sp:<addr> error:0 in mongod[<addr>+<offset>]
```

The operator logs show the replica set never initialising because all three pods
are crash-looping:

```
kubectl logs -n psmdb-operator -l app.kubernetes.io/name=percona-server-mongodb-operator
```

**Cause (confirmed — 2026-05-23):** MongoDB 8.x binaries are compiled for the
`x86-64-v3` microarchitecture level (requires AVX, AVX2, BMI, FMA, F16C, LZCNT,
MOVBE, XSAVE). Many hypervisors default to a v2-level CPU type (e.g. Proxmox
defaults to `x86-64-v2-AES`), which lacks several of these instruction sets —
notably AVX and AVX2. When the mongod binary executes an instruction not present
on the vCPU, the kernel delivers `SIGILL` and the process dies.

This applies to all cluster nodes that share the same VM CPU type. The operator
sees all three pods crash-looping and cannot form the replica set.

**Verify CPU compatibility from inside a node:**

```bash
# SSH to any Kubernetes node and run:
grep -o 'avx[^ ]*' /proc/cpuinfo | sort -u
```

If the output includes both `avx` and `avx2`, the CPU supports x86-64-v3 and
MongoDB 8 will run. If either is missing, the CPU is at x86-64-v2 or lower.

**Fix:** Change the VM CPU type to `x86-64-v3` (or `host`) in your hypervisor:

- **Proxmox:** Shut down the VM → **Hardware → Processors → Type** → change from
  `x86-64-v2-AES` to `x86-64-v3` → start the VM.
- **Other hypervisors:** Look for the CPU model or CPU feature level setting in
  the VM configuration. Set it to `x86-64-v3`, `host`, or `host-passthrough`.
  Consult your hypervisor's documentation for the exact setting name.

The mongod pods will start successfully on next attempt. No manifest changes
required — this is a host-level fix.

**Prevention:** All Kubernetes node VMs should expose `x86-64-v3` (or `host`)
CPU features to the guest. This provides the instruction set expected by modern
server software — MongoDB 8 and increasingly other database and ML workloads. If
the hypervisor or bare-metal host does not support x86-64-v3, use MongoDB 7.x
instead; it only requires x86-64-v2. See `docs/mongodb-runbooks.md`.

---

## MongoDB Replica Set ID Mismatch

### Cluster stuck in `error` state with `InvalidReplicaSetConfig` in mongod logs

**Symptom:** ArgoCD shows the `perconaservermongodb` (psmdb) resource as `Degraded`
or in `error` state. Pod logs contain the error:

```
replica set IDs do not match, ours: <id-A>; remote node's: <id-B>
```

The operator logs show:

```
Reconcile Cluster: handle ReplicaSetNoPrimary: get standalone mongo client:
ping mongo: connection() error occurred during connection handshake:
auth error: sasl conversation error: AuthenticationFailed
```

And mongod logs from the failing pod show:

```
UserNotFound: Could not find user "clusterMonitor" for db "admin"
ReadConcernMajorityNotAvailableYet: Read concern majority reads are currently not possible.
collection [local.oplog.rs] not found
```

**Cause (confirmed — 2026-05-24):** The SealedSecrets referenced by the
`PerconaServerMongoDB` CRD (`spec.secrets.users`, `spec.secrets.keyFile`,
`spec.secrets.encryptionKey`) were deployed **without sync wave annotations**.
ArgoCD applied the CRD and SealedSecrets concurrently. The Percona operator saw
the CRD before the SealedSecret controller had decrypted the secrets into actual
Kubernetes Secrets. The operator auto-generated random credentials (including a
random keyfile) and bootstrapped the replica set with them.

When the SealedSecret controller eventually decrypted the real secrets, the
operator detected the mismatch and attempted to reconfigure the cluster. This
resulted in a split-brain:

- Some pods stored the auto-generated credentials and their associated
  `replicaSetId` in their local database.
- Other pods (or the same pods after restart) stored the real credentials
  and a different `replicaSetId`.
- The operator could not authenticate to fix the cluster because the
  credentials in the Secret no longer matched what mongod expected.
- The operator also created an `internal-mongodb-users` shadow secret
  containing cached auto-generated values, which survived naive cleanup.

**Fix — GitOps method (no sync pauses, no kubectl patching ArgoCD):**

**Step 1 — Remove the CRD from git so ArgoCD prunes it:**

```bash
mv apps/percona-mongodb/cluster-mongodb.yaml /tmp/cluster-mongodb.yaml.bak
git checkout -b fix/mongodb-replica-set-reset
git rm apps/percona-mongodb/cluster-mongodb.yaml
git commit -m "fix: temporarily remove MongoDB cluster CRD to reset replica set"
git push -u origin fix/mongodb-replica-set-reset
```

Wait for ArgoCD to sync and prune the `PerconaServerMongoDB` resource
(all mongodb pods terminate).

**Step 2 — Wipe PVCs and secrets from the cluster:**

```bash
# Verify no mongodb pods remain
kubectl get pods -n mongodb
# Should show "No resources found"

# Delete stale PVCs (contain wrong replicaSetId)
kubectl delete pvc --all -n mongodb

# Delete all Secrets — including the internal-mongodb-users shadow secret
# the operator created from auto-generated values
kubectl delete secret --all -n mongodb

# Wait a few seconds for SealedSecret controller to repopulate from sealed secrets
sleep 5
kubectl get secret -n mongodb
# Should show: mongodb-users, mongodb-keyfile, mongodb-encryption-key
```

**Step 3 — Restore the CRD in git so ArgoCD re-creates it:**

```bash
cp /tmp/cluster-mongodb.yaml.bak apps/percona-mongodb/cluster-mongodb.yaml
git add apps/percona-mongodb/cluster-mongodb.yaml
git commit -m "fix: restore MongoDB cluster CRD with clean bootstrap"
git push
```

ArgoCD syncs, operator bootstraps a fresh 3-node replica set with all secrets
present and consistent. The sync wave annotations (added in commit `eb9faa2`)
ensure SealedSecrets decrypt at wave `-3` before the CRD applies at wave `-2`,
preventing recurrence.

**Step 4 — Merge to main:**

```bash
# Create PR from fix/mongodb-replica-set-reset → main
# After merge, ArgoCD reconciles and the cluster reaches ready state
```

**Prevention:** Every `SealedSecret` that a CRD or operator reads must carry an
`argocd.argoproj.io/sync-wave` annotation in `metadata.annotations` set to `-3`
(or at least one wave earlier than the consuming CRD). See the sync wave
annotation checker in `docs/sealed-secrets.md` and the mandatory pre-commit
verification in `CLAUDE.md`.

**Diagnosis — check replica set IDs across pods:**

```bash
CLUSTER_ADMIN_PASSWORD=$(kubectl get secret mongodb-users -n mongodb \
  -o jsonpath='{.data.MONGODB_CLUSTER_ADMIN_PASSWORD}' | base64 -d)

for pod in mongodb-rs0-0 mongodb-rs0-1 mongodb-rs0-2; do
  echo "=== $pod ==="
  kubectl exec -n mongodb $pod -c mongod -- \
    mongosh -u clusterAdmin -p "$CLUSTER_ADMIN_PASSWORD" \
    --authenticationDatabase admin \
    --eval 'db.getSiblingDB("local").system.replset.findOne()._id' \
    --quiet 2>/dev/null || echo "FAILED"
done
```

If two pods show the same `_id` and a third shows a different one (or all three
differ), the replica set is split-brained and needs the full reset procedure above.

---

## Longhorn Volumes

### ext4 `lost+found` breaks apps that expect an empty data directory

Longhorn volumes formatted with ext4 contain a `lost+found` directory at the
volume root, owned by root:root (mode 700). An application that checks whether
its data directory is empty will see `lost+found` and assume existing data is
present — it then tries to read metadata files that don't exist and fails.

**Symptoms:**
- App fails on startup with "failed to infer version" or "database not found"
- PVC is brand new or was just recreated
- `lost+found` directory visible if you can exec into the pod or inspect the volume

**Affected apps:** Meilisearch (v1.35.1 confirmed; earlier versions likely)

**Fix:** Point the app's data path at a subdirectory of the volume. The app
creates the subdirectory on first start (it has write permission via `fsGroup`),
and `lost+found` stays harmlessly at the volume root.

```yaml
# Before (broken):
env:
  - name: MEILI_DB_PATH
    value: /meili_data

# After (fixed):
env:
  - name: MEILI_DB_PATH
    value: /meili_data/db
```

**General rule:** Any app that initializes a database on an empty volume should
store its data in a subdirectory, not at the volume root. This avoids the
`lost+found` false-positive on ext4-formatted volumes.

### Containers that default to root need explicit `runAsUser`

Images that run as root by default (most official Docker images: `python:*-slim`,
`node:*-alpine`, `postgres:*-alpine`, `redis:*-alpine`) will be rejected by
Kubernetes when `runAsNonRoot: true` is set without an explicit `runAsUser`.

**Symptoms:**
- Pod stuck in `CreateContainerConfigError` or init container fails immediately
- Event: `container has runAsNonRoot and image will run as root`
- Container never produces logs

**Fix:** Always set `runAsUser` and `runAsGroup` alongside `runAsNonRoot: true`
when the image doesn't declare a non-root `USER` in its Dockerfile.

```yaml
# Broken — image runs as root, Kubernetes rejects:
securityContext:
  runAsNonRoot: true

# Fixed — explicit UID, Kubernetes sets the process UID:
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  runAsNonRoot: true
```

**Note:** `redis:*-alpine` is an exception — it runs as the `redis` user (UID
999). Still set `runAsUser: 999` explicitly; don't rely on defaults.

**Check an image's user before writing the securityContext:**
```bash
docker inspect <image> | jq '.[0].Config.User' 2>/dev/null
# Or check the Dockerfile: grep "^USER" Dockerfile
```
Empty string or `"0"` → image runs as root → set `runAsUser`.
