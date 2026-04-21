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

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; ((PASS++)); }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; ((FAIL++)); }
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

# 3. List (should see our alias)
echo "--- 3. List ---"
list_out=$(c2c relay list --relay-url "$RELAY" --alias "$ALIAS" 2>&1) || true
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

# Summary
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
