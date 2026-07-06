#!/usr/bin/env bash
# codex-c2c-live-test.sh — drive a VANILLA `codex exec` session through a live
# c2c round-trip: register → find peer → send DM → blocking wait-inbox → dereg.
#
# Usage:
#   scripts/codex-c2c-live-test.sh [PEER_ALIAS] [TEST_ALIAS] [WAIT_TIMEOUT]
#
#   PEER_ALIAS    peer that will reply while codex blocks (default: fable-scribe)
#   TEST_ALIAS    alias codex registers as (default: vanilla-probe-zq)
#   WAIT_TIMEOUT  wait-inbox timeout (default: 120s)
#
# The DRIVER (you, the coordinating agent) must watch for the test DM and reply
# to TEST_ALIAS while codex blocks in step 6, e.g.:
#   c2c send vanilla-probe-zq "reply — unblocking your wait-inbox"
#
# Notes:
# - Strips inherited Claude/companion session env so the codex child cannot
#   hijack the parent agent's c2c identity (kimi-inside-claude class bug).
# - `C2C_MCP_CLIENT_PID=$PPID` on register pins the long-lived codex process:
#   without it the registration captures the transient shell pid and the alias
#   is born dead/unroutable (finding 2026-07-06T10-15-00Z, task: stable-pid).
# - Report lands at /tmp/codex-c2c-live-test.md.
set -euo pipefail

PEER_ALIAS="${1:-fable-scribe}"
TEST_ALIAS="${2:-vanilla-probe-zq}"
WAIT_TIMEOUT="${3:-120s}"
REPORT=/tmp/codex-c2c-live-test.md

env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDECODE \
    -u CLAUDE_CONFIG_DIR -u CODEX_COMPANION_SESSION_ID -u C2C_MCP_SESSION_ID \
  codex exec -C "$(git rev-parse --show-toplevel)" --sandbox danger-full-access \
"You are a VANILLA codex session live-testing the c2c messaging CLI (freshly rebuilt). Execute these steps IN ORDER via shell, capturing each command's exact stdout/stderr and exit code. Do not improvise extra c2c commands.

1. c2c whoami
2. C2C_MCP_CLIENT_PID=\$PPID c2c register --alias ${TEST_ALIAS}   # PPID pins your long-lived codex process so peers see you alive
3. c2c whoami
4. c2c find ${PEER_ALIAS}
5. c2c send ${PEER_ALIAS} \"hello from vanilla codex exec (${TEST_ALIAS}) — step 5 of live test\"
6. c2c wait-inbox --timeout ${WAIT_TIMEOUT} --json    # BLOCKING: a peer (${PEER_ALIAS}) will reply while you wait; note how long it blocked and the exit code
7. c2c deregister ${TEST_ALIAS}

Then write a markdown report to ${REPORT}: for each step the command, exit code, output verbatim, plus a final PASS/FAIL verdict per step and 2-3 sentences on friction you hit (identity pickup? errors? confusing output?). End your reply with the single word DONE."
