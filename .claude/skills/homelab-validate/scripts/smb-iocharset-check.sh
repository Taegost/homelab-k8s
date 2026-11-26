#!/usr/bin/env bash
# Verify SMB storage manifests mount with iocharset=utf8:
#   1. StorageClass with provisioner smb.csi.k8s.io — option must be in the
#      TOP-LEVEL mountOptions list. StorageClass has no spec field; an option
#      nested under spec.mountOptions silently does nothing.
#   2. PersistentVolume with csi.driver smb.csi.k8s.io — option must be in
#      spec.mountOptions. A top-level mountOptions on a PV is silently
#      ignored.
# Non-SMB storage manifests are never flagged.
# Usage: ./smb-iocharset-check.sh
set -euo pipefail

echo "=== SMB iocharset Check ==="

# Prefilter: any staged YAML mentioning the SMB driver (covers both the
# StorageClass `provisioner:` line and the PV `csi.driver:` line). Kind and
# placement are validated per document below.
files=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(yaml|yml)$' | xargs -r grep -l "smb.csi.k8s.io" 2>/dev/null || true)

if [ -z "$files" ]; then
  echo "PASS: no SMB storage manifests in this change"
  exit 0
fi

failures=0

# Process substitution (<(...)) avoids the pipeline subshell — failures++
# must survive the loop to be checked after it completes.
while read -r f; do
  [ -z "$f" ] && continue
  echo "  $f"

  result=$(python3 -c "
import sys, yaml

with open(sys.argv[1]) as fh:
    docs = list(yaml.safe_load_all(fh))

errors = []
for doc in docs:
    if not doc:
        continue
    kind = doc.get('kind')
    if kind == 'StorageClass':
        if doc.get('provisioner') != 'smb.csi.k8s.io':
            continue
        name = doc.get('metadata', {}).get('name', 'unknown')
        opts = doc.get('mountOptions') or []
        if 'iocharset=utf8' not in opts:
            errors.append(
                f'StorageClass/{name}: iocharset=utf8 missing from top-level'
                ' mountOptions (StorageClass has no spec — an option nested'
                ' under spec.mountOptions silently does nothing)')
    elif kind == 'PersistentVolume':
        spec = doc.get('spec') or {}
        if (spec.get('csi') or {}).get('driver') != 'smb.csi.k8s.io':
            continue
        name = doc.get('metadata', {}).get('name', 'unknown')
        opts = spec.get('mountOptions') or []
        if 'iocharset=utf8' not in opts:
            errors.append(
                f'PersistentVolume/{name}: iocharset=utf8 missing from'
                ' spec.mountOptions (a top-level mountOptions on a PV is'
                ' silently ignored)')

if errors:
    for e in errors:
        print(f'    FAIL: {e}')
    sys.exit(1)
else:
    print('    PASS')
    sys.exit(0)
" 2>&1 "$f") || true

  echo "$result"
  if echo "$result" | grep -q "FAIL:"; then
    failures=$((failures + 1))
  fi
done < <(echo "$files")

if [ "$failures" -gt 0 ]; then
  echo ""
  echo "FAIL: $failures staged file(s) with SMB mounts missing iocharset=utf8"
  exit 1
fi

echo "PASS: all SMB storage manifests mount with iocharset=utf8"
