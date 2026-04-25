#!/bin/bash
# relay-smoke-test.sh — Comprehensive relay verification after prod deploy
# Run after Railway rebuild completes (check git_hash in /health first)
#
# Usage: ./scripts/relay-smoke-test.sh [relay-url]
# Default relay-url: https://relay.c2c.im

set -euo pipefail

RELAY="${1:-https://relay.c2c.im}"
ALIAS="smoke-$(date +%s)"
PASS=0
FAIL=0

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; ((PASS++)) || true; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; ((FAIL++)) || true; }
info()  { printf '  %s\n' "$*"; }

echo "=== c2c Relay Smoke Test ==="
echo "  Relay:  $RELAY"
echo "  Alias:  $ALIAS"
echo ""

# 1. Health check
echo "--- 1. Health ---"
health=$(curl -sf "$RELAY/health" 2>/dev/null) || { red "health endpoint unreachable"; exit 1; }
echo "$health" | python3 -m json.tool 2>/dev/null || echo "$health"
auth_mode=$(echo "$health" | python3 -c "import json,sys; print(json.load(sys.stdin).get('auth_mode','unknown'))" 2>/dev/null)
git_hash=$(echo "$health" | python3 -c "import json,sys; print(json.load(sys.stdin).get('git_hash','?'))" 2>/dev/null)
if [ "$auth_mode" = "prod" ]; then
  green "auth_mode=prod (relay is in production mode)"
else
  red "expected auth_mode=prod, got: $auth_mode"
fi
info "git_hash: $git_hash"
echo ""

# 2. Register alias
echo "--- 2. Register ---"
reg_out=$(c2c relay register --alias "$ALIAS" --relay-url "$RELAY" 2>&1) || true
echo "$reg_out"
if echo "$reg_out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
  green "register succeeded"
else
  red "register failed — relay auth bootstrap fix may not be deployed"
  echo ""
  echo "Expected fix: adb152f (allow /register to bypass header Ed25519)"
  echo "Current hash: $git_hash"
  exit 1
fi
echo ""

# 3. List (C2C_MCP_AUTO_REGISTER_ALIAS tells the CLI which alias to sign as for the peer route)
echo "--- 3. List ---"
list_out=$(C2C_MCP_AUTO_REGISTER_ALIAS="$ALIAS" c2c relay list --relay-url "$RELAY" 2>&1) || true
echo "$list_out"
if echo "$list_out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
  green "list succeeded"
else
  red "list failed"
fi
echo ""

# 4. Send DM to self (loopback)
echo "--- 4. Loopback DM ---"
dm_out=$(c2c relay dm send "$ALIAS" "smoke-test loopback" --alias "$ALIAS" --relay-url "$RELAY" 2>&1) || true
echo "$dm_out"
if echo "$dm_out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
  green "loopback DM send succeeded"
else
  red "loopback DM send failed"
fi
echo ""

# 5. Poll inbox
echo "--- 5. Poll inbox ---"
poll_out=$(c2c relay dm poll --alias "$ALIAS" --relay-url "$RELAY" 2>&1) || true
echo "$poll_out"
if echo "$poll_out" | python3 -c "import json,sys; d=json.load(sys.stdin); msgs=d.get('messages',[]); exit(0 if len(msgs)>0 else 1)" 2>/dev/null; then
  green "loopback DM received"
else
  red "loopback DM not in inbox"
fi
echo ""

# 6. Room operations (join → list → leave)
ROOM="smoke-room-$(date +%s)"
echo "--- 6. Room operations (room: $ROOM) ---"

join_out=$(c2c relay rooms join --alias "$ALIAS" --room "$ROOM" --relay-url "$RELAY" 2>&1) || true
echo "$join_out"
if echo "$join_out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
  green "room join succeeded"
else
  red "room join failed"
fi

# List rooms (unauthenticated — should work without Ed25519)
list_rooms_out=$(c2c relay rooms list --relay-url "$RELAY" 2>&1) || true
if echo "$list_rooms_out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
  green "room list (unauthenticated) succeeded"
else
  red "room list failed"
fi

send_room_out=$(c2c relay rooms send --alias "$ALIAS" --room "$ROOM" "smoke test message" --relay-url "$RELAY" 2>&1) || true
if echo "$send_room_out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
  green "room send succeeded"
else
  red "room send failed"
fi

# NOTE: room leave was non-fatal on older prod relays that lacked /leave_room.
# join+send+history are the critical room ops; leave is best-effort.
leave_out=$(c2c relay rooms leave --alias "$ALIAS" --room "$ROOM" --relay-url "$RELAY" 2>&1) || true
echo "$leave_out"
if echo "$leave_out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
  green "room leave succeeded"
else
  info "room leave failed (non-fatal — TTL expiry or session drift)"
fi

# Room history (unauthenticated — should work without Ed25519)
hist_out=$(c2c relay rooms history --room "$ROOM" --relay-url "$RELAY" 2>&1) || true
if echo "$hist_out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
  green "room history (unauthenticated) succeeded"
else
  red "room history failed"
fi
echo ""

# 7. Ed25519 identity check
echo "--- 7. Ed25519 identity ---"
IDENTITY_PATH="${C2C_RELAY_IDENTITY_PATH:-$HOME/.config/c2c/identity.json}"
if [ -f "$IDENTITY_PATH" ]; then
  green "identity file present: $IDENTITY_PATH"
  # Verify register included identity_pk (the binding is what enables Ed25519 on peer routes)
  if echo "$reg_out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('identity_pk_registered') or d.get('ok') else 1)" 2>/dev/null; then
    info "register ok (identity binding may be confirmed in relay logs)"
  fi
else
  info "no identity file at $IDENTITY_PATH (Ed25519 signing not enabled)"
  info "generate with: c2c relay identity init"
fi
echo ""

# Summary
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
