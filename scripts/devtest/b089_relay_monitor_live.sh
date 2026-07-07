#!/usr/bin/env bash
# B089 live verification: the monitor surfaces a relay DM (peek, non-draining)
# and a second peek cycle does NOT re-surface it or drain it.
# Isolated: temp HOME + temp broker root + ephemeral port + local relay.
set -u
cd "$(dirname "$0")/../.."   # repo root (worktree)
eval $(opam env)
C2C="./_build/default/ocaml/cli/c2c.exe"

TMP=$(mktemp -d)
export HOME="$TMP/home"; mkdir -p "$HOME"
BROKER="$TMP/broker"; mkdir -p "$BROKER"
export C2C_MCP_BROKER_ROOT="$BROKER"
PORT=$(python3 -c 'import random; print(random.randint(20000,60000))')
export C2C_RELAY_URL="http://127.0.0.1:$PORT"
RELAY_LOG="$TMP/relay.log"

cleanup() {
  [ -n "${MON_PID:-}" ] && kill "$MON_PID" 2>/dev/null
  [ -n "${RELAY_PID:-}" ] && kill "$RELAY_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== starting relay on :$PORT =="
$C2C relay serve --listen 127.0.0.1:$PORT --storage memory >"$RELAY_LOG" 2>&1 &
RELAY_PID=$!
# wait for relay to accept connections
for i in $(seq 1 40); do
  if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then exec 3>&- 3<&-; break; fi
  sleep 0.25
done

echo "== identity + register receiver (rx) and sender (tx) =="
$C2C relay identity init >/dev/null 2>&1
$C2C relay register --alias rx >/dev/null 2>&1 || { echo "REGISTER rx FAILED"; cat "$RELAY_LOG"; exit 1; }
$C2C relay register --alias tx >/dev/null 2>&1 || { echo "REGISTER tx FAILED"; cat "$RELAY_LOG"; exit 1; }

MON_OUT="$TMP/monitor.out"
echo "== starting monitor (alias rx, relay-interval 1.5s) =="
# Monitor orphan-checks its parent, so keep this script as its parent.
$C2C monitor --alias rx --relay-interval 1.5 >"$MON_OUT" 2>&1 &
MON_PID=$!

# give the monitor ~2s to print its ready banner + do a first (empty) peek
sleep 2

echo "== send a cross-host DM tx -> rx =="
$C2C relay dm send --alias tx rx "hello-from-relay-089" >/dev/null 2>&1 \
  || { echo "SEND FAILED"; cat "$RELAY_LOG"; exit 1; }

# wait > 1 relay-interval so the monitor peeks at least once after the send
sleep 3
kill $MON_PID 2>/dev/null

echo "===== MONITOR OUTPUT ====="
cat "$MON_OUT"
echo "===== END MONITOR OUTPUT ====="

echo "== verify non-draining: relay dm peek STILL sees the message =="
PEEK=$($C2C relay dm peek --alias rx 2>/dev/null)
echo "peek result: $PEEK"
if echo "$PEEK" | grep -q "hello-from-relay-089"; then
  echo "PEEK-NON-DRAINING: PASS (message still present after monitor peeks)"
else
  echo "PEEK-NON-DRAINING: FAIL (monitor drained the relay inbox!)"; exit 1
fi

echo "== verify monitor surfaced it (tagged relay) =="
if grep -q "hello-from-relay-089" "$MON_OUT" && grep -q "relay watch:" "$MON_OUT"; then
  echo "MONITOR-SURFACE: PASS"
else
  echo "MONITOR-SURFACE: FAIL (DM not surfaced or relay watch not active)"; exit 1
fi

echo "== verify monitor did NOT re-print the DM on the second peek cycle =="
N=$(grep -c "hello-from-relay-089" "$MON_OUT")
if [ "$N" -eq 1 ]; then
  echo "DEDUP-ACROSS-CYCLES: PASS (surfaced exactly once)"
else
  echo "DEDUP-ACROSS-CYCLES: FAIL (surfaced $N times, expected 1)"; exit 1
fi

echo "ALL LIVE CHECKS PASSED"
