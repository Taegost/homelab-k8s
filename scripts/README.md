# Scripts

This folder contains supporting scripts for the homelab-k8s repository. These are operational tools — run manually when needed, not applied by ArgoCD.

## Scripts

### `longhorn-pvc-report.sh`

Prints a utilisation report for every Longhorn PVC in the cluster, sorted by % used. Useful for spotting volumes approaching their limit before they cause application failures.

```
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