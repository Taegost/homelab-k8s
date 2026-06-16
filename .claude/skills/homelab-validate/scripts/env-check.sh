#!/usr/bin/env bash
# Warn when Deployments have missing or empty envFrom/env blocks.
# Checks main containers only (skips initContainers).
# All findings are WARN — never blocks commits. Exit code always 0.
# Usage: ./env-check.sh
set -euo pipefail

echo "=== Env Check ==="

files=$(git diff --cached --name-only | grep -E '\.(yaml|yml)$' | xargs -r grep -l "kind: Deployment" 2>/dev/null || true)

if [ -z "$files" ]; then
  echo "SKIP: no Deployments staged"
  exit 0
fi

warn_count=0

while read -r f; do
  [ -z "$f" ] && continue
  echo "  $f"

  result=$(python3 -c "
import yaml, sys

with open('$f') as fh:
    docs = list(yaml.safe_load_all(fh))

for doc in docs:
    if not doc or doc.get('kind') != 'Deployment':
        continue
    spec = doc.get('spec', {})
    template = spec.get('template', {})
    pod_spec = template.get('spec', {})
    containers = pod_spec.get('containers', [])
    # Skip initContainers — they legitimately have no env injection

    for container in containers:
        cname = container.get('name', 'unknown')
        has_envfrom = 'envFrom' in container and container['envFrom']
        has_env = 'env' in container and container['env']

        if has_envfrom:
            print(f'    PASS: container \x27{cname}\x27 — has envFrom')
        elif has_env:
            print(f'    PASS: container \x27{cname}\x27 — has env')
        else:
            print(f'    WARN: container \x27{cname}\x27 — no envFrom or env blocks')
" 2>&1) && rc=0 || rc=$?

  echo "$result"
  if [ "$rc" -ne 0 ]; then
    echo "    ERROR: script crashed (exit code $rc)"
  elif echo "$result" | grep -q "WARN:"; then
    warn_count=$((warn_count + 1))
  fi
done < <(echo "$files")

if [ "$warn_count" -gt 0 ]; then
  echo ""
  echo "WARN: $warn_count file(s) with missing env injection (non-blocking)"
fi

# Always exit 0 — this check never blocks commits
exit 0
