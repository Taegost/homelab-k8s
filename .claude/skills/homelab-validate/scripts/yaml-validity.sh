#!/usr/bin/env bash
# Validate YAML syntax for all staged YAML files.
# Usage: ./yaml-validity.sh
set -euo pipefail

echo "=== YAML Validity ==="
failures=0

files=$(git diff --cached --name-only | grep -E '\.(yaml|yml)$' || true)

if [ -z "$files" ]; then
  echo "PASS: no YAML files staged"
  exit 0
fi

# Process substitution (&lt;(...)) avoids the pipeline subshell — failures++
# must survive the loop to be checked after it completes.
while read -r f; do
  echo -n "  $f ... "
  if python3 -c "import yaml; list(yaml.safe_load_all(open('$f')))" 2>&1; then
    echo "OK"
  else
    echo "FAIL"
    failures=$((failures + 1))
  fi
done < <(echo "$files")

if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures file(s) have invalid YAML"
  exit 1
fi

echo "PASS: all YAML files valid"
