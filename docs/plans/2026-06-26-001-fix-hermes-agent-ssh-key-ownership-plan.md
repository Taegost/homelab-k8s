---
title: "fix: Hermes agent SSH key ownership — initContainer pattern"
date: 2026-06-26
type: fix
status: active
module: hermes-agent
component: deployment
severity: medium
---

# Fix: Hermes Agent SSH Key Ownership

## Problem

The Hermes agent container runs as uid 10000 (hermes) but the SSH client key is mounted from a SealedSecret with `defaultMode: 0400`, making it readable only by root. The agent cannot SSH into the sandbox.

`fsGroup` cannot be used because:
1. OpenSSH rejects group-readable private keys
2. s6-overlay handles user switching and fsGroup caused /run permission issues

## Root Cause

Kubernetes Secret mounts are always owned by root. With `defaultMode: 0400`, only the owner (root) can read the file. Without `fsGroup`, the container user (hermes, uid 10000) has no way to read it.

## Solution

Use an initContainer pattern:

1. Add an `initContainer` running as root (uid 0) that copies the SSH key from the Secret mount to a shared emptyDir volume
2. Set correct ownership (hermes:hermes, 10000:10000) and permissions (0400) on the copy
3. Mount the shared emptyDir at `/opt/data/.ssh/id_ed25519` in the main container instead of the Secret directly

### Changes to deployment-hermes-agent.yaml

**Add volume:**
```yaml
- name: ssh-keys-workdir
  emptyDir:
    medium: Memory
```

**Add initContainer:**
```yaml
initContainers:
  - name: ssh-key-init
    image: busybox:1.37.0
    command:
      - sh
      - -c
      - |
        install -m 0400 -o 10000 -g 10000 /ssh-secret/id_ed25519 /ssh-keys/id_ed25519
    securityContext:
      runAsUser: 0
      runAsNonRoot: false
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
        add: [CHOWN]
    volumeMounts:
      - name: ssh-client-key
        mountPath: /ssh-secret
        readOnly: true
      - name: ssh-keys-workdir
        mountPath: /ssh-keys
```

**Note:** The existing `ssh-client-key` volume definition remains — the initContainer still references it.






**Update main container volumeMounts:**
Replace `ssh-client-key` mount with `ssh-keys-workdir`:
```yaml
- name: ssh-keys-workdir
  mountPath: /opt/data/.ssh/id_ed25519
  subPath: id_ed25519
  readOnly: true
```

## Verification

1. Deploy the change
2. Exec into the agent container: `kubectl exec -it <pod> -n hermes-agent -- bash`
3. Check key ownership: `ls -la /opt/data/.ssh/id_ed25519` — should show `10000:10000` (or `hermes:hermes` if passwd entry exists)
4. Check key permissions: should be `-r--------` (0400)
5. Test SSH: `ssh -o ConnectTimeout=5 hermes-sandbox "echo connected"` — should succeed

## Unaffected Components

The `known-hosts` and `ssh-config` ConfigMap mounts are unaffected — these files are also mounted as root-owned volumes, but their default modes (0644) remain readable by UID 10000. They would break if tightened to owner-only permissions.

## Scope Boundary

- Only changes `deployment-hermes-agent.yaml`
- No changes to SealedSecret, ConfigMaps, NetworkPolicy, or sandbox deployment

## Related

- `docs/solutions/conventions/hermes-agent-ssh-sandbox-deployment-pattern.md`
- `docs/solutions/best-practices/security-context-audit-pattern.md`
