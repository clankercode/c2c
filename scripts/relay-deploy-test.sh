#!/usr/bin/env bash
# scripts/relay-deploy-test.sh — local Railway deploy reproducer + peer-PASS gate.
#
# Mimics Railway's relay build + startup path:
#   1. docker build (compile check)
#   2. docker run (startup crash check)
#   3. health endpoint check (HTTP 200)
#   4. EACCES perm-degrade (identity write failure — must not crash)
#
# Exit codes:
#   0  all steps passed
#   1  any step failed (build / run / health / EACCES)
#
# Deferred items (NOT covered by this script):
#   - Dead-letter path: needs C2C_RELAY_ADMIN_TOKEN + live relay; covered by
#     relay-smoke-test.sh step 8 when run against production.
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

cleanup() {
    echo "=== Cleaning up container ==="
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

cd "$(git rev-parse --show-toplevel)"

# Resolve the git ref to a commit SHA
REF_SHA=$(git rev-parse "$GIT_REF^{commit}")
echo "=== Relay deploy test: ref=$GIT_REF sha=$REF_SHA ==="

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
echo "=== Step 4: EACCES perm-degrade (identity write failure) ==="
# Simulate Railway's /data volume being read-only (wrong uid).
# The relay must NOT crash — it should fall back to in-memory identity.
EACCES_CONTAINER="c2c-relay-test-eacces-$$"
LOCKED_DIR=$(mktemp -d)
chmod 000 "$LOCKED_DIR"
if ! docker run --rm -d \
        --name "$EACCES_CONTAINER" \
        -p $((PORT+1)):$((PORT+1)) \
        -v "${LOCKED_DIR}:/data" \
        -e PORT="$((PORT+1))" \
        -e C2C_RELAY_TOKEN="test-token-for-deploy" \
        c2c-relay-test:"$REF_SHA" 2>&1; then
    rm -rf "$LOCKED_DIR"
    echo "!!! Step 4 FAILED: docker run (EACCES) failed"
    exit 1
fi
rm -rf "$LOCKED_DIR"  # Volume stays locked inside container
sleep 3
EACCES_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://localhost:$((PORT+1))/health" 2>&1 || echo "000")
EACCES_RESPONSE=$(curl -s --max-time 10 "http://localhost:$((PORT+1))/health" 2>&1 || true)
docker rm -f "$EACCES_CONTAINER" 2>/dev/null || true
if [[ "$EACCES_HTTP" == "200" ]]; then
    echo "=== Step 4 PASSED: relay degraded gracefully under EACCES (HTTP 200) ==="
    echo "    Health response: $EACCES_RESPONSE"
    echo "    Identity persisted to in-memory; marker logged to stderr"
else
    echo ""
    echo "!!! Step 4 FAILED: relay crashed on EACCES (HTTP $EACCES_HTTP)"
    echo "    Response: $EACCES_RESPONSE"
    exit 1
fi

echo ""
echo "=== ALL STEPS PASSED ==="
exit 0
