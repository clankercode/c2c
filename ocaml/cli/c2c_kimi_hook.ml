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

(* Sentinel comment used to detect already-installed blocks.
   Idempotency relies on this exact substring being present. *)
let toml_block_marker = "# c2c-managed PreToolUse hook (#142)"

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
# Configuration:
#   C2C_KIMI_APPROVAL_REVIEWER  reviewer alias (default: coordinator1)
#   C2C_KIMI_APPROVAL_TIMEOUT   seconds to wait for verdict (default: 120)
#
# Slice 1 of #142.  Slice 2 wires the [[hooks]] block in ~/.kimi/config.toml
# via `c2c install kimi`.  The matcher / event filter is configured there;
# this script unconditionally forwards whatever it receives.
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
#   C2C_KIMI_APPROVAL_TIMEOUT   seconds (default: 120)
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

(* Idempotency check: returns true iff the file at [path] already
   contains the [toml_block_marker] sentinel. Missing file -> false. *)
let toml_block_already_present ~config_path =
  if not (Sys.file_exists config_path) then false
  else
    let ic = open_in config_path in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let s = really_input_string ic (in_channel_length ic) in
      let needle = toml_block_marker in
      let nlen = String.length needle in
      let slen = String.length s in
      let rec search i =
        if i + nlen > slen then false
        else if String.sub s i nlen = needle then true
        else search (i + 1)
      in
      search 0)

(* Append the rendered [[hooks]] block to [config_path]. Idempotent —
   no-op if [toml_block_marker] already present.

   Returns one of:
     `Already_present  — block was already there, no write
     `Appended         — block was appended successfully
     `Created          — file did not exist; created with the block

   When [dry_run], prints a summary and returns the corresponding
   verdict without touching the file. *)
let append_toml_block ~config_path ~hook_path ~dry_run =
  if toml_block_already_present ~config_path then begin
    if dry_run then
      Printf.printf "[DRY-RUN] %s already contains c2c hook block (no-op)\n%!" config_path;
    `Already_present
  end else begin
    let block = render_toml_block ~hook_path in
    let existed = Sys.file_exists config_path in
    if dry_run then begin
      Printf.printf "[DRY-RUN] would %s %d bytes to %s\n%!"
        (if existed then "append" else "write")
        (String.length block) config_path;
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
