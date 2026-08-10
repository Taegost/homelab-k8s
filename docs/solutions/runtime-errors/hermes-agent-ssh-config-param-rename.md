---
title: "Hermes Agent 0.19.0 SSH Config Parameter Rename Breaks Terminal Tool"
date: "2026-08-10"
category: runtime-errors
module: terminal
problem_type: runtime_error
component: tooling
symptoms:
  - "ValueError: SSH environment requires ssh_host and ssh_user to be configured"
  - "Terminal tool completely non-functional after upgrading Hermes Agent to 0.19.0"
  - "SSH backend fails to initialize despite valid config.yaml on PVC"
root_cause: config_error
resolution_type: config_change
severity: high
tags:
  - hermes-agent
  - ssh
  - config-schema
  - upgrade-breaking-change
  - terminal-tool
---

# Hermes Agent 0.19.0 SSH Config Parameter Rename Breaks Terminal Tool

## Problem

After upgrading Hermes Agent to version 0.19.0, the terminal tool stopped working entirely. The SSH backend, which executes commands in a separate sandbox pod, raised a `ValueError` on every invocation because the config parameter names it expected had changed.

## Symptoms

- Every terminal tool invocation failed immediately with: `ValueError: SSH environment requires ssh_host and ssh_user to be configured`
- No commands could be executed through the terminal tool
- The error appeared as soon as any agent task attempted to use the terminal, making the agent effectively non-functional for any task requiring shell access
- The Hermes health check (`hermes doctor`) showed the terminal check as failing

## What Didn't Work

- Restarting the Hermes pod had no effect -- the error was in the config file, not the runtime state
- Verifying the SSH connection manually (`ssh -i /opt/data/.ssh/id_ed25519 hermes@hermes-sandbox.hermes-agent.svc.cluster.local`) confirmed the underlying SSH connectivity was fine; the sandbox pod was reachable and accepting connections
- The SSH key and known_hosts files were correctly provisioned and had proper permissions -- the problem was upstream of the actual SSH connection

## Solution

Update `/opt/data/config.yaml` on the Hermes PVC to use the new `ssh_`-prefixed parameter names introduced in Hermes 0.19.0.

**Before (broken):**

```yaml
terminal:
  backend: ssh
  host: hermes-sandbox.hermes-agent.svc.cluster.local
  user: hermes
  key: /opt/data/.ssh/id_ed25519
  port: 22
```

**After (fixed):**

```yaml
terminal:
  backend: ssh
  ssh_host: hermes-sandbox.hermes-agent.svc.cluster.local
  ssh_user: hermes
  ssh_key: /opt/data/.ssh/id_ed25519
  ssh_port: 22
```

The fix requires renaming four parameters: `host` to `ssh_host`, `user` to `ssh_user`, `key` to `ssh_key`, and `port` to `ssh_port`. No values change -- only the key names.

After updating the config, restart the Hermes pod to pick up the new values.

## Why This Works

Hermes 0.19.0 changed the SSH backend configuration schema to require the `ssh_` prefix on all SSH-related parameters. The backend code validates that `ssh_host` and `ssh_user` are present before attempting to establish a connection. When the old parameter names (`host`, `user`, `key`, `port`) are present instead, the validator sees them as missing fields and raises the `ValueError` before any SSH connection is attempted.

The prefix change likely happened to namespace SSH-specific parameters more clearly, avoiding collisions with other configuration sections that might also use generic names like `host` or `port`. Once the parameter names match what the code expects, the SSH backend initializes normally and connects to the sandbox pod using the same host, user, key, and port that were always configured.

## Prevention

- **Check release notes before upgrading Hermes.** Breaking config schema changes are the kind of thing that should appear in release notes, but they are easy to miss. Read the changelog for any version bump, even minor ones.
- **Test terminal connectivity after upgrades.** Run `hermes doctor` immediately after any Hermes version upgrade to catch config schema changes before they block agent tasks.
- **Pin Hermes versions deliberately.** If the agent is critical to workflow, pin the version in the Deployment manifest and upgrade on a schedule rather than reactively. This gives time to review changelogs.
- **Consider a config validation startup check.** If Hermes supports a dry-run or config validation mode, run it as a post-upgrade verification step. Catching a `ValueError` at startup is better than discovering it when an agent task fails mid-execution.

## Related Issues

- [Hermes Agent Troubleshooting — Terminal Tool SSH Configuration Error](../../troubleshooting/hermes.md) — Same issue documented in the troubleshooting guide with verification steps
- [Deploying SSH-Sandboxed AI Agents to Kubernetes](../conventions/hermes-agent-ssh-sandbox-deployment-pattern.md) — Covers Kubernetes-level SSH sandbox deployment architecture (ConfigMaps, secrets, NetworkPolicy); does not cover application-level config.yaml parameter naming
