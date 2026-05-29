# WordPress "No Update Required" Loop — Kubernetes Troubleshooting Guide

## Symptoms

- Logging into `wp-admin` immediately presents the message: **"No Update Required: Your WordPress database is already up to date!"**
- The site functions normally on the frontend
- The issue persists across logins and pod restarts

---

## Environment

- Self-hosted Kubernetes cluster
- WordPress running as a Deployment with multiple replicas
- Longhorn RWX PVC for persistent storage
- MariaDB managed by `mariadb-operator`
- Traefik as the ingress controller
- WordPress Docker image using a floating tag (e.g. `wordpress:6.9-php8.5-apache`)

---

## Root Causes

### 1. Floating Image Tag Causing `db_version` Mismatch

The WordPress Docker image was using a floating tag (`6.9-php8.5-apache`). On pod restarts, a freshly pulled image could contain WordPress core files from a different minor build, causing the `$wp_db_version` value in `wp-includes/version.php` to differ from the `db_version` stored in the database. Since only `wp-content` was on the PVC, core files were ephemeral and could silently change between restarts.

### 2. Probe Endpoints Causing Unintended WordPress Execution

The readiness probe was configured to hit `/wp-login.php`. Because the probe requests use an internal cluster IP as the host header (not the site's domain), WordPress redirected them to the configured `siteurl`, causing 302 responses and marking pods as not ready.

A subsequent change to `/wp-admin/install.php` was worse — `install.php` bootstraps the full WordPress stack on every probe request, executing plugin hooks and database interactions every 10 seconds per pod.

### 3. `WP_SITEURL` Not Explicitly Defined

Only `WP_HOME` was defined in `WORDPRESS_CONFIG_EXTRA`. WordPress was reading `siteurl` from the database, which can cause subtle redirect inconsistencies when the value isn't locked in code.

---

## Diagnostic Steps

### Check `db_version` Match

Run from a temporary pod in the cluster:

```bash
kubectl run -it --rm db-debug --image=mariadb:latest --restart=Never -n REPLACE_NAMESPACE -- \
  mariadb -h REPLACE_DB_HOST -u REPLACE_DB_USER -pREPLACE_PASSWORD REPLACE_DB_NAME \
  -e "SELECT option_value FROM wp_options WHERE option_name = 'db_version';"
```

Compare against the value in the WordPress pod:

```bash
kubectl exec -it -n REPLACE_NAMESPACE REPLACE_POD_NAME -- \
  grep wp_db_version /var/www/html/wp-includes/version.php
```

If the values differ, that confirms a `db_version` mismatch.

### Check `siteurl` and `home` in Database

```bash
kubectl run -it --rm db-debug --image=mariadb:latest --restart=Never -n REPLACE_NAMESPACE -- \
  mariadb -h REPLACE_DB_HOST -u REPLACE_DB_USER -pREPLACE_PASSWORD REPLACE_DB_NAME \
  -e "SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl', 'home');"
```

Both should match the domain defined in `WP_HOME`.

### Enable Debug Logging

Add to `WORDPRESS_CONFIG_EXTRA` in your Kubernetes secret:

```
define('WP_DEBUG_LOG', true); define('WP_DEBUG_DISPLAY', false);
```

Add as a separate environment variable in the deployment:

```yaml
- name: WORDPRESS_DEBUG
  value: "1"
```

> **Note:** Do not define `WP_DEBUG` inside `WORDPRESS_CONFIG_EXTRA` — the official WordPress Docker image handles this via the `WORDPRESS_DEBUG` env var. Defining it twice causes a PHP warning.

Tail the log in real time:

```bash
kubectl exec -it -n REPLACE_NAMESPACE REPLACE_POD_NAME -- \
  tail -f /var/www/html/wp-content/debug.log
```

---

## Resolution

### Step 1 — Fix Probe Endpoints

Change both liveness and readiness probes to a static file that does not execute WordPress:

```yaml
livenessProbe:
  httpGet:
    path: /wp-includes/images/blank.gif
    port: http
  failureThreshold: 3
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /wp-includes/images/blank.gif
    port: http
  failureThreshold: 3
  periodSeconds: 10
```

### Step 2 — Define `WP_SITEURL` Explicitly

Update `WORDPRESS_CONFIG_EXTRA` in your Kubernetes secret to include both defines:

```
define('WP_HOME', 'https://REPLACE_DOMAIN'); define('WP_SITEURL', 'https://REPLACE_DOMAIN');
```

### Step 3 — Migrate WordPress Files to PVC

This decouples WordPress core files from the image, preventing future floating-tag regressions.

**Create a migration pod:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: wp-migration
  namespace: REPLACE_NAMESPACE
spec:
  containers:
  - name: migration
    image: REPLACE_WP_IMAGE
    command: ["bash", "-c", "sleep infinity"]
    volumeMounts:
    - name: wordpress-content
      mountPath: /mnt/pvc
  volumes:
  - name: wordpress-content
    persistentVolumeClaim:
      claimName: REPLACE_PVC_CLAIM_NAME
  restartPolicy: Never
```

Apply it:

```bash
kubectl apply -f wp-migration.yaml
```

Exec in:

```bash
kubectl exec -it -n REPLACE_NAMESPACE wp-migration -- bash
```

Run the migration (WordPress source files in the image are at `/usr/src/wordpress/`, not `/var/www/html/`, when the entrypoint is overridden):

```bash
# Step 1: Move existing wp-content files into a proper subdirectory
mkdir /mnt/pvc/wp-content && mv /mnt/pvc/* /mnt/pvc/wp-content/

# Step 2: Copy all WordPress core files from image, excluding wp-content
for item in /usr/src/wordpress/*; do
  [ "$(basename $item)" != "wp-content" ] && cp -a "$item" /mnt/pvc/
done
```

> The `mv` will error trying to move `wp-content` into itself — this is expected and harmless.

### Step 4 — Correct `db_version` in `version.php` if Needed

If the values from the diagnostic step were mismatched, correct `version.php` directly:

```bash
sed -i 's/$wp_db_version = REPLACE_OLD_VERSION;/$wp_db_version = REPLACE_NEW_VERSION;/' \
  /mnt/pvc/wp-includes/version.php
```

Verify:

```bash
grep wp_db_version /mnt/pvc/wp-includes/version.php
```

### Step 5 — Update Volume Mount and Clean Up

Update the deployment manifest to mount the PVC at the WordPress root instead of `wp-content`:

```yaml
- name: wordpress-content
  mountPath: /var/www/html
```

Delete the migration pod:

```bash
kubectl delete pod wp-migration -n REPLACE_NAMESPACE
```

Restart the deployment to pick up all changes:

```bash
kubectl rollout restart deployment/REPLACE_DEPLOYMENT_NAME -n REPLACE_NAMESPACE
```

---

## Verification

After the rollout completes, log into `wp-admin` and confirm:

- No "No Update Required" or "Database Update Required" screen appears
- Plugins, themes, and uploads are intact
- The site renders correctly on the frontend