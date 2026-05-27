# Troubleshooting: Longhorn Volume Stuck with "Already Mounted or Mount Point Busy"

## Symptoms

A pod crashloops and never reaches Running state. The pod events show:

```
MountVolume.MountDevice failed for volume "pvc-<id>" : rpc error: code = Internal desc =
mount failed: exit status 32
Mounting command: mount
Mounting arguments: -t ext4 -o defaults /dev/longhorn/pvc-<id>
  /var/lib/kubelet/plugins/kubernetes.io/csi/driver.longhorn.io/<guid>/globalmount
Output: mount: .../globalmount: /dev/longhorn/pvc-<id> already mounted or mount point busy.
dmesg(1) may have more information after failed mount system call.
```

Key indicators that this is the specific issue described here:
- The same `<guid>` in the globalmount path persists across pod restarts
- `/proc/mounts` and `findmnt` show **nothing** mounted at that path
- The Longhorn UI shows the volume as **attached** to a node even though no pod is
  successfully using it

---

## What Does NOT Fix This

These steps are reasonable first instincts but do not resolve the issue:

- **Deleting the crashing pod** — the pod recreates and hits the same error
- **Bouncing the Longhorn CSI plugin pod** on the affected node — clears in-memory state
  but the kernel-level block device claim persists
- **Deleting the VolumeAttachment** — clears Kubernetes-side state but the device-mapper
  mapping remains in the kernel
- **Force-detaching the volume in the Longhorn UI** — Longhorn warns this can break
  VolumeAttachment resources, and even if done, the underlying cause is not addressed
- **Running `umount -f -l` on the globalmount path** — silently does nothing if the
  device is claimed at the device-mapper level rather than mounted at that path directly

---

## Root Cause

`multipathd` (the Linux multipath daemon) was running on the cluster nodes. This daemon is
designed for enterprise SAN environments where a server has multiple physical HBAs connected
to a storage array, creating redundant I/O paths. It works by **claiming block devices** and
creating virtual device-mapper devices on top of them.

The problem: `multipathd` aggressively claims **any eligible block device** it discovers,
including Longhorn volumes. When Longhorn's CSI driver then tries to mount the volume, the
kernel refuses because `multipathd` has already taken ownership of the underlying device via
a device-mapper mapping (e.g. `mpatha`, `mpathd`).

This is documented in the official Longhorn KB:
https://longhorn.io/kb/troubleshooting-volume-with-multipath/

The tricky part: **disabling `multipathd` is not enough on its own**. Stopping the daemon
does not remove device-mapper mappings it already created. Those mappings live in the kernel
and persist until explicitly removed or the node is rebooted.

---

## Resolution

### Step 1: Disable multipathd on all nodes (permanent fix)

The socket unit will reactivate the service if not also disabled. Disable both:

```bash
sudo systemctl disable --now multipathd.service multipathd.socket
```

Verify both are inactive:

```bash
systemctl is-active multipathd.service multipathd.socket
# Both should return: inactive
```

This must be done on **all cluster nodes**, not just the one currently showing the error.
The Ansible playbook at `ansible/roles/node-prep` handles this — see that role for the
canonical implementation.

### Step 2: Remove stale device-mapper mappings left by multipathd

Even after disabling the daemon, existing mappings remain in the kernel. Check for them:

```bash
sudo dmsetup ls
```

You will see entries like `mpatha`, `mpathd`, `mpathe` alongside legitimate LVM entries
(e.g. `ubuntu--vg-ubuntu--lv`). **Do not touch the LVM entries** — those are the OS disk.

To identify which mpath entry corresponds to your stuck Longhorn volume:

```bash
# Get the major:minor of the Longhorn device
ls -l /dev/longhorn/pvc-<id>
# e.g. output: brw-rw---- 1 root disk 8, 32 ...  <- major=8, minor=32

# Find which mpath device sits on top of that underlying disk
sudo dmsetup deps mpatha
sudo dmsetup deps mpathd
sudo dmsetup deps mpathe
# Whichever one lists (8, 32) is the one claiming your volume
```

Remove all spurious mpath entries (safe to do all at once since multipathd is now disabled
and none of these devices are needed on direct-attached storage):

```bash
sudo dmsetup remove mpatha mpathd mpathe
# Adjust names to match what dmsetup ls showed on your node
```

If any fail with "device or resource busy", use the force flag:

```bash
sudo dmsetup remove -f mpatha
```

### Step 3: Delete the crashing pod

With the device-mapper mapping gone, Longhorn can now claim the block device cleanly:

```bash
kubectl delete pod <pod-name> -n <namespace>
```

The owning controller (Deployment/StatefulSet) or ArgoCD will recreate the pod, and the
CSI attach/mount sequence will succeed.

---

## Why multipathd Was Running

`multipathd` is included in Ubuntu's default package set and enabled by default on many
distros, even on hardware that has no use for it. On mini PCs with directly attached
NVMe/SATA drives — which have a single path to each disk — multipath provides zero benefit.
It is solving a problem that does not exist in a homelab context.

---

## Prevention

### Permanent: Ensure multipathd is disabled at node provision time

Add to the node preparation Ansible role so this is handled automatically for any new node
that joins the cluster. See the Ansible playbook for the canonical implementation.

### If the issue recurs on a new node

Run through Steps 2 and 3 above. Step 1 will already be handled by Ansible if the node was
provisioned correctly.

### Check Longhorn's own node preflight output

Longhorn's preflight checker will warn if `multipathd` is active on a node:

```
warn: - multipathd.service is running. Please refer to
https://longhorn.io/kb/troubleshooting-volume-with-multipath/ for more information.
```

If you see this warning during a Longhorn install or upgrade, fix it before proceeding.

---

## Key Facts for Future Debugging

- `multipathd` creates device-mapper entries (visible in `dmsetup ls` as `mpath*`) that
  persist in the kernel even after the daemon is stopped
- `findmnt` and `/proc/mounts` will show **nothing** for a device claimed this way — the
  block device is held at the device-mapper layer, not as a filesystem mount
- The Longhorn volume will show as **attached** in the UI because Longhorn's control plane
  thinks everything is fine — the failure happens at the kernel mount layer, below Longhorn's
  visibility
- The same globalmount GUID persisting across pod restarts is a strong signal the issue is
  at the device-mapper level, not a stale pod or CSI state problem
- Rebooting the affected node will also clear all device-mapper state and resolve the
  immediate issue, but the root cause (multipathd enabled) must still be addressed to prevent
  recurrence