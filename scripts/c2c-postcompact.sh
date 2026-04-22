#!/bin/bash
# c2c-postcompact.sh — PostCompact hook: clear compacting flag
#
# Fires after Claude Code context compaction completes. Calls c2c clear-compact
# so senders no longer receive compacting warnings.
#
# Required env vars (set by c2c start or the MCP server entry):
#   C2C_MCP_SESSION_ID   — broker session id
#   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir

if command -v c2c >/dev/null 2>&1; then
    c2c clear-compact 2>/dev/null
    exit 0
fi
sleep 0.05
exit 0
