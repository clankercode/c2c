(* c2c_claude_hook_scripts.ml — canonical Claude Code hook script contents.

   Extracted from c2c_setup so both the installer (c2c_setup) and the
   self-healing `c2c doctor hooks --fix` (c2c_doctor_hooks) share ONE source
   of truth for the PostToolUse / Stop / SessionStart-End hook scripts.
   Dependency-free: pure string data. *)

let claude_hook_script = {|
#!/bin/bash
# c2c-inbox-check.sh — PostToolUse hook for c2c auto-delivery in Claude Code
#
# Calls c2c-inbox-hook-ocaml which drains inboxes and emits any cold-boot
# context block in one hookSpecificOutput.additionalContext payload.
#
# IMPORTANT: do NOT use `exec` for hook binaries. Claude Code's Node.js hook runner
# tracks the initially-spawned bash PID, and when bash exec's to the c2c
# binary the runner's waitpid() bookkeeping gets confused and surfaces
# `ECHILD: unknown error, waitpid` on every tool call. Running binaries as
# bash subprocesses and exiting bash normally fixes it.
#
# Optional env vars (set by c2c start, the MCP server entry, or tests):
#   C2C_MCP_SESSION_ID   — broker session id
#   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir
#   C2C_SESSIONS_BROKER_ROOT — global session broker override

SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || echo "$SCRIPT_DIR")"

# Prefer the installed OCaml hook because it can read Claude's stdin
# session_id, drain the global sessions broker, and merge cold-boot context.
# Fall back to the dev-tree exe, then to `c2c hook post-tool` (unified subcommand).
if command -v c2c-inbox-hook-ocaml >/dev/null 2>&1; then
    C2C_REPO_ROOT="$REPO_ROOT" c2c-inbox-hook-ocaml
elif [ -x "$REPO_ROOT/_build/default/ocaml/tools/c2c_inbox_hook.exe" ]; then
    C2C_REPO_ROOT="$REPO_ROOT" "$REPO_ROOT/_build/default/ocaml/tools/c2c_inbox_hook.exe"
elif command -v c2c >/dev/null 2>&1; then
    c2c hook post-tool
else
    # Neither binary found: sleep to avoid fast-exit ECHILD race, then exit.
    sleep 0.05
fi
exit 0
|}

let claude_stop_hook_script = {|
#!/bin/bash
# c2c-stop-deliver.sh — Stop hook for c2c auto-delivery in Claude Code
#
# Delivers queued c2c messages on text-only turns (no tool call).
# When messages exist, emits non-error Stop feedback so Claude continues and
# sees the messages as additional context. When no messages, exits silently.
#
# Calls c2c-stop-hook-ocaml which reads session_id from stdin JSON (same
# parser as the PostToolUse hook), drains the global sessions broker, and
# emits {"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"<messages>"}}
# if messages exist.
#
# IMPORTANT: do NOT use `exec` for hook binaries (same ECHILD reason as
# c2c-inbox-check.sh).
#
# Optional env vars (set by c2c start, the MCP server entry, or tests):
#   C2C_MCP_SESSION_ID   — broker session id
#   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir
#   C2C_SESSIONS_BROKER_ROOT — global session broker override

SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || echo "$SCRIPT_DIR")"

# Prefer the installed OCaml stop hook. Fall back to dev-tree exe, then to
# `c2c hook stop` (the unified subcommand). If none found, warn loudly and
# exit — a wired hook with no binary means delivery is silently broken.
if command -v c2c-stop-hook-ocaml >/dev/null 2>&1; then
    C2C_REPO_ROOT="$REPO_ROOT" c2c-stop-hook-ocaml
elif [ -x "$REPO_ROOT/_build/default/ocaml/tools/c2c_stop_hook.exe" ]; then
    C2C_REPO_ROOT="$REPO_ROOT" "$REPO_ROOT/_build/default/ocaml/tools/c2c_stop_hook.exe"
elif command -v c2c >/dev/null 2>&1; then
    c2c hook stop
else
    echo "[c2c] WARNING: stop hook binary not found (c2c-stop-hook-ocaml, c2c_stop_hook.exe, or c2c hook stop)." >&2
    echo "[c2c] Text-only-turn delivery is broken. Run: just install-all" >&2
    exit 0
fi
|}

(* SessionStart/SessionEnd hook (claude-session-hooks slice). One script serves
   both events: `c2c hook claude` dispatches on the payload's hook_event_name.
   SessionStart delivers onboarding/wake text + cold-boot / post-compact
   context + queued messages; SessionEnd deregisters hook auto-registrations. *)
let claude_session_hook_script = {|
#!/bin/bash
# c2c-session-hook.sh — SessionStart/SessionEnd hook for c2c in Claude Code
#
# Runs `c2c hook claude`, which reads the Claude hook payload (JSON) on stdin
# (hook_event_name selects SessionStart vs SessionEnd), resolves this
# session's c2c identity (env-first: a managed session's C2C_MCP_SESSION_ID
# wins; vanilla sessions auto-register on first fire), refreshes the /c2c
# skill, drains queued messages, and emits
# hookSpecificOutput.additionalContext. SessionEnd deregisters hook
# auto-registrations. Never fails the turn: errors exit 0, empty stdout.
#
# IMPORTANT: do NOT use `exec` for hook binaries. Claude Code's Node.js hook
# runner tracks the initially-spawned bash PID; exec-ing confuses its
# waitpid() bookkeeping and surfaces ECHILD errors (same reason as
# c2c-inbox-check.sh).

REPO_ROOT="$(git rev-parse --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null)"

if command -v c2c >/dev/null 2>&1; then
    c2c hook claude
elif [ -x "$HOME/.local/bin/c2c" ]; then
    "$HOME/.local/bin/c2c" hook claude
elif [ -n "$REPO_ROOT" ] && [ -x "$REPO_ROOT/_build/default/ocaml/cli/c2c.exe" ]; then
    "$REPO_ROOT/_build/default/ocaml/cli/c2c.exe" hook claude
else
    # No c2c binary found: sleep to avoid fast-exit ECHILD race, then exit.
    sleep 0.05
fi
exit 0
|}
