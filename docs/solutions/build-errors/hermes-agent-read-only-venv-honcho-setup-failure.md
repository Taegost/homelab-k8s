---
title: hermes memory setup honcho fails with read-only venv
date: 2026-06-24
category: build-errors
module: hermes-agent
problem_type: build_error
component: tooling
severity: medium
symptoms:
  - "hermes memory setup honcho fails with: Failed to create directory /opt/hermes/.venv/lib/python3.13/site-packages/honcho_ai-2.1.2.dist-info"
  - "honcho-ai package installation reports: /opt/hermes/.venv/bin/python3: No module named pip"
root_cause: incomplete_setup
resolution_type: environment_setup
tags:
  - hermes-agent
  - honcho
  - kubernetes
  - read-only-venv
  - derived-image
  - python-packages
related_components:
  - assistant
---

# hermes memory setup honcho fails with read-only venv

## Problem

When running `hermes memory setup honcho` inside the hermes-agent Kubernetes
container, the setup wizard tries to install the `honcho-ai` Python package
into the virtual environment at `/opt/hermes/.venv`. The venv is owned by root
(read-only at runtime), and the container runs as non-root UID 10000. The
installation fails with a permission error, blocking Honcho memory integration.

## Symptoms

```
Installing dependencies: honcho-ai
⚠ Failed to install honcho-ai
  error: Failed to install: honcho_ai-2.1.2-py3-none-any.whl (honcho-ai==2.1.2)
Caused by: Failed to create directory `/opt/hermes/.venv/lib/python3.13/site-packages/honcho_ai-2.1.2.dist-info`
```

On retry with pip:

```
/opt/hermes/.venv/bin/python3: No module named pip
```

## What Didn't Work

- **Manual `pip install` inside the container** — fails because the venv is
  read-only (`dr-xr-xr-x` owned by root). The non-root `hermes` user (UID
  10000) cannot write to it.
- **`pip install --user`** — would install to `/opt/data/.local/lib/` (the
  writable PVC), but the `hermes memory setup` wizard doesn't use `--user` and
  Python doesn't include the user site-packages by default in the venv.
- **Init container approach** — an init container could install `honcho-ai`
  into a PVC, but `PYTHONPATH` would need to be set in the main container and
  the package would need to be re-installed on image upgrades. Not the
  documented approach.

## Solution

Build a **derived Docker image** that inherits from the official hermes-agent
image and pre-installs `honcho-ai`:

```dockerfile
FROM nousresearch/hermes-agent:v2026.6.19
USER root
RUN /opt/hermes/.venv/bin/pip install --no-cache-dir honcho-ai
USER hermes
```

This is the [officially documented approach](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
for installing additional Python packages in the Hermes Agent container:

> **Derived image (durable):** Build a custom image inheriting from the official one.

Build, tag, and push to the cluster's registry, then update the hermes-agent
deployment to reference the custom image instead of the official one.

### Build steps

```bash
# Build the derived image
docker build -t hermes-agent-custom:latest -f Dockerfile.hermes .

# Tag and push to your registry
docker tag hermes-agent-custom:latest <registry>/hermes-agent-custom:latest
docker push <registry>/hermes-agent-custom:latest
```

### Deployment change

Update `apps/hermes-agent/deployment-hermes-agent.yaml` to reference the
custom image instead of `nousresearch/hermes-agent:v2026.6.19`.

## Why This Works

The hermes-agent image is designed with `/opt/hermes` as a read-only install
tree and `/opt/data` as the only writable volume (PVC). The
[Docker documentation](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
explicitly states:

> The `/opt/hermes` install tree is read-only at runtime — all mutable state
> belongs under `/opt/data`.

The derived image approach installs `honcho-ai` into the venv at build time
(when root access is available), making it available to the non-root runtime
user without modifying the read-only filesystem. The package persists across
pod restarts and is upgraded by rebuilding the derived image with a new base
tag.

## Prevention

When deploying Hermes Agent with memory providers that require additional
Python packages, build a derived image as part of the deployment workflow.
Check the provider's setup documentation for package requirements before
deploying — `hermes memory setup` expects to install packages at runtime,
which only works in writable environments (local installs, Docker with
writable volumes, or derived images).

## Related

- [Hermes Agent Docker documentation](https://hermes-agent.nousresearch.com/docs/user-guide/docker) — official guidance on derived images
- [Honcho Memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/honcho) — Hermes docs for Honcho integration
- `apps/honcho/README.md` — Hermes Integration section
- `docs/plans/2026-06-23-005-feat-honcho-deployment-plan.md` — Section 3.1 (identified this issue as a follow-up task)
