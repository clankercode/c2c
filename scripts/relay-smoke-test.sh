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

# Retry wrapper: tries a command up to N times with a short delay between attempts.
# Usage: retry 3 1 c2c relay rooms send ... (3 attempts, 1s delay)
retry() {
  local max_attempts=$1; local delay=$2; shift 2
  local attempt=1
  local out err
  while (( attempt <= max_attempts )); do
    out=$("$@" 2>&1) && return 0
    err=$out
    if (( attempt < max_attempts )); then
      info "attempt $attempt failed, retrying in ${delay}s..."
      sleep "$delay"
    fi
    ((attempt++))
  done
  echo "$err"
  return 1
}

send_room_out=$(retry 3 1 c2c relay rooms send --alias "$ALIAS" --room "$ROOM" "smoke test message" --relay-url "$RELAY" 2>&1) || true
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

# 8. Cross-host rejection + dead-letter row (regression guard for #379 / 492c052b)
#
# Sends to <alias>@unknown-relay-host and asserts the relay rejects with
# error="cross_host_not_implemented" (rather than silent-drop). When an
# admin bearer is available (C2C_RELAY_ADMIN_TOKEN), additionally asserts
# a dead_letter row materialised via GET /dead_letter.
#
# Catches the silent-drop bug class fixed in 492c052b / 4450cf56:
# pre-fix, b@hostZ was dropped instead of dead-lettered, so a regression
# would be invisible without this probe. Until forwarder S2 lands, the
# correct behavior IS rejection — once forwarding is implemented this
# section's expectations need to flip.
echo "--- 8. Cross-host rejection + dead-letter ---"
CROSS_HOST_TARGET="$ALIAS@unknown-relay-host.invalid"
ch_out=$(c2c relay dm send "$CROSS_HOST_TARGET" "smoke cross-host probe" \
           --alias "$ALIAS" --relay-url "$RELAY" 2>&1) || true
echo "$ch_out"
if echo "$ch_out" | python3 -c "import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
# Relay returns {ok:false, error_code:'cross_host_not_implemented', error:'<msg>'};
# accept either field for forward-compat.
code = d.get('error_code') or d.get('error', '')
sys.exit(0 if 'cross_host_not_implemented' in str(code) else 1)" 2>/dev/null; then
  green "cross-host send rejected with cross_host_not_implemented (#379 silent-drop guard)"
else
  red "cross-host send did not reject as expected — silent-drop regression? (#379 / 492c052b)"
fi

# dead_letter visibility: admin-bearer endpoint, so this is conditional.
# When C2C_RELAY_ADMIN_TOKEN is unset, degrade to info — the rejection
# shape check above is the real regression-catcher and stands alone.
if [ -n "${C2C_RELAY_ADMIN_TOKEN:-}" ]; then
  dl_out=$(curl -sf -H "Authorization: Bearer $C2C_RELAY_ADMIN_TOKEN" \
                 "$RELAY/dead_letter" 2>&1) || true
  if ALIAS="$ALIAS" echo "$dl_out" | ALIAS="$ALIAS" python3 -c "import json,sys,os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
entries = d.get('dead_letter', d if isinstance(d, list) else [])
alias = os.environ.get('ALIAS', '')
hits = [e for e in entries
        if isinstance(e, dict)
        and e.get('reason') == 'cross_host_not_implemented'
        and alias in str(e.get('to_alias', ''))]
sys.exit(0 if hits else 1)" 2>/dev/null; then
    green "dead_letter row visible for cross-host rejection"
  else
    red "dead_letter row missing — fix 492c052b regressed?"
  fi
else
  info "dead_letter row check skipped (set C2C_RELAY_ADMIN_TOKEN to enable)"
fi
echo ""

# 9. Heartbeat (peer-route auth classification)
# Per smoke-coverage audit (cairn 2026-04-29), gap A: /heartbeat regression
# would silently break nudge cadence + /list freshness with no PASS/FAIL signal.
# In prod, /heartbeat is a peer route requiring Ed25519 (relay.ml:2596-2602).
# Bash can't replicate Ed25519 signing without reimplementing crypto, so this
# section asserts the route is correctly classified as a peer route by hitting
# it unsigned and expecting HTTP 401 with the spec-§5.1 error message.
# Coverage: catches reclassification to admin (would say "Bearer token") or
# self-auth (would 200/400) and catches auth-spec error-message drift. Does
# NOT catch route-deletion alone (auth runs before routing — unknown paths
# also 401). A signed-call PASS is a follow-up gated on `c2c relay heartbeat`
# CLI (audit Proposal A note).
echo "--- 9. Heartbeat (route presence + auth classification) ---"
hb_node="cli-$ALIAS"
hb_session="cli-$ALIAS"
hb_resp=$(curl -s -o /tmp/hb_body.$$ -w "%{http_code}" -X POST "$RELAY/heartbeat" \
  -H "content-type: application/json" \
  -d "{\"node_id\":\"$hb_node\",\"session_id\":\"$hb_session\"}" 2>/dev/null) || true
hb_body=$(cat /tmp/hb_body.$$ 2>/dev/null || echo "")
rm -f /tmp/hb_body.$$
echo "  HTTP $hb_resp: $hb_body"
if [ "$hb_resp" = "401" ] && echo "$hb_body" | python3 -c "
import json, sys
d = json.load(sys.stdin)
err = d.get('error') or ''
# Peer-route message comes from auth_decision (relay.ml:2602):
#   'peer route requires Ed25519 auth (spec §5.1)'
# Admin-route reclassification would say 'Bearer token' instead.
sys.exit(0 if (
    d.get('ok') is False
    and d.get('error_code') == 'unauthorized'
    and 'Ed25519' in err
    and 'peer route' in err
) else 1)
" 2>/dev/null; then
  green "heartbeat is a peer route (HTTP 401, Ed25519-required, spec §5.1)"
else
  red "heartbeat auth classification regressed (got HTTP $hb_resp; expected 401 + peer-route message)"
fi
echo ""

# 10. send_all broadcast loopback (gap D from cairn audit)
#
# With one registered alias, /send_all should ack `ok` and (per current
# relay semantics) the broadcast lands in our own inbox as a
# self-loopback — this guards the 1:N broadcast fan-out path. A
# regression here would silently break broadcast/room-adjacent semantics
# and ship undetected to prod. See
# .collab/research/2026-04-29-smoke-coverage-audit-cairn.md proposal D.
echo "--- 10. send_all broadcast loopback ---"
SA_PROBE="smoke send_all probe $(date +%s)"
sa_out=$(c2c relay dm send-all "$SA_PROBE" --alias "$ALIAS" --relay-url "$RELAY" 2>&1) || true
echo "$sa_out"
if echo "$sa_out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
  green "send_all ack ok"
  # Poll inbox; loopback semantic depends on relay behavior. Accept
  # either (a) message landed (self-loopback included) as hard PASS, or
  # (b) message absent (sender excluded) as info — both are defensible
  # spec choices. The ack itself is the regression-catcher.
  sa_poll=$(c2c relay dm poll --alias "$ALIAS" --relay-url "$RELAY" 2>&1) || true
  if echo "$sa_poll" | grep -qF "$SA_PROBE"; then
    green "send_all delivered to self-loopback"
  else
    info "send_all not in own inbox (relay may exclude sender — non-fatal)"
  fi
else
  red "send_all failed (broadcast fan-out regressed?)"
fi
echo ""

# Summary
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
