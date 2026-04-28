# Archived

This directory contains Kubernetes manifests and Helm values for components that were
evaluated, partially or fully deployed, and then deliberately removed from the cluster.

Code is kept here rather than deleted so that:
- The reasoning behind the decision is preserved alongside the implementation
- The manifests can be recovered quickly if circumstances change
- Future operators can see what was tried and why it was abandoned

Nothing in this directory is applied to the cluster. ArgoCD only watches `apps/manifests/`
and the directories referenced from it — files here are invisible to it.

---

## Contents

### `nodelocaldns/`

**What it is:** NodeLocal DNSCache — a DaemonSet that runs a DNS cache agent on every node,
intercepting DNS queries via iptables before they reach the CoreDNS ClusterIP. Intended to
eliminate the Linux conntrack race condition that can cause intermittent DNS resolution
failures in k3s clusters.

**Why it was removed:** After a thorough DNS incident investigation during the Authentik
migration, the conntrack race condition turned out not to be the root cause of the symptoms
observed. The actual issue was a node-level `resolv.conf` search domain (`home.diceninjagaming.com`)
that caused cluster-internal FQDNs to match a Pi-hole wildcard before their absolute form
was tried. See [docs/troubleshooting.md](../docs/troubleshooting.md) for the full account.

Additionally, the lablabs Helm chart (`lablabs.github.io/k8s-nodelocaldns-helm`) does not
fully configure itself: it deploys the agent and sets up NOTRACK iptables rules for the
link-local IP (`169.254.20.11`), but pods still receive `10.43.0.10` (CoreDNS ClusterIP) in
their `resolv.conf`. Making it effective requires configuring the k3s kubelet with
`cluster-dns=169.254.20.11` on every node — an out-of-band, non-GitOps step. A component
that appears healthy in ArgoCD but provides no actual protection is worse than not having it.

**If you want to restore it:** See `archived/nodelocaldns/argocd-application.yaml` and
`archived/nodelocaldns/values.yaml`. Move them back to `apps/manifests/nodelocaldns.yaml`
and `apps/nodelocaldns/values.yaml`, then configure the kubelet on every node before
expecting it to be effective.
