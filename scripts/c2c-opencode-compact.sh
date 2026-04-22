#!/bin/bash
# c2c-opencode-compact.sh — OpenCode compacting wrapper
#
# Call this before triggering context compaction in OpenCode:
#   c2c set-compact --reason "opencode-compact"
#
# The c2c.ts plugin's session.compacted handler will automatically call
# c2c clear-compact when OpenCode finishes compaction.
#
# Alternatively, call this script directly which wraps set-compact + clear-compact:
#   c2c-opencode-compact.sh [--reason REASON]
#
# Required env vars (set by c2c start):
#   C2C_MCP_SESSION_ID   — broker session id
#   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir

REASON="${C2C_COMPACT_REASON:-opencode-compact}"

if command -v c2c >/dev/null 2>&1; then
    c2c set-compact --reason "$REASON" 2>/dev/null
    echo "Compacting flag set. Trigger compaction in OpenCode, then it will auto-clear on session.compacted."
else
    echo "c2c not found in PATH" >&2
    exit 1
fi
