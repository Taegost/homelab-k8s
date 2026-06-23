---
title: Certificate stuck pending — wrong Route53 issuer for domain
date: 2026-06-23
category: runtime-errors
module: cert-manager
problem_type: runtime_error
component: authentication
symptoms:
  - Certificate stuck in False/Ready state
  - ACME challenge pending for hours
  - "failed to determine Route 53 hosted zone ID: zone not found in Route 53" in cert-manager logs
root_cause: config_error
resolution_type: config_change
severity: high
tags: [cert-manager, route53, letsencrypt, acme, dns-01, sealed-secrets]
---

# Certificate stuck pending — wrong Route53 issuer for domain

## Problem

Certificate for `hermes.taegost.com` stuck in pending state for 2+ hours. The ACME DNS-01 challenge was failing because cert-manager couldn't find the Route53 hosted zone for the domain.

## Symptoms

- `kubectl get certificate` shows `Ready: False` for hours
- `kubectl get challenge` shows challenge stuck in `pending` state
- cert-manager logs repeating: `failed to determine Route 53 hosted zone ID: zone not found in Route 53 for domain _acme-challenge.hermes.taegost.com`

## What Didn't Work

- Waiting for the challenge to complete (it never would — the Route53 lookup was failing)
- Deleting the challenge (the finalizer blocked deletion, causing it to get stuck in Terminating state)

## Solution

1. **Identify the issue:** The Certificate was using `letsencrypt-diceninjagaming-prod` ClusterIssuer, which has Route53 credentials for the `diceninjagaming.com` hosted zone only

2. **Check available issuers:**
   ```bash
   kubectl get clusterissuer
   ```

3. **Update Certificate to use correct issuer:**
   ```yaml
   # certificate-hermes-agent.yaml
   spec:
     issuerRef:
       name: letsencrypt-taegost-prod  # was: letsencrypt-diceninjagaming-prod
       kind: ClusterIssuer
       group: cert-manager.io
   ```

4. **If challenge is stuck with finalizer, remove it:**
   ```bash
   kubectl patch challenge <challenge-name> -n <namespace> --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
   ```

## Why This Works

Each ClusterIssuer has its own Route53 credentials scoped to a specific hosted zone. The `letsencrypt-diceninjagaming-prod` issuer can only manage DNS records in the `diceninjagaming.com` zone. When cert-manager tried to create the `_acme-challenge.hermes.taegost.com` TXT record, it couldn't find the `taegost.com` zone because the credentials didn't have access.

Switching to `letsencrypt-taegost-prod` uses credentials with access to the correct hosted zone.

## Prevention

- When creating certificates, always verify the ClusterIssuer has access to the correct Route53 hosted zone
- Use `kubectl get clusterissuer` to list available issuers and their purposes
- Consider adding comments in Certificate manifests noting which hosted zone the issuer targets
- Monitor cert-manager logs during initial certificate provisioning — the "zone not found" error is distinctive and actionable

## Related Issues

- Stuck challenge finalizer: When a challenge fails, the finalizer can block deletion. Use `kubectl patch challenge` to remove it.
- Multiple hosted zones: If managing domains across multiple Route53 zones, ensure each domain's Certificate references the correct issuer
