#!/usr/bin/env bash
# kimi-bake-probe.sh — periodic kimi peer health probe for the wire-bridge
# bake window (Slice 4). Sends a probe DM to each target asking them to
# reply in swarm-lounge, then watches room_history for any message from that
# target within the timeout window. Logs latency + success/fail to a rolling
# JSONL.
#
# Why room-based reply detection: kimi peers use channel push for DM delivery —
# those replies go to the agent's transcript and cannot be detected by inbox
# polling from bash. Room messages are always archived in room_history and
# queryable regardless of delivery path. As long as the target posts at least
# one message to swarm-lounge within the window, we detect it.
#
# Usage:
#   scripts/kimi-bake-probe.sh [probe_id]
#     probe_id   optional; defaults to $(date +%s%3N)
#
# Env:
#   KIMI_BAKE_PROBE_TIMEOUT   reply timeout per target (default: 120s)
#   KIMI_BAKE_PROBE_LOG      JSONL log path (default: ~/.local/state/c2c/kimi-bake-probe/log.jsonl)
#   KIMI_BAKE_PROBE_TARGETS  space-separated alias list (default: "kuura-viima lumi-tyyni")
#   KIMI_BAKE_PROBE_ROOM     room to watch for replies (default: swarm-lounge)
#
# Exit: 0 if all targets posted in the room within timeout, 1 if any timed out.

set -euo pipefail

PROBE_ID="${1:-$(date +%s%3N)}"
TIMEOUT="${KIMI_BAKE_PROBE_TIMEOUT:-120}"
LOGFILE="${KIMI_BAKE_PROBE_LOG:-"$HOME/.local/state/c2c/kimi-bake-probe/log.jsonl"}"
TARGETS="${KIMI_BAKE_PROBE_TARGETS:-kuura-viima lumi-tyyni}"
REPLY_ROOM="${KIMI_BAKE_PROBE_ROOM:-swarm-lounge}"

mkdir -p "$(dirname "$LOGFILE")"

ts_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Probe one target: send DM asking for room reply, then watch room_history
# for ANY message from that alias within the timeout. The message need not
# contain the probe_id — any activity from the alias proves liveness.
# Returns 0 on success (prints latency_ms of first room message from alias),
# 1 on timeout (no room activity detected).
probe_target() {
  local alias="$1"
  local body="🔔 probe:${PROBE_ID} — please post any message in ${REPLY_ROOM} to confirm you're online"

  local sent_ts
  sent_ts=$(date +%s%3N)

  # Record the latest room history ts before we send so we can diff
  local before_ts
  before_ts=$(c2c room history "$REPLY_ROOM" --json --limit 1 2>/dev/null | \
    python3 -c "import sys,json; msgs=json.load(sys.stdin); print(msgs[0]['ts'] if msgs else 0)" 2>/dev/null || echo "0")

  # Send DM
  c2c send "$alias" "$body" >/dev/null 2>&1 || {
    echo "ERROR: c2c send failed for $alias" >&2
    return 1
  }

  local deadline=$((sent_ts / 1000 + TIMEOUT))
  local reply_ts=""

  while true; do
    local now_ms now_s
    now_ms=$(date +%s%3N)
    now_s=$((now_ms / 1000))
    if [ "$now_s" -ge "$deadline" ]; then
      break
    fi

    # room history: find the newest message from this alias, newer than before_ts
    local newest_from_alias
    newest_from_alias=$(c2c room history "$REPLY_ROOM" --json --limit 100 2>/dev/null | \
      python3 -c "
import sys, json
try:
    msgs = json.load(sys.stdin)
    before = ${before_ts}
    for m in msgs:
        if m.get('from_alias') == '${alias}' and float(m.get('ts', 0)) > before:
            print(m.get('ts', ''))
            break
except:
    pass
" 2>/dev/null)

    if [ -n "$newest_from_alias" ]; then
      reply_ts=$(python3 -c "print(int(float(${newest_from_alias}) * 1000))" 2>/dev/null)
      break
    fi

    sleep 5
  done

  if [ -z "$reply_ts" ]; then
    return 1
  fi

  local latency_ms=$((reply_ts - sent_ts))
  echo "$latency_ms"
  return 0
}

trim_log() {
  local log="$LOGFILE"
  if [ -f "$log" ] && [ "$(wc -l < "$log" 2>/dev/null || echo 0)" -gt 1000 ]; then
    tail -n 800 "$log" > "${log}.tmp" && mv "${log}.tmp" "$log"
  fi
}

FAIL_COUNT_FILE="${LOGFILE}.failcount"
get_fail_count() { cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0; }
inc_fail_count() {
  local n=$(( $(get_fail_count) + 1 ))
  echo "$n" > "$FAIL_COUNT_FILE"
}
reset_fail_count() { echo 0 > "$FAIL_COUNT_FILE"; }

any_failed=0
timestamp=$(ts_utc)
fail_count=$(get_fail_count)

for alias in $TARGETS; do
  if latency_ms=$(probe_target "$alias"); then
    printf '%s\n' "$(printf '{"ts":"%s","alias":"%s","ok":true,"latency_ms":%s,"probe_id":"%s","fail_count":%s}' \
      "$timestamp" "$alias" "$latency_ms" "$PROBE_ID" "$fail_count")" >> "$LOGFILE"
  else
    any_failed=1
    printf '%s\n' "$(printf '{"ts":"%s","alias":"%s","ok":false,"error":"timeout","probe_id":"%s","fail_count":%s}' \
      "$timestamp" "$alias" "$PROBE_ID" "$fail_count")" >> "$LOGFILE"
  fi
done

trim_log

if [ "$any_failed" -eq 1 ]; then
  inc_fail_count
  new_fail_count=$(get_fail_count)
  if [ "$new_fail_count" -ge 2 ]; then
    c2c send coordinator1 "🔴 HARD-FAIL: kimi bake probe failed 2+ consecutive times (probe_id=${PROBE_ID}). Targets: ${TARGETS}. Last log: ${LOGFILE}" --tag fail >/dev/null 2>&1 || true
  fi
  echo "FAIL (fail_count=${new_fail_count})" >&2
  exit 1
else
  reset_fail_count
  echo "OK" >&2
  exit 0
fi
