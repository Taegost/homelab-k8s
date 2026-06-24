---
module: metallb
tags: [metallb, networkpolicy, egress, hairpin, traefik, litellm]
problem_type: runtime-error
---

# MetalLB L2 hairpin breaks NetworkPolicy egress to LoadBalancer services

## Problem

A pod inside the cluster tries to reach a service via its external domain
(e.g., `litellm.diceninjagaming.com`), which resolves to a MetalLB LoadBalancer
IP (`192.168.5.202`). The connection fails with `ECONNREFUSED` even though the
NetworkPolicy egress rule allows traffic to that IP on port 443.

## Root Cause

MetalLB in L2 mode advertises the LoadBalancer IP via ARP on the local network.
When a pod on the same node connects to that IP, the traffic hairpins:

```
Pod → node NIC → MetalLB ARP → back to same node → Traefik pod
```

This hairpin path bypasses kube-proxy's iptables/nftables chains. The traffic
never hits the `namespaceSelector` or `podSelector` matching logic that
NetworkPolicy relies on. The CNI plugin (or kube-proxy) drops the packet.

Using an `ipBlock` egress rule for the MetalLB IP doesn't help — the packet
is dropped before the egress rule is evaluated, because the hairpin path
circumvents the normal routing flow.

## Solution

Replace the `ipBlock` egress rule with a `namespaceSelector` targeting the
namespace where the LoadBalancer's backend pods run (typically `traefik`).
kube-proxy routes the traffic internally via ClusterIP, bypassing the MetalLB
hairpin entirely.

**Wrong** — ipBlock for MetalLB IP (hairpin fails):

```yaml
egress:
  - to:
      - ipBlock:
          cidr: 192.168.5.202/32
    ports:
      - protocol: TCP
        port: 443
```

**Right** — namespaceSelector for traefik (hairpin-safe):

```yaml
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: traefik
    ports:
      - protocol: TCP
        port: 443
```

## Verification

```bash
# Test from the affected pod — should return 200 (or 401 for auth), not ECONNREFUSED
kubectl exec -n <namespace> <pod> -- python3 -c "
import urllib.request
try:
    r = urllib.request.urlopen('https://litellm.diceninjagaming.com/v1/models', timeout=10)
    print('Status:', r.status)
except Exception as e:
    print('Error:', e)
"
```

## When This Applies

- Any pod that reaches a service via its external domain, where the domain
  resolves to a MetalLB LoadBalancer IP on the same subnet as the cluster nodes
- When the app has a default-deny egress NetworkPolicy with explicit allow rules
- When the `ipBlock` approach produces `ECONNREFUSED` but the service is running

## References

- [MetalLB Concepts](https://metallb.universe.tf/concepts/) — L2 mode and ARP behavior
- `apps/honcho/networkpolicy-honcho-api.yaml` — working example with namespaceSelector
- `apps/honcho/networkpolicy-honcho-deriver.yaml` — working example with namespaceSelector
- `docs/solutions/conventions/honcho-deployment-patterns.md` — Section 2 (LiteLLM routing)
