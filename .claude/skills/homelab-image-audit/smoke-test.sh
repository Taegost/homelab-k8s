#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
AUDIT="$REPO_ROOT/.claude/skills/homelab-image-audit/audit.sh"
FAILED=0
PASSED=0

pass() { echo "  PASS: $1"; ((PASSED++)); }
fail() { echo "  FAIL: $1"; [[ -n "${2:-}" ]] && echo "        $2"; ((FAILED++)); }

audit_output() { "$AUDIT" "$@" 2>&1 || true; }
audit_has() {
    local name="$1" expected="$2"; shift 2
    if audit_output "$@" | grep -qF "$expected" 2>/dev/null; then
        pass "$name"
    else
        fail "$name" "expected: $expected"
    fi
}

echo "=== audit.sh Smoke Tests ==="
echo ""

# --- Non-interactive mode ---
echo "--- Non-interactive mode ---"

audit_has "nginx capabilities"   "CHOWN"   --image nginx:1.29-alpine --type nginx
audit_has "nginx SETGID"         "SETGID"  --image nginx:1.29-alpine --type nginx
audit_has "nginx SETUID"         "SETUID"  --image nginx:1.29-alpine --type nginx

audit_has "derived nginx CHOWN"  "CHOWN"   --image makeplane/plane-admin:v1.3.1 --type nginx
audit_has "derived nginx SETGID" "SETGID"  --image makeplane/plane-admin:v1.3.1 --type nginx

audit_has "rabbitmq CHOWN"       "CHOWN"          --image rabbitmq:3.13-management --type rabbitmq
audit_has "rabbitmq DAC_OVERRIDE" "DAC_OVERRIDE"  --image rabbitmq:3.13-management --type rabbitmq
audit_has "rabbitmq SETGID"      "SETGID"         --image rabbitmq:3.13-management --type rabbitmq

audit_has "redis non-root"       "non-root" --image redis:8-alpine --type redis
audit_has "valkey alias"         "non-root" --image valkey:9.0-alpine --type valkey

audit_has "generic gosu"         "gosu"     --image busybox:1.36 --type other
audit_has "generic su-exec"      "su-exec"  --image busybox:1.36 --type other

if audit_output --image unknown:latest --type unknown | grep -q "Unknown image type"; then
    pass "unknown type error message"
else
    fail "unknown type error message"
fi

# --- Auto-discovery ---
echo ""
echo "--- Auto-discovery ---"

KB_COUNT=$(find "$REPO_ROOT/docs/solutions" -name 'base-images-*.md' ! -name '*root-generic*' | wc -l)
if [[ "$KB_COUNT" -ge 3 ]]; then
    pass "KB has $KB_COUNT discoverable files (>= 3)"
else
    fail "KB has $KB_COUNT discoverable files (expected >= 3)"
fi

# root-generic should not be a valid --type
if audit_output --image x:y --type root-generic | grep -q "Unknown"; then
    pass "root-generic excluded from known types"
else
    fail "root-generic excluded from known types"
fi

# --- Regression: existing deployments ---
echo ""
echo "--- Regression: known deployments ---"

file_has() {
    local name="$1" file="$2" word="$3"
    if grep -qF "$word" "$file"; then pass "$name"; else fail "$name" "missing: $word"; fi
}

file_has "plane-admin has CHOWN"  "$REPO_ROOT/apps/plane/deployment-plane-admin.yaml" "CHOWN"
file_has "plane-admin has SETGID" "$REPO_ROOT/apps/plane/deployment-plane-admin.yaml" "SETGID"
file_has "plane-admin has SETUID" "$REPO_ROOT/apps/plane/deployment-plane-admin.yaml" "SETUID"

file_has "plane-web has CHOWN"    "$REPO_ROOT/apps/plane/deployment-plane-web.yaml" "CHOWN"
file_has "plane-web has SETGID"   "$REPO_ROOT/apps/plane/deployment-plane-web.yaml" "SETGID"
file_has "plane-web has SETUID"   "$REPO_ROOT/apps/plane/deployment-plane-web.yaml" "SETUID"

file_has "rabbitmq has DAC_OVERRIDE" "$REPO_ROOT/apps/plane/deployment-rabbitmq.yaml" "DAC_OVERRIDE"
file_has "rabbitmq has CHOWN"        "$REPO_ROOT/apps/plane/deployment-rabbitmq.yaml" "CHOWN"
file_has "rabbitmq has SETGID"       "$REPO_ROOT/apps/plane/deployment-rabbitmq.yaml" "SETGID"
file_has "rabbitmq has SETUID"       "$REPO_ROOT/apps/plane/deployment-rabbitmq.yaml" "SETUID"

file_has "valkey drops ALL" "$REPO_ROOT/apps/plane/deployment-valkey.yaml" "ALL"

# --- Summary ---
echo ""
echo "---"
echo "Results: $PASSED passed, $FAILED failed"
[[ "$FAILED" -gt 0 ]] && echo "SMOKE TEST FAILED" && exit 1
echo "SMOKE TEST PASSED"
