#!/usr/bin/env bash
# Check that Deployments mounting Longhorn PVCs have fsGroup set.
# fsGroup is required when the container runs as non-root.
# Usage: ./longhorn-fsgroup-check.sh
set -euo pipefail

echo "=== Longhorn PVC fsGroup Check ==="

longhorn_pvcs=$(git diff --cached --name-only | grep -E '\.(yaml|yml)$' | xargs -r grep -l "storageClassName: longhorn" 2>/dev/null || true)

if [ -z "$longhorn_pvcs" ]; then
  echo "PASS: no Longhorn PVCs in this change"
  exit 0
fi

failures=0

echo "$longhorn_pvcs" | while read -r pvc_file; do
  claim_name=$(grep "name:" "$pvc_file" | head -1 | awk '{print $2}')
  echo "  PVC: $pvc_file ($claim_name)"

  # Find Deployment that mounts this PVC
  dep=$(git diff --cached --name-only | xargs -r grep -l "kind: Deployment" 2>/dev/null | xargs -r grep -l "$claim_name" 2>/dev/null || true)

  if [ -z "$dep" ]; then
    echo "    WARN: no Deployment found mounting this PVC in staged changes"
    continue
  fi

  # Check if container runs as non-root
  if grep -A50 'containers:' "$dep" | grep -q 'runAsNonRoot: true\|runAsUser: [1-9]'; then
    # Non-root — fsGroup required
    if grep -q 'fsGroup:' "$dep"; then
      echo "    PASS: fsGroup set (container is non-root)"
    else
      echo "    FAIL: $dep — non-root container mounts Longhorn PVC but fsGroup is missing"
      failures=$((failures + 1))
    fi
  else
    echo "    PASS: container runs as root, fsGroup not needed"
  fi
done

if [ "$failures" -gt 0 ]; then
  echo ""
  echo "FAIL: $failures deployment(s) missing fsGroup"
  exit 1
fi

echo "PASS: Longhorn fsGroup check"
