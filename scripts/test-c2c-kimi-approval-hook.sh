#!/usr/bin/env bash
# test-c2c-kimi-approval-hook.sh — unit-tests scripts/c2c-kimi-approval-hook.sh
# by injecting a mock `c2c` binary that records `send` calls and returns a
# scripted verdict from `await-reply`.
#
# Coverage:
#   1. allow verdict        → hook exits 0
#   2. deny verdict         → hook exits 2 with stderr containing "denied"
#   3. timeout (await fails)→ hook exits 2 with stderr containing "no verdict"
#   4. send failure         → hook exits 2
#   5. token derived from tool_call_id when present
#
# Slice 1 of #157.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/scripts/c2c-kimi-approval-hook.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: $HOOK not executable" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH" >&2
  exit 0
fi

WORK="$(mktemp -d -t c2c-kimi-hook-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Build a mock c2c binary that:
#   * `c2c send <alias> <body>` → log to $C2C_MOCK_LOG, exit per $C2C_MOCK_SEND_RC
#   * `c2c await-reply --token T --timeout N` → print $C2C_MOCK_VERDICT, exit per $C2C_MOCK_AWAIT_RC
MOCK="$WORK/c2c"
cat >"$MOCK" <<'MOCKBIN'
#!/usr/bin/env bash
case "$1" in
  send)
    shift
    printf 'send %s -- %s\n' "$1" "$2" >>"${C2C_MOCK_LOG:-/dev/null}"
    exit "${C2C_MOCK_SEND_RC:-0}"
    ;;
  await-reply)
    if [ -n "${C2C_MOCK_VERDICT:-}" ]; then
      printf '%s\n' "$C2C_MOCK_VERDICT"
    fi
    exit "${C2C_MOCK_AWAIT_RC:-0}"
    ;;
  *)
    exit 99
    ;;
esac
MOCKBIN
chmod +x "$MOCK"

PAYLOAD='{"tool_name":"shell","tool_input":{"cmd":"rm -rf /"},"tool_call_id":"call_abc123","session_id":"s","cwd":"/"}'

run_hook() {
  # $1 verdict-on-stdout, $2 await-rc, $3 send-rc
  local stdout_file="$WORK/stdout" stderr_file="$WORK/stderr"
  local rc=0
  : >"$WORK/sendlog"
  C2C_BIN="$MOCK" \
  C2C_MOCK_LOG="$WORK/sendlog" \
  C2C_MOCK_VERDICT="$1" \
  C2C_MOCK_AWAIT_RC="$2" \
  C2C_MOCK_SEND_RC="$3" \
  C2C_KIMI_APPROVAL_REVIEWER="reviewer-alias" \
  C2C_KIMI_APPROVAL_TIMEOUT="2" \
  PATH="$WORK:$PATH" \
    bash "$HOOK" >"$stdout_file" 2>"$stderr_file" <<<"$PAYLOAD" || rc=$?
  echo "$rc"
}

fail() { echo "FAIL: $1" >&2; cat "$WORK/stderr" >&2 || true; exit 1; }
pass() { echo "ok: $1"; }

# Case 1: allow → exit 0
rc=$(run_hook "allow" 0 0)
[ "$rc" = "0" ] || fail "allow: expected exit 0, got $rc"
grep -q "ka_call_abc123" "$WORK/sendlog" || fail "allow: token from tool_call_id not in DM"
grep -q "^send reviewer-alias " "$WORK/sendlog" || fail "allow: DM not sent to configured reviewer"
pass "allow → exit 0"

# Case 2: deny → exit 2
rc=$(run_hook "deny" 0 0)
[ "$rc" = "2" ] || fail "deny: expected exit 2, got $rc"
grep -qi "denied" "$WORK/stderr" || fail "deny: stderr missing 'denied'"
pass "deny → exit 2"

# Case 3: timeout (await prints nothing, exits 1) → exit 2
rc=$(run_hook "" 1 0)
[ "$rc" = "2" ] || fail "timeout: expected exit 2, got $rc"
grep -qi "no verdict" "$WORK/stderr" || fail "timeout: stderr missing 'no verdict'"
pass "timeout → exit 2"

# Case 4: send failure → exit 2
rc=$(run_hook "allow" 0 7)
[ "$rc" = "2" ] || fail "send-fail: expected exit 2, got $rc"
grep -qi "failed to send DM" "$WORK/stderr" || fail "send-fail: stderr missing 'failed to send DM'"
pass "send failure → exit 2"

# Case 5: missing tool_call_id → token still minted, send still happens
PAYLOAD='{"tool_name":"shell","tool_input":{"cmd":"ls"}}'
rc=$(run_hook "allow" 0 0)
[ "$rc" = "0" ] || fail "no-call-id: expected exit 0, got $rc"
grep -qE "ka_[0-9a-f]{12}_[0-9]+" "$WORK/sendlog" || fail "no-call-id: synthesised token missing"
pass "no tool_call_id → synthesised token works"

echo "OK: scripts/c2c-kimi-approval-hook.sh — 5 cases green."
