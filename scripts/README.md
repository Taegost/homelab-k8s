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

> **Note:** The Python validation scripts (`audit-manifest-naming.py`,
> `check-sync-waves.py`, `update-filename-refs.py`) were moved to
> `.claude/skills/homelab-validate/scripts/` — they are AI maintenance
> scripts, not user-facing tools.

### `wp-migration.yaml`

Kubernetes Pod manifest for WordPress migration helper. Runs `wordpress:6.9-php8.5-apache` with `sleep infinity` and mounts the `wordpress-taegost-wp-content` PVC at `/mnt/pvc`. Useful for manual wp-content operations (rsync, file inspection) during migrations.

```bash
kubectl apply -f scripts/wp-migration.yaml
kubectl exec -it wp-migration -n wordpress-taegost -- bash
kubectl delete -f scripts/wp-migration.yaml
```
