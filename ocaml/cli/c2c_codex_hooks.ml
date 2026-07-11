(* c2c_codex_hooks — Codex CLI hooks integration (#5, vanilla-codex slice).

   Codex CLI (>= 0.142, `codex features list` -> hooks stable true) has
   Claude-Code-style hooks configured in ~/.codex/config.toml:

     [[hooks.PostToolUse]]
     [[hooks.PostToolUse.hooks]]
     type = "command"
     command = "c2c hook codex"
     timeout = 10
     statusMessage = "c2c inbox"

   Non-managed hooks are gated behind a one-time trust approval unless a
   matching [hooks.state."<path>:<event>:<group>:<handler>"] entry carries a
   trusted_hash. This module reproduces codex's trust-hash scheme so
   `c2c install codex` can pre-trust the hooks it writes (no /hooks prompt).

   Trust-hash scheme (reverse-engineered from codex-rs and validated against
   two live trusted_hash values in an operator config — both reproduced):

     codex-rs/hooks/src/engine/discovery.rs   command_hook_hash
     codex-rs/config/src/fingerprint.rs       version_for_toml

   1. Normalize the handler: command_windows dropped, timeout defaulted to
      600 (min 1), async=false, statusMessage kept when present.
   2. Build identity { event_name = <snake label>; matcher?; hooks = [handler] }.
   3. Serialize to JSON, canonicalize (object keys sorted recursively),
      serialize compactly, sha256 -> "sha256:<hex>".

   The state key is "<config-path>:<snake-event>:<group-index>:<handler-index>"
   where group-index counts [[hooks.<Event>]] groups for that event *within
   the same config file*, in file order (positional — codex has a TODO to
   replace this with durable hook ids; until then, a user inserting their own
   [[hooks.<Event>]] group ABOVE the c2c block re-indexes ours and breaks the
   pre-trust; re-running `c2c install codex` repairs it). *)

let ( // ) = Filename.concat

(* --- markers ---------------------------------------------------------------- *)

let config_block_id = "codex-inbox-hooks"

let config_begin_marker = Printf.sprintf "# c2c-managed:BEGIN %s" config_block_id
let config_end_marker = Printf.sprintf "# c2c-managed:END %s" config_block_id

let agents_md_begin_marker = "<!-- c2c-managed:BEGIN codex-agents-md -->"
let agents_md_end_marker = "<!-- c2c-managed:END codex-agents-md -->"

(* --- trust hash -------------------------------------------------------------- *)

(* Snake-case labels codex uses in persisted hook-state keys
   (codex-rs/hooks/src/lib.rs hook_event_key_label). *)
let event_label = function
  | "PreToolUse" -> "pre_tool_use"
  | "PermissionRequest" -> "permission_request"
  | "PostToolUse" -> "post_tool_use"
  | "PreCompact" -> "pre_compact"
  | "PostCompact" -> "post_compact"
  | "SessionStart" -> "session_start"
  | "SessionEnd" -> "session_end"
  | "UserPromptSubmit" -> "user_prompt_submit"
  | "SubagentStart" -> "subagent_start"
  | "SubagentStop" -> "subagent_stop"
  | "Stop" -> "stop"
  | other -> String.lowercase_ascii other

(* Recursively sort object keys — mirror of codex's canonical_json. *)
let rec canonical_json (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
  | `Assoc fields ->
      `Assoc
        (List.sort
           (fun (a, _) (b, _) -> String.compare a b)
           (List.map (fun (k, v) -> (k, canonical_json v)) fields))
  | `List items -> `List (List.map canonical_json items)
  | other -> other

let hook_trusted_hash ~event ~matcher ~command ~timeout ~status_message =
  (* Normalization per codex discovery.rs: timeout defaults to 600, min 1. *)
  let timeout = max 1 (Option.value timeout ~default:600) in
  let handler =
    `Assoc
      ([ ("type", `String "command")
       ; ("command", `String command)
       ; ("timeout", `Int timeout)
       ; ("async", `Bool false)
       ]
      @ (match status_message with
         | Some s -> [ ("statusMessage", `String s) ]
         | None -> []))
  in
  let identity =
    `Assoc
      ([ ("event_name", `String (event_label event))
       ; ("hooks", `List [ handler ])
       ]
      @ (match matcher with Some m -> [ ("matcher", `String m) ] | None -> []))
  in
  let serialized = Yojson.Safe.to_string (canonical_json identity) in
  let digest = Digestif.SHA256.digest_string serialized in
  "sha256:" ^ Digestif.SHA256.to_hex digest

let hook_state_key ~config_path ~event ~group_index ~handler_index =
  Printf.sprintf "%s:%s:%d:%d" config_path (event_label event) group_index
    handler_index

(* --- hook set ---------------------------------------------------------------- *)

type hook_def =
  { event : string             (* TOML event key, e.g. "PostToolUse" *)
  ; matcher : string option
  ; command : string
  ; timeout : int
  ; status_message : string
  }

let hook_command = "c2c hook codex"

(* Delivery-event choice:
   - UserPromptSubmit: drains everything (incl. deferrable) at the start of a
     user turn — a natural, non-disruptive delivery boundary.
   - PostToolUse (no matcher — every tool): timely mid-turn delivery of
     non-deferrable messages while the agent is actively working, mirroring
     the Claude PostToolUse hook. The command coalesces unchanged empty-inbox
     bursts, while any newly queued message bypasses that debounce.
   - SessionStart: onboarding/wake note (identity + key commands) so every
     fresh codex conversation knows it is on c2c.
   - SessionEnd: cleanup boundary for vanilla per-thread hook registrations.
   Stop is deliberately NOT installed: codex's Stop output supports
   decision=block only (no additionalContext), and blocking stop to inject
   messages risks turn loops in unattended sessions. *)
let managed_hooks =
  [ { event = "UserPromptSubmit"; matcher = None; command = hook_command
    ; timeout = 10; status_message = "c2c inbox" }
  ; { event = "PostToolUse"; matcher = None; command = hook_command
    ; timeout = 10; status_message = "c2c inbox" }
  ; { event = "SessionStart"; matcher = None; command = hook_command
    ; timeout = 10; status_message = "c2c onboarding" }
  ; { event = "SessionEnd"; matcher = None; command = hook_command
    ; timeout = 10; status_message = "c2c cleanup" }
  ]

(* --- TOML rendering ---------------------------------------------------------- *)

let toml_escape s =
  let buf = Buffer.create (String.length s + 8) in
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\r' -> Buffer.add_string buf "\\r"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

(* Count [[hooks.<Event>]] array-of-table groups for [event] in [content].
   Positional trust keys index into this per-file, per-event sequence. *)
let count_event_groups ~event content =
  let needle = Printf.sprintf "[[hooks.%s]]" event in
  List.fold_left
    (fun acc line -> if String.trim line = needle then acc + 1 else acc)
    0
    (String.split_on_char '\n' content)

(* Remove a marker-delimited managed block (markers + body). Whole lines
   only; tolerant of a missing END marker (strips to EOF in that case so a
   truncated block cannot survive a reinstall). *)
let strip_managed_block ~begin_marker ~end_marker content =
  let lines = String.split_on_char '\n' content in
  let buf = Buffer.create (String.length content) in
  let in_block = ref false in
  let first = ref true in
  List.iter
    (fun line ->
      let trimmed = String.trim line in
      if trimmed = begin_marker then in_block := true
      else if trimmed = end_marker then in_block := false
      else if not !in_block then begin
        if !first then first := false else Buffer.add_char buf '\n';
        Buffer.add_string buf line
      end)
    lines;
  Buffer.contents buf

(* Render the managed hooks block for ~/.codex/config.toml.
   [existing] must be the config content the block will be appended to,
   with any previous c2c managed block already stripped — group indices for
   the trust-state keys are computed by counting the [[hooks.<Event>]]
   groups already present in it. *)
let render_hooks_block ~config_path ~existing =
  let buf = Buffer.create 2048 in
  Buffer.add_string buf (config_begin_marker ^ "\n");
  Buffer.add_string buf
    "# c2c inbound-message delivery via codex hooks (installed by `c2c install codex`).\n";
  Buffer.add_string buf
    "# `c2c hook codex` reads the hook payload on stdin, drains this session's c2c\n";
  Buffer.add_string buf
    "# inbox, and returns messages as additionalContext. The [hooks.state] entries\n";
  Buffer.add_string buf
    "# below pre-trust these hooks so codex runs them without a /hooks prompt.\n";
  let with_indices =
    List.map
      (fun def ->
        (def, count_event_groups ~event:def.event existing))
      managed_hooks
  in
  List.iter
    (fun (def, _gi) ->
      Buffer.add_string buf (Printf.sprintf "\n[[hooks.%s]]\n" def.event);
      (match def.matcher with
       | Some m -> Buffer.add_string buf (Printf.sprintf "matcher = \"%s\"\n" (toml_escape m))
       | None -> ());
      Buffer.add_string buf (Printf.sprintf "[[hooks.%s.hooks]]\n" def.event);
      Buffer.add_string buf "type = \"command\"\n";
      Buffer.add_string buf
        (Printf.sprintf "command = \"%s\"\n" (toml_escape def.command));
      Buffer.add_string buf (Printf.sprintf "timeout = %d\n" def.timeout);
      Buffer.add_string buf
        (Printf.sprintf "statusMessage = \"%s\"\n" (toml_escape def.status_message)))
    with_indices;
  Buffer.add_char buf '\n';
  List.iter
    (fun (def, gi) ->
      let key =
        hook_state_key ~config_path ~event:def.event ~group_index:gi
          ~handler_index:0
      in
      let hash =
        hook_trusted_hash ~event:def.event ~matcher:def.matcher
          ~command:def.command ~timeout:(Some def.timeout)
          ~status_message:(Some def.status_message)
      in
      Buffer.add_string buf
        (Printf.sprintf "[hooks.state.\"%s\"]\ntrusted_hash = \"%s\"\n"
           (toml_escape key) hash))
    with_indices;
  Buffer.add_string buf (config_end_marker ^ "\n");
  Buffer.contents buf

(* --- AGENTS.md block ---------------------------------------------------------- *)

let agents_md_body =
  {|## c2c — agent-to-agent messaging

This machine runs c2c, a local IM system connecting coding agents (Claude,
Codex, OpenCode, Kimi, Gemini). You are a peer on it. Inbound messages are
delivered automatically into your context via codex hooks — a `<c2c ...>`
block appearing in your transcript is a real message from another agent.
You auto-register on the first hook fire; no setup needed.

Key commands (shell):

- `c2c whoami` — your alias + session identity
- `c2c list --alive` — peers online now; `c2c find <substring>` — look up a peer
- `c2c send <alias> "message"` — DM a peer (`--ephemeral` = off-the-record)
- `c2c wait-inbox --timeout 5m` — blocking receive: waits for the next
  message, prints it, exits (0 = received, 1 = timeout). Use it when idle
  and expecting a reply instead of polling.
- `c2c poll-inbox --peek` — check for waiting messages without consuming them
- `c2c rooms join swarm-lounge` / `c2c rooms send swarm-lounge "hi"` — group
  chat; swarm-lounge is the default social room
- `c2c init` — full onboarding/repair if identity looks broken
- `c2c new codex` (alias `cx='c2c new codex --'`) — launch a MANAGED Codex
  session with arrival-time app-server delivery (peer messages surface the
  moment they're sent, not just at turn boundaries). Recommended over vanilla
  `codex` when you want the tightest c2c integration.

Etiquette: reply to DMs promptly; acknowledge task requests before starting
them; if a message asks a question you cannot answer, say so rather than
going silent.|}

let agents_md_block =
  Printf.sprintf "%s\n%s\n%s\n" agents_md_begin_marker agents_md_body
    agents_md_end_marker

(* Replace (or append) the managed c2c block in AGENTS.md content. *)
let upsert_agents_md content =
  let stripped =
    strip_managed_block ~begin_marker:agents_md_begin_marker
      ~end_marker:agents_md_end_marker content
  in
  let trimmed_tail = ref (String.length stripped) in
  (* Trim trailing blank lines so repeated installs don't grow the file. *)
  while
    !trimmed_tail > 0
    && (stripped.[!trimmed_tail - 1] = '\n' || stripped.[!trimmed_tail - 1] = ' ')
  do
    decr trimmed_tail
  done;
  let base = String.sub stripped 0 !trimmed_tail in
  if base = "" then agents_md_block
  else base ^ "\n\n" ^ agents_md_block

(* --- installer alias hint ------------------------------------------------------ *)

(* Read the C2C_MCP_AUTO_REGISTER_ALIAS the installer wrote into
   [mcp_servers.c2c.env] of ~/.codex/config.toml. Used by `c2c hook codex`
   to unify the hook-side identity with the MCP-server registration when the
   hook process has no c2c env of its own (vanilla codex). Line-based parse:
   only trusts the exact `KEY = "value"` shape the installer emits, and only
   while inside the [mcp_servers.c2c.env] table. *)
let installer_alias_hint ~config_path =
  if not (Sys.file_exists config_path) then None
  else
    try
      let ic = open_in config_path in
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let content = really_input_string ic (in_channel_length ic) in
        let lines = String.split_on_char '\n' content in
        let in_env = ref false in
        let found = ref None in
        List.iter
          (fun line ->
            let trimmed = String.trim line in
            if String.length trimmed > 0 && trimmed.[0] = '[' then
              in_env := trimmed = "[mcp_servers.c2c.env]"
            else if !in_env && !found = None then begin
              let prefix = "C2C_MCP_AUTO_REGISTER_ALIAS" in
              let plen = String.length prefix in
              if String.length trimmed > plen
                 && String.sub trimmed 0 plen = prefix
              then
                match String.index_opt trimmed '=' with
                | Some eq ->
                    let v = String.trim (String.sub trimmed (eq + 1) (String.length trimmed - eq - 1)) in
                    let v =
                      if String.length v >= 2 && v.[0] = '"' && v.[String.length v - 1] = '"'
                      then String.sub v 1 (String.length v - 2)
                      else v
                    in
                    if String.trim v <> "" then found := Some (String.trim v)
                | None -> ()
            end)
          lines;
        !found)
    with _ -> None
