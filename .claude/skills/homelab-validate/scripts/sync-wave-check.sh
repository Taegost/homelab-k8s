#!/usr/bin/env bash
# Check which staged YAML files are missing sync-wave annotations.
# Only resources needing NON-DEFAULT sync order require the annotation.
# Wave 0 is ArgoCD's default — resources at wave 0 should OMIT it.
# Usage: ./sync-wave-check.sh
set -euo pipefail

echo "=== Sync Wave Check ==="

missing=$(git diff --cached --name-only | grep -E '\.(yaml|yml)$' | xargs -r grep -L "sync-wave" 2>/dev/null || true)

if [ -z "$missing" ]; then
  echo "PASS: all staged YAML files have sync-wave annotations"
  exit 0
fi

echo "$missing" | while read -r f; do
  kind=$(grep -m1 "kind:" "$f" 2>/dev/null | awk '{print $2}' || echo "unknown")

  case "$kind" in
    SealedSecret)
      echo "  NEEDS WAVE (-3): $f"
      ;;
    PerconaServerMongoDB|User|Grant)
      echo "  NEEDS WAVE (-2): $f"
      ;;
    Database)
      echo "  NEEDS WAVE (-1): $f"
      ;;
    Deployment|Service|IngressRoute|PersistentVolumeClaim|ConfigMap|NetworkPolicy|Certificate)
      echo "  OK (wave 0): $f — default wave, annotation not needed"
      ;;
    *)
      echo "  NO WAVE: $f (kind=$kind — review whether annotation needed)"
      ;;
  esac
done

echo ""
echo "Legend:"
echo "  NEEDS WAVE (-3): SealedSecrets — add in BOTH metadata.annotations AND spec.template.metadata.annotations"
echo "  NEEDS WAVE (-2): Cross-namespace secret consumers (User CRD, PerconaServerMongoDB)"
echo "  NEEDS WAVE (-1): CNPG Database CRDs"
echo "  OK (wave 0):    App-level resources — OMIT annotation (ArgoCD default)"

# Only fail if there are NEEDS WAVE items (not OK wave 0 items)
if echo "$missing" | xargs -r grep -lE "kind: (SealedSecret|PerconaServerMongoDB|User|Grant|Database)" 2>/dev/null | grep -q .; then
  exit 1
fi

exit 0
