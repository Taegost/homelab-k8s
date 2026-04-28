# Troubleshooting

Cluster-level diagnostics and known gotchas. Add a section here whenever you resolve something non-obvious.

---

## DNS

### Architecture

| Component | Detail |
|-----------|--------|
| In-cluster DNS | CoreDNS — 1 replica, managed by k3s addon controller (`kube-system`) |
| ClusterIP | `10.43.0.10` (service name: `kube-dns`) |
| NodeLocal DNSCache | DaemonSet on every node — intercepts DNS queries via iptables before they reach CoreDNS |
| NodeLocal link-local IP | `169.254.20.11` — **not** `169.254.20.10` as shown in the official k8s docs |
| Upstream DNS | Pi-hole at `192.168.5.247` (primary) and `192.168.5.248` (secondary) |
| Pi-hole wildcard | `*.diceninjagaming.com` → `192.168.5.202` (Traefik ingress) — this is correct and expected |

**Query path (normal):** Pod → iptables intercept → NodeLocal agent (`169.254.20.11`) → cache hit served locally, or cache miss forwarded directly to a CoreDNS pod IP → CoreDNS forwards non-cluster domains to Pi-hole.

The NodeLocal agent forwards cache misses directly to a CoreDNS **pod IP**, not the ClusterIP service — this is intentional and how it avoids the conntrack race condition.

---

### Known issue: conntrack race condition (intermittent wrong IP returned)

**Symptom:** DNS resolution intermittently returns `192.168.5.202` (the Traefik ingress IP) for hostnames that have nothing to do with `diceninjagaming.com` — including internal cluster names like `pgpooler.postgres.svc.cluster.local` and external internet hostnames.

**Cause:** Linux conntrack has a race condition with concurrent UDP DNS queries. When a pod fires A and AAAA record queries simultaneously, kube-proxy NATs them toward the CoreDNS ClusterIP. If two queries from different pods share a similar 5-tuple at the same moment, conntrack can deliver the response from one query to the other pod's socket. Because there is always heavy traffic to `*.diceninjagaming.com` from in-cluster pods (which legitimately resolves to `192.168.5.202`), those responses are frequently in-flight and are the most common swap target.

**Fix:** NodeLocal DNSCache (`apps/manifests/nodelocaldns.yaml`) — intercepts DNS at the node level via iptables before kube-proxy is involved. Conntrack never enters the DNS path.

**If NodeLocal DNSCache is deployed but the issue persists:**
1. Verify the DaemonSet is running on all nodes: `kubectl get daemonset -n kube-system node-local-dns`
2. Confirm iptables rules are set up on the affected node (SSH to the node):
   ```bash
   iptables -t raw -L OUTPUT -n | grep 10.43.0.10
   iptables -t nat -L PREROUTING -n | grep 10.43.0.10
   ```
   Both should show rules redirecting port 53 traffic to `169.254.20.11`.
3. If rules are missing, the pod may have restarted without teardown. Check pod logs:
   ```bash
   kubectl logs -n kube-system -l k8s-app=node-local-dns --tail=50
   ```

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

**NodeLocal link-local IP is `169.254.20.11`, not `169.254.20.10`.**
The official Kubernetes documentation and most community guides reference `169.254.20.10`. This cluster uses the lablabs Helm chart which defaults to `169.254.20.11`. Substitute accordingly when following external troubleshooting guides.

**`*.diceninjagaming.com` always resolves to `192.168.5.202` — this is correct.**
Pi-hole has a wildcard DNS record pointing all `*.diceninjagaming.com` subdomains to the Traefik ingress IP. Any pod querying a `diceninjagaming.com` hostname will receive `192.168.5.202`, which is the correct and intended behaviour. This is only a problem if a `diceninjagaming.com` DNS response gets delivered to a pod that queried a different hostname (see conntrack race condition above).

**CoreDNS is managed by the k3s addon controller, not ArgoCD.**
The CoreDNS `Deployment` in `kube-system` is owned by k3s's `objectset.rio.cattle.io` addon controller. Direct edits via `kubectl` or ArgoCD patches will be reverted. Changes to CoreDNS configuration must go through a `coredns-custom` ConfigMap (for Corefile changes) or the addon manifest on the server node at `/var/lib/rancher/k3s/server/manifests/`. See the k3s docs for details.

**If the NodeLocal DaemonSet pod crashes, DNS fails for all pods on that node.**
The `system-node-critical` priority class and DaemonSet restart policy keep the recovery window short, but there is no redundancy at the per-node level. Monitor `kubectl get pods -n kube-system -l k8s-app=node-local-dns` as part of any incident investigation involving DNS failures on a specific node.

**Removing NodeLocal DNSCache leaves iptables rules behind.**
The chart defaults to `skipTeardown: true`. If the DaemonSet is deleted (e.g. by ArgoCD prune), iptables rules that redirect DNS traffic to `169.254.20.11` will remain on each node until manually removed or the node is rebooted. DNS will fail on those nodes until cleaned up. To manually remove the rules, either reboot the node or identify and delete the relevant `iptables -t raw` and `iptables -t nat` rules pointing at `169.254.20.11`.
