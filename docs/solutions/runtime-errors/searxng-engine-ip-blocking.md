---
module: searxng
tags: [searxng, fastcrw, search, ip-blocking, captcha, rate-limiting, troubleshooting]
problem_type: runtime-error
---

# Upstream engine IP blocking makes SearXNG (and everything downstream) return empty results

## Problem

Search returns empty results with a success response everywhere in the stack:

- `firecrawl_search` via the fastcrw MCP returns `{"success":true,"data":{"web":[]},"creditsUsed":0}`
- fastcrw `/v1/search` and `/v2/search` both return empty result sets
- SearXNG's own JSON API returns `{"results":[], "unresponsive_interfaces":[]}` for fresh queries

Nothing errors. The empty result propagates through every layer as success, so
there is no stack trace to start from — the whole chain looks healthy.

First diagnosed 2026-09-03 (PR #65, issue #66).

## Root Cause

Upstream search engines (DuckDuckGo, karmasearch, and at the time google,
brave, startpage, qwant, mojeek) were rejecting the cluster's egress IP — the
home WAN IP. Engine reputation systems flag it for automated query volume,
regardless of SearXNG being self-hosted. DuckDuckGo served CAPTCHA pages
(`SearxEngineCaptchaException`), karmasearch returned HTTP 403
(`SearxEngineAccessDeniedException`).

With most enabled engines dead, SearXNG's aggregated default search returned
empty. Two effects made the failure intermittent and misleading:

1. **Per-pod in-memory suspensions** — SearXNG suspends an engine for a while
   after repeated errors, per pod. Two replicas can be in different suspension
   states, so identical queries flip between empty and non-empty.
2. **Valkey cache hits** — a query that succeeded once keeps returning results
   from cache while fresh queries fail. Testing with a recently-used query
   ("it works with `kubernetes release`!") proves nothing.

An amplifier sat in fastcrw: `query_expand = true` with
`query_expand_variants = 3` fired three SearXNG queries per search, tripling
the query volume that flagged the IP in the first place.

## Diagnosis

Work bottom-up from SearXNG — skip fastcrw and the MCP entirely until SearXNG
is ruled in or out:

1. Check SearXNG logs for engine exceptions (the smoking gun):

   ```bash
   kubectl logs -n searxng -l app=searxng --since=1h | grep -iE "captcha|denied|suspended"
   ```

   `SearxEngineCaptchaException` / `SearxEngineAccessDeniedException` = IP
   blocking. Note both replicas — suspension states differ.

2. Test engines individually, with **fresh queries** (avoid Valkey cache):

   ```bash
   for e in bing brave google duckduckgo mojeek; do
     curl -sS "https://searxng.diceninjagaming.com/search?q=$(openssl rand -hex 4)&format=json&engines=$e" \
       | python3 -c "import sys,json;print('$e:',len(json.load(sys.stdin).get('results',[])))"
   done
   ```

   Caveat: gibberish queries legitimately return 0 from exact-match engines
   (wikipedia, mojeek). Re-test stragglers with a real query before declaring
   them dead.

3. Only then check fastcrw, e.g.:

   ```bash
   curl -sS -X POST https://fastcrw.taegost.com/v2/search \
     -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
     -d '{"query":"rust tokio tutorial","limit":3}'
   ```

   `firecrawl-mcp` (npm) hardcodes `/v2/search` — there is no way to pin v1 —
   and it surfaces empty result sets as success, which is why the MCP shows no
   error at all.

Things that will waste time if you skip step 1: fastcrw config, image tags,
Traefik whitelist middlewares, NetworkPolicies, MCP auth. All were exonerated
here.

## Fix

Applied 2026-09-03 (PR #65):

1. **Prune engines with no recovery path** — `duckduckgo`, `karmasearch`,
   `startpage` removed via `use_default_settings.engines.remove` in
   `apps/searxng/configmap-searxng.yaml`.
2. **Bump SearXNG image** — 2026.5.10 → 2026.9.3; engine handling improved
   upstream and the google engine recovered with the newer build.
3. **Disable fastcrw query expansion** — `query_expand = false` in
   `apps/fastcrw/configmap-fastcrw-config.yaml`, cutting engine query volume 3x
   to slow re-flagging.
4. **Restart both deployments manually** — subPath-mounted config files never
   hot-reload (by design in this repo), and the restart also clears per-pod
   in-memory engine suspensions:

   ```bash
   kubectl rollout restart deployment -n searxng searxng
   kubectl rollout restart deployment -n fastcrw fastcrw
   ```

google stayed enabled deliberately: a blocked engine auto-suspends and
contributes nothing silently, and it recovered on its own after the version
bump and restart — the IP-reputation flag was not permanent. Egress-proxy
remedies were considered and rejected (issue #66 tracks the investigation).

## Verification

- Per-engine test (step 2 above): bing, brave, google all > 0
- fastcrw `/v2/search`: non-empty `data.web` across repeated runs
- `firecrawl_search` MCP: results, end to end

## Related

- Issue #66 — google engine recovery investigation; residual anomalies
  (mojeek and wikipedia return 0 even for matched queries on 2026.9.3)
- `docs/solutions/runtime-errors/metallb-hairpin-networkpolicy-egress.md` —
  the companion gotcha for in-cluster pods reaching SearXNG via its external
  FQDN (fastcrw does exactly this)
