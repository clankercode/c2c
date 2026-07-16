#!/usr/bin/env bash
# scripts/relay-deploy-test.sh — local Railway deploy reproducer + peer-PASS gate.
#
# Mimics Railway's relay build + startup path:
#   1. docker build (compile check)
#   2. docker run (startup crash check)
#   3. health endpoint check (HTTP 200)
#   4. supervisor lifecycle ledger exists in the image/runtime path
#   5. EROFS diagnostic-volume fallback (instrumentation must not crash relay)
#
# Exit codes:
#   0  all steps passed
#   1  any step failed (build / run / health / diagnostic fallback)
#
# Deferred items (NOT covered by this script):
#   - Dead-letter path: needs C2C_RELAY_ADMIN_TOKEN; covered by
#     relay-smoke-test.sh step 8 against an isolated local relay.
#   - Multi-container relay mesh: not testable in single-host docker without
#     compose orchestrator; Railway's own infra tests this.
#   - Token-auth validation: needs a valid C2C_RELAY_TOKEN and would require
#     a second container registering against the first; too heavy for a gate.
#   - Volume persistence: /data written → survive restart requires a
#     compose-based test with a named volume; deferred to a dedicated
#     compose-based integration suite.
#
# Usage:
#   ./scripts/relay-deploy-test.sh [--local-port PORT] [GIT_REF]
#   just relay-deploy-test [GIT_REF]
#
# GIT_REF defaults to HEAD of the current repo.
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found — cannot run relay-deploy-test" >&2
    exit 1
fi

PORT="${RELAY_DEPLOY_TEST_PORT:-18080}"
GIT_REF="${1:-HEAD}"
CONTAINER_NAME="c2c-relay-test-$$"
EACCES_CONTAINER=""
LOCKED_DIR=""

cleanup() {
    echo "=== Cleaning up containers ==="
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    if [[ -n "$EACCES_CONTAINER" ]]; then
        docker rm -f "$EACCES_CONTAINER" 2>/dev/null || true
    fi
    if [[ -n "$LOCKED_DIR" ]]; then
        rm -rf "$LOCKED_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

cd "$(git rev-parse --show-toplevel)"

# Resolve the git ref to a commit SHA
REF_SHA=$(git rev-parse "$GIT_REF^{commit}")
echo "=== Relay deploy test: ref=$GIT_REF sha=$REF_SHA ==="

if rg -q '"startCommand"' railway.json; then
    echo "!!! Railway startCommand overrides the tested Docker CMD" >&2
    exit 1
fi

echo ""
echo "=== Step 1: docker build ==="
if ! docker build \
        --build-arg OCAML_VERSION=5.2 \
        -f Dockerfile \
        -t c2c-relay-test:"$REF_SHA" \
        . 2>&1; then
    echo ""
    echo "!!! Step 1 FAILED: docker build failed"
    exit 1
fi
echo "=== Step 1 PASSED: docker build OK ==="

echo ""
echo "=== Step 2: docker run (startup check) ==="
# Start container in background
if ! docker run --rm -d \
        --name "$CONTAINER_NAME" \
        -p "${PORT}:${PORT}" \
        -e PORT="${PORT}" \
        -e C2C_RELAY_TOKEN="test-token-for-deploy" \
        c2c-relay-test:"$REF_SHA" 2>&1; then
    echo ""
    echo "!!! Step 2 FAILED: docker run failed"
    exit 1
fi

# Give the server a moment to start
sleep 3

echo ""
echo "=== Step 3: health endpoint ==="
HEALTH_RESPONSE=$(curl -s --max-time 10 "http://localhost:${PORT}/health" 2>&1) || true
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://localhost:${PORT}/health" 2>&1 || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "=== Step 3 PASSED: health returned HTTP $HTTP_CODE ==="
    echo "    Response: $HEALTH_RESPONSE"
else
    echo ""
    echo "!!! Step 3 FAILED: health returned HTTP $HTTP_CODE"
    echo "    Response: $HEALTH_RESPONSE"

    echo ""
    echo "=== Container logs ==="
    docker logs "$CONTAINER_NAME" 2>&1 || true

    echo ""
    echo "!!! DIAGNOSIS:"
    if [[ "$HTTP_CODE" == "000" ]]; then
        echo "  - Connection refused: server not listening on port $PORT"
        echo "  - Likely: startup crash or binding to wrong interface"
        echo "  - Check container logs above for crash trace"
    elif [[ "$HTTP_CODE" == "502" || "$HTTP_CODE" == "504" ]]; then
        echo "  - Gateway error: Cloudflare/nginx proxy can't reach origin"
        echo "  - Not a local issue — Railway-specific routing problem"
    else
        echo "  - Unexpected HTTP $HTTP_CODE"
        echo "  - Server may be rejecting the health check for other reasons"
    fi
    exit 1
fi

echo ""
echo "=== All steps PASSED ==="
echo "  Build:  OK"
echo "  Run:    OK"
echo "  Health: HTTP $HTTP_CODE"
echo ""
echo "Relay deploy path is working locally."
echo ""
echo "=== Step 4: persistent supervisor diagnostics ==="
if docker exec "$CONTAINER_NAME" sh -c \
        'set -eu
         diag=/data/relay-diagnostics
         test -s "$diag/lifecycle.jsonl"
         grep -q '"'"'"event":"supervisor_start"'"'"' "$diag/lifecycle.jsonl"
         test "$(stat -c %u /data)" = 0
         test "$(stat -c %g /data)" = "$(id -g c2c)"
         test "$(stat -c %a /data)" = 1770
         test "$(stat -c %u "$diag")" = 0
         test "$(stat -c %a "$diag")" = 711
         test "$(stat -c %u "$diag/cores")" = "$(id -u c2c)"
         test "$(stat -c %a "$diag/cores")" = 700
         if setpriv --reuid=c2c --regid=c2c --init-groups \
                 mv "$diag" "$diag.moved" 2>/dev/null; then
             echo "c2c could rename root diagnostic directory" >&2
             exit 1
         fi
         relay_found=0
         for status in /proc/[0-9]*/status; do
             if test "$(sed -n '"'"'s/^Name:[[:space:]]*//p'"'"' "$status")" = c2c; then
                 test "$(awk '"'"'/^Uid:/{print $2}'"'"' "$status")" = "$(id -u c2c)"
                 relay_found=1
             fi
         done
         test "$relay_found" = 1'; then
    echo "=== Step 4 PASSED: supervisor lifecycle ledger is active ==="
else
    echo "!!! Step 4 FAILED: supervisor lifecycle ledger missing"
    docker logs "$CONTAINER_NAME" 2>&1 || true
    exit 1
fi

# A restart must not recursively hand old diagnostic evidence to c2c while
# migrating SQLite files on the same volume.
docker exec "$CONTAINER_NAME" sh -c \
    'printf safe > /data/relay-diagnostics/owner-sentinel && chmod 0600 /data/relay-diagnostics/owner-sentinel'
docker restart "$CONTAINER_NAME" >/dev/null
sleep 3
RESTART_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "http://localhost:${PORT}/health" 2>/dev/null || true)
if [[ "$RESTART_HTTP" != "200" ]] || ! docker exec "$CONTAINER_NAME" sh -c \
        'test "$(stat -c %u /data/relay-diagnostics/owner-sentinel)" = 0 && test "$(cat /data/relay-diagnostics/owner-sentinel)" = safe'; then
    echo "!!! Step 4 FAILED: restart changed diagnostic ownership or health"
    docker logs "$CONTAINER_NAME" 2>&1 || true
    exit 1
fi
echo "=== Step 4 restart PASSED: diagnostic ownership remained root-only ==="

echo ""
echo "=== Step 5: EROFS diagnostic-volume fallback ==="
# Simulate the diagnostic volume becoming read-only while using an in-memory
# relay child. This isolates the instrumentation contract: losing /data must
# move the ledger to /tmp without taking an otherwise runnable child down.
# (SQLite itself does not support a read-only database directory fallback.)
EACCES_CONTAINER="c2c-relay-test-eacces-$$"
LOCKED_DIR=$(mktemp -d)
if ! docker run -d \
        --name "$EACCES_CONTAINER" \
        -p $((PORT+1)):$((PORT+1)) \
        -v "${LOCKED_DIR}:/data:ro" \
        -e PORT="$((PORT+1))" \
        -e C2C_RELAY_PERSIST_DIR=/data \
        -e C2C_RELAY_TOKEN="test-token-for-deploy" \
        c2c-relay-test:"$REF_SHA" sh -c \
        'exec /usr/local/bin/c2c-relay-supervisor setpriv --reuid=c2c --regid=c2c --init-groups c2c relay serve --listen 0.0.0.0:${PORT} --token "${C2C_RELAY_TOKEN}"' \
        2>&1; then
    echo "!!! Step 5 FAILED: docker run (EACCES) failed"
    exit 1
fi
sleep 3
if ! EACCES_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        "http://localhost:$((PORT+1))/health" 2>&1); then
    EACCES_HTTP=000
fi
EACCES_RESPONSE=$(curl -s --max-time 10 "http://localhost:$((PORT+1))/health" 2>&1 || true)
EACCES_LOGS=$(docker logs "$EACCES_CONTAINER" 2>&1 || true)
EACCES_DIAG_OK=0
if docker exec "$EACCES_CONTAINER" sh -c \
        'find /tmp -maxdepth 2 -type f -path "*/c2c-relay-diagnostics-*/lifecycle.jsonl" -size +0c | grep -q .'; then
    EACCES_DIAG_OK=1
fi
docker rm -f "$EACCES_CONTAINER" 2>/dev/null || true
EACCES_CONTAINER=""
rm -rf "$LOCKED_DIR"
LOCKED_DIR=""
if [[ "$EACCES_HTTP" == "200" ]] \
        && grep -q 'persistent diagnostics unavailable; using /tmp/' \
            <<<"$EACCES_LOGS" \
        && [[ "$EACCES_DIAG_OK" == "1" ]]; then
    echo "=== Step 5 PASSED: diagnostics fell back under EROFS (HTTP 200) ==="
    echo "    Health response: $EACCES_RESPONSE"
    echo "    Supervisor ledger fell back to /tmp without affecting the relay"
else
    echo ""
    echo "!!! Step 5 FAILED: diagnostic fallback failed (HTTP $EACCES_HTTP)"
    echo "    Response: $EACCES_RESPONSE"
    echo "    Temp diagnostic ledger present: $EACCES_DIAG_OK"
    echo "    Logs:"
    echo "$EACCES_LOGS"
    exit 1
fi

echo ""
echo "=== ALL STEPS PASSED ==="
exit 0
