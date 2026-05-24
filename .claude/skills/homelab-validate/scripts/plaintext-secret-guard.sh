#!/usr/bin/env bash
# Block plaintext secret files from being staged.
# secret-*.yaml is gitignored — if grep matches, unstage immediately.
# Usage: ./plaintext-secret-guard.sh
set -euo pipefail

echo "=== Plaintext Secret Guard ==="

staged=$(git diff --cached --name-only | grep -E '(^|/)secret-[^/]*\.yaml$' 2>/dev/null || true)

if [ -n "$staged" ]; then
  echo "BLOCKED: plaintext secret(s) staged:"
  echo "$staged"
  echo "Unstage with: git restore --staged <file>"
  exit 1
fi

echo "CLEAN: no plaintext secrets staged"
