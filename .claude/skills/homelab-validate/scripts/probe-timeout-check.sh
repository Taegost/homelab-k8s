#!/usr/bin/env bash
# Verify exec probes have adequate timeoutSeconds.
# Tiered CLI lists:
#   Slow tier (FAIL if <5s): rabbitmq-diagnostics, rabbitmqctl, celery
#   Fast tier (FAIL if <2s): redis-cli, valkey-cli, pg_isready, mysqladmin, mongosh
#   Generic exec probes with missing/default timeout: WARN
# Usage: ./probe-timeout-check.sh
set -euo pipefail

echo "=== Probe Timeout Check ==="

# Fast pre-filter: only parse Deployments that contain exec probes
files=$(git diff --cached --name-only | grep -E '\.(yaml|yml)$' | xargs -r grep -l "kind: Deployment" 2>/dev/null | xargs -r grep -l 'exec:' 2>/dev/null || true)

if [ -z "$files" ]; then
  echo "SKIP: no Deployments with exec probes staged"
  exit 0
fi

failures=0

while read -r f; do
  [ -z "$f" ] && continue
  echo "  $f"

  result=$(python3 -c "
import yaml, sys

SLOW_CLIS = ['rabbitmq-diagnostics', 'rabbitmqctl', 'celery']
FAST_CLIS = ['redis-cli', 'valkey-cli', 'pg_isready', 'mysqladmin', 'mongosh']
PROBE_NAMES = ['livenessProbe', 'readinessProbe', 'startupProbe']

with open('$f') as fh:
    docs = list(yaml.safe_load_all(fh))

errors = []
for doc in docs:
    if not doc or doc.get('kind') != 'Deployment':
        continue
    spec = doc.get('spec', {})
    template = spec.get('template', {})
    pod_spec = template.get('spec', {})
    containers = pod_spec.get('containers', [])

    for container in containers:
        cname = container.get('name', 'unknown')
        for probe_name in PROBE_NAMES:
            probe = container.get(probe_name)
            if not probe:
                continue
            exec_probe = probe.get('exec')
            if not exec_probe:
                continue

            command = exec_probe.get('command', [])
            if not command:
                continue
            cmd_str = ' '.join(command) if isinstance(command, list) else str(command)

            timeout = probe.get('timeoutSeconds')
            if timeout is None:
                timeout = 1  # Kubernetes default

            # Check against tiered CLI lists
            is_slow = any(cli in cmd_str for cli in SLOW_CLIS)
            is_fast = any(cli in cmd_str for cli in FAST_CLIS)

            if is_slow and timeout < 5:
                errors.append(f'    FAIL: {probe_name} exec [{cmd_str}] — timeoutSeconds: {timeout}, known-slow CLI needs >= 5')
            elif is_fast and timeout < 2:
                errors.append(f'    FAIL: {probe_name} exec [{cmd_str}] — timeoutSeconds: {timeout}, need >= 2')
            elif not is_slow and not is_fast and timeout <= 1:
                errors.append(f'    WARN: {probe_name} exec [{cmd_str}] — timeoutSeconds: {timeout} (default), consider increasing')
            else:
                errors.append(f'    PASS: {probe_name} timeoutSeconds: {timeout}')

if errors:
    for e in errors:
        print(e)
    if any('FAIL:' in e for e in errors):
        sys.exit(1)
    else:
        sys.exit(0)
else:
    print('    PASS: no exec probes found')
    sys.exit(0)
" 2>&1) && rc=0 || rc=$?

  echo "$result"
  if [ "$rc" -ne 0 ] || echo "$result" | grep -q "FAIL:"; then
    failures=$((failures + 1))
  fi
done < <(echo "$files")

if [ "$failures" -gt 0 ]; then
  echo ""
  echo "FAIL: $failures file(s) have probe timeout issues"
  exit 1
fi

echo ""
echo "PASS: all exec probe timeouts adequate"
