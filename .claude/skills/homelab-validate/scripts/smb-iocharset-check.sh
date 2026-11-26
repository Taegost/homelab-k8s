#!/usr/bin/env bash
# Verify SMB storage manifests mount with iocharset=utf8:
#   1. StorageClass with provisioner smb.csi.k8s.io — option must be in the
#      TOP-LEVEL mountOptions list. StorageClass has no spec field; an option
#      nested under spec.mountOptions silently does nothing.
#   2. PersistentVolume with csi.driver smb.csi.k8s.io — option must be in
#      spec.mountOptions. A top-level mountOptions on a PV is silently
#      ignored.
# Non-SMB storage manifests are never flagged.
# Validates STAGED (index) content via `git show ":<path>"` — what will
# actually be committed — not working-tree files, so unstaged drift cannot
# mask or fake a result.
# Usage: ./smb-iocharset-check.sh
set -euo pipefail

echo "=== SMB iocharset Check ==="

# Prefilter: any staged YAML mentioning the SMB driver (covers both the
# StorageClass `provisioner:` line and the PV `csi.driver:` line). Kind and
# placement are validated per document below. Reads INDEX content via
# `git show ":<path>"`, so selection cannot be bypassed by filename or
# affected by unstaged working-tree edits.
staged=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(yaml|yml)$' || true)
files=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if git show ":$f" 2>/dev/null | grep -q "smb.csi.k8s.io"; then
    files+="$f"$'\n'
  fi
done <<< "$staged"

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

  # Pipe the staged blob into python (reads stdin). rc captures placement
  # FAIL (python exits 1) AND infrastructure failures (missing PyYAML,
  # unreadable blob) — any nonzero exit counts as a failure, so the check
  # can never report PASS for work it did not run.
  rc=0
  result=$(git show ":$f" | python3 -c "
import sys, yaml

docs = list(yaml.safe_load_all(sys.stdin))

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
" 2>&1) || rc=$?

  echo "$result"
  if [ "$rc" -ne 0 ]; then
    failures=$((failures + 1))
  fi
done < <(echo "$files")

if [ "$failures" -gt 0 ]; then
  echo ""
  echo "FAIL: $failures staged file(s) with SMB mounts missing iocharset=utf8"
  exit 1
fi

echo "PASS: all SMB storage manifests mount with iocharset=utf8"
