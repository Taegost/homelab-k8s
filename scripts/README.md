# Scripts

This folder contains supporting scripts for the homelab-k8s repository. These are operational tools — run manually when needed, not applied by ArgoCD.

## Scripts

### `longhorn-pvc-report.sh`

Prints a utilisation report for every Longhorn PVC in the cluster, sorted by % used. Useful for spotting volumes approaching their limit before they cause application failures.

```text
PVC                            NAMESPACE        USED(Gi)   CAP(Gi)   %USED
---                            ---------        --------   -------   -----
prowlarr-config                arr-stack            5.84      8.00   73.0
radarr-config                  arr-stack            3.09      5.00   61.7
...
```

**Usage:**

```bash
./scripts/longhorn-pvc-report.sh
```

Requires `kubectl` configured and pointed at the cluster. No other dependencies.

See `docs/storage.md` for context on what the numbers mean and how the recurring trim job affects reported sizes.

### `audit-manifest-naming.py`

Scans `apps/` for single-resource YAML manifests and reports filenames that do not match the `<kind>-<resource-name>.yaml` convention documented in CLAUDE.md. Identifies violations only — does not rename files.

```bash
python3 scripts/audit-manifest-naming.py
```

Exit code 0 when zero violations found, 1 when violations exist.

### `check-sync-waves.py`

Pre-commit sync wave verification. Checks staged (or all/committed) YAML manifests for correct `argocd.argoproj.io/sync-wave` annotations per CLAUDE.md conventions. Reports missing or unnecessary wave-0 annotations.

```bash
python3 scripts/check-sync-waves.py              # check staged files
python3 scripts/check-sync-waves.py --all         # check all committed files
python3 scripts/check-sync-waves.py --files a.yaml b.yaml  # specific files
```

### `update-filename-refs.py`

Updates filename references after manifest renames. Reads a CSV mapping file of `old_path,new_path` pairs and replaces all occurrences in tracked repository files. Supports `--dry-run` mode.

```bash
# Preview changes:
python3 scripts/update-filename-refs.py --mapping renames.csv --dry-run

# Apply changes:
python3 scripts/update-filename-refs.py --mapping renames.csv

# Single pair:
python3 scripts/update-filename-refs.py --old apps/foo/deployment.yaml --new apps/foo/deployment-foo.yaml
```

### `wp-migration.yaml`

Kubernetes Pod manifest for WordPress migration helper. Runs `wordpress:6.9-php8.5-apache` with `sleep infinity` and mounts the `wordpress-taegost-wp-content` PVC at `/mnt/pvc`. Useful for manual wp-content operations (rsync, file inspection) during migrations.

```bash
kubectl apply -f scripts/wp-migration.yaml
kubectl exec -it wp-migration -n wordpress-taegost -- bash
kubectl delete -f scripts/wp-migration.yaml
```
