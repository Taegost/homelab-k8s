---
title: "Longhorn PVCs Stuck from multipathd Claiming iSCSI Devices"
date: 2026-06-21
category: runtime-errors
module: longhorn
problem_type: runtime_error
component: tooling
symptoms:
  - "MountVolume.MountDevice failed — already mounted or mount point busy"
  - "Same globalmount GUID persists across pod restarts"
  - "/proc/mounts and findmnt show nothing mounted at the target path"
  - "Longhorn UI shows volume as attached but no pod is using it"
  - "dmsetup ls reveals mpath* entries alongside legitimate LVM entries"
root_cause: config_error
resolution_type: environment_setup
severity: critical
tags:
  - longhorn
  - iscsi
  - multipathd
  - device-mapper
  - storage
  - pvc
---

# Longhorn PVCs Stuck from multipathd Claiming iSCSI Devices

## Problem

Pods using Longhorn PVCs enter a permanent crashloop because the CSI driver cannot mount the block device. The mount fails at the kernel level with "already mounted or mount point busy" — but the device is not actually mounted anywhere visible. `multipathd` aggressively claims Longhorn's iSCSI-backed block devices via the kernel's device-mapper subsystem.

## Symptoms

```
MountVolume.MountDevice failed for volume "pvc-<id>":
mount failed: exit status 32
mount: .../globalmount: /dev/longhorn/pvc-<id> already mounted or mount point busy.
```

- `/proc/mounts` and `findmnt` show nothing mounted at the target path
- Longhorn UI shows volume as attached but no pod is using it
- `dmsetup ls` shows `mpath*` entries

## What Didn't Work

| Action | Why it fails |
|--------|-------------|
| Deleting the crashing pod | Pod recreates, hits the same error |
| Bouncing Longhorn CSI plugin pod | Kernel device-mapper claim persists |
| Deleting VolumeAttachment | Device-mapper mapping remains |
| Force-detaching in Longhorn UI | Underlying cause not addressed |
| `umount -f -l` | Device claimed at device-mapper level |

## Solution

### Step 1: Disable multipathd on all nodes

```bash
sudo systemctl disable --now multipathd.service multipathd.socket
```

The socket unit will reactivate the service if not also disabled.

### Step 2: Remove stale device-mapper mappings

```bash
sudo dmsetup ls                    # identify mpath* entries
sudo dmsetup deps mpatha           # find which claims the stuck volume
sudo dmsetup remove mpatha mpathd mpathe
# If "device or resource busy":
sudo dmsetup remove -f mpatha
```

### Step 3: Delete the crashing pod

```bash
kubectl delete pod <pod-name> -n <namespace>
```

## Why This Works

- **Disabling the service and socket** prevents `multipathd` from claiming new devices. Socket must also be disabled — systemd reactivates through socket activation.
- **Removing device-mapper mappings** releases the kernel-level claim. Simply stopping the daemon leaves orphaned mappings.
- **Deleting the pod** forces Kubernetes to re-run CSI attach/mount from scratch.

## Prevention

- **Disable `multipathd` at node provisioning time** — enabled by default on Ubuntu even on single-path hardware.
- **Add to bootstrap prerequisites** before deploying Longhorn.
- **Longhorn's preflight checker warns** if `multipathd` is active.
- **`open-iscsi` must be installed** on all nodes (separate prerequisite).

## Related

- `docs/troubleshooting/troubleshooting-longhorn-stale-mount.md` — full troubleshooting guide
- `docs/storage.md` — Longhorn prerequisites
- `bootstrap/README.md` — prerequisites checklist
- Longhorn KB: https://longhorn.io/kb/troubleshooting-volume-with-multipath/
