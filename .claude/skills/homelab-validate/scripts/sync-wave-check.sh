#!/usr/bin/env bash
# Check which staged YAML files are missing sync-wave annotations.
# Usage: ./sync-wave-check.sh
set -euo pipefail

echo "=== Sync Wave Check ==="

missing=$(git diff --cached --name-only | grep -E '\.(yaml|yml)$' | xargs -r grep -L "sync-wave" 2>/dev/null || true)

if [ -z "$missing" ]; then
  echo "PASS: all staged YAML files have sync-wave annotations"
  exit 0
fi

echo "$missing" | while read -r f; do
  echo "  NO WAVE: $f"
done

echo ""
echo "For each file above, decide:"
echo "  - References a Secret (secretKeyRef, passwordSecretRef, secretName)? → add wave"
echo "  - Is a CRD that consumes a SealedSecret? → add wave"
echo "  - Is a SealedSecret itself? → add wave in BOTH metadata.annotations AND spec.template.metadata.annotations"
echo "  - Pure config, no dependencies? → safe to omit"

exit 1
