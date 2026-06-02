#!/usr/bin/env python3
"""Audit Kubernetes manifest filenames against naming conventions.

Scans apps/ for single-resource YAML manifests and reports files whose
filename does not start with the expected <kind>- prefix (or sealedsecret-
for SealedSecret resources).

The <kind>-<resource-name>.yaml convention requires the lowercased resource
kind as a filename prefix. Files that lack this prefix, use a wrong prefix
(shorthand/abbreviation), or use a suffix instead of a prefix are reported.

This script only identifies violations — it does not compute expected new
filenames. The rename table in the implementation plan is authoritative for
the correct new paths.

Usage:
    python3 scripts/audit-manifest-naming.py

Exit code: 0 when zero violations found, 1 when violations exist.
"""

import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
APPS_DIR = REPO_ROOT / "apps"

# Files excluded because they contain multiple resources (install manifests,
# Helm-generated templates) — the naming convention does not apply.
EXCLUDED_FILES = {
    APPS_DIR / "argocd/argocd.yaml",
    APPS_DIR / "cert-manager/cert-manager.yaml",
    APPS_DIR / "metallb/metallb.yaml",
    APPS_DIR / "sealed-secrets/sealed-secrets-controller.yaml",
}

# Directories excluded because they follow a different documented convention.
EXCLUDED_DIRS = {
    APPS_DIR / "manifests",           # ArgoCD Application manifests (named after app dir)
    APPS_DIR / "traefik/external",    # External route files (<service-name>.yaml)
}


def is_values_file(path: Path) -> bool:
    """Check if file is a Helm values.yaml (not a Kubernetes resource manifest)."""
    return path.name == "values.yaml"


def is_single_resource_manifest(path: Path) -> bool:
    """Check if path looks like a single-resource Kubernetes manifest."""
    if path in EXCLUDED_FILES:
        return False
    for excluded_dir in EXCLUDED_DIRS:
        try:
            path.relative_to(excluded_dir)
            return False
        except ValueError:
            pass
    return True


def expected_kind_prefix(kind: str) -> str:
    """Return the expected filename prefix for a given resource kind.

    SealedSecret resources use 'sealedsecret-' prefix per the
    sealedsecret-<name>.yaml convention. All others use <lowercased-kind>-.
    """
    if kind.lower() == "sealedsecret":
        return "sealedsecret-"
    return f"{kind.lower()}-"


def extract_kind(path: Path) -> str | None:
    """Parse the first YAML document and return its kind."""
    try:
        with open(path) as f:
            docs = list(yaml.safe_load_all(f))
    except yaml.YAMLError:
        return None

    docs = [d for d in docs if d is not None]
    if not docs:
        return None

    if len(docs) > 1:
        print(f"  SKIP (multi-doc): {path}", file=sys.stderr)
        return None

    doc = docs[0]
    if not isinstance(doc, dict):
        return None

    return doc.get("kind")


def main() -> int:
    violations: list[tuple[Path, str]] = []
    skipped = 0

    yaml_files = sorted(
        p for p in APPS_DIR.rglob("*.yaml")
        if not is_values_file(p) and is_single_resource_manifest(p)
    )
    yaml_files += sorted(
        p for p in APPS_DIR.rglob("*.yml")
        if not is_values_file(p) and is_single_resource_manifest(p)
    )

    for path in yaml_files:
        kind = extract_kind(path)
        if kind is None:
            skipped += 1
            continue

        prefix = expected_kind_prefix(kind)
        if not path.name.startswith(prefix):
            violations.append((path, kind))

    if violations:
        print(f"Found {len(violations)} naming convention violation(s):\n")
        for path, kind in violations:
            old_rel = path.relative_to(REPO_ROOT)
            print(f"  {old_rel}")
            print(f"    resource kind: {kind}")
            print(f"    expected prefix: {expected_kind_prefix(kind)}")
        print()

    if skipped:
        print(f"Skipped {skipped} file(s) (multi-document or unparseable).", file=sys.stderr)

    if violations:
        print(f"SUMMARY: {len(violations)} violation(s) found.", file=sys.stderr)
        return 1

    print("All manifest filenames conform to naming conventions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
