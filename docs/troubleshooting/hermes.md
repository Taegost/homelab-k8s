# Hermes Agent Troubleshooting

## Terminal Tool SSH Configuration Error (2026-08-10)

### Issue
After upgrading to Hermes 0.19.0, the terminal tool failed with:
```
ValueError: SSH environment requires ssh_host and ssh_user to be configured
```

### Root Cause
Hermes 0.19.0 changed the configuration parameter names for the SSH terminal backend. The old parameter names (without the `ssh_` prefix) were no longer recognized.

**Old config.yaml (broken):**
```yaml
terminal:
  backend: ssh
  host: hermes-sandbox.hermes-agent.svc.cluster.local
  user: hermes
  key: /opt/data/.ssh/id_ed25519
  port: 22
```

**New config.yaml (fixed):**
```yaml
terminal:
  backend: ssh
  ssh_host: hermes-sandbox.hermes-agent.svc.cluster.local
  ssh_user: hermes
  ssh_key: /opt/data/.ssh/id_ed25519
  ssh_port: 22
```

### Fix Applied
Updated `/opt/data/config.yaml` on the PVC to use the new parameter names with the `ssh_` prefix.

### Verification
```bash
# Test SSH connection directly
kubectl exec -n hermes-agent deployment/hermes-agent -- \
  ssh -o StrictHostKeyChecking=no -i /opt/data/.ssh/id_ed25519 -p 22 \
  hermes@hermes-sandbox.hermes-agent.svc.cluster.local echo "SSH OK"

# Test terminal tool via Python
kubectl exec -n hermes-agent deployment/hermes-agent -- bash -c '
  cd /opt/hermes && python3 -c "
  import yaml
  from tools.environments.ssh import SSHEnvironment
  with open(\"/opt/data/config.yaml\") as f:
      config = yaml.safe_load(f)
  term = config.get(\"terminal\", {})
  env = SSHEnvironment(
      host=term.get(\"ssh_host\", \"\"),
      user=term.get(\"ssh_user\", \"\"),
      port=term.get(\"ssh_port\", 22),
      key_path=term.get(\"ssh_key\", \"\"),
  )
  result = env.execute(\"echo SSH_OK\")
  print(f\"Result: {result}\")
  env.cleanup()
"'
```

### Notes
- The Service `hermes-sandbox` maps port 22 → targetPort 2222
- The sandbox container runs sshd on port 2222
- The SSH client and config.yaml should use port 22 (the Service port)
- No changes needed to the ConfigMap or deployment manifests

### Related
- Hermes 0.19.0 release notes (if available)
- SSH backend documentation: https://hermes-agent.nousresearch.com/docs/user-guide/configuration/
