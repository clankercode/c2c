(* c2c_hook_lib — shared stdin-parsing + inbox-drain logic for Claude hooks
 *
 * Used by both c2c_inbox_hook (PostToolUse) and c2c_stop_hook (Stop).
 * Factored to avoid duplication and ensure consistent session_id parsing.
 *)

let env_nonempty name =
  match Sys.getenv_opt name with
  | Some s when String.trim s <> "" -> Some (String.trim s)
  | _ -> None

(* Nudge state for PostToolUse hook debounce logic.
   Persisted to a per-session JSON file in the broker root.
   Format: { "last_nudge_ts": float, "first_waiting_ts": float }
   Both timestamps are Unix epoch seconds. *)
type nudge_state =
  { last_nudge_ts : float
  ; first_waiting_ts : float
  }

let default_nudge_state =
  { last_nudge_ts = 0.0
  ; first_waiting_ts = 0.0
  }

(* Get the path to the nudge state file for a session.
   Location: <broker_root>/<session_id>.nudge.state.json
   Falls back to a temp dir if broker_root is empty. *)
let nudge_state_path ~broker_root ~session_id =
  let root =
    if broker_root <> "" then broker_root
    else
      (* Check C2C_SESSIONS_BROKER_ROOT first (for testing) *)
      match env_nonempty "C2C_SESSIONS_BROKER_ROOT" with
      | Some root -> root
      | None ->
          (* Fallback to home directory *)
          let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
          Filename.concat home ".local/share/c2c"
  in
  Filename.concat root (session_id ^ ".nudge.state.json")

(* Read nudge state from file. Returns default state if file doesn't exist or is invalid. *)
let read_nudge_state ~broker_root ~session_id =
  let path = nudge_state_path ~broker_root ~session_id in
  try
    let ic = open_in path in
    let content = In_channel.input_all ic in
    close_in ic;
    match Yojson.Safe.from_string (String.trim content) with
    | `Assoc fields ->
        let last_nudge_ts =
          match List.assoc_opt "last_nudge_ts" fields with
          | Some (`Float f) -> f
          | Some (`Int n) -> float_of_int n
          | _ -> 0.0
        in
        let first_waiting_ts =
          match List.assoc_opt "first_waiting_ts" fields with
          | Some (`Float f) -> f
          | Some (`Int n) -> float_of_int n
          | _ -> 0.0
        in
        { last_nudge_ts; first_waiting_ts }
    | _ -> default_nudge_state
  with _ -> default_nudge_state

(* Write nudge state to file atomically (temp + rename).
   Non-fatal on any error. *)
let write_nudge_state ~broker_root ~session_id state =
  let path = nudge_state_path ~broker_root ~session_id in
  try
    (* Ensure the directory exists *)
    let dir = Filename.dirname path in
    C2c_mcp.mkdir_p ~mode:0o700 dir;
    let json : Yojson.Safe.t =
      `Assoc
        [ ("last_nudge_ts", `Float state.last_nudge_ts)
        ; ("first_waiting_ts", `Float state.first_waiting_ts)
        ]
    in
    let payload = Yojson.Safe.to_string json in
    let tmp = path ^ ".tmp" in
    let oc = open_out tmp in
    output_string oc payload;
    output_char oc '\n';
    close_out oc;
    Unix.rename tmp path
  with _ -> ()

let max_stdin_scan_bytes = 64 * 1024

let extract_json_string_field_prefix ~field raw =
  let len = String.length raw in
  let skip_ws i =
    let rec loop j =
      if j >= len then j
      else
        match raw.[j] with
        | ' ' | '\n' | '\r' | '\t' -> loop (j + 1)
        | _ -> j
    in
    loop i
  in
  let parse_string i =
    if i >= len || raw.[i] <> '"' then None
    else
      let b = Buffer.create 32 in
      let rec loop j =
        if j >= len then None
        else
          match raw.[j] with
          | '"' -> Some (Buffer.contents b, j + 1)
          | '\\' when j + 1 < len ->
              let c =
                match raw.[j + 1] with
                | '"' -> '"'
                | '\\' -> '\\'
                | '/' -> '/'
                | 'b' -> '\b'
                | 'f' -> '\012'
                | 'n' -> '\n'
                | 'r' -> '\r'
                | 't' -> '\t'
                | c -> c
              in
              Buffer.add_char b c;
              loop (j + 2)
          | '\\' -> None
          | c ->
              Buffer.add_char b c;
              loop (j + 1)
      in
      loop (i + 1)
  in
  let rec scan i depth =
    if i >= len then None
    else
      match raw.[i] with
      | '"' ->
          (match parse_string i with
           | None -> None
           | Some (key, next_i) ->
               if depth = 1 && key = field then
                 let colon_i = skip_ws next_i in
                 if colon_i < len && raw.[colon_i] = ':' then
                   let value_i = skip_ws (colon_i + 1) in
                   match parse_string value_i with
                   | Some (value, _) when String.trim value <> "" ->
                       Some (String.trim value)
                   | _ -> None
                 else scan next_i depth
               else scan next_i depth)
      | '{' | '[' -> scan (i + 1) (depth + 1)
      | '}' | ']' -> scan (i + 1) (max 0 (depth - 1))
      | _ -> scan (i + 1) depth
  in
  scan 0 0

let read_stdin_session_id () =
  let chunk_size = 4096 in
  let chunk = Bytes.create chunk_size in
  let buf = Buffer.create 4096 in
  let rec loop remaining =
    if remaining <= 0 then None
    else
      let want = min chunk_size remaining in
      match input stdin chunk 0 want with
      | 0 ->
          extract_json_string_field_prefix ~field:"session_id"
            (Buffer.contents buf)
      | n ->
          Buffer.add_subbytes buf chunk 0 n;
          let raw = Buffer.contents buf in
          (match extract_json_string_field_prefix ~field:"session_id" raw with
           | Some _ as found -> found
           | None -> loop (remaining - n))
  in
  try loop max_stdin_scan_bytes with _ -> None

(* B042 / B130: detect subagent/silent context. Hooks that run inside a
   dispatched subagent must never auto-register OR drain/inject the owner
   session's inbox — a subagent inherits the parent's env (incl.
   C2C_MCP_SESSION_ID / CLAUDE_SESSION_ID) and fires the same c2c hooks, so
   without this guard the parent's queued DMs leak into an unrelated
   subagent's transcript (B130).

   Two signals mark a subagent:
   - C2C_NO_AUTO_REGISTER=1 (B042): explicit opt-out an operator/wrapper sets.
   - CLAUDE_CODE_CHILD_SESSION (B130): Claude Code stamps every dispatched
     Task-tool subagent process with this env var (value "1"). This is the
     robust, harness-provided signal — nothing in c2c sets C2C_NO_AUTO_REGISTER
     for Task-tool children, so B042 alone never fired for them.

   Hooks should exit early (silent, no drain) when this returns true.

   Delegates to the canonical detector in C2c_mcp_helpers_post_broker so the
   parse rules (and the set of subagent signals) stay identical across every
   entrypoint — the hooks here, the MCP auto-register path, and the standalone
   cold-boot / post-compact hook binaries. *)
let is_subagent_quiet () = C2c_mcp_helpers_post_broker.is_subagent_context ()
let global_inbox_exists ~root ~session_id =
  Sys.file_exists (Filename.concat root (session_id ^ ".inbox.json"))

(* Repo broker for hook delivery: explicit env wins; otherwise resolve the
   canonical repo-fingerprint broker from cwd. Returns "" when resolution
   fails (not in a git repo, etc.) — callers treat "" as no-repo-broker.

   Why this exists: vanilla (non-managed) Claude/Codex hook processes have
   no C2C_MCP_BROKER_ROOT in their env, so the old `env-or-""` derivation
   never drained the per-repo broker — peer DMs sent via `c2c send <alias>`
   sat undrained while the hook reported "no messages". Resolving the
   canonical `$HOME/.c2c/repos/<fp>/broker` (fp from remote.origin.url of
   the cwd's git repo, same order as `C2c_repo_fp.resolve_broker_root`)
   closes that gap so hooks deliver repo-broker DMs with zero env config.

   IMPORTANT: only return the resolved root when its broker already exists
   on disk (registry.json present). Hooks must NOT create broker directories
   as a side effect for repos that never initialized c2c; returning ""
   preserves the old no-op behavior for non-c2c repos. The env-override
   branch is intentionally NOT existence-gated — the broker dir is created
   lazily on first use for that path (managed sessions), matching the
   pre-existing `env-or-""` contract. *)
let resolve_hook_broker_root () =
  match env_nonempty "C2C_MCP_BROKER_ROOT" with
  | Some root -> root
  | None ->
      (match (try Some (C2c_repo_fp.resolve_broker_root ()) with _ -> None) with
       | Some root
         when root <> ""
              && Sys.file_exists (Filename.concat root "registry.json") ->
           root
       | _ -> "")

(* [push_only:true] (mid-turn: PostToolUse) drains only non-deferrable
   messages — deferrable ones stay queued for a turn boundary. Turn-boundary
   hooks (Stop, SessionStart) pass [push_only:false] for the full drain. *)
let drain_repo_messages ?(push_only = true) ~broker_root ~session_id () =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  if C2c_mcp.Broker.is_session_channel_capable broker ~session_id then begin
    prerr_endline
      (Printf.sprintf
         "[hook] skipping drain — session %s is channel-capable; \
          watcher owns delivery"
         session_id);
    (broker, [])
  end else
    ( broker
    , (if push_only then C2c_mcp.Broker.drain_inbox_push
       else C2c_mcp.Broker.drain_inbox)
        ~drained_by:"hook" broker ~session_id
    )

let drain_global_messages ?(push_only = true) ~session_id () =
  let root = C2c_repo_fp.resolve_sessions_broker_root () in
  if global_inbox_exists ~root ~session_id then
    let broker = C2c_mcp.Broker.create ~root in
    (if push_only then C2c_mcp.Broker.drain_inbox_push
     else C2c_mcp.Broker.drain_inbox)
      ~drained_by:"hook" broker ~session_id
  else []

(* Check if there are messages waiting in the inbox without draining.
   Returns the count of messages waiting. *)
let count_waiting_messages ~broker_root ~session_id =
  let count_repo () =
    match broker_root with
    | "" -> 0
    | root ->
        let broker = C2c_mcp.Broker.create ~root in
        let messages = C2c_mcp.Broker.read_inbox broker ~session_id in
        List.length messages
  in
  let count_global () =
    let root = C2c_repo_fp.resolve_sessions_broker_root () in
    if global_inbox_exists ~root ~session_id then
      let broker = C2c_mcp.Broker.create ~root in
      let messages = C2c_mcp.Broker.read_inbox broker ~session_id in
      List.length messages
    else 0
  in
  count_repo () + count_global ()

(* Format a nudge line for the agent. Short and non-disruptive. *)
let format_nudge_line ~count =
  Printf.sprintf "c2c: %d message(s) waiting (drain via c2c poll-inbox or wait for turn end)" count

(* Resolve session_id from stdin JSON payload, falling back to env var.
   Returns:
     Ok ""        — no session_id found (caller should exit silently)
     Ok sid       — validated session_id
     Error msg    — session_id present but invalid (caller decides exit code) *)
let resolve_session_id () =
  let raw_session_id =
    match read_stdin_session_id () with
    | Some sid -> sid
    | None -> Option.value (env_nonempty "C2C_MCP_SESSION_ID") ~default:""
  in
  if raw_session_id = "" then Ok ""
  else
    match C2c_mcp.validate_session_id raw_session_id with
    | Ok sid -> Ok sid
    | Error msg -> Error msg

(* Drain all messages (repo + global) for the given session_id.
   [push_only] defaults to true (mid-turn semantics); turn-boundary callers
   (Stop hook) pass [push_only:false] to also deliver deferrable messages.
   Returns (repo_broker_opt, messages, alias). *)
let drain_all_messages ?(push_only = true) ~session_id ~broker_root () =
  let repo_broker, repo_messages =
    match broker_root with
    | "" -> (None, [])
    | root ->
        let broker, messages =
          drain_repo_messages ~push_only ~broker_root:root ~session_id ()
        in
        (Some broker, messages)
  in
  let global_messages = drain_global_messages ~push_only ~session_id () in
  let messages = repo_messages @ global_messages in
  let alias =
    match repo_broker with
    | None -> ""
    | Some broker ->
        (match C2c_mcp.Broker.list_registrations broker
               |> List.find_opt (fun r -> r.C2c_mcp.session_id = session_id) with
         | Some reg -> reg.C2c_mcp.alias
         | None -> "")
  in
  (repo_broker, messages, alias)

(* Look up sender role from repo broker registration. *)
let lookup_role repo_broker from_alias =
  match repo_broker with
  | None -> None
  | Some broker ->
      (match C2c_mcp.Broker.list_registrations broker
             |> List.find_opt (fun r -> r.C2c_mcp.alias = from_alias) with
       | Some reg -> reg.C2c_mcp.role
       | None     -> None)

(* Truthy env parse shared by the delivery-mode flags below. *)
let truthy_env name =
  match env_nonempty name with
  | Some v ->
      let v = String.trim (String.lowercase_ascii v) in
      v = "1" || v = "true" || v = "yes" || v = "on"
  | None -> false

(* PostToolUse delivery-mode resolution (claude-full-delivery slice).
   FULL message injection is the DEFAULT: mid-turn delivery for claude must
   deliver the full message, matching the codex PostToolUse hook.
   `C2C_POST_TOOL_NUDGE_ONLY=1` opts back into the legacy debounced nudge
   line. `C2C_POST_TOOL_FULL_INJECT=1` (the old opt-in) is still honored for
   backward compat and outranks NUDGE_ONLY — it is now redundant-but-harmless. *)
let post_tool_nudge_only () =
  (not (truthy_env "C2C_POST_TOOL_FULL_INJECT"))
  && truthy_env "C2C_POST_TOOL_NUDGE_ONLY"

(* Format messages as c2c envelope text. Returns empty string if no messages. *)
let format_messages_as_text ~repo_broker messages =
  match messages with
  | [] -> ""
  | _ ->
      let buf = Buffer.create 256 in
      List.iter
        (fun (m : C2c_mcp.message) ->
          let tag = C2c_mcp.extract_tag_from_content m.content in
          let role = lookup_role repo_broker m.from_alias in
          let envelope =
            C2c_mcp.format_c2c_envelope
              ~from_alias:m.from_alias
              ~to_alias:m.to_alias
              ?tag
              ?role
              ?reply_via:m.reply_via
              ~ts:m.ts
              ~with_reply_hint:true
              ~content:m.content
              ()
          in
          Buffer.add_string buf envelope;
          Buffer.add_char buf '\n')
        messages;
      Buffer.contents buf

(* ---------- PostToolUse shared runner (claude-full-delivery slice) ----------

   The standalone c2c-inbox-hook-ocaml binary and the `c2c hook post-tool`
   CLI fallback previously diverged (nudge-vs-full default, full-vs-push
   drain, repo-only vs repo+global, no subagent guard on the CLI path).
   Both now run through [run_post_tool] so their semantics are identical:

   - FULL delivery is the default: push-only drain (repo + global brokers —
     deferrable messages stay queued for the next turn boundary, mirroring
     the codex PostToolUse hook), channel-capable repo skip (the MCP
     watcher owns delivery for managed claude — no dual-drain), plus
     fallback cold-boot context (marker-deduped against the SessionStart
     hook via <broker_root>/.cold_boot_done/<sid>, so no double injection).
     NO debounce: the drain empties the inbox, so repeated fires are cheap
     no-ops — debouncing would only add delivery latency.
   - `C2C_POST_TOOL_NUDGE_ONLY=1` restores the legacy debounced nudge line
     (non-draining awareness ping, 60s debounce kept: without a drain the
     same waiting messages would otherwise nudge on every tool call). *)

type post_tool_output =
  | Post_tool_silent
  | Post_tool_context of string  (* full-delivery additionalContext payload *)
  | Post_tool_nudge of string    (* legacy debounced nudge line *)

(* Full-delivery core. Returns the output plus the resolved alias (used by
   the standalone binary's statefile writer). *)
let run_post_tool_full ~session_id ~broker_root =
  let repo_broker, messages, alias =
    drain_all_messages ~session_id ~broker_root ()
  in
  let messages_text = format_messages_as_text ~repo_broker messages in
  (* Cold-boot context (once per session). SessionStart normally handles
     cold-boot now; this fallback covers sessions without the SessionStart
     hook and is a no-op once the shared marker exists. *)
  let extra_contexts =
    match broker_root with
    | "" -> []
    | root ->
        (match C2c_cold_boot_context.context_for_session
                 ~broker_root:root ~session_id
         with
         | Some context -> [ context ]
         | None -> [])
  in
  let output =
    match messages_text, extra_contexts with
    | "", [] -> Post_tool_silent
    | _ ->
        let buf = Buffer.create 256 in
        if messages_text <> "" then Buffer.add_string buf messages_text;
        List.iter
          (fun context ->
            Buffer.add_string buf context;
            if context = "" || context.[String.length context - 1] <> '\n' then
              Buffer.add_char buf '\n')
          extra_contexts;
        Post_tool_context (Buffer.contents buf)
  in
  (output, alias)

(* Legacy nudge core (opt-out path). Non-draining; debounce rule:
   emit only when messages_waiting >= 1 AND (now - last_nudge_ts) >= 60s
   AND (now - first_waiting_ts) >= 60s; reset both on empty inbox. *)
let run_post_tool_nudge ~session_id ~broker_root =
  let now_ts = Unix.gettimeofday () in
  let nudge_state = read_nudge_state ~broker_root ~session_id in
  let waiting_count = count_waiting_messages ~broker_root ~session_id in
  if waiting_count = 0 then begin
    write_nudge_state ~broker_root ~session_id default_nudge_state;
    Post_tool_silent
  end else begin
    let time_since_last_nudge = now_ts -. nudge_state.last_nudge_ts in
    let time_since_first_waiting = now_ts -. nudge_state.first_waiting_ts in
    let should_nudge =
      waiting_count >= 1
      && time_since_last_nudge >= 60.0
      && time_since_first_waiting >= 60.0
    in
    if should_nudge then begin
      write_nudge_state ~broker_root ~session_id
        { last_nudge_ts = now_ts; first_waiting_ts = now_ts };
      Post_tool_nudge (format_nudge_line ~count:waiting_count)
    end else begin
      let new_state =
        if nudge_state.first_waiting_ts = 0.0 then
          { nudge_state with first_waiting_ts = now_ts }
        else nudge_state
      in
      write_nudge_state ~broker_root ~session_id new_state;
      Post_tool_silent
    end
  end

(* Mode dispatch. Returns (output, alias); alias is "" on the nudge path
   (it never touches the registry). *)
let run_post_tool ~session_id ~broker_root =
  if post_tool_nudge_only () then
    (run_post_tool_nudge ~session_id ~broker_root, "")
  else run_post_tool_full ~session_id ~broker_root

(* Emit the hookSpecificOutput JSON for a PostToolUse result. Silent -> no
   output. Shared so the standalone binary and the CLI fallback are
   byte-identical on stdout. *)
let print_post_tool_output output =
  let emit text =
    let json : Yojson.Safe.t =
      `Assoc
        [ ( "hookSpecificOutput"
          , `Assoc
              [ ("hookEventName", `String "PostToolUse")
              ; ("additionalContext", `String text)
              ] )
        ]
    in
    print_string (Yojson.Safe.to_string json);
    print_newline ()
  in
  match output with
  | Post_tool_silent -> ()
  | Post_tool_context text -> emit text
  | Post_tool_nudge line -> emit line
