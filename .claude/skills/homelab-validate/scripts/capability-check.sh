#!/usr/bin/env bash
# Verify Deployments with drop: [ALL] have required capabilities for known images.
# Reads capability requirements from docs/solutions/ KB files (auto-discovered).
# Usage: ./capability-check.sh
set -euo pipefail

echo "=== Capability Check ==="

REPO_ROOT=$(git rev-parse --show-toplevel)
KB_DIR="$REPO_ROOT/docs/solutions"

# Fast pre-filter: only parse Deployments that contain security contexts
files=$(git diff --cached --name-only | grep -E '\.(yaml|yml)$' | xargs -r grep -l "kind: Deployment" 2>/dev/null | xargs -r grep -l 'capabilities:' 2>/dev/null || true)

if [ -z "$files" ]; then
  echo "SKIP: no Deployments with capability blocks staged"
  exit 0
fi

failures=0

while read -r f; do
  [ -z "$f" ] && continue
  echo "  $f"

  result=$(python3 -c "
import yaml, sys, os, re, glob

KB_DIR = '$KB_DIR'

# --- KB auto-discovery ---
# Scan docs/solutions/base-images-*.md for image patterns and required capabilities.
# Skips root-generic.md (fallback only).
image_patterns = {}  # pattern -> type_name
type_caps = {}       # type_name -> list of capability names

for kb_path in sorted(glob.glob(os.path.join(KB_DIR, 'base-images-*.md'))):
    if 'root-generic' in kb_path:
        continue
    type_name = os.path.basename(kb_path).replace('base-images-', '').replace('.md', '')

    with open(kb_path) as kf:
        content = kf.read()

    # Extract image patterns from '## Image patterns' section
    patterns_match = re.search(
        r'^## Image patterns\s*\n(.*?)(?=\n## |\Z)',
        content,
        re.MULTILINE | re.DOTALL
    )
    if patterns_match:
        for m in re.finditer(r'\x60([^\x60]+)\x60', patterns_match.group(1)):
            pattern = m.group(1).replace('*', '')  # strip glob hints
            image_patterns[pattern] = type_name

    # Extract required capabilities from '## Required capabilities' table
    caps_match = re.search(
        r'^## Required capabilities.*?\n(.*?)(?=\n## |\Z)',
        content,
        re.MULTILINE | re.DOTALL
    )
    caps = []
    if caps_match:
        section = caps_match.group(1)
        # Check for 'None.' prose (like redis-valkey)
        if 'None.' in section:
            caps = []
        else:
            # Extract capability names from table rows: | \`CAP\` | ... |
            for m in re.finditer(r'\|\s*\x60([A-Z_]+)\x60\s*\|', section):
                caps.append(m.group(1))
    type_caps[type_name] = caps

# --- Check staged Deployments ---
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
        image = container.get('image', '')
        sc = container.get('securityContext', {})
        caps = sc.get('capabilities', {})
        drop = caps.get('drop', [])
        add = caps.get('add', [])

        # Only check when drop contains ALL
        if 'ALL' not in drop:
            continue

        # Match image against KB patterns
        matched_type = None
        for pattern, type_name in image_patterns.items():
            if pattern in image:
                matched_type = type_name
                break

        if not matched_type:
            # Unknown image — not checked (no KB entry)
            continue

        required = type_caps.get(matched_type, [])
        if not required:
            # KB says no capabilities needed (e.g., redis-valkey)
            if not add:
                errors.append(f'    PASS: container \x27{cname}\x27 ({matched_type}) — no capabilities required (non-root image)')
            else:
                errors.append(f'    WARN: container \x27{cname}\x27 ({matched_type}) — no capabilities required but has adds: {add}')
            continue

        # Check required vs added
        add_upper = [c.upper() for c in add]
        missing = [c for c in required if c not in add_upper]

        if missing:
            errors.append(f'    FAIL: container \x27{cname}\x27 ({matched_type}) — drop: [ALL] but missing: {', '.join(missing)}')
        else:
            errors.append(f'    PASS: container \x27{cname}\x27 ({matched_type}) — all required capabilities present')

if errors:
    for e in errors:
        print(e)
    if any('FAIL:' in e for e in errors):
        sys.exit(1)
    else:
        sys.exit(0)
else:
    print('    PASS: no containers with drop: [ALL] matched KB patterns')
    sys.exit(0)
" 2>&1) || true

  echo "$result"
  if echo "$result" | grep -q "FAIL:"; then
    failures=$((failures + 1))
  fi
done < <(echo "$files")

if [ "$failures" -gt 0 ]; then
  echo ""
  echo "FAIL: $failures file(s) have missing capabilities"
  exit 1
fi

echo ""
echo "PASS: all capability checks passed"
