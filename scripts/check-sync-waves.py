#!/usr/bin/env python3
"""Pre-commit sync wave verification.

Checks staged Kubernetes YAML manifests for sync-wave annotations per the
conventions in CLAUDE.md. Reports files that are missing expected annotations
or that have unnecessary wave-0 annotations.

Rules (from CLAUDE.md):
  Wave -3: Infrastructure SealedSecrets consumed by cluster CRDs
           (via passwordSecretRef, e.g. MongoDB users, CNPG roles)
  Wave -2: Cross-namespace secret consumers (User CRDs with passwordSecretRef)
  Wave -1: App-level SealedSecrets, Database CRDs
  Wave  0: Default — Deployments, Services, IngressRoutes, PVCs, ConfigMaps,
           NetworkPolicies, Certificates (OMIT annotation)

Usage:
    python3 scripts/check-sync-waves.py              # check staged files
    python3 scripts/check-sync-waves.py --all         # check all committed files
    python3 scripts/check-sync-waves.py --files a.yaml b.yaml  # specific files

Exit code: 0 when no issues found, 1 when issues exist.
"""

import argparse
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent

SYNC_WAVE_KEY = "argocd.argoproj.io/sync-wave"


def get_staged_yaml_files() -> list[str]:
    """Return list of staged YAML files from git diff --cached."""
    result = subprocess.run(
        ["git", "diff", "--cached", "--name-only"],
        capture_output=True, text=True, cwd=REPO_ROOT
    )
    if result.returncode != 0:
        print(f"ERROR: git diff failed: {result.stderr}", file=sys.stderr)
        return []
    return [
        f for f in result.stdout.strip().split("\n")
        if f and (f.endswith(".yaml") or f.endswith(".yml"))
    ]


def get_all_yaml_files() -> list[str]:
    """Return list of all committed YAML files under apps/."""
    result = subprocess.run(
        ["git", "ls-files", "apps/"],
        capture_output=True, text=True, cwd=REPO_ROOT
    )
    if result.returncode != 0:
        return []
    return [
        f for f in result.stdout.strip().split("\n")
        if f and (f.endswith(".yaml") or f.endswith(".yml"))
    ]


def parse_yaml(path: str) -> dict | None:
    """Parse the first YAML document from a file."""
    full_path = REPO_ROOT / path
    try:
        with open(full_path) as f:
            docs = list(yaml.safe_load_all(f))
    except (yaml.YAMLError, FileNotFoundError):
        return None

    docs = [d for d in docs if d is not None]
    if not docs:
        return None
    return docs[0] if isinstance(docs[0], dict) else None


def has_sync_wave(doc: dict) -> tuple[bool, str | None]:
    """Check if a resource has a sync-wave annotation.

    Returns (has_annotation, wave_value).
    Checks metadata.annotations and spec.template.metadata.annotations
    (for workload resources like Deployments).
    """
    annotations = doc.get("metadata", {}).get("annotations", {})
    if not isinstance(annotations, dict):
        annotations = {}

    wave = annotations.get(SYNC_WAVE_KEY)
    if wave is not None:
        return True, str(wave)

    # Check pod template annotations (Deployments, StatefulSets, etc.)
    template_meta = doc.get("spec", {}).get("template", {}).get("metadata", {})
    if isinstance(template_meta, dict):
        template_annotations = template_meta.get("annotations", {})
        if isinstance(template_annotations, dict):
            wave = template_annotations.get(SYNC_WAVE_KEY)
            if wave is not None:
                return True, str(wave)

    return False, None


def is_documentation(path: str) -> bool:
    """Check if a path is documentation, not a Kubernetes manifest."""
    return any(path.startswith(d) for d in
               ["docs/", "bootstrap/", "README", "CLAUDE", "AGENTS"])


def is_install_manifest(path: str) -> bool:
    """Check if a path is a multi-resource install manifest."""
    install_manifests = {
        "apps/argocd/argocd.yaml",
        "apps/cert-manager/cert-manager.yaml",
        "apps/metallb/metallb.yaml",
        "apps/sealed-secrets/sealed-secrets-controller.yaml",
    }
    return path in install_manifests


def is_helm_values(path: str) -> bool:
    """Check if a path is a Helm values.yaml."""
    return Path(path).name == "values.yaml"


def is_manifest_file(path: str) -> bool:
    """Check if a path should be checked for sync waves."""
    return not (is_documentation(path) or is_install_manifest(path)
                or is_helm_values(path) or "scripts/" in path)


def heuristics_suggest_wave(doc: dict, path: str) -> str | None:
    """Return a suggested wave based on resource heuristics, or None if wave 0."""
    kind = doc.get("kind", "")
    name = doc.get("metadata", {}).get("name", "")

    # SealedSecrets
    if kind == "SealedSecret":
        # Infrastructure SealedSecrets (consumed by CRDs via passwordSecretRef)
        # are in infra namespaces or have names suggesting cluster-level use
        namespace = doc.get("metadata", {}).get("namespace", "")
        infra_namespaces = {"postgres", "mongodb", "mariadb"}
        if namespace in infra_namespaces:
            return "-3"
        return "-1"  # App-level SealedSecret

    # Database CRDs
    if kind in {"Cluster", "MariaDB", "PerconaServerMongoDB", "Database"}:
        return "-1"

    # Cross-namespace secret consumers (User CRDs with passwordSecretRef)
    if kind == "User":
        return "-2"

    return None  # Wave 0 — no annotation needed


def check_files(file_paths: list[str]) -> int:
    """Check files for sync wave annotation issues. Returns count of issues."""
    issues = 0

    for path in sorted(file_paths):
        if not is_manifest_file(path):
            continue

        doc = parse_yaml(path)
        if doc is None:
            continue

        kind = doc.get("kind", "unknown")
        has_wave, wave_value = has_sync_wave(doc)

        if not has_wave:
            suggested = heuristics_suggest_wave(doc, path)
            if suggested:
                print(f"MISSING (likely wave {suggested}): {path}  ({kind})")
                issues += 1
            # Wave 0 files correctly omit annotation — no report needed
        else:
            # Has annotation — check if it's an unnecessary wave 0
            if wave_value == "0":
                print(f"UNNEEDED (wave 0 is default): {path}  ({kind})")
                issues += 1

    return issues


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Pre-commit sync wave annotation checker"
    )
    parser.add_argument(
        "--all", action="store_true",
        help="Check all committed YAML files (not just staged)"
    )
    parser.add_argument(
        "--files", nargs="+",
        help="Check specific files"
    )
    args = parser.parse_args()

    if args.files:
        files = args.files
    elif args.all:
        files = get_all_yaml_files()
    else:
        files = get_staged_yaml_files()

    if not files:
        print("No YAML files to check.")
        return 0

    print(f"Checking {len(files)} file(s)...\n")
    issues = check_files(files)

    if issues:
        print(f"\n{issues} sync wave issue(s) found.")
        return 1

    print("All sync wave annotations correct.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
