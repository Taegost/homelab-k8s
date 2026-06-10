#!/usr/bin/env bash
# Verify Deployments that mount Longhorn PVCs have correct securityContext:
#   1. fsGroup at pod level (needed for non-root containers)
#   2. runAsUser/runAsGroup at container level (needed when image runs as root)
#   3. fsGroup in container securityContext is invalid — must be pod-level
# Usage: ./longhorn-fsgroup-check.sh
set -euo pipefail

echo "=== Longhorn Security Context Check ==="

longhorn_pvcs=$(git diff --cached --name-only | grep -E '\.(yaml|yml)$' | xargs -r grep -l "storageClassName: longhorn" 2>/dev/null || true)

if [ -z "$longhorn_pvcs" ]; then
  echo "PASS: no Longhorn PVCs in this change"
  exit 0
fi

failures=0

# Process substitution (&lt;(...)) avoids the pipeline subshell — failures++
# must survive the loop to be checked after it completes.
while read -r pvc_file; do
  claim_name=$(grep "name:" "$pvc_file" | head -1 | awk '{print $2}')
  echo "  PVC: $pvc_file ($claim_name)"

  dep=$(git diff --cached --name-only | grep -E '\.(yaml|yml)$' | xargs -r grep -l "kind: Deployment" 2>/dev/null | xargs -r grep -l "$claim_name" 2>/dev/null || true)

  if [ -z "$dep" ]; then
    echo "    WARN: no Deployment found mounting this PVC in staged changes"
    continue
  fi

  # Check 1: pod-level fsGroup
  pod_fsgroup=$(grep -A30 'spec:' "$dep" | grep -A10 'securityContext:' | grep 'fsGroup:' || true)
  if [ -n "$pod_fsgroup" ]; then
    echo "    PASS: pod-level fsGroup set"
  else
    echo "    FAIL: $dep — pod-level fsGroup is missing (required for non-root containers on Longhorn)"
    failures=$((failures + 1))
  fi

  # Check 2: container-level fsGroup is invalid
  container_fsgroup=$(grep -A50 'containers:' "$dep" | grep -A30 'securityContext:' | grep 'fsGroup:' || true)
  if [ -n "$container_fsgroup" ]; then
    echo "    FAIL: $dep — fsGroup is set in container securityContext (must be pod-level, not container-level)"
    failures=$((failures + 1))
  fi

  # Check 3: runAsUser must be set when runAsNonRoot is true
  if grep -A50 'containers:' "$dep" | grep -A30 'securityContext:' | grep -q 'runAsNonRoot: true'; then
    has_runas=$(grep -A50 'containers:' "$dep" | grep -A30 'securityContext:' | grep -E 'runAsUser: [1-9]' || true)
    if [ -n "$has_runas" ]; then
      echo "    PASS: runAsUser set (runAsNonRoot=true)"
    else
      echo "    FAIL: $dep — runAsNonRoot: true but no runAsUser set (image may run as root, Kubernetes will reject)"
      failures=$((failures + 1))
    fi
  fi
done < <(echo "$longhorn_pvcs")

if [ "$failures" -gt 0 ]; then
  echo ""
  echo "FAIL: $failures issue(s) in securityContext"
  exit 1
fi

echo "PASS: Longhorn security context check"
