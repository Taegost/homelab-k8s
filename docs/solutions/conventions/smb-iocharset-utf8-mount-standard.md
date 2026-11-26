---
title: "SMB Mount iocharset=utf8 Standard: GitOps-Safe mountOptions Placement and Enforcement"
module: smb-csi
date: 2026-11-25
problem_type: convention
component: tooling
severity: medium
applies_when:
  - Adding or editing any SMB-backed StorageClass, static PersistentVolume, or PVC in this repo
  - "Choosing where mount options live: StorageClass top-level mountOptions vs PV spec.mountOptions"
  - Deciding how to change mount options on already-provisioned volumes without fighting ArgoCD self-heal
  - Writing pre-commit checks that must validate Kubernetes field paths, not just grep for strings
  - Setting expectations for when existing PV mounts pick up new mount options (node reboot restage)
symptoms:
  - mountOptions added at the wrong YAML level silently does nothing — no API validation, no ArgoCD error
  - kubectl-patching live PV mountOptions gets reverted by ArgoCD self-heal within ~5s
root_cause: config_error
resolution_type: config_change
related_components:
  - csi-driver-smb
  - storageclass
  - persistentvolume
  - argocd
  - pre-commit-hook
tags:
  - smb
  - iocharset
  - utf8
  - mount-options
  - storageclass
  - persistentvolume
  - argocd
  - gitops
---

# SMB persistent volumes mount with `iocharset=utf8` — applied via git, ArgoCD sync, and node reboots

## Context

The operator set a standing repo standard: every SMB persistent volume in this GitOps homelab mounts with `iocharset=utf8`. The option is defined in exactly three git-managed places — the `smb-backups` StorageClass and the two static SMB PVs (`manyfold-libraries`, `arr-stack-multimedia`) — and dynamically provisioned PVs inherit it from the StorageClass at provision time.

The first plan proposed the "obvious" cluster-side migration: `kubectl patch` the live PV objects to add the option, then scale the consuming Deployments to zero to force a restage. The operator rejected it on principle — this is a GitOps repo, and everything follows GitOps practices end to end. Verified research then killed the approach on the merits, three independent ways:

1. **ArgoCD fights live drift.** With auto-sync enabled, ArgoCD applies git↔live diffs to tracked resources only, and self-heal reverts live drift after a 5-second default timeout. A hand-patched PV object is untracked drift; the controller reverts it (https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/, verified 2026-11-25).
2. **Patching a PV triggers no rollout.** Deployments roll pods only on changes to their PodTemplateSpec. Editing a PV object — even successfully — causes no pod restart, so the patched option never remounts anyway.
3. **Even a restart is not a restage.** `kubectl rollout restart` can reuse cached NodeStage state on the same node, so the mount may come back with the old baked options regardless.

The lesson generalizes beyond this repo: in a GitOps-managed cluster, a desired end state that cannot be expressed as a git change is not deliverable by patching live objects — you need a mechanism that turns a git merge into the live change.

## Guidance

### The mechanism: mount options bake at NodeStageVolume; a reboot is a full unstage

CSI mount options are read and baked in when the kubelet stages the volume on a node (`NodeStageVolume`). They do not change while a mount is staged. A node reboot unstages every mount on that node; when pods come back, each volume restages reading the PV object's **current** `mountOptions`. That makes the reboot the only mutation-free carrier for a mount-option change.

The GitOps flow is therefore:

1. **Commit the change to the git-managed definition sites** — the StorageClass and each static PV manifest.
2. **Let ArgoCD sync it** to the live objects. This is the entire cluster mutation.
3. **Reboot nodes during routine maintenance.** Each reboot restages every SMB mount that node hosts with the synced options. No `kubectl patch`, no scale-to-zero, no `rollout restart`.
4. **Verify read-only** from inside a consuming pod:

   ```bash
   kubectl exec -n <namespace> deploy/<app> -- grep cifs /proc/mounts
   ```

The reusable recipe is documented in `docs/storage.md` under "SMB mounts".

### Scope split: static PVs remount via reboot; dynamic PVs do not

The standard lands differently for the two provisioning modes, and the doc must say so explicitly or it promises a flow that does not exist:

- **Static, git-managed PVs** (2 in this repo): ArgoCD syncs the manifest change to the live PV object, and node reboots restage their mounts with the new options. Full live migration via the flow above.
- **Dynamically provisioned PVs** (7 Bound `smb-backups` PVs here): options are baked at provision time and only change when the volume is **reprovisioned**. A StorageClass change does not propagate to existing PVs. The standard applies to them forward-looking only — every new PVC against the class provisions with `iocharset=utf8`. The residual on existing volumes was explicitly accepted by the operator rather than migrated.

### Field-path gotcha: placement differs by kind, and wrong placement fails silently

The mount-options field path is different per object kind, and Kubernetes validates neither:

- **StorageClass**: `mountOptions` is **top-level**. A StorageClass has no `spec`; an option nested under `spec.mountOptions` silently does nothing.
- **PersistentVolume**: the field is `spec.mountOptions`. A top-level `mountOptions` on a PV is silently ignored.

The Kubernetes API does not validate mount options (https://kubernetes.io/docs/concepts/storage/persistent-volumes/#mount-options, verified 2026-11-25), so a misplacement produces no error, no event, and no warning — the option just never takes effect, often discovered only when a mount-behavior bug appears far from its cause.

### Enforcement: pre-commit check that validates kind-correct placement

A new pre-commit check, `smb-iocharset-check.sh` (check 12 of the homelab-validate suite, running on every YAML commit — it selects SMB manifests by staged content), blocks any commit staging an SMB StorageClass (`provisioner: smb.csi.k8s.io`) or SMB PV (`csi.driver: smb.csi.k8s.io`) that lacks `iocharset=utf8`. Non-SMB storage manifests are never flagged.

Key implementation lesson: **grep-based sibling checks cannot validate kind-correct field placement.** A grep for `iocharset=utf8` anywhere in the file would pass a StorageClass with the option nested under `spec` — exactly the silent no-op above. The check instead parses each staged YAML file per document (PyYAML `safe_load_all`, the same dependency as `networkpolicy-check.sh`) and enforces placement by kind. Both misplacements fail with messages explaining the silent no-op:

```python
if kind == 'StorageClass':
    if doc.get('provisioner') != 'smb.csi.k8s.io':
        continue
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
    opts = spec.get('mountOptions') or []
    if 'iocharset=utf8' not in opts:
        errors.append(
            f'PersistentVolume/{name}: iocharset=utf8 missing from'
            ' spec.mountOptions (a top-level mountOptions on a PV is'
            ' silently ignored)')
```

## Why This Matters

- **The patch-and-restage instinct is wrong twice in a GitOps repo.** It violates the operating model (live drift gets reverted), and it does not even work mechanically (PV edits trigger no rollout; restarts can reuse cached staging). Reaching for `kubectl patch` on state baked into CSI staging wastes an afternoon before revealing both facts.
- **The reboot is the free migration vehicle.** Nodes reboot during routine maintenance anyway. Committing the change and letting reboots carry it means zero manual cluster mutation, zero downtime planning, and zero drift — the remount rides maintenance instead of fighting it.
- **Silent field-path misplacement is a trap with no feedback loop.** Kubernetes does not validate mount options, so the failure mode is "option present in the manifest, absent from every mount." Without kind-aware enforcement, the mistake ships and surfaces later as a bug far from its cause.
- **Dynamic-PV scope must be stated, not implied.** A doc that says "update the StorageClass and reboot" implicitly promises that the seven existing dynamic volumes will pick the option up. They will not — their options change only at reprovision. Recording the residual (and the operator's acceptance of it) is what makes the standard honest.

## When to Apply

- Adding or changing mount options on CSI-provisioned storage (SMB, NFS, or any CSI driver) in a GitOps-managed cluster.
- Choosing a delivery mechanism for any config that is baked at attach/stage time and cannot be changed in place.
- Writing a StorageClass or static PV manifest — place `mountOptions` at the kind-correct path (top-level for StorageClass, `spec.mountOptions` for PV).
- Extending the pre-commit validation suite with a check whose correctness depends on **where** a field sits, not whether a string exists in the file — use per-document YAML parsing rather than grep.
- Deciding scope for an existing-resource standard: split git-managed definitions (live-migratable via sync + restage trigger) from provision-time-baked resources (forward-looking only, residual documented and accepted).

## Examples

### Definition sites (all three now carry the option)

StorageClass — `mountOptions` is top-level, no `spec`:

```yaml
# apps/infrastructure/storage/storageclass-smb-backups.yaml (excerpt)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: smb-backups
provisioner: smb.csi.k8s.io
mountOptions:
  - noserverino
  - _netdev
  - noperm
  - uid=99
  - gid=100
  - dir_mode=0777
  - file_mode=0777
  - iocharset=utf8
```

Static PV — `mountOptions` lives under `spec`:

```yaml
# apps/manyfold/persistentvolume-manyfold-libraries.yaml (excerpt)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: manyfold-libraries
spec:
  storageClassName: ""
  mountOptions:
    - noserverino
    - _netdev
    - noperm
    - uid=99
    - gid=100
    - forceuid
    - forcegid
    - dir_mode=0777
    - file_mode=0777
    - iocharset=utf8
  csi:
    driver: smb.csi.k8s.io
    volumeHandle: manyfold-libraries
```

The second static PV, `apps/arr-stack/persistentvolume-arr-stack-multimedia.yaml`, carries the same `spec.mountOptions` placement with the arr-stack option set (`forceuid`/`forcegid`, `nobrl`, `cache=none` — see its inline comments for why).

### The migration flow (the whole thing)

```bash
# 1. Commit manifest changes; ArgoCD syncs (read-only check that sync landed —
#    StorageClass and both static PVs must list iocharset=utf8):
kubectl get storageclass smb-backups -o jsonpath='{.metadata.name}{"  "}{.mountOptions}{"\n"}'
kubectl get pv arr-stack-multimedia manyfold-libraries \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.mountOptions}{"\n"}{end}'

# 2. Reboot nodes during routine maintenance — full unstage, pods restage
#    with the PV's current mountOptions.

# 3. Verify read-only, per consuming workload. Select the /multimedia mount by
#    mount point (field 2) before extracting iocharset: arr workloads also
#    mount a dynamic smb-backups volume at /backups, and the plain grep union
#    could let utf8 from /backups mask a stale option on the static /multimedia
#    mount. If a container lacks grep, swap in 'cat /proc/mounts'.
for d in bazarr radarr sonarr whisparr; do
  echo "== $d"
  kubectl exec -n arr-stack deploy/$d -- sh -c "grep cifs /proc/mounts | awk '\$2 == \"/multimedia\"'" | grep -o 'iocharset=[a-z0-9]*' | sort -u
done
echo "== manyfold"
kubectl exec -n manyfold deploy/manyfold -- grep cifs /proc/mounts | grep -o 'iocharset=[a-z0-9]*' | sort -u
```

A pod rescheduled onto a not-yet-rebooted node shows old options until that node reboots — the final verification pass catches stragglers.

### The check, wired into the suite

`check 12` of `.claude/skills/homelab-validate/scripts/smb-iocharset-check.sh`. Runs on every commit touching `.yaml`/`.yml` files. Prefilter greps staged (index) content — read via `git show ":<path>"`, not working-tree files — for `smb.csi.k8s.io` (covers both the StorageClass `provisioner:` line and the PV `csi.driver:` line); matching files are parsed per document with `yaml.safe_load_all` for kind-correct placement validation. Content-based selection means file naming cannot bypass the check; commits touching no SMB manifests exit PASS immediately.

Verification performed this session:

- **Live FAIL-path proof**: staged a deliberately no-`iocharset` StorageClass fixture; the hook blocked the commit.
- **Four-agent implementation verification**: PASS.
- Cited sources (both verified 2026-11-25):
  - ArgoCD auto-sync / self-heal: https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
  - Kubernetes PV mount options: https://kubernetes.io/docs/concepts/storage/persistent-volumes/#mount-options

### Residual, explicitly accepted

The seven Bound dynamic `smb-backups` PVs keep their current mount options until naturally reprovisioned. Operator acceptance on record (2026-11-25): the dynamic ones "do not need to be recreated as part of this"; any downstream risk is accepted. The standard governs all future provisioning via the StorageClass.

## Related

- `docs/storage.md` → "SMB mounts" — the user-facing runbook recipe for this flow (cross-reference; this doc carries the reasoning, that one the procedure)
- `docs/solutions/tooling-decisions/pre-commit-validation-suite.md` — suite doc for all 12 checks, including this one
- `docs/solutions/performance-issues/bazarr-crash-loop-startup-probe-gil-smb.md` — same `multimedia` PV, same `grep /proc/mounts` verification technique, mount options changing runtime behavior
- `docs/plans/2026-11-25-001-feat-smb-utf8-iocharset-plan.md` — the plan with the full decision log (D-entries)
- `docs/solutions/best-practices/security-context-audit-pattern.md` — precedent for the parse-per-kind validation approach
