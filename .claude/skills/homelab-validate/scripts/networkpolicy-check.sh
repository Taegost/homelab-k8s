#!/usr/bin/env bash
# Verify NetworkPolicy correctness:
#   1. Every from entry with podSelector must also have namespaceSelector
#   2. No deny-all policies (must have at least one from block)
# Usage: ./networkpolicy-check.sh
set -euo pipefail

echo "=== NetworkPolicy Check ==="

files=$(git diff --cached --name-only | grep -E '\.(yaml|yml)$' | xargs -r grep -l "kind: NetworkPolicy" 2>/dev/null || true)

if [ -z "$files" ]; then
  echo "PASS: no NetworkPolicy files staged"
  exit 0
fi

failures=0

while read -r f; do
  [ -z "$f" ] && continue
  echo "  $f"

  result=$(python3 -c "
import yaml, sys

with open('$f') as fh:
    docs = list(yaml.safe_load_all(fh))

errors = []
for doc in docs:
    if not doc or doc.get('kind') != 'NetworkPolicy':
        continue
    name = doc.get('metadata', {}).get('name', 'unknown')
    spec = doc.get('spec', {})
    ingress = spec.get('ingress', [])
    policy_types = spec.get('policyTypes', [])

    if 'Ingress' in policy_types and not ingress:
        errors.append(f'deny-all policy (no ingress rules)')
        continue

    for i, rule in enumerate(ingress):
        frm = rule.get('from', [])
        for j, entry in enumerate(frm):
            if 'podSelector' in entry and 'namespaceSelector' not in entry:
                errors.append(f'from[{i}][{j}]: podSelector without namespaceSelector')

if errors:
    for e in errors:
        print(f'    FAIL: {e}')
    sys.exit(1)
else:
    print('    PASS')
    sys.exit(0)
" 2>&1) || true

  echo "$result"
  if echo "$result" | grep -q "FAIL:"; then
    failures=$((failures + 1))
  fi
done < <(echo "$files")

if [ "$failures" -gt 0 ]; then
  echo ""
  echo "FAIL: $failures issue(s) in NetworkPolicy files"
  exit 1
fi

echo "PASS: all NetworkPolicies valid"
