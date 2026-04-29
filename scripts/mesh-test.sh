#!/usr/bin/env bash
# scripts/mesh-test.sh — #330 mesh validation: two-relay Docker mesh.
#
# Tests the full cross-host send path:
#   alice@relay-a → bob@relay-b  (via /forward endpoint)
#
# Topology:
#   relay-a (port 18080) ←→ relay-b (port 18081)
#   alice registered on relay-a
#   bob registered on relay-b
#   relay-a configured with peer relay-b (and vice versa)
#
# Steps:
#   1. Build Docker image
#   2. Start relay-a + relay-b with identity volumes
#   3. Extract relay identity public keys
#   4. Restart with mutual peer-relay configuration
#   5. Register alice on relay-a, bob on relay-b
#   6. Send alice → bob@relay-b
#   7. Verify bob receives (no cross_host_not_implemented dead-letter)
#
# Usage:
#   ./scripts/mesh-test.sh
set -euo pipefail

RELAY_IMAGE="c2c-relay-test:mesh"
CONTAINER_A="c2c-mesh-relay-a"
CONTAINER_B="c2c-mesh-relay-b"
VOL_A="c2c-mesh-vol-a"
VOL_B="c2c-mesh-vol-b"
PORT_A=18080
PORT_B=18081
TOKEN="mesh-test-token"

# Resolve script directory for helper utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cleanup() {
    echo "=== Cleaning up ==="
    docker rm -f "$CONTAINER_A" "$CONTAINER_B" 2>/dev/null || true
    echo "Containers removed."
}
trap cleanup EXIT

cd "$(git rev-parse --show-toplevel)"

echo "=== Mesh test: two-relay cross-host send ==="
echo ""

# -----------------------------------------------------------------------------
# Step 1: Build Docker image (reuse Dockerfile)
echo "=== Step 1: docker build ==="
if ! docker build -f Dockerfile -t "$RELAY_IMAGE" . >/dev/null 2>&1; then
    echo "!!! Step 1 FAILED: docker build failed"
    exit 1
fi
echo "=== Step 1 PASSED ==="
echo ""

# -----------------------------------------------------------------------------
# Create named volumes for identity persistence
echo "=== Creating identity volumes ==="
docker volume create "$VOL_A" >/dev/null 2>&1 || true
docker volume create "$VOL_B" >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# Step 2: Start relay-a and relay-b with fresh identities
echo "=== Step 2: Start relay-a and relay-b (identity generation) ==="

# Ensure the Docker network exists
docker network create c2c-mesh-net 2>/dev/null || true

# Start relay-a (use default CMD which reads C2C_RELAY_PERSIST_DIR + C2C_RELAY_STORAGE)
docker rm -f "$CONTAINER_A" 2>/dev/null || true
docker run --rm -d \
    --name "$CONTAINER_A" \
    --network c2c-mesh-net \
    -p "${PORT_A}:${PORT_A}" \
    -e PORT="${PORT_A}" \
    -e C2C_RELAY_TOKEN="$TOKEN" \
    -e C2C_RELAY_NAME="relay-a" \
    -e C2C_RELAY_PERSIST_DIR="/var/lib/c2c" \
    -e C2C_RELAY_STORAGE="sqlite" \
    -v "${VOL_A}:/var/lib/c2c" \
    "$RELAY_IMAGE" \
    >/dev/null

# Start relay-b
docker rm -f "$CONTAINER_B" 2>/dev/null || true
docker run --rm -d \
    --name "$CONTAINER_B" \
    --network c2c-mesh-net \
    -p "${PORT_B}:${PORT_B}" \
    -e PORT="${PORT_B}" \
    -e C2C_RELAY_TOKEN="$TOKEN" \
    -e C2C_RELAY_NAME="relay-b" \
    -e C2C_RELAY_PERSIST_DIR="/var/lib/c2c" \
    -e C2C_RELAY_STORAGE="sqlite" \
    -v "${VOL_B}:/var/lib/c2c" \
    "$RELAY_IMAGE" \
    >/dev/null

# Wait for startup
sleep 4

# Verify both are up
HTTP_A=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT_A}/health" || echo "000")
HTTP_B=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT_B}/health" || echo "000")

if [[ "$HTTP_A" != "200" ]] || [[ "$HTTP_B" != "200" ]]; then
    echo "!!! Step 2 FAILED: relay health check failed"
    echo "    relay-a: HTTP $HTTP_A"
    echo "    relay-b: HTTP $HTTP_B"
    docker logs "$CONTAINER_A" 2>&1 || true
    docker logs "$CONTAINER_B" 2>&1 || true
    exit 1
fi
echo "=== Step 2 PASSED: both relays healthy ==="
echo ""

# -----------------------------------------------------------------------------
# Step 3: Extract relay identity public keys from the identity JSON files
echo "=== Step 3: Extract relay identity public keys ==="

# Identity is stored at /var/lib/c2c/identity.json inside the container
# Mount the volumes to extract the public keys

# Extract relay-a public key (identity file is relay-server-identity.json per relay.ml)
# Use tr -d '\n' to flatten the pretty-printed JSON so grep can find the key
# Note: JSON has space after colon, so pattern includes " *:" to handle both
RELAY_A_PK=$(docker run --rm \
    -v "${VOL_A}:/data:ro" \
    alpine:latest \
    sh -c 'cat /data/relay-server-identity.json | tr -d "\n"' 2>/dev/null \
    | grep -o '"public_key": *"[^"]*"' \
    | sed 's/"public_key": *"\([^"]*\)"/\1/') || true

# Extract relay-b public key
RELAY_B_PK=$(docker run --rm \
    -v "${VOL_B}:/data:ro" \
    alpine:latest \
    sh -c 'cat /data/relay-server-identity.json | tr -d "\n"' 2>/dev/null \
    | grep -o '"public_key": *"[^"]*"' \
    | sed 's/"public_key": *"\([^"]*\)"/\1/') || true

if [[ -z "$RELAY_A_PK" ]] || [[ -z "$RELAY_B_PK" ]]; then
    echo "!!! Step 3 FAILED: could not extract identity public keys"
    echo "    relay-a pk: ${RELAY_A_PK:-EMPTY}"
    echo "    relay-b pk: ${RELAY_B_PK:-EMPTY}"
    exit 1
fi
echo "    relay-a pk: ${RELAY_A_PK:0:20}..."
echo "    relay-b pk: ${RELAY_B_PK:0:20}..."
echo "=== Step 3 PASSED ==="
echo ""

# -----------------------------------------------------------------------------
# Step 4: Restart relays with mutual peer-relay configuration
echo "=== Step 4: Restart relays with peer-relay configuration ==="

# Stop existing containers (they'll be recreated with peer config)
docker rm -f "$CONTAINER_A" "$CONTAINER_B" 2>/dev/null || true
sleep 2

# Start relay-a with peer relay-b
# Use --entrypoint sh -c 'exec c2c relay serve ...' so we can pass arbitrary CLI flags
docker run --rm -d \
    --name "$CONTAINER_A" \
    --network c2c-mesh-net \
    -p "${PORT_A}:${PORT_A}" \
    -e C2C_RELAY_TOKEN="$TOKEN" \
    -e C2C_RELAY_NAME="relay-a" \
    -v "${VOL_A}:/var/lib/c2c" \
    --entrypoint sh \
    "$RELAY_IMAGE" \
    -c 'exec c2c relay serve \
        --listen "0.0.0.0:'"${PORT_A}"'" \
        --token "'"$TOKEN"'" \
        --persist-dir /var/lib/c2c \
        --storage sqlite \
        --relay-name relay-a \
        --peer-relay "relay-b=http://'"$CONTAINER_B"':'"${PORT_B}"'" \
        --peer-relay-pubkey "relay-b='"${RELAY_B_PK}"'"' \
    >/dev/null

# Start relay-b with peer relay-a
docker run --rm -d \
    --name "$CONTAINER_B" \
    --network c2c-mesh-net \
    -p "${PORT_B}:${PORT_B}" \
    -e C2C_RELAY_TOKEN="$TOKEN" \
    -e C2C_RELAY_NAME="relay-b" \
    -v "${VOL_B}:/var/lib/c2c" \
    --entrypoint sh \
    "$RELAY_IMAGE" \
    -c 'exec c2c relay serve \
        --listen "0.0.0.0:'"${PORT_B}"'" \
        --token "'"$TOKEN"'" \
        --persist-dir /var/lib/c2c \
        --storage sqlite \
        --relay-name relay-b \
        --peer-relay "relay-a=http://'"$CONTAINER_A"':'"${PORT_A}"'" \
        --peer-relay-pubkey "relay-a='"${RELAY_A_PK}"'"' \
    >/dev/null

sleep 4

# Verify both are up
HTTP_A=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT_A}/health" || echo "000")
HTTP_B=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT_B}/health" || echo "000")

if [[ "$HTTP_A" != "200" ]] || [[ "$HTTP_B" != "200" ]]; then
    echo "!!! Step 4 FAILED: relay health check failed after peer config"
    echo "    relay-a: HTTP $HTTP_A"
    echo "    relay-b: HTTP $HTTP_B"
    docker logs "$CONTAINER_A" 2>&1 || true
    docker logs "$CONTAINER_B" 2>&1 || true
    exit 1
fi
echo "=== Step 4 PASSED: both relays up with peer config ==="
echo ""

# Wait for relays to be fully ready after peer-config restart
sleep 4

# -----------------------------------------------------------------------------
# Step 5: Register alice with Ed25519 identity (signed registration)
# alice gets an Ed25519 keypair, registers with a signed proof on relay-a
echo "=== Step 5: Register alice (Ed25519) and bob (relay-a and relay-b) ==="

# Use Python helper to avoid bash/python variable passing issues
python3 "${SCRIPT_DIR}/mesh_test_client.py"
STEP5_RC=$?

if [[ $STEP5_RC -ne 0 ]]; then
    echo "!!! Step 5 FAILED (python client exited $STEP5_RC)"
    docker logs "$CONTAINER_A" 2>&1 | tail -10 || true
    docker logs "$CONTAINER_B" 2>&1 | tail -10 || true
    exit 1
fi
echo "=== Step 5 PASSED ==="
echo ""

# -----------------------------------------------------------------------------
# Step 6: alice sends signed request to bob@relay-b (cross-host send)
echo "=== Step 6: alice sends signed request to bob@relay-b (cross-host) ==="

# Build the send body
SEND_BODY='{"from_alias":"alice","to_alias":"bob@relay-b","content":"hello from alice via mesh","message_id":"mesh-test-001"}'
echo "$SEND_BODY" > /tmp/mesh_send_body.json

# Sign the send request with alice's Ed25519 key
# Alice's priv key is in /tmp/alice_priv.key from mesh_test_client.py
if [[ -f /tmp/alice_priv.key ]]; then
    ALICE_PRIV=$(cat /tmp/alice_priv.key)
    REQ_TS=$(python3 "${SCRIPT_DIR}/sign_ed25519.py" now-ts)
    REQ_NONCE="alice-req-nonce-$(date +%s)"
    AUTH_HEADER=$(python3 "${SCRIPT_DIR}/sign_ed25519.py" sign-request \
        "$ALICE_PRIV" "alice" "POST" "/send" "" /tmp/mesh_send_body.json "$REQ_TS" "$REQ_NONCE")
    echo "    alice auth header: $AUTH_HEADER"
    SEND_RESP=$(curl -s -X POST "http://localhost:${PORT_A}/send" \
        -H "Authorization: ${AUTH_HEADER}" \
        -H "Content-Type: application/json" \
        -d "$SEND_BODY")
    echo "    send response: $SEND_RESP"
else
    echo "!!! alice private key not found — skipping step 6"
fi
echo "=== Step 6 complete ==="
echo ""

# -----------------------------------------------------------------------------
# Step 7: Verify bob received the message (poll inbox on relay-b)
echo "=== Step 7: Verify bob received the message on relay-b ==="

BOB_INBOX=$(curl -s -X POST "http://localhost:${PORT_B}/poll_inbox" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"node_id":"node-bob","session_id":"sess-bob"}')
echo "    bob inbox: $BOB_INBOX"

MSG_COUNT=$(echo "$BOB_INBOX" | grep -o '"from_alias"' | wc -l || echo "0")
if [[ "$MSG_COUNT" -ge 1 ]]; then
    echo "=== Step 7 PASSED: bob received $MSG_COUNT message(s) ==="
else
    echo "!!! Step 7 FAILED: bob's inbox is empty — cross-host send may have failed"
    echo ""
    echo "=== Checking dead_letter on relay-a ==="
    DL_A=$(curl -s -X POST "http://localhost:${PORT_A}/admin/dead_letter" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{}')
    echo "    dead_letter on relay-a: $DL_A"
    echo ""
    echo "=== Container logs ==="
    docker logs "$CONTAINER_A" 2>&1 | tail -20 || true
    docker logs "$CONTAINER_B" 2>&1 | tail -20 || true
    exit 1
fi

# Verify the message content
if echo "$BOB_INBOX" | grep -q "hello from alice via mesh"; then
    echo "=== Message content verified ==="
else
    echo "!!! Message content mismatch"
    exit 1
fi

echo ""
echo "=== ALL STEPS PASSED ==="
echo "    Mesh cross-host send alice@relay-a → bob@relay-b via /forward endpoint: OK"
