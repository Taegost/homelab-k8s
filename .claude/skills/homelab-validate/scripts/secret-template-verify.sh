#!/usr/bin/env bash
# Verify plaintext secret templates before signing off on work.
# secret-*.yaml files are gitignored — check the filesystem directly.
# Usage: ./secret-template-verify.sh [directory]
set -euo pipefail

search_dir="${1:-.}"

echo "=== Secret Template Verification ==="

secrets=$(find "$search_dir" -name 'secret-*.yaml' -not -path '*/.git/*' -not -name 'sealedsecret-*' 2>/dev/null || true)

if [ -z "$secrets" ]; then
  echo "PASS: no plaintext secret files found"
  exit 0
fi

failures=0

# Process substitution (&lt;(...)) avoids the pipeline subshell — failures++
# must survive the loop to be checked after it completes.
while read -r f; do
  echo "--- $f ---"

  # Check 1: sync-wave in metadata.annotations
  if grep -A10 '^metadata:' "$f" | grep -q 'argocd.argoproj.io/sync-wave'; then
    echo "  PASS: sync-wave in metadata.annotations"
  else
    echo "  FAIL: missing sync-wave in metadata.annotations"
    failures=$((failures + 1))
  fi

  # Check 2: sync-wave in spec.template.metadata.annotations (for sealed output)
  if grep -A30 '^spec:' "$f" | grep -q 'argocd.argoproj.io/sync-wave'; then
    echo "  PASS: sync-wave in spec.template.metadata.annotations"
  else
    echo "  FAIL: missing sync-wave in spec.template.metadata.annotations"
    failures=$((failures + 1))
  fi

  # Check 3: no dots or dashes in placeholder values
  if grep -Po '(your[_-][^"'"'"'\n]*[.-][^"'"'"'\n]*)' "$f" 2>/dev/null | grep -q .; then
    echo "  FAIL: placeholder values contain dots or dashes — use underscores only"
    failures=$((failures + 1))
  else
    echo "  PASS: placeholder format"
  fi

  # Check 4: required fields
  if grep -q '^  name:' "$f"; then
    echo "  PASS: has name field"
  else
    echo "  FAIL: missing name field"
    failures=$((failures + 1))
  fi

  if grep -q '^  namespace:' "$f"; then
    echo "  PASS: has namespace field"
  else
    echo "  FAIL: missing namespace field"
    failures=$((failures + 1))
  fi
done < <(echo "$secrets")

if [ "$failures" -gt 0 ]; then
  echo ""
  echo "FAIL: $failures issue(s) in secret templates — fix before signing off"
  exit 1
fi

echo ""
echo "PASS: all secret templates verified"
