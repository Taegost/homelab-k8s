---
title: "feat: Add wordpress-taegost site and aws-ddns for taegost.com"
type: feat
status: active
created: 2026-05-22
---

# feat: Add wordpress-taegost site and aws-ddns for taegost.com

Deploy a new WordPress instance at `taegost.com` for Mike's professional portfolio and blog, alongside a new `aws-ddns-personal` deployment to keep the domain's Route53 DNS records current. Because `taegost.com` uses separate AWS credentials from `diceninjagaming.com`, new cert-manager infrastructure (credentials secret + ClusterIssuers) is required before any TLS certificate can be issued.

---

## Problem Frame

The cluster already runs `wordpress-dng` at `diceninjagaming.com`. Mike wants a second, independent WordPress site at `taegost.com` for his professional portfolio. The two sites share the cluster's MariaDB instance but are otherwise fully isolated. `taegost.com` lives in a separate Route53 hosted zone managed under different AWS credentials, so new cert-manager issuers are needed before a TLS cert can be provisioned.

---

## Scope Boundaries

### In scope
- New cert-manager credential secret and ClusterIssuers for `taegost.com`
- New WordPress deployment (`wordpress-taegost`) at `taegost.com` — 2 replicas, Longhorn RWX PVC
- All supporting manifests: namespace, MariaDB CRDs, sealed secrets, PVC, Certificate, Service, IngressRoute, ArgoCD Application
- New `aws-ddns-personal` deployment for `taegost.com` Route53 DNS updates

### Deferred to Follow-Up Work
- Authentik SSO protection for wp-admin (the commented-out route block from wordpress-dng is the pattern to follow when ready)
- Switching the IngressRoute from `default-whitelist` to public (`default-headers`) once the site is ready for public traffic — **the SSO route block above must be implemented and verified before this switchover**; going public without it exposes `/wp-login.php` and `/wp-admin` to internet brute-force attacks
- PHP plugin/theme installation and WordPress admin setup (post-deploy, manual)

### Out of scope
- Route53 hosted zone creation for `taegost.com` (assumed to already exist)
- IAM policy setup for the new AWS user (assumed to be configured out-of-band before sealing the credential secret)
- Any changes to `wordpress-dng` or the existing aws-ddns deployment

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Separate ClusterIssuers | `letsencrypt-taegost-prod` + `letsencrypt-taegost-staging` | taegost.com uses different AWS credentials; the existing `route53-credentials` secret only covers the DNG zone. Two new issuers pointing at a new `route53-credentials-taegost` secret are required. |
| Cert-manager staging-first | Start with staging issuer in the Certificate resource | Production issuer rate limits (5 failed validations/hour, 50 certs/domain/week) make staging validation mandatory. Switch to prod only after `kubectl get certificate` shows `Ready=True` on staging. |
| 2 replicas + RWX PVC | Same as `wordpress-dng` | Requested by user. RWX access mode allows simultaneous pod attachment; no `strategy: Recreate` needed (unlike RWO). |
| Shared auth keys SealedSecret | Dedicated `wordpress-taegost-keys` secret with all 8 keys/salts | Multi-replica deployments require consistent auth keys — each pod generates random keys at startup if env vars are absent, causing cross-pod cookie validation failures. Keys must be pre-generated and injected. |
| aws-ddns in shared namespace | New `personal-deployment.yaml` and `personal-sealedsecret.yaml` in `apps/aws-ddns/` | The existing `aws-ddns` ArgoCD Application already manages the whole directory; no new Application manifest is needed. The namespace comment explicitly documents this pattern. |
| No configmap for aws-ddns-personal | `DOMAIN` env var inline in deployment | The dng deployment doesn't use a ConfigMap either; the namespace comment mentioned one as a suggestion. Keeping non-sensitive config inline matches the established pattern. |

---

## Dependencies

- MariaDB operator and cluster running in `mariadb` namespace (already deployed)
- cert-manager running in `cert-manager` namespace (already deployed)
- Sealed Secrets controller running in `kube-system` (already deployed)
- `taegost.com` hosted zone exists in Route53
- AWS IAM user for `taegost.com` has `route53:GetChange`, `route53:ChangeResourceRecordSets`, `route53:ListResourceRecordSets` permissions on the `taegost.com` hosted zone
- Pi-hole has a DNS A record for `taegost.com` → `192.168.5.202` (Traefik MetalLB IP) — required for internal testing while `default-whitelist` is in effect; without it, internal browsers resolve via public DNS to the external IP and may not reach Traefik at all

---

## Implementation Units

### U1. cert-manager infrastructure for taegost.com

**Goal:** Provision the Route53 credential secret and ClusterIssuers that the wordpress-taegost Certificate resource depends on. These must be deployed and ready before U3.

**Requirements:** New public-facing site at `taegost.com` requires DNS-01 TLS validation via Route53. Separate AWS credentials from DNG mean the existing `route53-credentials` secret cannot be reused.

**Dependencies:** None (cert-manager already running)

**Files:**
- `apps/cert-manager/secret-route53-credentials-taegost.yaml` — plaintext template, gitignored via `secret-*.yaml` pattern
- `apps/cert-manager/sealedsecret-route53-credentials-taegost.yaml` — committed after sealing
- `apps/cert-manager/clusterissuer-taegost-staging.yaml`
- `apps/cert-manager/clusterissuer-taegost-prod.yaml`

**Approach:**
- The credential secret is named `route53-credentials-taegost` in the `cert-manager` namespace, with keys `access-key-id` and `secret-access-key` — matching the shape of the existing `route53-credentials` secret for consistency
- Both ClusterIssuers follow the naming convention `letsencrypt-<domain-shortname>-<env>`: `letsencrypt-taegost-staging` and `letsencrypt-taegost-prod`
- Both reference `route53-credentials-taegost`, `region: us-east-1` (Route53 is global but this region is always correct), and a monitored email address for Let's Encrypt account notifications — use a `taegost.com` domain alias (e.g. `certs@taegost.com`) matching the DNG pattern of keeping personal email out of committed YAML; the address receives expiry warnings so it must be actively monitored — **fill in before sealing/committing**
- The cert-manager ArgoCD Application manages `apps/cert-manager/` already; committing these files causes ArgoCD to deploy them automatically
- Seal and commit, then verify: `kubectl get clusterissuer letsencrypt-taegost-staging letsencrypt-taegost-prod` should show `READY=True`

**Test scenarios:**
- After deploy, both ClusterIssuers show `Ready=True` in `kubectl get clusterissuer`
- The `route53-credentials-taegost` Secret exists in the `cert-manager` namespace (confirms SealedSecret was decrypted by the controller)
- `kubectl describe clusterissuer letsencrypt-taegost-staging` shows no error events

**Verification:** `kubectl get clusterissuer letsencrypt-taegost-staging letsencrypt-taegost-prod -o wide` — both show `READY True` before proceeding to U3.

---

### U2. MariaDB provisioning for wordpress-taegost

**Goal:** Provision the dedicated database, user, grant, and credential secret so the WordPress deployment can connect to MariaDB.

**Requirements:** wordpress-taegost needs its own isolated database and user in the shared MariaDB instance.

**Dependencies:** MariaDB cluster running (already the case)

**Files:**
- `apps/wordpress-taegost/secret-wordpress-taegost-db-credentials.yaml` — plaintext template (gitignored), namespace `mariadb`, sync wave `-3`
- `apps/wordpress-taegost/sealedsecret-wordpress-taegost-db-credentials.yaml` — committed, namespace `mariadb`, sync wave `-3`
- `apps/wordpress-taegost/user-wordpress-taegost.yaml` — namespace `mariadb`, sync wave `-2`
- `apps/wordpress-taegost/grant-wordpress-taegost.yaml` — namespace `mariadb`, sync wave `-2`
- `apps/wordpress-taegost/database-wordpress-taegost.yaml` — namespace `mariadb`, sync wave `-1`

**Approach:**
- Follow `docs/mariadb-runbooks.md` exactly — the three CRDs and their sealedsecret go in the app's own folder with `namespace: mariadb`
- Sync wave ordering: sealedsecret at wave `-3` → User+Grant at wave `-2` → Database at wave `-1` → everything else at wave `0`
- The `User` CRD references `passwordSecretKeyRef: { name: wordpress-taegost-db-credentials, key: password }` — this secret is in the `mariadb` namespace (not the app namespace)
- The `Grant` CRD: `privileges: ["ALL PRIVILEGES"]`, `database: wordpress-taegost`, `table: "*"`, `username: wordpress-taegost`, `host: "%"`
- The Database CRD should include `characterSet: utf8mb4` and `collate: utf8mb4_unicode_ci` (the runbook template includes these; the existing DNG database manifest does not but it predates the updated template)
- Seal with: `kubeseal --format yaml < apps/wordpress-taegost/secret-wordpress-taegost-db-credentials.yaml > apps/wordpress-taegost/sealedsecret-wordpress-taegost-db-credentials.yaml`

**Test scenarios:**
- After deploy, `kubectl get database,user,grant -n mariadb` shows `wordpress-taegost` resources with `Ready=True`
- `kubectl get secret wordpress-taegost-db-credentials -n mariadb` exists (confirms SealedSecret decrypted)
- No error events on the User or Grant resources: `kubectl describe user wordpress-taegost -n mariadb`

**Verification:** All three CRDs in `mariadb` namespace show `Ready=True` before creating the Deployment.

---

### U3. WordPress-taegost application manifests

**Goal:** Create all kubernetes manifests for the wordpress-taegost deployment: namespace, ConfigMap, PVC, sealed secrets, Certificate, Deployment, Service, and IngressRoute.

**Requirements:** 2-replica WordPress site at `taegost.com` with Longhorn RWX PVC for shared wp-content, per-app TLS cert, initially restricted to internal IPs.

**Dependencies:** U1 (ClusterIssuer must exist), U2 (database must exist)

**Files:**
- `apps/wordpress-taegost/namespace-wordpress-taegost.yaml`
- `apps/wordpress-taegost/configmap-php-config.yaml` — namespace `wordpress-taegost`
- `apps/wordpress-taegost/persistentvolumeclaim-wordpress-taegost-wp-content.yaml`
- `apps/wordpress-taegost/certificate-taegost-com.yaml` — **starts with staging issuer**
- `apps/wordpress-taegost/secret-wordpress-taegost.yaml` — plaintext template (gitignored), namespace `wordpress-taegost`
- `apps/wordpress-taegost/sealedsecret-wordpress-taegost.yaml` — namespace `wordpress-taegost`
- `apps/wordpress-taegost/secret-wordpress-taegost-keys.yaml` — plaintext template (gitignored)
- `apps/wordpress-taegost/sealedsecret-wordpress-taegost-keys.yaml` — namespace `wordpress-taegost`
- `apps/wordpress-taegost/deployment-wordpress-taegost.yaml`
- `apps/wordpress-taegost/service-wordpress-taegost.yaml`
- `apps/wordpress-taegost/ingressroute-wordpress-taegost.yaml`

**Approach:**

*Namespace:* `wordpress-taegost` with `app.kubernetes.io/name: wordpress-taegost` label.

*ConfigMap (`php-config`):* Same PHP ini values as DNG (`upload_max_filesize = 128M`, `post_max_size = 128M`, `memory_limit = 256M`). Name it `php-config` in the `wordpress-taegost` namespace — safe because ConfigMaps are namespace-scoped.

*PVC:* `accessModes: [ReadWriteMany]`, `storageClassName: longhorn`, `storage: 10Gi`. Mounted at `/var/www/html/wp-content` in the Deployment.

*Certificate:* In `wordpress-taegost` namespace (per-app cert pattern for public-facing sites). `metadata.name: taegost-com`. `secretName: taegost-com-tls`. Start with `issuerRef.name: letsencrypt-taegost-staging`. After verifying `Ready=True`, update to `letsencrypt-taegost-prod` and commit.

*Sealed secrets — three required:*
1. `sealedsecret-wordpress-taegost-db-credentials.yaml` in `mariadb` namespace (covered in U2)
2. `sealedsecret-wordpress-taegost.yaml` in `wordpress-taegost` namespace — keys `WORDPRESS_DB_USER` and `WORDPRESS_DB_PASSWORD` (same password as the mariadb-namespace secret; must match)
3. `sealedsecret-wordpress-taegost-keys.yaml` in `wordpress-taegost` namespace — all 8 auth keys/salts: `WORDPRESS_AUTH_KEY`, `WORDPRESS_SECURE_AUTH_KEY`, `WORDPRESS_LOGGED_IN_KEY`, `WORDPRESS_NONCE_KEY`, `WORDPRESS_AUTH_SALT`, `WORDPRESS_SECURE_AUTH_SALT`, `WORDPRESS_LOGGED_IN_SALT`, `WORDPRESS_NONCE_SALT`. Generate fresh values from https://api.wordpress.org/secret-key/1.1/salt/ and extract the values only.

*Deployment:*
- Image: `wordpress:6.9-php8.5-apache` (matching DNG — update image tag to match current DNG tag at implementation time)
- `replicas: 2`
- No `strategy` field (default RollingUpdate is correct for RWX)
- `securityContext.fsGroup: 33` (www-data — required for Longhorn volume write access on first boot)
- `securityContext.allowPrivilegeEscalation: false`
- `WORDPRESS_CONFIG_EXTRA` sets `define('WP_HOME', 'https://taegost.com')` and `define('WP_SITEURL', 'https://taegost.com')`
- `WORDPRESS_DB_HOST: mariadb-primary.mariadb.svc.cluster.local`
- `WORDPRESS_DB_NAME: wordpress-taegost`
- `WORDPRESS_DB_USER` and `WORDPRESS_DB_PASSWORD` from `sealedsecret-wordpress-taegost`
- All 8 auth keys/salts from `sealedsecret-wordpress-taegost-keys`
- Liveness and readiness probes: `httpGet path: /wp-includes/images/blank.gif port: http`
- Resources: match DNG (requests `100m CPU / 512Mi memory`, limits `1000m CPU / 1Gi memory`)
- Volume mounts: wp-content PVC at `/var/www/html/wp-content`, php-config ConfigMap as `php-config.ini`, emptyDir at `/tmp`
- `automountServiceAccountToken: false`

*Service:* ClusterIP, port 80, `targetPort: http`. Name and selector use `app.kubernetes.io/name: wordpress-taegost`.

*IngressRoute:* In `wordpress-taegost` namespace (per-app cert pattern). Host rule `Host(\`taegost.com\`)`. `tls.secretName: taegost-com-tls`. Initially uses `default-whitelist` middleware (restrict to internal IPs until site is ready to go public).

**Test scenarios:**
- After deploy, both pods reach `Running` state: `kubectl get pods -n wordpress-taegost`
- Staging cert reaches `Ready=True`: `kubectl get certificate taegost-com -n wordpress-taegost`
- WordPress is reachable from an internal IP via `https://taegost.com` (whitelist in effect)
- WordPress installation wizard appears on first visit (confirms DB connection is working)
- After completing WordPress setup, log in as admin and confirm session persists across page loads (validates auth keys are consistent across replicas)
- Switching a request between pods does not invalidate the session (confirms both pods share the same auth key values)
- After switching Certificate issuerRef to prod and reapplying, the certificate re-issues as a trusted cert

**Verification:** Both pods `Running`, certificate `Ready=True` (staging first, then prod), WordPress admin accessible from internal network.

---

### U4. ArgoCD Application manifest for wordpress-taegost

**Goal:** Register the wordpress-taegost app with ArgoCD so it is reconciled from the repo.

**Requirements:** All manifests in `apps/wordpress-taegost/` must be managed by ArgoCD.

**Dependencies:** U3 (manifests must exist before the Application is meaningful; in practice can be committed together)

**Files:**
- `apps/manifests/wordpress-taegost.yaml`

**Approach:**
- Follow the `apps/manifests/wordpress-dng.yaml` pattern exactly
- `path: apps/wordpress-taegost`, `destination.namespace: wordpress-taegost`
- `syncPolicy.automated: { prune: true, selfHeal: true }`
- `syncOptions: [CreateNamespace=true]`
- Sync wave `0` on the Application itself (standard for app workloads)
- No `directory.recurse` needed — all manifests are in a flat directory

**Test scenarios:**
- After commit and push, ArgoCD shows `wordpress-taegost` application in `Synced` state
- All resources in the Application are `Healthy`
- No `Unknown` or `Degraded` resources

**Verification:** `kubectl get application wordpress-taegost -n argocd` shows `Sync Status: Synced, Health Status: Healthy`.

---

### U5. aws-ddns-personal deployment for taegost.com

**Goal:** Deploy a new `aws-ddns-personal` instance in the existing `aws-ddns` namespace to keep `taegost.com` Route53 records updated with the cluster's public IP.

**Requirements:** `taegost.com` DNS records must stay current when the home IP changes.

**Dependencies:** None (the existing `aws-ddns` ArgoCD Application already manages the whole `apps/aws-ddns/` directory)

**Files:**
- `apps/aws-ddns/personal-sealedsecret.yaml` — namespace `aws-ddns`, secret name `aws-ddns-personal-secret`, keys `AWS_ACCESS_KEY`, `AWS_SECRET`, `AWS_ZONE_ID`
- `apps/aws-ddns/personal-deployment.yaml` — namespace `aws-ddns`, deployment name `aws-ddns-personal`

**Approach:**
- Deployment follows `dng-deployment.yaml` exactly: `replicas: 1`, `strategy: Recreate`, image `taegost/aws-ddns:latest`, pod-level `securityContext.seccompProfile.type: RuntimeDefault`, container-level `securityContext` (`runAsUser: 1000`, `runAsGroup: 1000`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`)
- `DOMAIN` env var: `taegost.com` and any other records to keep updated (fill in the full space-separated list at implementation time)
- `envFrom.secretRef.name: aws-ddns-personal-secret` for the AWS credentials
- Resources: same as dng (`requests: 60M / 0.01 CPU`, `limits: 128M / 0.1 CPU`)
- The `AWS_ZONE_ID` in the new sealed secret is the Route53 Hosted Zone ID for `taegost.com` — different from the DNG zone ID
- No namespace changes needed: `apps/aws-ddns/namespace.yaml` comment already anticipates this exact pattern

**Test scenarios:**
- After deploy, `aws-ddns-personal` pod reaches `Running`: `kubectl get pods -n aws-ddns`
- Pod logs show the DOMAIN list being resolved and Route53 records being updated (no auth errors): `kubectl logs -n aws-ddns -l app=aws-ddns-personal`
- `taegost.com` resolves to the current home public IP from an external DNS check

**Verification:** Pod running, logs show successful Route53 update with no errors.

---

## Sequencing

U1 and U2 can be implemented in parallel (no cross-dependency). U3 depends on U1 being deployed (ClusterIssuer required) and U2 being deployed (database required). U4 commits alongside or immediately after U3. U5 is fully independent and can be done at any point.

```
U1 (cert-manager infra) ─┐
                          ├─→ U3 (WordPress manifests) → U4 (ArgoCD Application)
U2 (MariaDB provisioning)─┘

U5 (aws-ddns-personal) [independent]
```

**Recommended commit order:**
1. Commit U1 (`apps/cert-manager/` additions) → push → verify ClusterIssuers ready
2. Commit U2 (MariaDB CRDs + sealed secret) → push → verify DB resources ready  
3. Commit U3 + U4 (all wordpress-taegost manifests + ArgoCD Application) → push → verify staging cert, then switch to prod issuer
4. Commit U5 (`apps/aws-ddns/` additions) → push → verify DNS updating

---

## Deferred Implementation Notes

- **Prod issuer switchover:** After staging cert validates (`Ready=True`), update `certificate-taegost-com.yaml` to reference `letsencrypt-taegost-prod` and commit. After committing, verify the transition within 5 minutes: `kubectl describe certificaterequest -n wordpress-taegost` should show a successful ACME challenge. If prod issuance fails (IAM permission scope, rate limit, DNS propagation), revert the `issuerRef` to `letsencrypt-taegost-staging` and diagnose before retrying — do not leave the Certificate stuck in a failed state cycling retries.
- **Public traffic:** When ready to go live, update `ingressroute-wordpress-taegost.yaml` to replace `default-whitelist` with `default-headers`. Must be done in the same commit as the Authentik SSO route block — do not enable public traffic without SSO in place.
- **DOMAIN list for aws-ddns:** The full list of `taegost.com` records to keep current is not known at plan time — fill in at implementation.
- **ClusterIssuer email:** Use a `taegost.com` domain alias (e.g. `certs@taegost.com`) — see U1 Approach for rationale. Not known at plan time.
