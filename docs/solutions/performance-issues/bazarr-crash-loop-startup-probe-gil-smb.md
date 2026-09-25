---
title: "Bazarr crash loop — liveness probe killing a GIL-starved startup scan on SMB"
date: 2026-09-25
category: performance-issues
module: arr-stack
problem_type: performance_issue
component: tooling
severity: high
symptoms:
  - "Bazarr pod crash-looped at roughly 320 container restarts per day and never reached Ready"
  - "Liveness probe failed with context deadline exceeded on GET /api/system/ping once the port was bound"
  - "Early-phase connection refused during s6 init — port not yet bound, cosmetic, not the kill mechanism"
  - "Container exited 0 with reason Completed — graceful s6 SIGTERM handling masked kubelet kills as benign completion"
  - "CPU pegged at the cgroup limit during startup while memory stayed flat — not an OOM kill"
root_cause: config_error
resolution_type: config_change
related_components:
  - sonarr
  - radarr
  - whisparr
  - multimedia-pv
tags: [kubernetes, probes, liveness, startup-probe, bazarr, arr-stack, gil, smb]
---

# Bazarr crash loop — liveness probe killing a GIL-starved startup scan on SMB

## Problem

Bazarr (subtitle manager, `lscr.io/linuxserver/bazarr`, `arr-stack` namespace) crash-looped for weeks at roughly 320 container restarts per day — all 7 retained daily logs were pathological — and the pod never reached Ready. The cause was an interaction between three things: a slow startup library scan over an SMB mount configured `cache=none`, Python's GIL serializing the interpreter during that scan, and a liveness probe with the default 1-second timeout and a 120-second total kill budget.

## Symptoms

- Readiness and liveness probe failures on `GET http://<pod-ip>:6767/api/system/ping` in two distinct modes:
  - `dial tcp ...:6767: connect: connection refused` — only during the first ~15-30s of each container, while s6 init had not yet bound the port. Cosmetic, not the killer.
  - `context deadline exceeded (Client.Timeout exceeded while awaiting headers)` — the port was bound and the kernel accepted the TCP connection, but no HTTP response arrived within the default 1s probe timeout. This was the actual kill mechanism.
- Every container lived exactly 98-120 seconds and then died. The math is exact: liveness `initialDelaySeconds: 30` + 3 failures × 30s `periodSeconds` puts the SIGTERM at ~90s, and the observed 98-120s exit adds s6's graceful shutdown time on top. An exact, repeatable death cadence is probe math, not app instability.
- Container exit code 0 with reason `Completed` — the LSIO s6-overlay handled SIGTERM gracefully, so `lastState` looked benign and masked the fact that kubelet was killing the container.
- CPU pegged at the cgroup limit (988m of 1000m) with 27% sys time; memory fine (165Mi of 512Mi) — not an OOM kill.
- App log showed a single line per start ("Scheduler will use this timezone: America/New_York") and then silence — startup never completed.

## What Didn't Work

- **Bumping the CPU limit (1000m → 2000m).** Restarts continued at the exact 120s cadence with CPU at 758m/2000m. This falsified the CPU-throttling hypothesis: extra cgroup quota cannot fix GIL starvation, because only one Python thread runs bytecode at a time regardless of how many cores are available.
- **Assuming the sampled process was stuck in a blocked `read()` syscall.** The inspected PID turned out to be the idle s6 parent wrapper (`python3 /app/bazarr/bin/bazarr.py`, only 3 open fds). The real Bazarr process was `/lsiopy/bin/python3 -u bazarr/main.py` with 106 threads (from `/proc/<pid>/status`), in state `R` (running, CPU-bound) — not blocked at all. Lesson: in s6-overlay images, verify *which* python process you are sampling before drawing conclusions from it.
- **Correlating onset with the `mountOptions` commit date.** The timeline initially looked causal, but the issue had been going on for weeks. The exact onset date mattered less than the mechanism; timeline archaeology of the deployment's `Available` condition transitions proved a red herring. The productive redirect was: "why does the probe fail?"

## Solution

Add a `startupProbe` to `apps/arr-stack/bazarr/deployment-bazarr.yaml` sized to the real startup duration, and raise `timeoutSeconds` above the 1s default on the steady-state probes:

```yaml
startupProbe:
  httpGet:
    path: /api/system/ping
    port: 6767
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 180   # 10s × 180 = 30 min startup budget
readinessProbe:
  httpGet:
    path: /api/system/ping
    port: 6767
  timeoutSeconds: 3      # was default 1s — GIL contention can exceed 1s even when healthy
  initialDelaySeconds: 15
  periodSeconds: 15
  failureThreshold: 3
livenessProbe:
  httpGet:
    path: /api/system/ping
    port: 6767
  timeoutSeconds: 3
  initialDelaySeconds: 30
  periodSeconds: 30
  failureThreshold: 3
```

Verification: pod 1/1 Ready in ~6 minutes, 0 restarts, `GET /api/system/ping` → `{"status": "OK"}` from inside the pod, deployment `Available=True`.

## Why This Works

The root cause chain, with every link verified:

1. **Slow mount.** The shared `multimedia` PV is an SMB mount, and repo commit `8cc4d51` ("Update: mountOptions for multimedia PV") added `nobrl` plus `cache=none`. Live confirmation inside the pods: `grep multimedia /proc/mounts` showed `cache=none,actimeo=1` on the CIFS mount. With `cache=none`, every directory walk is a network round trip.
2. **Measured walk cost.** From a sibling pod (Radarr) on the same mount: 478 top-level directories cost 268ms; 8,931 entries at depth 2 cost 16.5s — about 1.85ms per entry.
3. **Startup scan starves the GIL.** Bazarr's startup library scan runs a large worker pool (`/proc/<pid>/status`: `Threads: 106`). During the scan, an in-pod `wget -T 3 http://127.0.0.1:6767/api/system/ping` timed out — the server was bound but answering nothing.
4. **Python cannot answer mid-scan within the probe budget; .NET can.** Sonarr on the same mount burned 988m CPU for ~10 minutes after restart, then dropped to 320m when its scan completed — but it stayed Ready throughout, because ASP.NET answers `/ping` from its thread pool. Bazarr is Python: the GIL serializes the interpreter, so the HTTP event loop could not service requests within the 3s test budget while the scan saturated CPU (measured with `wget -T 3`, not proven absolutely unresponsive — which is also why the steady-state liveness probe keeps `timeoutSeconds: 3` rather than assuming one startupProbe pass makes the app permanently responsive).
5. **The probe path was never wrong.** `/api/system/ping` is valid — the deployment ran Ready for months with it. The failure was timing, not correctness.

The kill loop then closes mechanically: the liveness probe (default 1s timeout, `initialDelaySeconds: 30`, `failureThreshold: 3`, `periodSeconds: 30`) failed 3 consecutive times starting at the 30s mark, so kubelet sent SIGTERM at exactly 120s — always mid-scan. The restart reset the scan to zero, guaranteeing it would never finish: an infinite crash loop. The `cache=none` mount multiplied scan duration far past the 120s budget; the pre-existing 1s default timeout and 120s total liveness budget were the latent condition that turned "slow startup" into "fatal startup."

The fix works because of how `startupProbe` behaves: while it has not yet passed, the kubelet does not run liveness or readiness probes **at all** — no kills during the startup budget. When the scan finishes, threads wind down, the event loop answers, the startupProbe passes, and the normal probes resume. The raised `timeoutSeconds: 3` on readiness/liveness absorbs residual GIL contention bursts that exceed 1s even when the app is healthy.

## Prevention

- **Any Python/asyncio app with a CPU/GIL-heavy startup** (library scans, migrations, cache warming) needs a `startupProbe` sized to the *real* startup duration, plus `timeoutSeconds > 1s` on all httpGet probes. The default 1s timeout is punishing under GIL contention. When in doubt, measure startup end-to-end once, then set `failureThreshold` with generous headroom (Bazarr: 10s × 180 = 30 minutes).
- **`cache=none` on shared SMB PVs multiplies startup scan cost for every pod mounting it.** .NET apps survive (their threaded probe answers mid-scan) but pay ~10 minutes of CPU-pegged restart time; Python apps die. Treat `cache=none` on a PV shared across the *arr stack as a scanning-cost multiplier, not a tuning detail.
- **Detecting this failure class — three signatures to memorize:**
  - Exit code 0 + reason `Completed` on a crash-looping container = probe kill with a graceful SIGTERM handler, NOT a clean exit.
  - Exact-time deaths on a fixed cadence (here, 120s) = probe math (`initialDelay + failureThreshold × period`), not app instability.
  - `connection refused` early then `context deadline exceeded` = normal init followed by a server that is bound but not answering — look at what the process is doing (thread count, process state), not at the port.
- **Sample the right process.** In s6-overlay (LSIO) images, the first `python3` you find may be the idle wrapper. Match on the full command line and check `/proc/<pid>/status` for `Threads:` before concluding a process is blocked or busy.
- **Repo gap:** `.claude/skills/homelab-validate/scripts/probe-timeout-check.sh` only validates EXEC probe timeouts — httpGet probes silently inherit the 1s default and slip through. Extending that hook to flag httpGet probes missing an explicit `timeoutSeconds` would catch this class at commit time.
- **Same risk class, same fix:** Sonarr, Radarr, and Whisparr share the same multimedia mount and the same restart scan cost. Apply the same startupProbe treatment proactively rather than waiting for each to crash-loop. (Sonarr/Radarr are .NET and survive, but they still pay ~10 CPU-pegged minutes per restart.)
- **Residual trade-offs to watch:** every Bazarr restart pays a ~6 minute scan because `cache=none` means no cache warming; and post-scan memory ran 484Mi/512Mi — tight against the limit, so watch for OOMKilled after the fix.

## Related

- `docs/solutions/runtime-errors/rabbitmq-fsgroup-erlang-cookie.md` — same failure family (probe kills of a healthy-but-slow app), different root cause (config permission error vs inherent slow startup). Its "raise timeoutSeconds" rule generalizes; note its "raising failureThreshold didn't help" was correct *there* because the slowness was a fixable config error, whereas Bazarr's startup scan is inherently slow and needed the budget.
- `docs/solutions/conventions/honcho-deployment-patterns.md` — its section 4 claims HTTP probes "do not need" explicit timeoutSeconds; this incident shows kubelet applies `timeoutSeconds` to httpGet request timeouts too, and the 1s default can kill a healthy-but-slow app. That claim needs correction.
- `docs/solutions/conventions/fastcrw-multi-service-deployment-pattern.md` — "startupProbe for Heavy Containers" is the same pattern at 5-minute scale (Chromium cold start); Bazarr extends it to 30 minutes for SMB-I/O-bound Python scans.
- `docs/solutions/tooling-decisions/pre-commit-validation-suite.md` — documents probe-timeout-check.sh's exec-probe-only coverage, the enforcement gap that let this ship.
