---
title: "WordPress wp-admin Hangs from External Loopback Requests"
date: 2026-06-21
category: runtime-errors
module: wordpress
problem_type: runtime_error
component: tooling
symptoms:
  - "wp-admin pages show infinite spinner with no error"
  - "Frontend loads fine, only admin is affected"
  - "No errors in WordPress logs, pod logs, or PHP error logs"
  - "Browser dev tools show request hanging with no HTTP error code"
root_cause: config_error
resolution_type: config_change
severity: medium
tags:
  - wordpress
  - loopback
  - wp-admin
  - mu-plugin
  - traefik
  - kubernetes-networking
---

# WordPress wp-admin Hangs from External Loopback Requests

## Problem

WordPress makes HTTP requests to itself for wp-cron, Site Health checks, and plugin update checks. In Kubernetes, these requests go to the public domain, leave the cluster, hit Traefik, and route back in — a full external round-trip for what should be an internal operation. Multiple simultaneous loopbacks stack up, exhausting PHP execution time.

## Symptoms

- Frontend loads normally
- Any `/wp-admin` page shows an infinite spinner
- No errors in any logs
- Loopback latency: ~1.1s public-domain vs ~0.4s internal service URL

## What Didn't Work

- **Checking PHP error logs** — no errors logged; requests simply hung
- **Disabling plugins via wp-admin** — couldn't access wp-admin to disable them
- **WP_DEBUG logging** — revealed no specific errors

## Solution

A WordPress **MU plugin** deployed as a Kubernetes ConfigMap:

```php
<?php
/*
 * Plugin Name: Internal Loopback Rewriter
 * Description: Rewrites WordPress self-requests to use the internal Kubernetes
 *              service URL instead of the public domain.
 */

define('INTERNAL_LOOPBACK_TARGET_URL', 'https://diceninjagaming.com');
define('INTERNAL_LOOPBACK_SERVICE_URL', 'http://wordpress-dng.wordpress-dng.svc.cluster.local');

add_filter('pre_http_request', function($preempt, $parsed_args, $url) {
    if (!getenv('KUBERNETES_SERVICE_HOST')) return $preempt;

    if (strpos($url, INTERNAL_LOOPBACK_TARGET_URL) !== false) {
        $internal_url = str_replace(INTERNAL_LOOPBACK_TARGET_URL, INTERNAL_LOOPBACK_SERVICE_URL, $url);
        add_filter('https_local_ssl_verify', '__return_false');
        add_filter('https_ssl_verify', '__return_false');
        $response = wp_remote_request($internal_url, $parsed_args);
        remove_filter('https_local_ssl_verify', '__return_false');
        remove_filter('https_ssl_verify', '__return_false');
        return $response;
    }
    return $preempt;
}, 10, 3);
```

Mounted at `/var/www/html/wp-content/mu-plugins/loopback-internal.php` with `defaultMode: 0644`.

### Plugin isolation for rogue plugins

When `wp-admin` hangs, binary-search to isolate the culprit:

```bash
# Disable all plugins
kubectl exec -it deployment/wordpress-taegost -n wordpress-taegost -- \
  mv /var/www/html/wp-content/plugins /var/www/html/wp-content/plugins_disabled

# If login works, restore and binary search
```

## Why This Works

The plugin hooks `pre_http_request` with priority 10. For every outbound request, it checks if the URL contains the public domain and replaces it with the internal K8s service URL. The `KUBERNETES_SERVICE_HOST` guard makes it a no-op outside Kubernetes. MU-plugin placement ensures it loads before regular plugins and cannot be deactivated.

## Prevention

- **Every WordPress site in Kubernetes should include the loopback plugin at deployment time.**
- **When deploying a new site**, copy the ConfigMap and update the two `define()` constants.
- **Define `WP_SITEURL` explicitly** alongside `WP_HOME`.
- **Use static probe endpoints** (e.g., `/wp-includes/images/blank.gif`) for health probes.
- **Pin Docker image tags** to prevent `db_version` mismatches.

## Related

- `docs/troubleshooting.md` — WordPress section
- `apps/wordpress-dng/configmap-wordpress-loopback-plugin.yaml` — DNG site plugin
- `apps/wordpress-taegost/configmap-wordpress-loopback-plugin.yaml` — Taegost site plugin
