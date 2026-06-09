#!/usr/bin/env bash
# Check which staged YAML files are missing sync-wave annotations.
# Only resources needing NON-DEFAULT sync order require the annotation.
# Wave 0 is ArgoCD's default — resources at wave 0 should OMIT it.
# Usage: ./sync-wave-check.sh
set -euo pipefail

echo "=== Sync Wave Check ==="

STAGED=$(git diff --cached --name-only | grep -E '\.(yaml|yml)$' || true)

if [ -z "$STAGED" ]; then
  echo "PASS: no YAML files staged"
  exit 0
fi

missing=$(echo "$STAGED" | xargs -r grep -L "sync-wave" 2>/dev/null || true)

if [ -z "$missing" ]; then
  echo "PASS: all staged YAML files have sync-wave annotations"
else
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
      Deployment|Service|IngressRoute|PersistentVolumeClaim|ConfigMap|NetworkPolicy|Certificate|Job)
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
fi

# Check for wave ordering violations: a resource at wave < 0 referencing a
# ConfigMap or Secret that lacks a sync-wave annotation (implicit wave 0).
# The lower-wave resource starts first but its dependency hasn't synced yet.
echo ""
echo "=== Wave Ordering Check ==="
FAILURES=0

# Build a lookup: resource name -> file, sync-wave
# Parse the staged files for metadata.name and sync-wave annotation
declare -A RESOURCE_WAVE
while IFS= read -r f; do
  name=$(grep -A2 '^metadata:' "$f" | grep 'name:' | head -1 | awk '{print $2}' || true)
  wave=$(grep 'argocd.argoproj.io/sync-wave' "$f" | head -1 | grep -oP '"\K-?\d+' || echo "0")
  [ -n "$name" ] && RESOURCE_WAVE["$name"]="$wave"
done < <(echo "$STAGED")

# Find resources with sync-wave < 0 that reference ConfigMaps or Secrets
while IFS= read -r f; do
  wave=$(grep 'argocd.argoproj.io/sync-wave' "$f" | head -1 | grep -oP '"\K-?\d+' || echo "0")
  if [ "$wave" -ge 0 ] 2>/dev/null; then
    continue
  fi

  # Extract configMapRef and secretRef/secretKeyRef names
  refs=$(grep -E '^\s+name:\s+\S+' "$f" | grep -B1 -E '(configMapRef|secretRef|secretKeyRef)' | grep 'name:' | awk '{print $2}' || true)

  for ref in $refs; do
    ref_wave="${RESOURCE_WAVE[$ref]:-0}"
    # If referenced resource is in our change set and at a higher wave
    if [ -n "${RESOURCE_WAVE[$ref]+set}" ] && [ "$ref_wave" -gt "$wave" ] 2>/dev/null; then
      echo "  FAIL: $f (wave $wave) references $ref (wave $ref_wave)"
      echo "        $ref must be at wave $wave or earlier — referenced by lower-wave resource"
      FAILURES=$((FAILURES + 1))
    fi
  done
done < <(echo "$STAGED")

if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: no wave ordering violations"
else
  echo ""
  echo "FAIL: $FAILURES wave ordering violation(s)"
  exit 1
fi

# Only fail the overall check if there are NEEDS WAVE items (not OK wave 0 items)
if echo "$missing" | xargs -r grep -lE "kind: (SealedSecret|PerconaServerMongoDB|User|Grant|Database)" 2>/dev/null | grep -q .; then
  exit 1
fi

exit 0
