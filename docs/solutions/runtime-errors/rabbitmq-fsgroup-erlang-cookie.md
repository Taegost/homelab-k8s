---
title: "RabbitMQ fsGroup vs Erlang Cookie Permission Conflict"
date: 2026-06-21
category: runtime-errors
module: plane
problem_type: runtime_error
component: tooling
symptoms:
  - "RabbitMQ pod in CrashLoopBackOff despite server being functionally healthy"
  - "Startup probe failed: command timed out after 1s"
  - "rabbitmq-diagnostics check_running consistently fails"
  - "Pod events show probe failures but rabbitmqctl status shows healthy"
root_cause: config_error
resolution_type: config_change
severity: high
tags:
  - rabbitmq
  - longhorn
  - fsgroup
  - erlang-cookie
  - capabilities
  - security-context
---

# RabbitMQ fsGroup vs Erlang Cookie Permission Conflict

## Problem

RabbitMQ pods crash-looped on a k3s cluster with Longhorn storage because Kubernetes' `fsGroup` security context field overwrites the strict file permissions RabbitMQ requires on its Erlang distribution cookie. The investigation uncovered three additional layered issues: capability failures after dropping ALL capabilities, OOMKill from cgroup memory blindness, and probe timeouts from insufficient default values.

## Symptoms

- Pod enters `CrashLoopBackOff` immediately after deployment
- `rabbitmqctl status` shows the server is healthy, but probes never pass
- Events: `Startup probe failed: command timed out after 1s`
- Kernel OOM-kills the container despite low actual memory usage
- `setgid(101) failed (1: Operation not permitted)` in container logs

## What Didn't Work

- **Adding `fsGroup: 101`** as defense-in-depth for Longhorn PVC access — caused kubelet to recursively apply group-write permissions, corrupting `.erlang.cookie` mode `0600` to `0640+`
- **Removing fsGroup** without fixing existing PVCs — cookie persisted on Longhorn volume with wrong permissions from prior runs
- **Startup probe with `failureThreshold: 12`** — didn't address root cause of probe failure (cookie permissions)
- **Default `timeoutSeconds: 1`** — `rabbitmq-diagnostics` takes 2-5s under CPU load; default timeout killed healthy pods every ~180s
- **256Mi memory limit** — RabbitMQ reads host `/proc/meminfo` (13.6GB), computes watermark at 5.4GB, gets OOM-killed at 256Mi

## Solution

### 1. Remove fsGroup entirely

No `fsGroup` in pod `securityContext`. The kubelet's recursive permission overwrite is the root conflict.

### 2. Init container for volume preparation

Replace `fsGroup` functionality with a controlled init container:

```yaml
initContainers:
  - name: volume-permissions
    image: busybox:1.37
    command:
      - sh
      - -c
      - |
        rm -rf /var/lib/rabbitmq/lost+found
        chown -R 100:101 /var/lib/rabbitmq
        if [ -f /var/lib/rabbitmq/.erlang.cookie ]; then
          chmod 0600 /var/lib/rabbitmq/.erlang.cookie
          chown 100:101 /var/lib/rabbitmq/.erlang.cookie
        fi
    volumeMounts:
      - name: rabbitmq-data
        mountPath: /var/lib/rabbitmq
```

### 3. Four specific capabilities after drop ALL

```yaml
securityContext:
  capabilities:
    drop: [ALL]
    add: [CHOWN, SETGID, SETUID, DAC_OVERRIDE]
```

- `CHOWN` — entrypoint chowns data directory
- `SETGID` / `SETUID` — `su-exec` drops from root to rabbitmq user (UID 100)
- `DAC_OVERRIDE` — probe commands running as root need to read mode-0600 cookie

### 4. Absolute memory watermark ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rabbitmq-override
data:
  rabbitmq.conf: |
    vm_memory_high_watermark.absolute = 500MB
```

With container limit set to 768Mi (above the watermark, with headroom for Erlang VM).

### 5. Probe timeout override

```yaml
livenessProbe:
  exec:
    command: [rabbitmq-diagnostics, -q, check_running]
  timeoutSeconds: 10
  failureThreshold: 20
  periodSeconds: 10
```

## Why This Works

Without `fsGroup`, the kubelet does not touch file permissions on the Longhorn volume. The `.erlang.cookie` retains mode `0600` as created by the entrypoint. The init container provides the volume-level preparation `fsGroup` would have done (ownership, lost+found cleanup) but in a controlled way. The init container also repairs stale cookies from prior `fsGroup` runs — critical because Longhorn PVCs persist across pod restarts. `DAC_OVERRIDE` allows probe commands (running as root) to read the `0600` cookie without failing permission checks.

## Prevention

- **Never use `fsGroup` with RabbitMQ.** Use the init container pattern instead.
- **Always set `timeoutSeconds: 10` on exec probes.** The Kubernetes default of 1s is insufficient for `rabbitmq-diagnostics`.
- **Always set `vm_memory_high_watermark.absolute`.** RabbitMQ reads host `/proc/meminfo`, not the container cgroup limit.
- **When dropping ALL capabilities, trace every syscall** the entrypoint and runtime process makes.
- **Longhorn PVCs with strict permission files (mode 0600) are incompatible with `fsGroup`.**

## Related

- `docs/solutions/base-images-rabbitmq.md` — capability requirements reference
- `docs/troubleshooting/troubleshooting-plane.md` — detailed Plane troubleshooting runbook
- `apps/plane/deployment-rabbitmq.yaml` — final working manifest
