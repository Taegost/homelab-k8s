#!/bin/bash
# longhorn-pvc-report.sh
#
# Prints a utilisation report for every Longhorn PVC in the cluster,
# sorted highest-to-lowest by % used. Useful for spotting volumes that
# are approaching their limit before they cause application failures.
#
# Usage:
#   ./scripts/longhorn-pvc-report.sh
#
# No arguments. Requires kubectl to be configured and pointed at the cluster.
#
# How it works:
#   Longhorn exposes Prometheus metrics at :9500/metrics on each longhorn-manager
#   pod. However, each manager only reports metrics for volumes attached to its
#   own node — querying a single pod will silently miss volumes on other nodes.
#   This script loops through all manager pods and concatenates their output so
#   the report is always complete regardless of scheduling.
#
# Metrics used:
#   longhorn_volume_actual_size_bytes — total blocks written at the storage layer
#   longhorn_volume_capacity_bytes    — provisioned PVC size
#
# Important: "actual size" reflects block-layer usage, not filesystem usage.
# Deleted files free space at the filesystem level but Longhorn still counts
# those blocks as used until an fstrim is issued. The recurring trim job in
# apps/longhorn/recurringjob-filesystem-trim.yaml handles this automatically.
# A large gap between this report and `du` output inside a container is normal
# on volumes that haven't been trimmed recently.

set -euo pipefail

# Print the header outside the awk pipeline so sort only operates on data rows
printf "%-30s %-15s %9s %9s %7s\n" "PVC" "NAMESPACE" "USED(Gi)" "CAP(Gi)" "%USED"
printf "%-30s %-15s %9s %9s %7s\n" "---" "---------" "--------" "-------" "-----"

# Collect metrics from every longhorn-manager pod and pipe the combined output
# into a single awk pass. Volumes appearing in multiple pods' output (e.g. during
# replica rebalancing) are handled by overwriting with the last seen value, which
# is safe since capacity is constant and actual size is per-attachment.
for POD in $(kubectl get pods -n longhorn-system -l app=longhorn-manager \
  -o jsonpath='{.items[*].metadata.name}'); do
  kubectl exec -n longhorn-system "$POD" -- \
    curl -s http://longhorn-backend:9500/metrics 2>/dev/null
done | awk '
  /^longhorn_volume_actual_size_bytes\{/ {
    # Extract the pvc and pvc_namespace label values using POSIX match() +
    # substr(). The three-argument form of match() is gawk-only and will fail
    # on mawk (the default awk on many systems). RSTART and RLENGTH are set by
    # match() and give us the position and length of the matched string, letting
    # us slice out just the label value without a gawk dependency.
    #
    # Offset for pvc="...":           skip 5 chars (pvc=") + trim 1 trailing "
    # Offset for pvc_namespace="...": skip 15 chars + trim 1 trailing "
    match($0, /pvc="[^"]+"/)
    pvc = substr($0, RSTART+5, RLENGTH-6)
    match($0, /pvc_namespace="[^"]+"/)
    ns = substr($0, RSTART+15, RLENGTH-16)
    actual[pvc, ns] = $NF
  }
  /^longhorn_volume_capacity_bytes\{/ {
    match($0, /pvc="[^"]+"/)
    pvc = substr($0, RSTART+5, RLENGTH-6)
    match($0, /pvc_namespace="[^"]+"/)
    ns = substr($0, RSTART+15, RLENGTH-16)
    cap[pvc, ns] = $NF
  }
  END {
    for (key in cap) {
      split(key, parts, SUBSEP)
      pvc = parts[1]; ns = parts[2]
      pct = (actual[key]+0) / cap[key] * 100
      printf "%-30s %-15s %9.2f %9.2f %6.1f\n", \
        pvc, ns, actual[key]/1073741824, cap[key]/1073741824, pct
    }
  }
' | sort -k5 -rn