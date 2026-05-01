#!/usr/bin/env bash
# c2c-kimi-approval-hook.sh — invoked by kimi-cli on a matched PreToolUse
# event.  Forwards the approval request to a configured reviewer via c2c
# DM, blocks on `c2c await-reply`, and translates the verdict back to
# kimi-cli via the standard exit-code protocol:
#
#   exit 0  → allow (kimi proceeds)
#   exit 2  → block (stderr is shown to the agent as the rejection reason)
#
# Configuration:
#   C2C_KIMI_APPROVAL_REVIEWER  reviewer alias (default: coordinator1)
#   C2C_KIMI_APPROVAL_TIMEOUT   seconds to wait for verdict (default: 120)
#
# Source-of-truth note (slice 2 of #142, 2026-04-30): this file remains
# the test fixture for slice 1's bash-side test harness, but the script
# DEPLOYED by `c2c install kimi` is embedded in the c2c binary at
# ocaml/cli/c2c_kimi_hook.ml (approval_hook_script_content).  Keep both
# in rough sync; the embedded copy is what operators actually run.
#
# Slice 1 of #142: this script + `c2c await-reply` CLI.
# Slice 2 of #142: install side — embeds + writes [[hooks]] block.
# This file unconditionally forwards whatever it receives; the matcher
# is configured in the operator's ~/.kimi/config.toml [[hooks]] block.
set -euo pipefail

# Tools required: jq for parsing kimi's stdin payload, c2c for messaging.
if ! command -v jq >/dev/null 2>&1; then
  echo "c2c-kimi-approval-hook: jq is required but not on PATH" >&2
  exit 2
fi
if ! command -v c2c >/dev/null 2>&1; then
  echo "c2c-kimi-approval-hook: c2c is required but not on PATH" >&2
  exit 2
fi

# Allow tests to inject mock c2c via $C2C_BIN.
C2C_BIN="${C2C_BIN:-c2c}"

# Read kimi's JSON payload from stdin
payload="$(cat)"
tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // ""')"
tool_input="$(printf '%s' "$payload" | jq -c '.tool_input // {}')"
tool_call_id="$(printf '%s' "$payload" | jq -r '.tool_call_id // ""')"

REVIEWER="${C2C_KIMI_APPROVAL_REVIEWER:-coordinator1}"
TIMEOUT="${C2C_KIMI_APPROVAL_TIMEOUT:-120}"

# --------------------------------------------------------------------------
# Safe-pattern allowlist — exit 0 immediately without DM for read-only commands.
# This runs BEFORE the authorizer chain, so safe commands cost nothing.
# --------------------------------------------------------------------------
is_safe_command() {
  # Extract command string from tool_input
  local cmd
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"
  [ -z "$cmd" ] && return 1

  # Strip leading whitespace, extract first token
  local first
  first="$(printf '%s' "$cmd" | awk '{print $1}')"
  [ -z "$first" ] && return 1

  case "$first" in
    cat|ls|pwd|head|tail|wc|file|stat|which|whereis|type|env|printenv|\
echo|printf|true|false|test|\[)
      return 0
      ;;
    grep|rg|ag|find|fd|tree|du|df|free|uptime|date|hostname|whoami|id|\
ps|pgrep|pidof|lsof|jobs|history|column|sort|uniq|cut|paste|tr|sed|awk|\
jq|yq|xq|tomlq)
      # Pure-read or pure-text-transformer commands with no side effects
      return 0
      ;;
    git)
      # Only allow read-only git subcommands
      local sub
      sub="$(printf '%s' "$cmd" | awk '{print $2}')"
      case "$sub" in
        status|log|diff|show|branch|tag|remote|config|rev-parse|\
rev-list|describe|blame|reflog|ls-files|ls-tree|fetch|\
shortlog|count|status|-h|--help)
          return 0
          ;;
        *)  # push, pull, commit, reset, checkout, merge, rebase, etc. — require approval
          return 1
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

# If the command is safe, exit 0 immediately — no DM, no round-trip.
if is_safe_command; then
  exit 0
fi

# Mint a token: prefer kimi's tool_call_id (stable, unique per call); fall
# back to a hash of the payload + a nanosecond-timestamp suffix.
if [ -n "$tool_call_id" ]; then
  TOKEN="ka_${tool_call_id}"
else
  payload_hash="$(printf '%s' "$payload" | sha256sum | cut -c1-12)"
  TOKEN="ka_${payload_hash}_$(date +%s%N)"
fi

# Build the DM body the reviewer sees.  The reply syntax we expect is
# any DM whose content contains the token plus "allow" or "deny".
body="$(cat <<EOF
[kimi-approval] PreToolUse:
  tool: $tool_name
  args: $tool_input
  token: $TOKEN
  timeout: ${TIMEOUT}s

Reply with:
  c2c send <kimi-alias> "$TOKEN allow"
  c2c send <kimi-alias> "$TOKEN deny because <reason>"
EOF
)"

# Forward to the reviewer.  If the send fails we fall closed (exit 2);
# kimi will surface the stderr to the agent.
if ! "$C2C_BIN" send "$REVIEWER" "$body" >/dev/null 2>&1; then
  echo "c2c-kimi-approval-hook: failed to send DM to reviewer=$REVIEWER" >&2
  exit 2
fi

# Block on a verdict.  await-reply prints "allow" or "deny" on stdout
# and exits 0; on timeout it prints nothing and exits 1.
verdict="$("$C2C_BIN" await-reply --token "$TOKEN" --timeout "$TIMEOUT" 2>/dev/null || true)"

case "$verdict" in
  allow|ALLOW)
    exit 0
    ;;
  deny|DENY)
    echo "denied by reviewer=$REVIEWER (token=$TOKEN)" >&2
    exit 2
    ;;
  "")
    echo "no verdict from reviewer=$REVIEWER within ${TIMEOUT}s; falling closed (token=$TOKEN)" >&2
    exit 2
    ;;
  *)
    echo "unrecognized verdict '$verdict' from await-reply; falling closed (token=$TOKEN)" >&2
    exit 2
    ;;
esac
