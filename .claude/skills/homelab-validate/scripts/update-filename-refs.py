#!/usr/bin/env python3
"""Update filename references after manifest renames.

Reads a mapping file of old_path -> new_path pairs (CSV) and replaces all
occurrences of each old path in tracked repository files. Handles both
full paths (apps/foo/old.yaml) and bare filenames (old.yaml).

Usage:
    # Preview changes without writing:
    python3 .claude/skills/homelab-validate/scripts/update-filename-refs.py --mapping renames.csv --dry-run

    # Apply changes:
    python3 .claude/skills/homelab-validate/scripts/update-filename-refs.py --mapping renames.csv

    # Single pair on command line:
    python3 .claude/skills/homelab-validate/scripts/update-filename-refs.py --old apps/foo/deployment.yaml --new apps/foo/deployment-foo.yaml

Mapping file format (CSV with header):
    old_path,new_path
    apps/argocd/ingressroute.yaml,apps/argocd/ingressroute-argocd.yaml
    apps/arr-stack/bazarr/deployment.yaml,apps/arr-stack/bazarr/deployment-bazarr.yaml

Exit code: 0 when successful, 1 on errors.
"""

import argparse
import csv
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Directories excluded from reference updates (historical artifacts).
EXCLUDED_DIRS = [
    ".git",
    "docs/plans",
    "docs/superpowers/plans",
    "docs/superpowers/specs",
]

# Files excluded from reference updates (multi-resource install manifests).
EXCLUDED_FILES = [
    "apps/argocd/argocd.yaml",
    "apps/cert-manager/cert-manager.yaml",
    "apps/metallb/metallb.yaml",
    "apps/sealed-secrets/sealed-secrets-controller.yaml",
]


def load_mapping(csv_path: Path) -> list[tuple[str, str]]:
    """Load old->new path pairs from a CSV file."""
    pairs = []
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            old = row.get("old_path", "").strip()
            new = row.get("new_path", "").strip()
            if old and new:
                pairs.append((old, new))
    return pairs


def is_excluded(rel_path: str) -> bool:
    """Check if a file path should be excluded from updates."""
    for excluded in EXCLUDED_FILES:
        if rel_path == excluded:
            return True
    for excluded_dir in EXCLUDED_DIRS:
        if rel_path.startswith(excluded_dir + "/") or rel_path == excluded_dir:
            return True
    return False


def find_replaceable_files() -> list[Path]:
    """Find all text files in the repo that can be searched and replaced."""
    files = []
    for path in REPO_ROOT.rglob("*"):
        if path.is_symlink() or path.is_dir():
            continue

        try:
            rel = str(path.relative_to(REPO_ROOT))
        except ValueError:
            continue

        if is_excluded(rel):
            continue

        # Skip binary and generated files
        if path.suffix in {".png", ".jpg", ".jpeg", ".gif", ".ico", ".woff", ".woff2",
                           ".ttf", ".eot", ".otf", ".zip", ".tar", ".gz", ".bz2",
                           ".pdf", ".mp3", ".mp4", ".webm", ".ogg"}:
            continue

        # Skip node_modules and similar dependency dirs
        if any(part in {"node_modules", "__pycache__", ".venv", "vendor"}
               for part in path.parts):
            continue

        files.append(path)

    return sorted(files)


def replace_in_file(path: Path, old: str, new: str, dry_run: bool) -> int:
    """Replace all occurrences of old with new in a file. Returns count of replacements."""
    try:
        with open(path) as f:
            content = f.read()
    except (UnicodeDecodeError, PermissionError):
        return 0

    count = content.count(old)
    if count == 0:
        return 0

    if not dry_run:
        new_content = content.replace(old, new)
        with open(path, "w") as f:
            f.write(new_content)

    return count


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Update filename references after manifest renames"
    )
    parser.add_argument(
        "--mapping", type=Path,
        help="CSV file with old_path,new_path columns"
    )
    parser.add_argument(
        "--old", action="append", default=[],
        help="Single old path (repeatable, use with --new)"
    )
    parser.add_argument(
        "--new", action="append", default=[],
        help="Single new path (repeatable, use with --old)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Preview changes without writing files"
    )
    args = parser.parse_args()

    pairs: list[tuple[str, str]] = []

    if args.mapping:
        pairs.extend(load_mapping(args.mapping))

    if args.old or args.new:
        if len(args.old) != len(args.new):
            print("ERROR: --old and --new must have the same count", file=sys.stderr)
            return 1
        pairs.extend(zip(args.old, args.new))

    if not pairs:
        print("ERROR: no mappings provided. Use --mapping or --old/--new.", file=sys.stderr)
        parser.print_help()
        return 1

    files = find_replaceable_files()
    total_replacements = 0

    if args.dry_run:
        print("DRY RUN — no files will be modified.\n")

    for old, new in pairs:
        pair_total = 0
        old_bare = Path(old).name
        new_bare = Path(new).name

        for file_path in files:
            count = replace_in_file(file_path, old, new, dry_run=args.dry_run)
            if count:
                rel = file_path.relative_to(REPO_ROOT)
                print(f"  {rel}: {count} replacement(s)")
                print(f"    {old} -> {new}")
                pair_total += count

            # Also check for bare filename references (without full path)
            if old_bare != old and old_bare != new_bare:
                bare_count = replace_in_file(file_path, old_bare, new_bare,
                                             dry_run=args.dry_run)
                if bare_count:
                    rel = file_path.relative_to(REPO_ROOT)
                    print(f"  {rel}: {bare_count} bare-name replacement(s)")
                    print(f"    {old_bare} -> {new_bare}")
                    pair_total += bare_count

        if pair_total == 0:
            print(f"  No references found for: {old}")
        total_replacements += pair_total

    if args.dry_run:
        print(f"\nDRY RUN: {total_replacements} total replacement(s) would be made.")
    else:
        print(f"\nDone. {total_replacements} total replacement(s) made.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
