#!/usr/bin/env bash
# Verify IngressRoute consistency rules.
# Usage: ./ingressroute-check.sh
set -euo pipefail

echo "=== IngressRoute Consistency ==="

# Internal routes in traefik namespace — must have default-whitelist middleware
internal_missing=$(git diff --cached --name-only | xargs -r grep -l "namespace: traefik" 2>/dev/null | xargs -r grep -L "default-whitelist" 2>/dev/null || true)
if [ -n "$internal_missing" ]; then
  echo "FAIL: internal IngressRoute(s) missing default-whitelist middleware:"
  echo "$internal_missing"
  exit 1
fi

# Public routes NOT in traefik namespace — must NOT have whitelist middleware
public_with_whitelist=$(git diff --cached --name-only | xargs -r grep -l "kind: IngressRoute" 2>/dev/null | xargs -r grep -L "namespace: traefik" 2>/dev/null | xargs -r grep -l "whitelist" 2>/dev/null || true)
if [ -n "$public_with_whitelist" ]; then
  echo "FAIL: public IngressRoute(s) have whitelist middleware (remove it):"
  echo "$public_with_whitelist"
  exit 1
fi

# Internal routes should NOT have a per-app Certificate
internal_certs=$(git diff --cached --name-only | grep "certificate-.*\.yaml" 2>/dev/null || true)
if [ -n "$internal_certs" ]; then
  echo "  WARN: per-app Certificate(s) found — verify matching IngressRoute is NOT in traefik namespace"
  echo "$internal_certs"
fi

echo "PASS: IngressRoute consistency"
