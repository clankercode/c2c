#!/usr/bin/env bash
# smoke-schedule.sh — end-to-end smoke test for c2c schedule CLI
# Usage: ./smoke-schedule.sh [alias]
# Requires: c2c binary in PATH, C2C_MCP_AUTO_REGISTER_ALIAS set or passed as arg

set -euo pipefail

ALIAS="${1:-${C2C_MCP_AUTO_REGISTER_ALIAS:-test-schedule-smoke}}"
SCHED_NAME="test-sched-$$"
INTERVAL="2m"
MESSAGE="smoke-test message"

export C2C_MCP_AUTO_REGISTER_ALIAS="$ALIAS"

echo "=== smoke-schedule.sh ==="
echo "alias: $ALIAS"
echo ""

# Prerequisite: schedule subcommand must exist
if ! c2c schedule --help >/dev/null 2>&1; then
    echo "FAIL: 'c2c schedule' not available"
    exit 1
fi
echo "[OK] c2c schedule command available"

# Clean up any pre-existing schedule from prior run
c2c schedule rm "$SCHED_NAME" >/dev/null 2>&1 || true

# 1. schedule set
echo ""
echo "[TEST] c2c schedule set"
c2c schedule set "$SCHED_NAME" --interval "$INTERVAL" --message "$MESSAGE"
echo "[OK] schedule set"

# 2. schedule list --json
echo ""
echo "[TEST] c2c schedule list --json"
LIST_OUT=$(c2c schedule list --json)
echo "$LIST_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert any(s['name']=='$SCHED_NAME' for s in d), 'schedule not found in list'" 2>/dev/null && echo "[OK] schedule list --json" || { echo "FAIL: schedule not in list output"; echo "$LIST_OUT"; exit 1; }

# 3. schedule show --json
echo ""
echo "[TEST] c2c schedule show $SCHED_NAME --json"
SHOW_OUT=$(c2c schedule show "$SCHED_NAME" --json 2>/dev/null || echo '{"error":"not found"}')
echo "$SHOW_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('name')=='$SCHED_NAME', f\"expected name=$SCHED_NAME, got {d.get('name')}\"" 2>/dev/null && echo "[OK] schedule show --json" || { echo "FAIL: schedule show failed"; echo "$SHOW_OUT"; exit 1; }

# 4. schedule rm
echo ""
echo "[TEST] c2c schedule rm $SCHED_NAME"
c2c schedule rm "$SCHED_NAME"
echo "[OK] schedule rm"

# Verify gone
echo ""
echo "[TEST] schedule removed from list"
LIST_AFTER=$(c2c schedule list --json)
echo "$LIST_AFTER" | python3 -c "import sys,json; d=json.load(sys.stdin); assert not any(s['name']=='$SCHED_NAME' for s in d), 'schedule still in list after rm'" 2>/dev/null && echo "[OK] schedule not in list after rm" || { echo "FAIL: schedule still present after rm"; exit 1; }

echo ""
echo "=== ALL TESTS PASSED ==="
