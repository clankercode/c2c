(* c2c_kimi_hook.ml — slice 2 of #142 (kimi PreToolUse permission forwarding).

   This module bundles two artifacts that ship with `c2c install`:

   1. The PreToolUse hook script ([approval_hook_script_content]) — the
      bash that kimi-cli will exec when a hook block fires. Embedded
      verbatim into the c2c binary so installation is self-contained
      (no repo path lookup, no "must run from src tree" requirement).
      `c2c install self` writes it alongside the c2c binary at
      ~/.local/bin/c2c-kimi-approval-hook.sh.

   2. The fully-commented [[hooks]] block ([toml_block_template]) —
      appended to ~/.kimi/config.toml by `c2c install kimi`. The block
      is COMMENTED by default per Cairn 2026-04-30: discoverability-
      by-comment-block over cleverness of negative-lookahead matchers.
      Operator opts in by uncommenting + picking a matcher.

   Idempotency: [append_toml_block] looks for the literal sentinel
   marker [toml_block_marker] before appending, so running
   `c2c install kimi` twice yields a single block. The marker is
   intentionally short + load-bearing — DO NOT change it without
   migrating existing installs (or accept double-blocks).

   Slice 1 of #142 landed the script + `c2c await-reply` CLI on master
   (985b05b7 + 674b6230). Slice 2 (this) makes the install side work.
   Slice 3 (separate) flips `c2c start kimi` from --afk to --yolo so
   the hook becomes the sole permission gate. Slice 4 reuses the same
   script for Claude Code parity via ~/.claude/settings.json. *)

let ( // ) = Filename.concat

let approval_hook_filename = "c2c-kimi-approval-hook.sh"

(* Block identifier for the kimi PreToolUse approval hook.

   #162: the original idempotency design used a single load-bearing
   sentinel comment ("# c2c-managed PreToolUse hook (#142)") matched
   anywhere in the file. That works fine for one block but collides
   the moment c2c wants to write a second managed block (e.g. a
   PostToolUse hook, a different event filter, a follow-up tool):
   any block carrying the same legacy header would be detected as
   "already present" and the new block would silently never land.

   The block-id-based scheme below wraps each managed block in
   `# c2c-managed:BEGIN <id>` / `# c2c-managed:END <id>` lines.
   Idempotency keys on the BEGIN marker for the specific id, so
   distinct blocks coexist without colliding. *)
let approval_hook_block_id = "preuse-approval-hook-142"

let toml_block_begin_marker ~block_id =
  Printf.sprintf "# c2c-managed:BEGIN %s" block_id

let toml_block_end_marker ~block_id =
  Printf.sprintf "# c2c-managed:END %s" block_id

(* Legacy sentinel — kept ONLY to detect blocks installed before the
   block-id envelope shipped (#162). Existing operator config.toml
   files have this exact substring; we must continue to no-op-skip
   on a re-install when only the legacy marker is present. New
   blocks are detected via [toml_block_begin_marker]. *)
let toml_block_legacy_marker = "# c2c-managed PreToolUse hook (#142)"

(* Embedded bash script. Source of truth: scripts/c2c-kimi-approval-hook.sh.
   When updating, keep both in sync — the script-on-disk version is what
   slice 1 tests exercise; this embedded copy is what `c2c install self`
   actually deploys to operator machines. *)
let approval_hook_script_content = {bash|#!/usr/bin/env bash
# c2c-kimi-approval-hook.sh — invoked by kimi-cli on a matched PreToolUse
# event.  Forwards the approval request to a configured reviewer via c2c
# DM, blocks on `c2c await-reply`, and translates the verdict back to
# kimi-cli via the standard exit-code protocol:
#
#   exit 0  -> allow (kimi proceeds)
#   exit 2  -> block (stderr is shown to the agent as the rejection reason)
#
# #511 Slice 2: fallback authorizer chain walk.
# The hook reads `authorizers` from ~/.c2c/repo.json (an ordered JSON array).
# It sequentially tries each reviewer, splitting the total TIMEOUT budget
# equally among remaining authorizers. The first to respond wins; if all
# time out the hook falls closed (exit 2).
#
# Configuration (env vars):
#   C2C_KIMI_APPROVAL_TIMEOUT  total budget in seconds (default: 120)
#   C2C_KIMI_APPROVAL_REVIEWER  **DEPRECATED** (#502) — fallback to this
#                                single alias when repo.json has no authorizers[]
#   C2C_KIMI_APPROVAL_REVIEWER_SILENCE_DEPRECATION  set to 1 to silence the
#                                deprecation warning on each invocation
set -euo pipefail

# Tools required: jq for parsing kimi's stdin payload + repo.json, c2c for messaging.
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

# --------------------------------------------------------------------------
# Resolve the authorizer chain.
# 1. Try to read authorizers[] from ~/.c2c/repo.json
# 2. Fall back to C2C_KIMI_APPROVAL_REVIEWER env var (deprecated #502)
# 3. Fall back to "coordinator1" as last resort
# --------------------------------------------------------------------------
resolve_authorizers() {
  local repo_json="${HOME}/.c2c/repo.json"
  if [ -f "$repo_json" ]; then
    local authors
    authors="$(jq -r '.authorizers // empty' "$repo_json" 2>/dev/null)"
    if [ -n "$authors" ]; then
      printf '%s\n' "$authors"
      return 0
    fi
  fi
  return 1
}

# [#524] Read supervisor_strategy from repo.json. Returns the configured
# strategy or "first-alive" as the implicit default. Errors clearly if
# an unknown strategy is configured — operators see the problem immediately
# rather than silently getting wrong routing behavior.
resolve_supervisor_strategy() {
  local repo_json="${HOME}/.c2c/repo.json"
  if [ ! -f "$repo_json" ]; then
    printf 'first-alive'
    return 0
  fi
  local strategy
  strategy="$(jq -r '.supervisor_strategy // "first-alive"' "$repo_json" 2>/dev/null)"
  case "$strategy" in
    first-alive|round-robin|broadcast)
      printf '%s' "$strategy"
      return 0
      ;;
    *)
      echo "c2c-kimi-approval-hook: ERROR: unknown supervisor_strategy '$strategy' in ~/.c2c/repo.json" >&2
      echo "  Valid strategies: first-alive, round-robin, broadcast" >&2
      echo "  round-robin and broadcast are not yet implemented (#524 S1)" >&2
      echo "  Falling back to first-alive for this request." >&2
      printf 'first-alive'
      return 0
      ;;
  esac
}

# Deprecation warning (#502)
if [ -n "${C2C_KIMI_APPROVAL_REVIEWER:-}" ] \
   && [ -z "${C2C_KIMI_APPROVAL_REVIEWER_SILENCE_DEPRECATION:-}" ]; then
  echo "c2c-kimi-approval-hook: WARN: C2C_KIMI_APPROVAL_REVIEWER is deprecated (#502)." >&2
  echo "  The single-reviewer env var will be removed next cycle; the canonical" >&2
  echo "  approval path is the authorizers[] list in .c2c/repo.json (see #511)." >&2
  echo "  Set C2C_KIMI_APPROVAL_REVIEWER_SILENCE_DEPRECATION=1 to suppress." >&2
fi

# Build the authorizers array
AUTHORIZERS=()
if resolved="$(resolve_authorizers)" && [ -n "$resolved" ]; then
  while IFS= read -r authorizer; do
    [ -n "$authorizer" ] && AUTHORIZERS+=("$authorizer")
  done <<< "$resolved"
else
  # Deprecated fallback: single reviewer env var
  if [ -n "${C2C_KIMI_APPROVAL_REVIEWER:-}" ]; then
    AUTHORIZERS+=("${C2C_KIMI_APPROVAL_REVIEWER}")
  else
    AUTHORIZERS+=("coordinator1")
  fi
fi

if [ ${#AUTHORIZERS[@]} -eq 0 ]; then
  echo "c2c-kimi-approval-hook: no authorizers available; falling closed" >&2
  exit 2
fi

# --------------------------------------------------------------------------
# Mint a token: prefer kimi's tool_call_id (stable, unique per call);
# fall back to a hash of the payload + a nanosecond-timestamp suffix.
# --------------------------------------------------------------------------
if [ -n "$tool_call_id" ]; then
  TOKEN="ka_${tool_call_id}"
else
  payload_hash="$(printf '%s' "$payload" | sha256sum | cut -c1-12)"
  TOKEN="ka_${payload_hash}_$(date +%s%N)"
fi

# --------------------------------------------------------------------------
# Build the DM body (shared across all authorizer attempts).
# --------------------------------------------------------------------------
build_body() {
  local reviewer="$1"
  cat <<EOF
[kimi-approval] PreToolUse:
  tool: $tool_name
  args: $tool_input
  token: $TOKEN
  authorizers: ${AUTHORIZERS[*]}
  timeout: ${TIMEOUT}s total budget

Approve via:
  c2c approval-reply $TOKEN allow
  c2c approval-reply $TOKEN deny because <reason>
EOF
}

# --------------------------------------------------------------------------
# Write the initial pending record with the full authorizers chain.
# The primary_authorizer will be updated after each failed attempt.
# --------------------------------------------------------------------------
authorizers_csv="$(IFS=,; echo "${AUTHORIZERS[*]}")"
"$C2C_BIN" approval-pending-write \
  --token "$TOKEN" \
  --tool-name "$tool_name" \
  --tool-input "$tool_input" \
  --authorizers "$authorizers_csv" \
  --primary-authorizer "${AUTHORIZERS[0]}" \
  --timeout "$TIMEOUT" >/dev/null 2>&1 || true

# #484: Register token with MCP pending-reply system for auth-binding.
# Gives the broker session-derived identity, supervisor-list validation,
# and TTL enforcement.  Non-fatal: text-based flow still works without it.
"$C2C_BIN" open-pending-reply "$TOKEN" \
  --kind permission \
  --supervisors "$authorizers_csv" 2>/dev/null || true

# --------------------------------------------------------------------------
# Resolve supervisor strategy from repo.json (default: first-alive).
# [#524] Routing is driven by this strategy.
# --------------------------------------------------------------------------
SUPERVISOR_STRATEGY="$(resolve_supervisor_strategy)"

# --------------------------------------------------------------------------
# Routing dispatcher: first-alive | round-robin | broadcast
# round-robin and broadcast are not yet implemented (#524 S1).
# --------------------------------------------------------------------------
case "$SUPERVISOR_STRATEGY" in

  first-alive)
    # Sequential chain walk: try each authorizer with equal budget timeout.
    # budget = TIMEOUT / remaining_count
    last_index=$((${#AUTHORIZERS[@]} - 1))
    for i in "${!AUTHORIZERS[@]}"; do
      authorizer="${AUTHORIZERS[$i]}"
      remaining=$((${#AUTHORIZERS[@]} - i))
      # Compute integer budget: divide total timeout by remaining authorizers.
      # bash doesn't do float, so we use a simple integer division.
      budget=$((TIMEOUT / remaining))
      # Ensure minimum budget of 5 seconds so we don't spin too fast.
      [ "$budget" -lt 5 ] && budget=5

      body="$(build_body "$authorizer")"

      # Update primary_authorizer to show who we're currently asking
      "$C2C_BIN" approval-pending-write \
        --token "$TOKEN" \
        --update-authorizer "$authorizer" >/dev/null 2>&1 || true

      # Send DM to this authorizer
      if ! "$C2C_BIN" send "$authorizer" "$body" >/dev/null 2>&1; then
        echo "c2c-kimi-approval-hook: failed to send DM to authorizer=$authorizer" >&2
        continue
      fi

      # Wait for verdict with this authorizer's budget
      verdict="$("$C2C_BIN" await-reply --token "$TOKEN" --timeout "$budget" 2>/dev/null || true)"

      case "$verdict" in
        allow|ALLOW)
          exit 0
          ;;
        deny|DENY)
          echo "denied by authorizer=$authorizer (token=$TOKEN)" >&2
          exit 2
          ;;
        "")
          # Timeout — try next authorizer if any remain
          if [ "$i" -lt "$last_index" ]; then
            continue
          else
            echo "no verdict from any authorizer within ${TIMEOUT}s total; falling closed (token=$TOKEN)" >&2
            exit 2
          fi
          ;;
        *)
          echo "unrecognized verdict '$verdict' from authorizer=$authorizer; falling closed (token=$TOKEN)" >&2
          exit 2
          ;;
      esac
    done
    # Should not reach here, but defensive fallthrough
    exit 2
    ;;

  round-robin|broadcast)
    echo "c2c-kimi-approval-hook: supervisor_strategy '$SUPERVISOR_STRATEGY' is not yet implemented (#524 S1)" >&2
    echo "  Falling back to first-alive for this request." >&2
    # Re-use first-alive path by re-invoking this logic inline.
    last_index=$((${#AUTHORIZERS[@]} - 1))
    for i in "${!AUTHORIZERS[@]}"; do
      authorizer="${AUTHORIZERS[$i]}"
      remaining=$((${#AUTHORIZERS[@]} - i))
      budget=$((TIMEOUT / remaining))
      [ "$budget" -lt 5 ] && budget=5
      body="$(build_body "$authorizer")"
      "$C2C_BIN" approval-pending-write \
        --token "$TOKEN" \
        --update-authorizer "$authorizer" >/dev/null 2>&1 || true
      if ! "$C2C_BIN" send "$authorizer" "$body" >/dev/null 2>&1; then
        echo "c2c-kimi-approval-hook: failed to send DM to authorizer=$authorizer" >&2
        continue
      fi
      verdict="$("$C2C_BIN" await-reply --token "$TOKEN" --timeout "$budget" 2>/dev/null || true)"
      case "$verdict" in
        allow|ALLOW) exit 0 ;;
        deny|DENY)
          echo "denied by authorizer=$authorizer (token=$TOKEN)" >&2
          exit 2
          ;;
        "")
          if [ "$i" -lt "$last_index" ]; then
            continue
          else
            echo "no verdict from any authorizer within ${TIMEOUT}s total; falling closed (token=$TOKEN)" >&2
            exit 2
          fi
          ;;
        *)
          echo "unrecognized verdict '$verdict' from authorizer=$authorizer; falling closed (token=$TOKEN)" >&2
          exit 2
          ;;
      esac
    done
    exit 2
    ;;

esac
|bash}

(* Fully-commented [[hooks]] block appended to ~/.kimi/config.toml.

   Default-no-forwarding posture: kimi-cli's HookDef.matcher is a regex
   that defaults to "" (empty), and engine.py:196-198 treats empty as
   match-all. So we cannot ship an "empty matcher" stub — that would
   forward every tool call. Instead we ship the entire block commented
   out, with examples for common patterns + an "everything" example
   for debugging.

   The {hook_path} placeholder is substituted at install time with the
   actual path the script was installed to (typically
   ~/.local/bin/c2c-kimi-approval-hook.sh). *)
let toml_block_template = {toml|
# c2c-managed PreToolUse hook (#142). Slice 2 — install side.
#
# Forwards a PreToolUse approval request from kimi to a remote reviewer
# (default: coordinator1) via c2c, blocks on `c2c await-reply`, and
# translates the verdict to kimi's exit-code protocol (0 = allow,
# 2 = block).
#
# To enable: pick ONE of the [[hooks]] blocks below and uncomment it.
# IMPORTANT: kimi-cli's TOML schema requires either a top-level
# `hooks = []` scalar OR `[[hooks]]` array-of-tables — not both. If
# this file already has `hooks = []` near the top, delete that line
# before uncommenting.
#
# Reviewer alias and timeout are tunable via env when launching kimi:
#   C2C_KIMI_APPROVAL_REVIEWER  reviewer alias (default: coordinator1)
#                                DEPRECATED (#502): superseded by
#                                supervisors[] in .c2c/repo.json (#490).
#   C2C_KIMI_APPROVAL_TIMEOUT   seconds (default: 120)
#
# Matcher syntax — kimi-cli vs Claude Code (#161)
# -----------------------------------------------
# kimi-cli's HookDef.matcher is a single regex matched against
# `"<ToolName>:<argString>"` (engine.py: name + ":" + args concatenated
# before regex search). So `^Bash$:rm\s+-rf` means "tool is exactly
# Bash AND the arg string starts with `rm -rf`" — the colon is
# literal payload, not syntax. To match a tool name with no arg
# constraint, end with `:` (e.g. `^Write$:`) or just `^Write$`
# (still matches because `:` appears in the haystack).
#
# Claude Code's PreToolUse matcher is by contrast a tool-name regex
# only: `Bash` or `^(Bash|Edit)$`. There is no `:argRegex` half.
# Operators porting hook configs between the two CLIs must rewrite
# the matcher accordingly — a Claude-style `Bash` matcher in
# ~/.kimi/config.toml will match every tool whose name+args contains
# the substring `Bash` (probably way too broad).
#
# An empty matcher (`""`) is match-all in kimi-cli (engine.py:196-198),
# which is why this template ships fully commented out — see header.
#
# Examples — uncomment ONE.
#
# A) Forward only obviously-dangerous shell commands:
# [[hooks]]
# event = "PreToolUse"
# command = "{hook_path}"
# matcher = "^Bash$:.*\\b(rm\\s+-rf|chmod\\s+-R\\s+777|dd\\s+if=)"
# timeout = 120
#
# B) Forward writes to system paths:
# [[hooks]]
# event = "PreToolUse"
# command = "{hook_path}"
# matcher = "^Write$:/(etc|var|root|usr|opt)/"
# timeout = 120
#
# C) Forward EVERY tool call (chatty; for debugging only):
# [[hooks]]
# event = "PreToolUse"
# command = "{hook_path}"
# matcher = ""
# timeout = 120
|toml}

(* Substitute {hook_path} placeholder. Returns the rendered block. *)
let render_toml_block ~hook_path =
  let pattern = "{hook_path}" in
  let buf = Buffer.create (String.length toml_block_template) in
  let len = String.length toml_block_template in
  let plen = String.length pattern in
  let i = ref 0 in
  while !i < len do
    if !i + plen <= len
       && String.sub toml_block_template !i plen = pattern
    then (
      Buffer.add_string buf hook_path;
      i := !i + plen)
    else (
      Buffer.add_char buf toml_block_template.[!i];
      incr i)
  done;
  Buffer.contents buf

(* Substring search helper — returns true iff [needle] occurs in [s]. *)
let string_contains s needle =
  let nlen = String.length needle in
  let slen = String.length s in
  if nlen = 0 then true
  else
    let rec search i =
      if i + nlen > slen then false
      else if String.sub s i nlen = needle then true
      else search (i + 1)
    in
    search 0

(* Idempotency check (#162): returns true iff [config_path] already
   contains the BEGIN marker for [block_id], OR the legacy single-
   sentinel header (for backward-compat with pre-#162 installs that
   wrote the approval-hook block without the BEGIN/END envelope).
   Missing file -> false. *)
let toml_block_already_present ?(block_id = approval_hook_block_id) ~config_path () =
  if not (Sys.file_exists config_path) then false
  else
    let ic = open_in config_path in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let s = really_input_string ic (in_channel_length ic) in
      let new_marker = toml_block_begin_marker ~block_id in
      let legacy_match =
        block_id = approval_hook_block_id
        && string_contains s toml_block_legacy_marker
      in
      string_contains s new_marker || legacy_match)

(* Wrap a rendered block body in `# c2c-managed:BEGIN <id>` /
   `# c2c-managed:END <id>` envelope lines (#162). The body is
   bracketed verbatim — we keep the legacy "c2c-managed PreToolUse
   hook (#142)" header inside the body for human readability and as
   a soft cross-link. *)
let envelope_block ~block_id body =
  Printf.sprintf "%s\n%s\n%s\n"
    (toml_block_begin_marker ~block_id)
    body
    (toml_block_end_marker ~block_id)

(* Append the rendered [[hooks]] block to [config_path]. Idempotent —
   no-op if a block with the same [block_id] is already present (or
   the legacy single-sentinel marker for the approval-hook block).

   Returns one of:
     `Already_present  — block was already there, no write
     `Appended         — block was appended successfully
     `Created          — file did not exist; created with the block

   When [dry_run], prints a summary and returns the corresponding
   verdict without touching the file. *)
let append_toml_block ?(block_id = approval_hook_block_id) ~config_path ~hook_path ~dry_run () =
  if toml_block_already_present ~block_id ~config_path () then begin
    if dry_run then
      Printf.printf "[DRY-RUN] %s already contains c2c hook block (id=%s, no-op)\n%!"
        config_path block_id;
    `Already_present
  end else begin
    let body = render_toml_block ~hook_path in
    let block = envelope_block ~block_id body in
    let existed = Sys.file_exists config_path in
    if dry_run then begin
      Printf.printf "[DRY-RUN] would %s %d bytes to %s (id=%s)\n%!"
        (if existed then "append" else "write")
        (String.length block) config_path block_id;
      if existed then `Appended else `Created
    end else begin
      let dir = Filename.dirname config_path in
      (try C2c_mcp.mkdir_p dir with _ -> ());
      let flags = [Open_append; Open_creat; Open_wronly] in
      let oc = open_out_gen flags 0o644 config_path in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
        output_string oc block);
      if existed then `Appended else `Created
    end
  end

(* Install the embedded approval hook script to [dest_dir] with mode
   0755. Returns the absolute install path (or what it would be in
   dry-run mode). *)
let install_approval_hook_script ~dest_dir ~dry_run =
  let dest_path = dest_dir // approval_hook_filename in
  if dry_run then begin
    Printf.printf "[DRY-RUN] would write %d bytes to %s (mode 0755)\n%!"
      (String.length approval_hook_script_content) dest_path;
    dest_path
  end else begin
    (try C2c_mcp.mkdir_p dest_dir with _ -> ());
    let tmp = dest_path ^ ".tmp" in
    let oc = open_out_bin tmp in
    Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc approval_hook_script_content);
    Unix.chmod tmp 0o755;
    Unix.rename tmp dest_path;
    dest_path
  end
