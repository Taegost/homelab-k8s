---
title: "feat: Deploy Hermes Agent with SSH Sandbox Backend"
status: completed
created: 2026-06-22
---

# feat: Deploy Hermes Agent with SSH Sandbox Backend

## Summary

Deploy [Hermes Agent](https://hermes-agent.nousresearch.com) (`nousresearch/hermes-agent:v2026.6.19`) as a new application in the homelab-k8s cluster under the namespace `hermes-agent`. Hermes is a self-improving AI agent by Nous Research with a built-in web dashboard, OpenAI-compatible API server, messaging gateway, and inbound webhook adapter. The deployment includes an SSH sandbox backend (`taegost/hermes-sandbox:v1.0.0`) running as a separate pod, with NetworkPolicy-enforced isolation restricting sandbox access to the hermes-agent pod only. Dashboard authentication uses self-hosted OIDC via Authentik. The API server integrates with the existing OpenWebUI instance.

## Problem Frame

The cluster needs a self-hosted AI agent that can:
- Run autonomously with persistent state across restarts
- Expose a web dashboard (port 9119), API server (port 8642), and webhook adapter (port 8644)
- Execute code in an isolated sandbox (SSH backend) with no cluster-internal access by default
- Authenticate dashboard users via the existing Authentik SSO infrastructure
- Connect to the existing LiteLLM backend for model inference
- Integrate with OpenWebUI as an API connection

Hermes Agent cannot scale horizontally (SQLite single-writer, shared bot tokens). It requires a single persistent volume for all state, process namespace sharing for dashboard gateway-liveness detection, and SSH keypairs for sandbox authentication.

## Requirements

| ID | Requirement |
|----|-------------|
| R1 | Single-replica Deployment with `strategy: Recreate` |
| R2 | Longhorn RWO PVC mounted at `/opt/data` for all Hermes state |
| R3 | Three ports exposed: 9119 (dashboard), 8642 (API/gateway), 8644 (webhooks) |
| R4 | `shareProcessNamespace: true` on the Pod spec |
| R5 | Container runs as UID 10000 (hermes user); no `HERMES_ALLOW_ROOT_GATEWAY` |
| R6 | Dashboard OIDC via Authentik (`HERMES_DASHBOARD_OIDC_ISSUER`, `HERMES_DASHBOARD_OIDC_CLIENT_ID`) |
| R7 | SSH sandbox backend with separate Deployment, ClusterIP Service (22→2222), and own Longhorn PVC |
| R8 | NetworkPolicy: sandbox reachable only on port 22 from hermes-agent pod; sandbox egress limited to open internet (no cluster or local network access) |
| R9 | Three SealedSecrets (SSH agent keypair, SSH sandbox keypair, Hermes agent config), three ConfigMaps (known_hosts, ssh_config, sshd_config) |
| R10 | API server enabled with key from SealedSecret; integration note for OpenWebUI |
| R11 | Model pointed at `litellm.diceninjagaming.com` |
| R12 | FQDN: `hermes.taegost.com` |
| R13 | Per-app cert (publicly exposed); dashboard and API use `default-whitelist` middleware; webhook uses `default-headers` |
| R14 | NetworkPolicy restricting hermes-agent ingress to Traefik only |

## Key Technical Decisions

### KTD1: Image version pinning

Pin to `nousresearch/hermes-agent:v2026.6.19` — the latest versioned tag as of 2026-06-22. The `:latest` tag is a moving target and blocked by the pre-commit hook. The sandbox image is pinned to `taegost/hermes-sandbox:v1.0.0` — the latest semver tag.

### KTD2: Sync wave strategy

- **SealedSecrets (SSH keypairs + API key)** — wave `-1`. Must decrypt before Deployments mount them. No CRDs consume these secrets, so wave `-3` is unnecessary.
- **ConfigMaps, Services, IngressRoutes, PVCs, Certificate, NetworkPolicy, Deployments** — wave `0` (default). No ordering dependencies beyond the secrets being present.

ConfigMaps consumed by Deployments at pod start (ssh-config, sshd-config, known-hosts) should also carry `argocd.argoproj.io/sync-wave: "-1"` to guarantee they exist before the Deployment pod starts. Resources at the same sync wave are applied in parallel — a ConfigMap at wave 0 is not guaranteed to exist before a Deployment at wave 0.

### KTD3: NetworkPolicy for sandbox isolation

The sandbox must NOT reach cluster-internal services (pods, services, the Kubernetes API) or the local network. The NetworkPolicy uses a deny-all-egress baseline with explicit allows for:
1. DNS (kube-dns at 10.43.0.10, port 53)
2. Non-cluster, non-local traffic (all destinations except 10.0.0.0/8 cluster CIDR and 192.168.0.0/16 local network)

Ingress is restricted to port 2222 from pods labeled `app: hermes-agent` in the same namespace.

**Future configurability:** As trust in the sandbox builds, egress rules can be relaxed by adding explicit `to` entries for specific cluster services (e.g., the LiteLLM API, the Postgres pooler). The deny-all baseline makes this additive — new rules open specific paths without removing the cluster-isolation guarantee.

### KTD4: Sandbox PVC mount paths

The sandbox needs three directories persisted: `/home/hermes`, `/opt/data`, and `/workspace`. A single Longhorn PVC is mounted at all three paths using the pattern from `apps/librechat/deployment-librechat.yaml` — multiple volume names referencing the same PVC claim, each with a different `mountPath`. This keeps PVC management simple (one volume to back up, resize, or monitor) while making all three paths persistent.

### KTD5: Port mapping for sandbox Service

The sandbox container exposes port 2222 (non-privileged). The ClusterIP Service listens on port 22 and forwards to targetPort 2222. This gives the Hermes pod a standard SSH port to connect to while keeping the container's sshd on a non-privileged port.

### KTD6: Dashboard auth via Authentik OIDC

Hermes supports self-hosted OIDC via `HERMES_DASHBOARD_OIDC_ISSUER` and `HERMES_DASHBOARD_OIDC_CLIENT_ID`. The Authentik setup requires creating an OAuth2/OIDC application and provider in the Authentik admin UI. The runbook documents the exact steps following the pattern established by Open WebUI and LiteLLM.

### KTD7: Model configuration

Point Hermes at the existing LiteLLM backend at `litellm.diceninjagaming.com`. The `OPENAI_BASE_URL` and `OPENAI_API_KEY` environment variables configure the provider endpoint at deployment time. The specific model is selected post-deployment via `hermes model` — these env vars just tell Hermes where to find the LiteLLM gateway. The LiteLLM API key is the same key used by Open WebUI.

### KTD8: fsGroup for Longhorn volumes

Hermes runs as UID 10000. Longhorn volumes provisioned owned by root require `fsGroup: 10000` in the pod securityContext so the kubelet chowns the volume on first mount. The sandbox also runs as UID 10000 and needs the same fsGroup.

## Implementation Units

### U1. Generate SSH Keypairs and Seal All Secrets

**Goal:** Document the SSH keypair generation workflow, provide Secret templates with kubeseal commands, and create all ConfigMaps. The user will populate and seal the secrets themselves.

**Requirements:** R7, R9

**Dependencies:** None (prerequisite for all other units)

**Files:**
- `apps/hermes-agent/configmap-hermes-agent-known-hosts.yaml`
- `apps/hermes-agent/configmap-hermes-agent-ssh-config.yaml`
- `apps/hermes-agent/configmap-hermes-agent-sshd-config.yaml`

**SealedSecrets (user-created, not in this unit's file list):**
- `apps/hermes-agent/sealedsecret-hermes-agent-ssh-agent-keys.yaml` — user creates and seals
- `apps/hermes-agent/sealedsecret-hermes-agent-ssh-sandbox-keys.yaml` — user creates and seals
- `apps/hermes-agent/sealedsecret-hermes-agent.yaml` — user creates and seals

**Approach:**

**SSH keypair generation workflow (manual, before any manifests are applied):**

```bash
# Generate sandbox host keypair (sandbox sshd identity)
ssh-keygen -t ed25519 -f hermes-sandbox-host -C "hermes-sandbox-host" -N ""

# Generate known_hosts content from the host public key
# The hostname must match the sandbox Service FQDN:
# hermes-sandbox.hermes-agent.svc.cluster.local
echo "hermes-sandbox.hermes-agent.svc.cluster.local $(cat hermes-sandbox-host.pub)" > known_hosts_content

# Generate agent keypair (hermes-agent authenticates to sandbox)
ssh-keygen -t ed25519 -f hermes-agent-client -C "hermes-agent-client" -N ""
```

**Generation order matters:** The sandbox host keypair must be generated first because the known_hosts content is derived from it. All four artifacts (both keypairs, known_hosts, and the SSH config) must be ready before any secrets are sealed.

**Secret templates (user populates and seals):**

Three plaintext Secret templates are needed. These are gitignored — only the sealed versions are committed.

```yaml
# secret-hermes-agent-ssh-agent-keys.yaml (gitignored)
# kubeseal --format yaml < secret-hermes-agent-ssh-agent-keys.yaml > apps/hermes-agent/sealedsecret-hermes-agent-ssh-agent-keys.yaml
apiVersion: v1
kind: Secret
metadata:
  name: hermes-agent-ssh-agent-keys
  namespace: hermes-agent
type: Opaque
stringData:
  id_ed25519: "<contents of hermes-agent-client>"
  id_ed25519.pub: "<contents of hermes-agent-client.pub>"
```

```yaml
# secret-hermes-agent-ssh-sandbox-keys.yaml (gitignored)
# kubeseal --format yaml < secret-hermes-agent-ssh-sandbox-keys.yaml > apps/hermes-agent/sealedsecret-hermes-agent-ssh-sandbox-keys.yaml
apiVersion: v1
kind: Secret
metadata:
  name: hermes-agent-ssh-sandbox-keys
  namespace: hermes-agent
type: Opaque
stringData:
  ssh_host_ed25519_key: "<contents of hermes-sandbox-host>"
  ssh_host_ed25519_key.pub: "<contents of hermes-sandbox-host.pub>"
```

```yaml
# secret-hermes-agent.yaml (gitignored)
# kubeseal --format yaml < secret-hermes-agent.yaml > apps/hermes-agent/sealedsecret-hermes-agent.yaml
apiVersion: v1
kind: Secret
metadata:
  name: hermes-agent
  namespace: hermes-agent
type: Opaque
stringData:
  api-server-key: "<generate with: openssl rand -hex 32>"
  oidc-client-id: "<from Authentik OAuth2/OIDC application>"
  webhook-secret: "<generate with: openssl rand -hex 32>"
  litellm-api-key: "<same LiteLLM API key used by Open WebUI>"
```

**Create ConfigMaps:**

`configmap-hermes-agent-known-hosts.yaml`:
- Content: the `known_hosts_content` file generated in Step 1
- Key: `known_hosts`

`configmap-hermes-agent-ssh-config.yaml`:
- Content:
  ```
  Host hermes-sandbox
      HostName hermes-sandbox.hermes-agent.svc.cluster.local
      User hermes
      IdentityFile /opt/data/.ssh/id_ed25519
      UserKnownHostsFile /opt/data/.ssh/known_hosts
      StrictHostKeyChecking yes
      Port 22
  ```
- Key: `config`

`configmap-hermes-agent-sshd-config.yaml`:
- Content:
  ```
  Port 2222
  ListenAddress 0.0.0.0
  PermitRootLogin no
  AllowUsers hermes
  PubkeyAuthentication yes
  PasswordAuthentication no
  ChallengeResponseAuthentication no
  UsePAM yes
  StrictModes no
  HostKey /etc/ssh/ssh_host_ed25519_key
  AuthorizedKeysFile /home/hermes/.ssh/authorized_keys
  Subsystem sftp /usr/lib/openssh/sftp-server
  ```
- Key: `sshd_config`

**SealedSecret sync wave annotations:** All three SealedSecrets must carry `argocd.argoproj.io/sync-wave: "-1"` in `metadata.annotations` (not just in `spec.template.metadata.annotations`). See `docs/sealed-secrets.md` and `docs/troubleshooting.md` for why this matters.

**Test expectation:** none — this unit produces configuration artifacts, not behavioral code.

**Verification:** All three ConfigMap files exist in `apps/hermes-agent/`. SealedSecrets (user-created) pass `kubeseal --validate`. ConfigMaps contain valid content. Known hosts file references the correct Service FQDN.

---

### U2. Hermes Main Deployment and Service

**Goal:** Create the main Hermes Deployment with all three ports, the Longhorn PVC, and the ClusterIP Service.

**Requirements:** R1, R2, R3, R4, R5, R11, R14

**Dependencies:** U1 (SealedSecrets and ConfigMaps must exist)

**Files:**
- `apps/hermes-agent/deployment-hermes-agent.yaml`
- `apps/hermes-agent/service-hermes-agent.yaml`
- `apps/hermes-agent/persistentvolumeclaim-hermes-agent-data.yaml`
- `apps/hermes-agent/networkpolicy-hermes-agent.yaml`

**Approach:**

**Deployment (`deployment-hermes-agent.yaml`):**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-agent
  namespace: hermes-agent
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hermes-agent
  template:
    metadata:
      labels:
        app: hermes-agent
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: memory-tier
                    operator: NotIn
                    values:
                      - small
      # shareProcessNamespace required per Hermes docs for dashboard
      # gateway-liveness detection. Both gateway and dashboard run in
      # the same container under s6-overlay, so this may be unnecessary
      # — test without it during implementation. Kept for now per R4.
      shareProcessNamespace: true
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
        fsGroup: 10000
      containers:
        - name: hermes-agent
          image: nousresearch/hermes-agent:v2026.6.19
          command: ["gateway", "run"]
          ports:
            - name: dashboard
              containerPort: 9119
            - name: api
              containerPort: 8642
            - name: webhook
              containerPort: 8644
          env:
            - name: HERMES_DASHBOARD
              value: "1"
            - name: HERMES_DASHBOARD_HOST
              value: "0.0.0.0"
            - name: HERMES_DASHBOARD_PORT
              value: "9119"
            - name: HERMES_DASHBOARD_PUBLIC_URL
              value: "https://hermes.taegost.com"
            - name: HERMES_DASHBOARD_OIDC_ISSUER
              value: "https://authentik.diceninjagaming.com/application/o/hermes/"
            - name: HERMES_DASHBOARD_OIDC_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: hermes-agent
                  key: oidc-client-id
            # Note: HERMES_DASHBOARD_OIDC_ISSUER does NOT need a Client Secret
            # because Hermes uses PKCE (authorization-code + PKCE), not a
            # confidential client flow. Only the Client ID is needed.
            - name: API_SERVER_ENABLED
              value: "true"
            - name: API_SERVER_HOST
              value: "0.0.0.0"
            - name: API_SERVER_PORT
              value: "8642"
            - name: API_SERVER_KEY
              valueFrom:
                secretKeyRef:
                  name: hermes-agent
                  key: api-server-key
            - name: WEBHOOK_ENABLED
              value: "true"
            - name: WEBHOOK_PORT
              value: "8644"
            - name: WEBHOOK_SECRET
              valueFrom:
                secretKeyRef:
                  name: hermes-agent
                  key: webhook-secret
            # ── Model / LiteLLM Backend ──────────────────────────────────────
            # Points Hermes at the existing LiteLLM instance. The model name
            # is set post-deployment via `hermes model` — these vars just
            # configure the provider endpoint.
            - name: OPENAI_BASE_URL
              value: "https://litellm.diceninjagaming.com/v1"
            - name: OPENAI_API_KEY
              valueFrom:
                secretKeyRef:
                  name: hermes-agent
                  key: litellm-api-key
          securityContext:
            runAsUser: 10000
            runAsGroup: 10000
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: data
              mountPath: /opt/data
            - name: ssh-client-key
              mountPath: /opt/data/.ssh/id_ed25519
              subPath: id_ed25519
              readOnly: true
            - name: known-hosts
              mountPath: /opt/data/.ssh/known_hosts
              subPath: known_hosts
              readOnly: true
            - name: ssh-config
              mountPath: /opt/data/.ssh/config
              subPath: config
              readOnly: true
          startupProbe:
            httpGet:
              path: /health
              port: 9119
            failureThreshold: 30
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 9119
            periodSeconds: 30
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health
              port: 9119
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 500Mi
            limits:
              cpu: 2000m
              memory: 4Gi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: hermes-agent-data
        - name: ssh-client-key
          secret:
            secretName: hermes-agent-ssh-agent-keys
            items:
              - key: id_ed25519
                path: id_ed25519
            defaultMode: 0400
        - name: known-hosts
          configMap:
            name: hermes-agent-known-hosts
        - name: ssh-config
          configMap:
            name: hermes-agent-ssh-config
```

**Key decisions in this manifest:**
- `command: ["gateway", "run"]` — starts the gateway process (which includes dashboard, API server, and webhook adapter) rather than the interactive CLI
- `shareProcessNamespace: true` — required for dashboard gateway-liveness detection
- `fsGroup: 10000` — matches the hermes user UID; kubelet chowns the Longhorn volume on first mount
- `runAsUser: 10000` / `runAsNonRoot: true` — image runs as UID 10000 by default; explicit for clarity and pre-commit validation
- `defaultMode: 0400` on the SSH private key — owner-read only; sshd and SSH clients are strict about key permissions
- SSH artifacts mounted into `/opt/data/.ssh/` — Hermes reads SSH config from its data directory
- `HERMES_DASHBOARD_OIDC_CLIENT_ID` from a SealedSecret (not yet in U1's secret template — added as a note)
- Resources: 500Mi request, 4Gi limit per the Hermes docs recommending 2-4GB
- Memory-tier nodeAffinity — avoids scheduling on nodes labeled `memory-tier=small`
- Startup probe on dashboard port 9119 with 30×10s budget (300s) for initial setup

**Service (`service-hermes-agent.yaml`):**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hermes-agent
  namespace: hermes-agent
spec:
  selector:
    app: hermes-agent
  ports:
    - name: dashboard
      port: 9119
      targetPort: 9119
    - name: api
      port: 8642
      targetPort: 8642
    - name: webhook
      port: 8644
      targetPort: 8644
```

**PVC (`persistentvolumeclaim-hermes-agent-data.yaml`):**

```yaml
# PersistentVolumeClaim — hermes-agent-data
#
# Longhorn-backed storage for Hermes Agent's /opt/data directory.
# Stores: SQLite session DB, config, memories, skills, credentials,
# per-profile gateway state, and SSH keys.
#
# Single-replica deployment with strategy: Recreate — RWO is correct.
#
# ** SECURITY NOTE: ** The hermes-agent process writes API keys to
# /opt/data/.env in plaintext on this Longhorn volume. Longhorn does not
# encrypt data at rest. If the physical disk, Longhorn replica, or backup
# is accessed, all credentials stored by hermes-agent are exposed. The SSH
# private key is NOT on this volume (it's mounted from a Secret via
# subPath). The sandbox pod does NOT write credentials to its PVC — all
# sensitive data in the sandbox is mounted read-only from Secrets.
# Monitor OQ5 for whether hermes-agent can read keys from env vars
# instead of .env.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hermes-agent-data
  namespace: hermes-agent
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
```

**NetworkPolicy (`networkpolicy-hermes-agent.yaml`):**

Restricts ingress to the hermes-agent pod to only Traefik (ports 9119, 8642, 8644). Egress is unrestricted — the agent needs access to LiteLLM, Authentik, and external services.

```yaml
# NetworkPolicy — hermes-agent
#
# Allows ingress only from Traefik (dashboard, API, webhook ports)
# and from the sandbox pod (SSH). All other ingress is denied.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: hermes-agent
  namespace: hermes-agent
spec:
  podSelector:
    matchLabels:
      app: hermes-agent
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
          podSelector:
            matchLabels:
              app.kubernetes.io/name: traefik
      ports:
        - protocol: TCP
          port: 9119
        - protocol: TCP
          port: 8642
        - protocol: TCP
          port: 8644
```

**Test scenarios:**
- Pod starts and reaches Ready state within the startup probe budget
- Dashboard accessible at `https://hermes.taegost.com` (via Traefik)
- API server responds at `https://hermes.taegost.com/api/v1/models`
- Webhook health check at `https://hermes.taegost.com/webhooks/health` returns `{"status": "ok"}` (note: the webhook health endpoint is at `/health` on port 8644 — verify during implementation whether Traefik's path-prefix routing intercepts this, or test from within the cluster)
- SSH config is readable at `/opt/data/.ssh/config` inside the pod
- Private key at `/opt/data/.ssh/id_ed25519` has mode 0400
- Direct pod IP access from non-Traefik pods is blocked by NetworkPolicy (ingress restricted to Traefik only)

**Verification:** `kubectl get pods -n hermes-agent` shows 1/1 Ready. All three ports respond to health checks via Traefik.

---

### U3. Sandbox Deployment and Service

**Goal:** Create the sandbox Deployment with SSH host keys, the ClusterIP Service (22→2222), and its own Longhorn PVC.

**Requirements:** R7, R8

**Dependencies:** U1 (SealedSecrets for host keypair)

**Files:**
- `apps/hermes-agent/deployment-hermes-sandbox.yaml`
- `apps/hermes-agent/service-hermes-sandbox.yaml`
- `apps/hermes-agent/persistentvolumeclaim-hermes-agent-sandbox-data.yaml`

**Approach:**

**Deployment (`deployment-hermes-sandbox.yaml`):**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-agent-sandbox
  namespace: hermes-agent
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hermes-agent-sandbox
  template:
    metadata:
      labels:
        app: hermes-agent-sandbox
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: memory-tier
                    operator: NotIn
                    values:
                      - small
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
        fsGroup: 10000
      containers:
        - name: sandbox
          image: taegost/hermes-sandbox:v1.0.0
          ports:
            - name: ssh
              containerPort: 2222
          securityContext:
            # The sandbox image starts as root (required for sshd privilege
            # separation) and drops to user hermes via its entrypoint.
            # allowPrivilegeEscalation is required — without it, every SSH
            # session fails. Capabilities needed for sshd: SETUID, SETGID,
            # SYS_CHROOT, CHOWN, AUDIT_WRITE.
            allowPrivilegeEscalation: true
            capabilities:
              drop:
                - ALL
              add:
                - SETUID
                - SETGID
                - SYS_CHROOT
                - CHOWN
                - AUDIT_WRITE
          volumeMounts:
            # Three mounts from the same PVC — librechat pattern.
            # Each path gets its own persistent storage backed by
            # the same Longhorn volume.
            - name: home-hermes
              mountPath: /home/hermes
            - name: opt-data
              mountPath: /opt/data
            - name: workspace
              mountPath: /workspace
            - name: authorized-keys
              mountPath: /home/hermes/.ssh/authorized_keys
              subPath: authorized_keys
              readOnly: true
            - name: ssh-sandbox-keys
              mountPath: /etc/ssh/ssh_host_ed25519_key
              subPath: ssh_host_ed25519_key
              readOnly: true
            - name: ssh-sandbox-keys
              mountPath: /etc/ssh/ssh_host_ed25519_key.pub
              subPath: ssh_host_ed25519_key.pub
              readOnly: true
            - name: sshd-config
              mountPath: /etc/ssh/sshd_config
              subPath: sshd_config
              readOnly: true
          startupProbe:
            tcpSocket:
              port: 2222
            failureThreshold: 30
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 2222
            periodSeconds: 30
            failureThreshold: 3
          readinessProbe:
            tcpSocket:
              port: 2222
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 2Gi
      volumes:
        - name: home-hermes
          persistentVolumeClaim:
            claimName: hermes-agent-sandbox-data
        - name: opt-data
          persistentVolumeClaim:
            claimName: hermes-agent-sandbox-data
        - name: workspace
          persistentVolumeClaim:
            claimName: hermes-agent-sandbox-data
        - name: authorized-keys
          secret:
            secretName: hermes-agent-ssh-agent-keys
            items:
              - key: id_ed25519.pub
                path: authorized_keys
            defaultMode: 0644
        - name: ssh-sandbox-keys
          secret:
            secretName: hermes-agent-ssh-sandbox-keys
            defaultMode: 0400
        - name: sshd-config
          configMap:
            name: hermes-agent-sshd-config
```

**Key decisions:**
- Pinned to `taegost/hermes-sandbox:v1.0.0` — never use `:latest` in manifests
- `allowPrivilegeEscalation: true` — required for sshd privilege separation; the sandbox image explicitly documents this
- Capabilities: `SETUID`, `SETGID`, `SYS_CHROOT`, `CHOWN`, `AUDIT_WRITE` — minimum set for sshd after dropping ALL
- `fsGroup: 10000` — matches the hermes user in the sandbox image
- Three PVC volume mounts (`home-hermes`, `opt-data`, `workspace`) all referencing the same PVC — librechat pattern for multi-path persistence
- `authorized_keys` mounted from the agent keypair SealedSecret's public key only (`items` field) — the private key is never exposed to the sandbox
- Host keys mounted at `/etc/ssh/` with `defaultMode: 0400` — sshd refuses to start otherwise
- `sshd_config` mounted from ConfigMap — configures non-privileged port 2222, key-only auth, restricts to `hermes` user
- TCP socket probes on port 2222 (not HTTP) — sshd doesn't serve HTTP health endpoints
- Memory-tier nodeAffinity — avoids scheduling on nodes labeled `memory-tier=small`

**Service (`service-hermes-sandbox.yaml`):**

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

**PVC (`persistentvolumeclaim-hermes-agent-sandbox-data.yaml`):**

```yaml
# PersistentVolumeClaim — hermes-agent-sandbox-data
#
# Longhorn-backed storage for the Hermes sandbox.
# Stores: agent-executed code, installed packages, and working state.
# Mounted at /home/hermes, /opt/data, and /workspace (librechat pattern —
# multiple volume names referencing the same PVC claim).
#
# Separate from the main hermes-agent PVC — the sandbox has its own lifecycle.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hermes-agent-sandbox-data
  namespace: hermes-agent
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
```

**Test scenarios:**
- Sandbox pod starts and reaches Ready state
- `ssh -p 22 hermes@hermes-sandbox.hermes-agent.svc.cluster.local` succeeds from the Hermes pod
- SSH connection refused from any other pod (NetworkPolicy enforcement)
- Host key at `/etc/ssh/ssh_host_ed25519_key` has mode 0400
- `authorized_keys` at `/home/hermes/.ssh/authorized_keys` contains the correct public key

**Verification:** `kubectl get pods -n hermes-agent` shows hermes-sandbox 1/1 Ready. SSH from Hermes pod to sandbox succeeds.

**seccompProfile gate:** If sshd sessions fail immediately after connection (chroot error in container logs), change the sandbox pod securityContext to `seccompProfile.type: Unconfined`. This is the most likely first deployment blocker — test SSH connectivity before proceeding to U4/U5.

---

### U4. NetworkPolicy for Sandbox Isolation

**Goal:** Enforce that the sandbox is only reachable on port 22 from the Hermes pod, and the sandbox cannot reach cluster-internal services.

**Requirements:** R8

**Dependencies:** None (can be applied independently)

**Files:**
- `apps/hermes-agent/networkpolicy-hermes-sandbox.yaml`

**Approach:**

```yaml
# NetworkPolicy — hermes-sandbox
#
# Restricts the sandbox pod's network access:
# - Ingress: only port 2222 from the hermes-agent pod (same namespace)
# - Egress: DNS only + all non-cluster, non-local traffic (open internet)
#
# This ensures the sandbox cannot reach cluster-internal services (pods,
# services, Kubernetes API) or the local network by default. As trust
# builds, specific cluster services can be added as explicit egress rules.
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
    # Allow DNS resolution (kube-dns)
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
    # Allow all non-cluster, non-local egress (open internet).
    # Block cluster CIDR (10.0.0.0/8) and local network (192.168.0.0/16).
    # The `except` clause in ipBlock is the standard k8s NetworkPolicy
    # mechanism for excluding CIDRs. To allow access to specific cluster
    # services (e.g., LiteLLM), add explicit egress rules with ipBlock
    # or namespaceSelector entries — the deny-all baseline makes this
    # additive.
    #
    # Note: FQDN-based egress filtering is not supported by standard
    # k8s NetworkPolicy. If the sandbox needs access to a specific
    # cluster hostname, either add an ipBlock rule for the service's
    # ClusterIP, or use Calico NetworkPolicy which supports FQDN rules.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 192.168.0.0/16
```

**Test scenarios:**
- Sandbox can resolve DNS (e.g., `nslookup google.com` from inside sandbox)
- Sandbox can reach external services (e.g., `curl https://httpbin.org`)
- Sandbox CANNOT reach `postgres-pooler.postgres.svc.cluster.local`
- Sandbox CANNOT reach other pods by IP
- Sandbox CANNOT reach local network (192.168.0.0/16)
- Hermes-agent pod CAN reach sandbox on port 22
- Other pods CANNOT reach sandbox on any port

**Verification:** `kubectl exec -n hermes-agent deployment/hermes-agent-sandbox -- curl -s https://httpbin.org/ip` succeeds. `kubectl exec -n hermes-agent deployment/hermes-agent-sandbox -- curl -s http://litellm.litellm.svc.cluster.local:4000/health` times out.

---

### U5. IngressRoutes and Certificate

**Goal:** Expose the dashboard, API, and webhook ports through Traefik with proper TLS certificates.

**Requirements:** R3, R12, R13

**Dependencies:** U2 (Service must exist)

**Files:**
- `apps/hermes-agent/ingressroute-hermes-agent.yaml`
- `apps/hermes-agent/certificate-hermes-agent.yaml`
- `apps/aws-ddns/deployment-aws-ddns-taegost.yaml` — add `hermes.taegost.com` to the `DOMAIN` env var

**Approach:**

**Certificate (`certificate-hermes-agent.yaml`):**

```yaml
# Certificate — hermes.taegost.com
#
# Hermes is publicly exposed (webhook adapter must be reachable from
# external services like GitHub), so it gets a dedicated certificate
# rather than relying on the shared wildcard.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: hermes-taegost-com
  namespace: hermes-agent
spec:
  secretName: hermes-taegost-com-tls
  duration: 2160h
  renewBefore: 720h
  dnsNames:
    - hermes.taegost.com
  issuerRef:
    name: letsencrypt-diceninjagaming-prod
    kind: ClusterIssuer
    group: cert-manager.io
```

**IngressRoute (`ingressroute-hermes-agent.yaml`):**

Three routes, one per port:
1. Dashboard (9119) — `default-whitelist` middleware (internal only)
2. API server (8642) — `default-whitelist` middleware (internal only)
3. Webhook adapter (8644) — `default-headers` middleware (publicly accessible for external webhook sources)

```yaml
# IngressRoute — hermes.taegost.com
#
# Three routes for the three Hermes ports:
# - /               → dashboard (9119) — internal only (default-whitelist)
# - /api            → API server (8642) — internal only (default-whitelist)
# - /webhooks       → webhook adapter (8644) — public (default-headers)
#
# The webhook route MUST be publicly accessible — external services
# (GitHub, GitLab, etc.) need to reach it. Dashboard and API are
# restricted to internal subnets via default-whitelist.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: hermes-agent
  namespace: hermes-agent
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`hermes.taegost.com`) && PathPrefix(`/api`)
      kind: Rule
      middlewares:
        - name: default-whitelist
          namespace: traefik
      services:
        - name: hermes-agent
          namespace: hermes-agent
          port: 8642
    - match: Host(`hermes.taegost.com`) && PathPrefix(`/webhooks`)
      kind: Rule
      middlewares:
        - name: default-headers
          namespace: traefik
      services:
        - name: hermes-agent
          namespace: hermes-agent
          port: 8644
    - match: Host(`hermes.taegost.com`)
      kind: Rule
      middlewares:
        - name: default-whitelist
          namespace: traefik
      services:
        - name: hermes-agent
          namespace: hermes-agent
          port: 9119
  tls:
    secretName: hermes-taegost-com-tls
```

**Key decisions:**
- Per-app cert (not wildcard) because Hermes is publicly exposed — the webhook adapter must be reachable from external services
- All three routes share the same hostname (`hermes.taegost.com`); path prefix matching routes to the correct backend
- `/api` and `/webhooks` routes listed before the catch-all `/` route — Traefik evaluates routes in order, and more specific paths must match first
- `default-whitelist` on dashboard and API routes (internal subnet restriction + security headers)
- `default-headers` on webhook route (security headers only, publicly accessible)

**Path-prefix routing consideration:** Traefik forwards the full request URI to the backend, including the path prefix. The [webhook documentation](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/webhooks) documents the webhook URL conventions — verify during implementation whether the API server and webhook adapter expect prefixed paths. If a `StripPrefix` middleware is needed, create a `middleware-hermes-agent-strip-prefix.yaml` and apply it to the relevant route(s).

**Webhook security:** Hermes enforces HMAC signature verification on incoming webhooks using `WEBHOOK_SECRET`. The webhook endpoint is publicly accessible (no IP restriction), but unauthorized requests without a valid signature are rejected by Hermes internally. Resolve OQ4 (secret format) before implementation.

**Dashboard auth:** The dashboard route uses `default-whitelist` (internal subnet restriction). Hermes has built-in OIDC via `HERMES_DASHBOARD_OIDC_ISSUER`. Verify during implementation whether Hermes's OIDC enforcement is mandatory — if optional, add the `authentik` forward-auth middleware to the dashboard route for defense-in-depth. The `default-whitelist` middleware ensures the dashboard is not publicly exposed regardless.

**Test scenarios:**
- `https://hermes.taegost.com` loads the dashboard
- `https://hermes.taegost.com/api/v1/models` returns the API model list
- `https://hermes.taegost.com/webhooks/health` returns the webhook health response
- TLS certificate is issued and valid

**Verification:** All three URLs return 200 responses. Certificate shows as Ready in `kubectl get certificate -n hermes-agent`.

---

### U6. ArgoCD Application Manifest

**Goal:** Register the Hermes app with ArgoCD for GitOps management.

**Requirements:** All

**Dependencies:** All prior units (manifests must exist in `apps/hermes-agent/`)

**Files:**
- `apps/manifests/hermes-agent.yaml`

**Approach:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hermes-agent
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/Taegost/homelab-k8s
    targetRevision: HEAD
    path: apps/hermes-agent
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: hermes-agent
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Standard pattern — follows `apps/manifests/mealie.yaml` exactly. `CreateNamespace=true` handles the `hermes-agent` namespace creation.

**Test expectation:** none — this is scaffolding.

**Verification:** `kubectl get application hermes-agent -n argocd` shows the app as Synced and Healthy.

---

### U7. Runbook Documentation

**Goal:** Create a runbook documenting the full deployment procedure, Authentik OIDC setup, SSH keypair generation workflow, post-deployment configuration, and troubleshooting.

**Requirements:** R6, R10

**Dependencies:** All prior units (documentation references the manifests)

**Files:**
- `apps/hermes-agent/README.md`

**Approach:**

The runbook covers:

1. **Prerequisites** — list of what must exist before deployment (cluster, Longhorn, Traefik, cert-manager, Authentik)

2. **SSH Keypair Generation** — the exact commands from U1, with emphasis on:
   - Generation order (host keypair first, then known_hosts, then client keypair)
   - Known hosts format (Service FQDN as hostname)
   - All four artifacts must be ready before sealing

3. **Sealed Secrets** — the sealing workflow from U1, including:
   - Namespace creation before sealing
   - Plaintext secrets are gitignored
   - `kubeseal` commands as single lines

4. **Authentik OIDC Setup** — step-by-step:
   - Create Authentik group "Hermes Users"
   - Create OAuth2/OIDC application:
     - Name: Hermes
     - Slug: `hermes`
     - Launch URL: `https://hermes.taegost.com`
   - Create provider:
     - Type: OAuth2/OIDC
     - Client ID: (auto-generated — copy to SealedSecret)
     - Client Secret: (auto-generated — copy to SealedSecret)
     - Redirect URI: `https://hermes.taegost.com/oauth/oidc/callback` (verify against Hermes docs — see OQ2)
     - Scopes: `openid`, `profile`, `email`
   - Bind provider to application
   - Note: Hermes uses PKCE (authorization-code + PKCE), so only the Client ID is needed in the env var — no Client Secret

5. **Model Configuration** — post-deployment:
   - Exec into the pod: `kubectl exec -it -n hermes-agent deployment/hermes-agent -- bash`
   - Configure LiteLLM backend: `hermes model` → select OpenAI-compatible → set base URL to `https://litellm.diceninjagaming.com/v1` → enter API key
   - Or edit `/opt/data/config.yaml` directly

6. **API Server Integration** — after deployment:
   - The API server is available at `https://hermes.taegost.com/api/v1`
   - In Open WebUI admin, add a new connection:
     - URL: `https://hermes.taegost.com/api/v1`
     - API Key: the value from the `hermes-agent` SealedSecret's `api-server-key`
   - Note: `API_SERVER_MODEL_NAME` can be set to customize the model name shown in Open WebUI

7. **Multi-profile Management** — post-deployment:
   - Profiles are managed inside the container by s6 supervisor
   - Create additional profiles: `kubectl exec -it -n hermes-agent deployment/hermes-agent -- hermes profile create <name>`
   - Each profile gets its own config, sessions, and gateway state under `/opt/data/profiles/<name>/`
   - No additional pods or Deployments needed

8. **Webhook Configuration** — post-deployment:
   - Webhooks are configured via `hermes webhook setup` or `config.yaml` under `platforms.webhook`
   - Document the webhook URL: `https://hermes.taegost.com/webhooks/<route-name>`
   - Reference the [webhook documentation](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/webhooks) for route configuration

9. **Security note — credential-at-rest** — **The hermes-agent process writes API keys to `/opt/data/.env` in plaintext on the Longhorn volume.** Longhorn does not encrypt data at rest. The SSH private key is safe (mounted from a Secret, not on the PVC), but application-level credentials are exposed if the disk, replica, or backup is accessed. The sandbox pod does NOT have this issue — its sensitive data is mounted read-only from Secrets. Evaluate whether hermes-agent can read keys from environment variables (SealedSecrets) instead of `.env`. See OQ5.

10. **Troubleshooting** — common issues:
   - Pod stuck in CreateContainerConfigError: check SealedSecrets are decrypted
   - Dashboard shows 401: check OIDC client ID and Authentik provider configuration
   - SSH to sandbox fails: check NetworkPolicy, key permissions, sshd config
   - Sandbox can't reach internet: check NetworkPolicy egress rules

**Test expectation:** none — this is documentation.

**Verification:** README.md exists, covers all sections, commands are copy-paste friendly, `kubeseal` commands are single-line.

---

## Scope Boundaries

### In scope
- All Kubernetes manifests for Hermes and its sandbox
- SealedSecrets for SSH keypairs and API key
- ConfigMaps for SSH configuration
- NetworkPolicy for sandbox isolation
- IngressRoutes and TLS certificate
- ArgoCD Application manifest
- Runbook documentation with Authentik OIDC setup

### Deferred to Follow-Up Work
- **Sandbox PVC mount path validation** — `/home/hermes`, `/opt/data`, and `/workspace` are confirmed. Additional directories may be needed — verify by running the sandbox image and inspecting its filesystem after first boot.
- **Messaging platform configuration** — Telegram, Discord, Slack, etc. are configured via `hermes gateway setup` after deployment. Not covered in this plan.
- **Webhook route configuration** — specific webhook routes (GitHub, GitLab, etc.) are configured post-deployment. The plan enables the webhook adapter; routes are added later.
- **Additional Hermes profiles** — created via `hermes profile create` after deployment. No manifest changes needed.
- **Hermes skills installation** — installed via `/skills` command or `hermes skills` after deployment.

### Outside this product's identity
- Custom Hermes model training or fine-tuning
- Hosting Hermes for multiple users (multi-tenant)
- Replacing Open WebUI with Hermes dashboard

## Open Questions

| ID | Question | Status |
|----|----------|--------|
| OQ1 | Which sandbox directories need persistence? | Resolved — `/home/hermes`, `/opt/data`, and `/workspace` — all persisted via a single PVC with multiple mounts (KTD4). |
| OQ2 | Does the Hermes dashboard OIDC callback path match the standard `/oauth/oidc/callback` pattern, or is it different? Check the Hermes docs or source. | Open — resolve during implementation |
| OQ3 | Does the `hermes-agent` image include `openssh-client` for SSH to the sandbox, or does a derived image need to be built? | Resolved — the Docker docs confirm `openssh-client` is included |
| OQ4 | What is the correct `WEBHOOK_SECRET` format? The docs mention HMAC — is it a raw string or base64? | Deferred to implementation |
| OQ5 | Can Hermes read API keys from environment variables instead of `.env` file? If so, keys can be injected from SealedSecrets and never written to the PVC. If not, Longhorn encryption-at-rest must be evaluated before deployment. | Open — resolve before implementation |

## Risks & Dependencies

| Risk | Severity | Mitigation |
|------|----------|------------|
| **Hermes stores API keys in plaintext on the PVC.** The `.env` file at `/opt/data/.env` contains all API keys (LiteLLM, OpenAI, `API_SERVER_KEY`, etc.) in plaintext. Longhorn does not encrypt data at rest. If the physical disk, Longhorn replica, or backup is accessed, all credentials are exposed. The SSH private key is safe (mounted from Secret via `subPath`, not stored on PVC), but application-level credentials are not. | **High** | Mitigation options: (1) Use Longhorn's built-in encryption-at-rest feature if available, (2) Ensure Longhorn replicas are only on trusted nodes, (3) Do not back up the PVC to unencrypted storage, (4) Consider whether some API keys can be passed as env vars from SealedSecrets instead of letting Hermes write them to `.env` — this depends on whether Hermes reads from env vars or only from its `.env` file. **This must be evaluated before implementation.** |
| Sandbox image pinned to v1.0.0 — newer releases may have security fixes | Low | Monitor Docker Hub for new tags; update the image tag when new versions are released |
| SSH host key rotation breaks known_hosts | Low | Host keys are generated once and sealed; rotation requires re-sealing and re-deploying both secrets |
| NetworkPolicy `except` blocks 10.0.0.0/8 — if cluster CIDRs expand beyond this range, they're still blocked | Low | The `except` clause covers the full 10.0.0.0/8 range. If the cluster uses a different range, update the policy |
| Longhorn volume `lost+found` directory confuses Hermes | Low | Hermes creates its own data structure under `/opt/data`; `lost+found` at the volume root should be harmless. If issues arise, use a subdirectory |
| `allowPrivilegeEscalation: true` on sandbox violates security baseline | Medium | Required for sshd privilege separation; documented in the sandbox image. Defense-in-depth via NetworkPolicy isolation compensates |
| `seccompProfile: Unconfined` may be needed for sandbox | Medium | The sandbox image docs note that `chroot(2)` syscalls may be blocked by seccomp RuntimeDefault. Test first; add `Unconfined` only if sshd sessions fail |

## Sources & Research

- [Hermes Agent Docker Hub](https://hub.docker.com/r/nousresearch/hermes-agent) — image tags, pull stats
- [Hermes Agent GitHub](https://github.com/NousResearch/hermes-agent) — project structure, features
- [Hermes Agent Docker Docs](https://hermes-agent.nousresearch.com/docs/user-guide/docker) — deployment, ports, volumes, env vars
- [Hermes Agent Environment Variables](https://hermes-agent.nousresearch.com/docs/reference/environment-variables) — full env var reference
- [Hermes Agent Security Docs](https://hermes-agent.nousresearch.com/docs/user-guide/security) — SSH backend config
- [Hermes Agent Webhook Docs](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/webhooks) — webhook adapter, URL conventions, port 8644
- [Hermes Sandbox Docker Hub](https://hub.docker.com/r/taegost/hermes-sandbox) — image details, capabilities, volume mounts
- Existing patterns: `apps/mealie/`, `apps/open-webui/`, `apps/litellm/` — IngressRoute, SealedSecret, OIDC conventions
