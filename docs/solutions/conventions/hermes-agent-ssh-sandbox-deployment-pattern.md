---
module: hermes-agent
date: 2026-06-22
problem_type: convention
component: tooling
severity: medium
applies_when:
  - "Deploying an AI agent with SSH sandbox backend to k3s"
  - "Configuring network-isolated sandbox pods with SSH keypair auth"
  - "Setting up per-app TLS with OIDC for public webhook access"
tags:
  - hermes-agent
  - ssh-sandbox
  - networkpolicy
  - k3s-deployment
  - oidc
  - longhorn
  - sync-wave
---

# Deploying SSH-Sandboxed AI Agents to Kubernetes

## Context

Deploying an AI agent that requires isolated code execution introduces architectural complexity beyond a standard web application. The agent needs a separate sandbox pod running sshd, SSH key authentication between pods, network-level isolation to prevent the sandbox from accessing cluster internals, and carefully tuned container security contexts that differ significantly between the agent and sandbox containers. This deployment pattern emerged from deploying Hermes Agent (Nous Research) with an SSH sandbox backend to a k3s cluster, but applies to any AI agent with a code-execution sandbox.

## Guidance

### 1. Two-pod architecture with SSH communication

The agent and sandbox run as separate Deployments in the same namespace. The agent connects to the sandbox over SSH for code execution. This separation enables independent scaling, security policy enforcement, and lifecycle management.

```yaml
# Sandbox Deployment — runs sshd, accepts SSH connections from the agent
# Container port 2222 (non-privileged) instead of 22
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-agent-sandbox
  namespace: hermes-agent
spec:
  replicas: 1
  strategy:
    type: Recreate  # Required for single-replica Longhorn RWO
  template:
    spec:
      containers:
        - name: sandbox
          image: taegost/hermes-sandbox:v1.0.0
          ports:
            - name: ssh
              containerPort: 2222
          securityContext:
            allowPrivilegeEscalation: true  # Required for sshd privilege separation
            capabilities:
              drop: [ALL]
              add: [SETUID, SETGID, SYS_CHROOT, CHOWN, AUDIT_WRITE]
```

```yaml
# Agent Deployment — the main application pod
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-agent
  namespace: hermes-agent
spec:
  replicas: 1
  strategy:
    type: Recreate
  template:
    spec:
      containers:
        - name: hermes-agent
          image: nousresearch/hermes-agent:v2026.6.19
          securityContext:
            runAsUser: 10000
            runAsGroup: 10000
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]  # No capabilities needed — fully non-root
```

Key differences: the sandbox needs `allowPrivilegeEscalation: true` and specific capabilities for sshd, while the agent container drops everything. Never copy security contexts between these two pods.

### 2. SSH key management with ordered generation

SSH keypairs must be generated in a specific order because the known_hosts content derives from the sandbox host public key.

```bash
# Step 1: Generate sandbox host keypair FIRST
ssh-keygen -t ed25519 -f hermes-sandbox-host -C "hermes-sandbox-host" -N ""

# Step 2: Generate known_hosts from the host public key
echo "hermes-sandbox.hermes-agent.svc.cluster.local $(cat hermes-sandbox-host.pub)" > known_hosts_content

# Step 3: Generate agent client keypair (for authenticating to the sandbox)
ssh-keygen -t ed25519 -f hermes-agent-client -C "hermes-agent-client" -N ""
```

The agent's public key becomes the sandbox's `authorized_keys`. The sandbox's host key becomes the agent's `known_hosts`. All four artifacts must exist before secrets are sealed.

### 3. Three-layer SSH configuration (ConfigMaps + Secrets)

SSH configuration is split across ConfigMaps (non-sensitive, sync-wave -1) and Secrets (sensitive, mounted via subPath).

```yaml
# SSH client config — tells the agent how to reach the sandbox
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-agent-ssh-config
  namespace: hermes-agent
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
data:
  config: |
    Host hermes-sandbox
        HostName hermes-sandbox.hermes-agent.svc.cluster.local
        User hermes
        IdentityFile /opt/data/.ssh/id_ed25519
        UserKnownHostsFile /opt/data/.ssh/known_hosts
        StrictHostKeyChecking yes
        Port 22
```

```yaml
# sshd_config — sandbox-side configuration
# Port 2222 (non-privileged), key-only auth, restricted to hermes user
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-agent-sshd-config
  namespace: hermes-agent
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
data:
  sshd_config: |
    Port 2222
    ListenAddress 0.0.0.0
    PermitRootLogin no
    AllowUsers hermes
    PubkeyAuthentication yes
    PasswordAuthentication no
    HostKey /etc/ssh/ssh_host_ed25519_key
    AuthorizedKeysFile /home/hermes/.ssh/authorized_keys
```

ConfigMaps use sync-wave -1 so they exist before the Deployments start at wave 0. Secrets (SSH private keys) are mounted via `subPath` so individual keys land at specific paths without overwriting the data volume.

### 4. Sandbox network isolation

The sandbox must reach the internet for package installation but must not access cluster-internal services or the local network.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: hermes-sandbox
  namespace: hermes-agent
spec:
  podSelector:
    matchLabels:
      app: hermes-agent-sandbox
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: hermes-agent
          podSelector:
            matchLabels:
              app: hermes-agent
      ports:
        - protocol: TCP
          port: 2222
  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Open internet, excluding cluster and local network
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 192.168.0.0/16
```

The `ipBlock.except` mechanism blocks cluster CIDR and local network while allowing everything else. This is additive — to allow specific cluster services later, add explicit egress rules rather than narrowing the baseline.

### 5. Per-app certificate for mixed-access routes

Hermes has both internal-only routes (dashboard, API) and a public route (webhook). A per-app certificate is required because the webhook must be reachable from external services.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: hermes-taegost-com
  namespace: hermes-agent
spec:
  secretName: hermes-taegost-com-tls
  dnsNames:
    - hermes.taegost.com
  issuerRef:
    name: letsencrypt-diceninjagaming-prod
    kind: ClusterIssuer
```

Routes use different middlewares based on access level — `default-whitelist` for internal, `default-headers` for public — ordered most-specific-first in the IngressRoute.

### 6. Longhorn volume chown with fsGroup

Fresh Longhorn volumes are owned by root. Non-root containers cannot write to them on first start. Set `fsGroup` in the pod `securityContext` to the container's GID so Kubernetes chowns mounted volumes before the container starts.

```yaml
spec:
  template:
    spec:
      securityContext:
        fsGroup: 10000  # Matches runAsGroup in container securityContext
```

The GID must match what the image runs as — always verify from the Dockerfile.

### 7. Service port mapping for non-privileged containers

Non-root containers cannot bind to ports below 1024. The sandbox listens on 2222 internally; the Service maps port 22 to targetPort 2222 so SSH clients connect on the standard port within the cluster.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hermes-sandbox
  namespace: hermes-agent
spec:
  selector:
    app: hermes-agent-sandbox
  ports:
    - name: ssh
      port: 22
      targetPort: 2222
```

## Why This Matters

- **SSH key ordering failure**: If the known_hosts ConfigMap is generated before the sandbox host keypair, the agent cannot verify the sandbox identity and all SSH connections fail with host key verification errors.
- **Missing sync-wave on ConfigMaps**: If ConfigMaps are at wave 0 alongside Deployments, the agent pod starts before its SSH configuration exists, producing cryptic SSH errors instead of clear startup failures.
- **Sandbox breakout risk**: Without the NetworkPolicy, the sandbox pod can reach the Kubernetes API, database pods, and every service in the cluster — turning a code-execution sandbox into a lateral-movement pivot.
- **sshd capability denial**: sshd requires privilege separation (root-to-user transition). Without `allowPrivilegeEscalation: true` and the five required capabilities, every SSH session fails silently after the TCP handshake.
- **fsGroup mismatch**: If `fsGroup` does not match the container's GID, the chown targets the wrong group and the container still cannot write to the volume.

## When to Apply

- Deploying any AI agent with a sandboxed code execution backend (SSH, Docker-in-Docker, gVisor)
- Any application that needs a sidecar or companion pod running sshd
- Any deployment where two pods communicate over SSH within the same namespace
- When NetworkPolicy isolation is needed for untrusted code execution
- When a single PVC needs to be mounted at multiple paths (the librechat pattern)

## Examples

### Before: Single pod, no isolation

```yaml
# WRONG — agent and sandbox in one pod, no network isolation
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-agent
spec:
  template:
    spec:
      containers:
        - name: hermes-agent
          image: nousresearch/hermes-agent:v2026.6.19
        - name: sandbox
          image: taegost/hermes-sandbox:v1.0.0
          securityContext:
            capabilities:
              drop: [ALL]  # sshd crashes without capabilities
```

Problems: no network isolation between agent and sandbox, sshd capabilities missing, cannot scale independently, a sandbox crash takes down the agent.

### After: Two-pod architecture with full isolation

```yaml
# CORRECT — separate Deployments, NetworkPolicy, proper security contexts
# See the full manifests in apps/hermes-agent/
```

### Before: SSH config as environment variable

```yaml
# WRONG — SSH config can't fit in an env var cleanly
env:
  - name: SSH_CONFIG
    value: "Host sandbox\n    HostName ..."
```

### After: SSH config as ConfigMap mounted at subPath

```yaml
# CORRECT — ConfigMap with sync-wave -1, mounted into the agent's SSH directory
volumeMounts:
  - name: ssh-config
    mountPath: /opt/data/.ssh/config
    subPath: config
    readOnly: true
volumes:
  - name: ssh-config
    configMap:
      name: hermes-agent-ssh-config
```

### Port mapping pattern

```yaml
# Service: standard SSH port for cluster-internal clients
ports:
  - name: ssh
    port: 22        # Cluster-internal clients connect here
    targetPort: 2222 # Container actually listens here (non-root)

# sshd_config: matches containerPort
Port 2222
```

## Related

- `apps/hermes-agent/` — complete deployment manifests and README runbook
- `docs/solutions/best-practices/security-context-audit-pattern.md` — per-image capability analysis
- `docs/solutions/conventions/sync-wave-ordering.md` — wave ordering conventions
- `docs/solutions/runtime-errors/librechat-deployment-cascade.md` — NetworkPolicy namespaceSelector pattern
- `CLAUDE.md` — Storage section (Longhorn fsGroup, Recreate strategy)
- `CLAUDE.md` — Sync wave reference (ConfigMap exception rule)
