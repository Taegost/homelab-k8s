#!/bin/bash
# longhorn-node-replicas.sh
#
# Lists every Longhorn replica scheduled on a given node, alongside the
# owning PVC's namespace, name, provisioned size, and actual (block-level)
# usage. Built for identifying rebalancing candidates when replica count is
# skewed across nodes (see scripts/longhorn-pvc-report.sh for %-used-based
# reporting instead — this script is about *where* replicas live, not how
# full they are).
#
# Usage:
#   ./scripts/longhorn-node-replicas.sh <node-name>
#
# Requires kubectl configured against the cluster and jq installed.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <node-name>" >&2
  exit 1
fi
NODE="$1"

# Pull PVC identity and size fields straight from the Volume CR's status —
# Longhorn writes the owning namespace/PVC name to status.kubernetesStatus,
# and status.actualSize is already in bytes at the block layer (same figure
# the UI shows), so no per-pod metrics scraping is needed here.
kubectl -n longhorn-system get volumes.longhorn.io -o json \
  | jq -r '.items[] | [
      .metadata.name,
      (.status.kubernetesStatus.namespace // "-"),
      (.status.kubernetesStatus.pvcName // "-"),
      (.spec.size // 0),
      (.status.actualSize // 0)
    ] | @tsv' \
  | sort > /tmp/vol-info.tsv

# Replicas actually placed on the target node, with their live rebuild state —
# this is what tells you whether a replica is safe to delete right now
# (currentState: running) or already mid-rebuild (leave it alone).
kubectl -n longhorn-system get replicas.longhorn.io -o json \
  | jq -r --arg n "$NODE" '.items[] | select(.spec.nodeID==$n)
      | [.spec.volumeName, .metadata.name, .status.currentState] | @tsv' \
  | sort > /tmp/reps-on-node.tsv

# Join on volume name (the shared key), then drop it from the printed output —
# namespace/PVC identify the volume just as well for this purpose, and the
# raw Longhorn volume name (pvc-<uuid>) doesn't help decide what to reschedule.
#
# Sort BEFORE the awk formatting pass, not after — sorting the final printed
# table would alphabetize the header row right back into the data (e.g.
# "NAMESPACE" and "---------" sort in among real namespace names). Sorting
# the raw TSV first means awk's header is the only thing printed pre-sorted,
# at the top, once.
join -t $'\t' /tmp/reps-on-node.tsv /tmp/vol-info.tsv \
  | sort -t $'\t' -k4,4 -k5,5 \
  | awk -F'\t' '
    BEGIN {
      printf "%-15s %-30s %10s %10s %-40s %-10s\n", \
        "NAMESPACE", "PVC", "SIZE(Gi)", "USED(Gi)", "REPLICA", "REPSTATE"
      printf "%-15s %-30s %10s %10s %-40s %-10s\n", \
        "---------", "---", "--------", "--------", "-------", "--------"
    }
    {
      # Post-join field order: 1=volumeName(key) 2=replica 3=repstate
      #                        4=namespace 5=pvc 6=size 7=actualSize
      size_gi   = $6 / 1073741824
      actual_gi = $7 / 1073741824
      printf "%-15s %-30s %10.2f %10.2f %-40s %-10s\n", \
        $4, $5, size_gi, actual_gi, $2, $3
    }'
    