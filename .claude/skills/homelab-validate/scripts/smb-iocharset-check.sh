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
#
# Paths are NUL-delimited (`-z` + `grep -z`) and held in a bash array: plain
# `--name-only` output QUOTES non-ASCII filenames (e.g. "caf\303\251.yaml"),
# and the trailing quote breaks the `\.(yaml|yml)$` anchor, silently skipping
# the file. NUL is the only separator git guarantees cannot appear in a path,
# and a scalar string cannot hold NUL separators — hence array.
files=()
while IFS= read -r -d '' f; do
  # grep -F, NOT -q: -q exits on first match and closes the pipe early, so
  # git show takes SIGPIPE on large blobs — under pipefail that reads as a
  # pipeline failure and the matched file is dropped. Plain grep consumes the
  # whole blob; -F keeps the driver string literal so its dots cannot match
  # arbitrary characters.
  if git show ":$f" 2>/dev/null | grep -F "smb.csi.k8s.io" >/dev/null; then
    files+=("$f")
  fi
done < <(git diff --cached --name-only -z --diff-filter=ACMR | grep -zE '\.(yaml|yml)$' || true)

if [ ${#files[@]} -eq 0 ]; then
  echo "PASS: no SMB storage manifests in this change"
  exit 0
fi

failures=0

# Iterate the prefilter array directly — no subshell, so failures++ below
# survives the loop; the ${#files[@]} guard above means the array is
# non-empty here (empty-array expansion under `set -u` never runs).
for f in "${files[@]}"; do
  echo "  $f"

  # Pipe the staged blob into python (reads stdin). rc captures placement
  # FAIL (python exits 1) AND infrastructure failures (missing PyYAML,
  # unreadable blob) — any nonzero exit counts as a failure, so the check
  # can never report PASS for work it did not run.
  rc=0
  result=$(git show ":$f" | python3 -c "
import sys, yaml

docs = []
# Flatten kind: List bundles first — a List wrapping an SMB manifest would
# otherwise be skipped by the per-kind checks below. Empty docs (blank YAML
# segments) are dropped, and an empty/missing items list yields nothing.
# No backticks in these comments: they sit inside bash double quotes, and
# bash command-substitutes backticks before python ever sees the code.
for doc in yaml.safe_load_all(sys.stdin):
    if not doc:
        continue
    if doc.get('kind') == 'List':
        docs.extend(item for item in (doc.get('items') or []) if item)
    else:
        docs.append(doc)

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
done

if [ "$failures" -gt 0 ]; then
  echo ""
  echo "FAIL: $failures staged file(s) with SMB mounts missing iocharset=utf8"
  exit 1
fi

echo "PASS: all SMB storage manifests mount with iocharset=utf8"
