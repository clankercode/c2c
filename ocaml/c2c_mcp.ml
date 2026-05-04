(* Substrate hoisted to [C2c_mcp_helpers] (types + pre-Broker helpers),
   [C2c_broker] (the broker state machine), and
   [C2c_mcp_helpers_post_broker] (post-Broker substrate: channel
   notification, envelope decrypt, room JSON, session glue, audit
   loggers) across #450 Slice 0 and Slice 0.5. This module retains the
   MCP server entrypoints (handle_tool_call, handle_request, log_rpc,
   skills helpers) and the static tool registry (tool_definitions). The
   [include]s + module-alias preserve the original public API: external
   callers continue to use [C2c_mcp.message], [C2c_mcp.Broker.X],
   [C2c_mcp.format_c2c_envelope], [C2c_mcp.channel_notification],
   [C2c_mcp.with_session], etc. *)

include C2c_mcp_helpers
include C2c_mcp_helpers_post_broker
(* [module Broker = C2c_broker] is re-exported via the include above
   ([C2c_mcp_helpers_post_broker] aliases it) so [C2c_mcp.Broker.X]
   continues to resolve for external callers. *)


let debug_tool_definition =
  tool_definition ~name:"debug"
    ~description:"Dev-build-only debug surface for controlled broker diagnostics. `action` selects the operation; unknown actions are rejected. `send_msg_to_self` enqueues a JSON-wrapped self-message; `send_raw_to_self` enqueues a self-message whose content is the raw `payload` string (skips the c2c_debug JSON wrapper, body goes verbatim through the channel-notification path); `get_env` lists C2C_*-prefixed env vars."
    ~required:["action"]
    ~properties:
      [ prop "action" "Debug action name (send_msg_to_self | send_raw_to_self | get_env)."
      ; ("payload", `Assoc [ ("type", `String "object"); ("description", `String "Optional arbitrary JSON payload (object/string/etc.) for the debug action. For send_raw_to_self this MUST be a string and is delivered verbatim.") ])
      ]

let base_tool_definitions =
  [ tool_definition ~name:"register"
      ~description:"Register a C2C alias for the current session. `alias` is optional: if omitted the server falls back to the C2C_MCP_AUTO_REGISTER_ALIAS environment variable. Calling register with no arguments is a safe way to refresh your registration (e.g. after a process restart that changed your PID)."
      ~required:[]
      ~properties:
        [ prop "alias" "New alias to register for this session. Pass a different alias to rename without changing env vars."
        ; prop "session_id" "Optional session id override; defaults to the current MCP session."
        ; prop "role" "Optional sender role for envelope attribution (coordinator, reviewer, agent, user)."
        ; prop "tmux_location" "Optional tmux session:window.pane target for this session (e.g. \"0:0.0\"). When not passed, falls back to the C2C_TMUX_LOCATION environment variable. Set automatically by managed sessions started via 'c2c start'."
        ]
  ; tool_definition ~name:"list"
      ~description:"List registered C2C peers."
      ~required:[]
      ~properties:[ bool_prop "alive_only" "Optional bool. When true, only return registrations with alive=true (live PID confirmed). Defaults to false (return all registrations)." ]
  ; tool_definition ~name:"send"
      ~description:"Send a C2C message to a registered peer alias. The sender alias is resolved from the current MCP session when possible; `from_alias` remains a legacy fallback for non-session callers. Optional `deferrable:true` marks the message as low-priority: push paths (channel notification, PostToolUse hook) skip it — recipient reads it on next explicit poll_inbox or idle flush. Optional `ephemeral:true` (local 1:1 only) delivers normally but skips the recipient-side archive append, so post-delivery the only persistent trace is the recipient's transcript / channel notification. For remote recipients (alias@host), the relay outbox persists by design and `ephemeral` is silently ignored on the relay side in v1 — cross-host ephemeral is a follow-up. Optional `tag:\"fail\"|\"blocking\"|\"urgent\"` (#392) prepends a visual marker to the body (🔴 FAIL: / ⛔ BLOCKING: / ⚠️ URGENT:) so the recipient spots the priority inline in their transcript — useful for peer-PASS FAIL verdicts and similar attention-asks. Receipt confirmation is impossible by design. Returns JSON {queued:true, ts:<epoch-seconds>, from_alias:<string>, to_alias:<string>} on success."
      ~required:["to_alias"; "content"]
      ~properties:[ prop "to_alias" "Target peer alias."; prop "from_alias" "Legacy fallback sender alias (deprecated)."; prop "content" "Message body."; bool_prop "deferrable" "Optional bool. When true, marks the message as low-priority — push delivery is suppressed; recipient reads it on next poll_inbox or idle flush."; bool_prop "ephemeral" "Optional bool. Local 1:1 only — when true, the message is delivered normally but skipped on the recipient-side archive append. For alias@host recipients the relay outbox persists by design; the flag is silently ignored on the relay side in v1."; prop "tag" "Optional visual-marker tag (#392). One of \"fail\" (🔴 FAIL:), \"blocking\" (⛔ BLOCKING:), or \"urgent\" (⚠️ URGENT:). Prepended to the body at send-time so the recipient spots the priority inline in their transcript. Unknown tag values are rejected." ]
  ; tool_definition ~name:"whoami"
      ~description:"Resolve the current C2C session registration."
      ~required:[]
      ~properties:
        [ prop "session_id" "Optional session id override; defaults to the current MCP session." ]
  ; tool_definition ~name:"poll_inbox"
      ~description:"Drain queued C2C messages for the current session. Returns a JSON array of {from_alias,to_alias,content} objects; call this at the start of each turn and after each send to reliably receive messages regardless of whether the client surfaces notifications/claude/channel. The session_id argument (if provided) must match the caller's MCP session — cross-session drain attempts are rejected."
      ~required:[]
      ~properties:
        [ prop "session_id" "Must match caller's MCP session (C2C_MCP_SESSION_ID); rejected if mismatched." ]
  ; tool_definition ~name:"peek_inbox"
      ~description:"Non-draining inbox check for the current session. Returns the same JSON array as `poll_inbox` but leaves the messages in the inbox so a subsequent `poll_inbox` still sees them. Useful for 'any mail?' checks without losing messages on error paths. Caller's session_id is always resolved from the MCP env (C2C_MCP_SESSION_ID); passing a session_id argument is ignored for isolation."
      ~required:[]
      ~properties:
        [ prop "session_id" "Optional session id override for compatible clients." ]
  ; tool_definition ~name:"sweep"
      ~description:"Remove dead registrations (whose parent process has exited) and delete orphan inbox files that belong to no current registration. Any non-empty orphan inbox content is appended to dead-letter.jsonl inside the broker directory before the inbox file is deleted, so cleanup is non-destructive to operator signal. Dead sessions are also evicted from all room member lists. Returns JSON {dropped_regs:[{session_id,alias}], deleted_inboxes:[session_id], preserved_messages: int, evicted_room_members:[{room_id,alias}]}."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"send_all"
      ~description:"Fan out a message to every currently-registered peer except the sender (and any alias in the optional `exclude_aliases` array). The sender alias is resolved from the current MCP session when possible; `from_alias` remains a legacy fallback. Non-live recipients are skipped with reason \"not_alive\" rather than raising, so partial failure does not abort the broadcast. Per-recipient enqueue takes the same per-inbox lock used by `send`. Returns JSON {sent_to:[alias], skipped:[{alias, reason}]}."
      ~required:["content"]
      ~properties:[ prop "content" "Message body to broadcast."; arr_prop "exclude_aliases" "Array of aliases to skip."; prop "tag" "Optional visual-marker tag (#392). One of \"fail\" (🔴 FAIL:), \"blocking\" (⛔ BLOCKING:), or \"urgent\" (⚠️ URGENT:). Prepended to the body at send-time so the recipient spots the priority inline in their transcript. Unknown tag values are rejected." ]
  ; tool_definition ~name:"join_room"
      ~description:"Join a persistent N:N room. Creates the room if it does not exist. Idempotent per (alias, session_id). Room IDs must be alphanumeric + hyphens + underscores. Returns JSON {room_id, members, history} where `history` is the most recent messages from the room's append-only log so a newly-joined member can catch up on context without a separate `room_history` call. Optional `history_limit` (default 20, max 200) controls how many history entries to include; pass 0 to skip history backfill. The member alias is resolved from the current MCP session when possible; `alias`/`from_alias` remain legacy fallbacks."
      ~required:["room_id"]
      ~properties:[ prop "room_id" "Unique room identifier (alphanumeric, hyphens, underscores)."; prop "alias" "Legacy fallback member alias (deprecated)."; int_prop "history_limit" "Max history entries on join (default 20, max 200, 0 to skip)." ]
  ; tool_definition ~name:"leave_room"
      ~description:"Leave a persistent N:N room. Returns the member list after leave. The member alias is resolved from the current MCP session when possible; `alias`/`from_alias` remain legacy fallbacks."
      ~required:["room_id"]
      ~properties:[ prop "room_id" "Room to leave."; prop "alias" "Legacy fallback member alias (deprecated)." ]
  ; tool_definition ~name:"delete_room"
      ~description:"Delete a room entirely. Only succeeds when the room has zero members. Returns JSON {room_id, deleted} on success."
      ~required:["room_id"]
      ~properties:[ prop "room_id" "Room to delete." ]
  ; tool_definition ~name:"send_room"
      ~description:"Send a message to a persistent N:N room. Appends to room history and fans out to every member's inbox except the sender, with to_alias tagged as '<alias>#<room_id>'. The sender alias is resolved from the current MCP session when possible; `from_alias` remains a legacy fallback. Optional `tag` (one of \"fail\", \"blocking\", \"urgent\") prepends a #392 visual indicator (🔴 FAIL: / ⛔ BLOCKING: / ⚠️ URGENT:) to each recipient's inbox row body so the salience surfaces in the transcript. Tag is presentation-only — history stores bare content for stable dedup. Returns JSON {delivered_to, skipped, ts}."
      ~required:["room_id"; "content"]
      ~properties:[ prop "room_id" "Target room."; prop "content" "Message body."; prop "alias" "Legacy fallback sender alias (deprecated)."; prop "tag" "Optional #392 visual indicator: \"fail\", \"blocking\", or \"urgent\". Recipients see the corresponding emoji+keyword prefix in their transcript. Unknown values rejected." ]
  ; tool_definition ~name:"list_rooms"
      ~description:"List all persistent rooms with member counts and member aliases. Returns a JSON array of {room_id, member_count, members}."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"my_rooms"
      ~description:"List rooms where your current session is a member. Caller's session_id is always resolved from the MCP env (C2C_MCP_SESSION_ID); passing a session_id argument is ignored for isolation — you can only see your own memberships. Same row shape as list_rooms: JSON array of {room_id, member_count, members}."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"room_history"
      ~description:"Return the last `limit` (default 50) messages from a room's append-only history. Pass `since` as a Unix epoch float to get only messages newer than that timestamp — useful for incremental polling without re-reading old history. Read-only."
      ~required:["room_id"]
      ~properties:[ prop "room_id" "Room whose history to retrieve."; int_prop "limit" "Max messages to return (default 50)."; float_prop "since" "Only return messages with ts > since (Unix epoch float, optional)." ]
  ; tool_definition ~name:"history"
      ~description:"Return your own archived inbox messages, newest first. Non-ephemeral messages drained via poll_inbox are appended to a per-session log before the live inbox is cleared. Messages sent with `ephemeral:true` are explicitly NOT archived — they have no permanent record after delivery, so history will not include them. Caller's session_id is always resolved from the MCP env (C2C_MCP_SESSION_ID); passing a session_id argument is ignored for isolation — you can only read your own history. Optional `limit` (default 50). Returns a JSON array of {drained_at, from_alias, to_alias, content} objects."
      ~required:[]
      ~properties:[ int_prop "limit" "Max messages to return (default 50)." ]
  ; tool_definition ~name:"tail_log"
      ~description:"Return the last N lines from the broker audit log (broker.log). Each line is a JSON object; the shape is a discriminated union — `tool`-keyed entries record RPC events ({ts, tool, ok}), and `event`-keyed entries record subsystem events (e.g. `send_memory_handoff` per #327, `nudge_tick`/`nudge_enqueue` per #335). Useful for verifying that your sends and polls reached the broker and observing nudge/handoff scheduler behavior without exposing message content. Optional `limit` (default 50, max 500). Returns a JSON array of log entries, oldest first."
      ~required:[]
      ~properties:[ int_prop "limit" "Max log entries (default 50, max 500)." ]
  ; tool_definition ~name:"server_info"
      ~description:"Return c2c client/broker version, git SHA, and feature flags. Useful for diagnostics and for checking which capabilities are available in the current session."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"prune_rooms"
      ~description:"Evict dead members from all room member lists without touching registrations or inboxes. Safe to call while outer loops are running (unlike `sweep`, which also drops registrations and deletes inboxes). Returns JSON {evicted_room_members:[{room_id,alias}]}."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"send_room_invite"
      ~description:"Invite an alias to a room. Only existing room members can send invites. For invite-only rooms, the invitee will be allowed to join."
      ~required:["room_id"; "invitee_alias"]
      ~properties:[ prop "room_id" "Room to invite to."; prop "invitee_alias" "Alias to invite."; prop "alias" "Legacy fallback sender alias (deprecated)." ]
  ; tool_definition ~name:"set_room_visibility"
      ~description:"Change a room's visibility mode. public = anyone can join; invite_only = only invited aliases can join. Only existing room members can change visibility."
      ~required:["room_id"; "visibility"]
      ~properties:[ prop "room_id" "Room to modify."; prop "visibility" "Either 'public' or 'invite_only'."; prop "alias" "Legacy fallback sender alias (deprecated)." ]
  ; tool_definition ~name:"set_dnd"
      ~description:"Enable or disable Do-Not-Disturb for this session. When DND is on, channel-push delivery (notifications/claude/channel) is suppressed — inbox still accumulates messages, poll_inbox always works. Optional `until_epoch` sets an auto-expire Unix timestamp; omit for manual-off only. Returns JSON {ok:true,dnd:bool}."
      ~required:["on"]
      ~properties:
        [ bool_prop "on" "true to enable DND, false to disable."
        ; float_prop "until_epoch" "Optional float Unix timestamp to auto-expire DND (e.g. Unix.gettimeofday()+3600 for 1h)."
        ]
  ; tool_definition ~name:"dnd_status"
      ~description:"Check current Do-Not-Disturb status for this session. Returns JSON {dnd:bool, dnd_since?:float, dnd_until?:float}."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"open_pending_reply"
      ~description:"Open a pending reply tracking entry when sending a permission or question request to supervisors. Records the perm_id, kind (permission/question), supervisors list, and TTL for validation when replies arrive."
      ~required:["perm_id"; "kind"; "supervisors"]
      ~properties:
        [ prop "perm_id" "Unique permission/request ID."
        ; prop "kind" "Type: 'permission' or 'question'."
        ; arr_prop "supervisors" "List of supervisor aliases that can answer."
        ]
  ; tool_definition ~name:"check_pending_reply"
      ~description:"Validate that a received reply is authorized for a pending permission/request. The reply-from alias is derived from the calling MCP session's registration; the legacy [reply_from_alias] argument is silently ignored (kept on the schema for backward compatibility — see #432 Slice B)."
      ~required:["perm_id"]
      ~properties:
        [ prop "perm_id" "Permission/request ID from the reply."
        ; prop "reply_from_alias" "DEPRECATED — legacy field, silently ignored. The broker derives the reply alias from the calling MCP session's registration (#432 Slice B)."
        ]
  ; tool_definition ~name:"set_compact"
      ~description:"Mark this session as compacting (context summarization in progress). Set by PreCompact hooks so senders receive a warning. Returns {compacting: {started_at, reason}}."
      ~required:[]
      ~properties:
        [ prop "reason" "Optional human-readable reason for compaction (e.g. 'context-limit-near')."
        ]
  ; tool_definition ~name:"clear_compact"
      ~description:"Clear the compacting flag for this session. Called by PostCompact hooks after context summarization completes."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"stop_self"
      ~description:"Ephemeral agents: stop this managed session cleanly. Confirm with your caller that your job is complete BEFORE calling this. Looks up the managed-instance name from the current session's registered alias and sends SIGTERM to the outer loop. Returns {ok, name, reason}."
      ~required:[]
      ~properties:
        [ prop "reason" "Optional short reason logged in the stop report (e.g. 'task complete')." ]
  ; tool_definition ~name:"memory_list"
      ~description:"List memory entries. Returns a JSON array of {alias, name, description, shared, shared_with} objects. The alias field is the entry's owner (the agent whose memory dir the entry lives in), NOT the caller's alias — use shared_with_me=true to filter for entries shared with the current caller. With shared_with_me=true, scans every agent's memory dir for entries that explicitly list the current alias in their shared_with frontmatter."
      ~required:[]
      ~properties:
        [ prop "shared_with_me" "When true, return entries (across every alias dir) where the current alias appears in shared_with. Receiver-side filter. Each returned item's alias field is the entry's owner (not the caller)."
        ]
  ; tool_definition ~name:"memory_read"
      ~description:"Read a memory entry by name. Returns {name, description, shared, shared_with, content} on success. Cross-agent reads require shared:true OR caller's alias in shared_with."
      ~required:["name"]
      ~properties:[ prop "name" "Memory entry name (without .md extension)." ]
  ; tool_definition ~name:"memory_write"
      ~description:"Write a memory entry. Creates or overwrites. When shared_with includes other aliases (and the entry is NOT globally shared), each recipient is sent a deferrable C2C DM with the path so they don't have to poll `memory list --shared-with-me` to discover it (#286). Globally-shared entries skip the targeted handoff — the audience is everyone. Returns {saved: name, notified: [alias]}."
      ~required:["name"; "content"]
      ~properties:
        [ prop "name" "Memory entry name."
        ; prop "description" "Short description (optional)."
        ; prop "shared" "Mark as globally shared (visible to all agents). Default false."
        ; prop "shared_with" "Optional comma-separated list of aliases granted read access (alternative to global shared)."
        ; prop "content" "Memory body text." ]
  ; tool_definition ~name:"schedule_set"
      ~description:"Create or update a named self-schedule. The schedule fires a self-DM at the given interval. Requires name and interval_s; other fields are optional."
      ~required:["name"; "interval_s"]
      ~properties:
        [ prop "name" "Schedule name (e.g. wake, sitrep)."
        ; float_prop "interval_s" "Interval in seconds between fires."
        ; prop "message" "Message text for the self-DM."
        ; prop "align" "Wall-clock alignment spec (e.g. @1h+7m)."
        ; bool_prop "only_when_idle" "Only fire when agent is idle (default true)."
        ; float_prop "idle_threshold_s" "Idle threshold in seconds (default: same as interval_s)."
        ; bool_prop "enabled" "Whether the schedule is enabled (default true)." ]
  ; tool_definition ~name:"schedule_list"
      ~description:"List all schedule entries for the current agent."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"schedule_rm"
      ~description:"Remove a named schedule entry."
      ~required:["name"]
      ~properties:[ prop "name" "Schedule name to remove." ]
  ]

(** Extract the tool name from a tool_definition JSON value. *)
let tool_definition_name (td : Yojson.Safe.t) : string =
  match td with
  | `Assoc pairs ->
    (match List.assoc_opt "name" pairs with
     | Some (`String n) -> n
     | _ -> failwith "tool_definition missing name")
  | _ -> failwith "tool_definition is not an object"

(** All base tool names as bare strings (e.g. ["register"; "list"; "send"; ...]). *)
let base_tool_names : string list =
  List.map tool_definition_name base_tool_definitions

let tool_definitions =
  if Build_flags.mcp_debug_tool_enabled
  then base_tool_definitions @ [ debug_tool_definition ]
  else base_tool_definitions


module Memory_handlers = C2c_memory_handlers
(* #450 Slice 1: body hoisted to [c2c_memory_handlers.ml]. Module-alias
   preserves [Memory_handlers.handle_memory_*] callers below. *)

let handle_memory_write = Memory_handlers.handle_memory_write

module Schedule_handlers = C2c_schedule_handlers

let handle_tool_call ~(broker : Broker.t) ~session_id_override ~tool_name ~arguments =
  match tool_name with
  | "register" ->
      C2c_identity_handlers.register ~broker ~session_id_override ~arguments
  | "list" ->
      C2c_identity_handlers.list ~broker ~session_id_override ~arguments
  | "send" ->
      C2c_send_handlers.send ~broker ~session_id_override ~arguments
  | "send_all" ->
      C2c_send_handlers.send_all ~broker ~session_id_override ~arguments
  | "whoami" ->
      C2c_identity_handlers.whoami ~broker ~session_id_override ~arguments
  | "debug" ->
      C2c_identity_handlers.debug ~broker ~session_id_override ~arguments
  | "poll_inbox" ->
      C2c_inbox_handlers.poll_inbox ~broker ~session_id_override ~arguments
  | "peek_inbox" ->
      C2c_inbox_handlers.peek_inbox ~broker ~session_id_override ~arguments
  | "history" ->
      C2c_inbox_handlers.history ~broker ~session_id_override ~arguments
  | "tail_log" ->
      C2c_inbox_handlers.tail_log ~broker ~session_id_override ~arguments
  | "server_info" ->
      C2c_inbox_handlers.server_info ~broker ~session_id_override ~arguments
  | "sweep" ->
      C2c_inbox_handlers.sweep ~broker ~session_id_override ~arguments
  | "prune_rooms" ->
      C2c_room_handlers.prune_rooms ~broker ~session_id_override ~arguments
  | "set_dnd" ->
      C2c_agent_state_handlers.set_dnd ~broker ~session_id_override ~arguments
  | "dnd_status" ->
      C2c_agent_state_handlers.dnd_status ~broker ~session_id_override ~arguments
  | "join_room" ->
      C2c_room_handlers.join_room ~broker ~session_id_override ~arguments
  | "leave_room" ->
      C2c_room_handlers.leave_room ~broker ~session_id_override ~arguments
  | "delete_room" ->
      C2c_room_handlers.delete_room ~broker ~session_id_override ~arguments
  | "send_room" ->
      C2c_room_handlers.send_room ~broker ~session_id_override ~arguments
  | "list_rooms" ->
      C2c_room_handlers.list_rooms ~broker ~session_id_override ~arguments
  | "my_rooms" ->
      C2c_room_handlers.my_rooms ~broker ~session_id_override ~arguments
  | "room_history" ->
      C2c_room_handlers.room_history ~broker ~session_id_override ~arguments
  | "send_room_invite" ->
      C2c_room_handlers.send_room_invite ~broker ~session_id_override ~arguments
  | "set_room_visibility" ->
      C2c_room_handlers.set_room_visibility ~broker ~session_id_override ~arguments
  | "open_pending_reply" ->
      C2c_pending_reply_handlers.open_pending_reply ~broker ~session_id_override ~arguments
  | "check_pending_reply" ->
      C2c_pending_reply_handlers.check_pending_reply ~broker ~session_id_override ~arguments
  | "set_compact" ->
      C2c_agent_state_handlers.set_compact ~broker ~session_id_override ~arguments
  | "clear_compact" ->
      C2c_agent_state_handlers.clear_compact ~broker ~session_id_override ~arguments
  | "stop_self" ->
      C2c_agent_state_handlers.stop_self ~broker ~session_id_override ~arguments
  | "memory_list" ->
      Memory_handlers.handle_memory_list ~broker ~session_id_override ~arguments
  | "memory_read" ->
      Memory_handlers.handle_memory_read ~broker ~session_id_override ~arguments
  | "memory_write" ->
      Memory_handlers.handle_memory_write ~broker ~session_id_override ~arguments
  | "schedule_set" ->
      Schedule_handlers.handle_schedule_set ~broker ~session_id_override ~arguments
  | "schedule_list" ->
      Schedule_handlers.handle_schedule_list ~broker ~session_id_override ~arguments
  | "schedule_rm" ->
      Schedule_handlers.handle_schedule_rm ~broker ~session_id_override ~arguments
  | _ -> Lwt.return (tool_err ("unknown tool: " ^ tool_name))

(* Append one structured line to <broker_root>/broker.log for every
   tools/call RPC. Never raises — audit failures must never break the
   RPC path. Content fields are deliberately omitted to avoid leaking
   message content into a shared log file. *)
let log_rpc ~broker_root ~tool_name ~is_error =
  let ts = Unix.gettimeofday () in
  log_broker_event ~broker_root "rpc"
    [ ("ts", `Float ts)
    ; ("tool", `String tool_name)
    ; ("ok", `Bool (not is_error)) ]

(* --- prompts/list and prompts/get helpers ---------------------------------

   Frontmatter (YAML between --- markers) is always at the top of SKILL.md.
   20 lines is sufficient to capture name + description from any skill file.
   SKILL.md bodies start after the second --- which is well within this limit.
*)

let skills_dir () =
  let top = match Git_helpers.git_common_dir_parent () with
    | Some t -> t
    | None -> Sys.getcwd ()
  in
  Filename.concat (Filename.concat top ".opencode") "skills"

let list_skills () =
  let dir = skills_dir () in
  try
    Array.to_list (Sys.readdir dir)
    |> List.filter (fun name ->
      let path = Filename.concat dir name in
      try Sys.is_directory path with _ -> false)
  with _ -> []

let parse_skill_frontmatter dir name =
  let skill_md = Filename.concat dir (Filename.concat name "SKILL.md") in
  try
    let ic = open_in skill_md in
    let lines = ref [] in
    let in_frontmatter = ref false in
    let name_ref = ref None in
    let desc_ref = ref None in
    let strip_quotes s =
      let len = String.length s in
      if len >= 2 && s.[0] = '"' && s.[len - 1] = '"'
      then String.sub s 1 (len - 2)
      else s
    in
    (try
       for _i = 1 to 20 do
         match input_line ic with
         | line ->
             let line = String.trim line in
             if line = "---" then in_frontmatter := not !in_frontmatter
             else if !in_frontmatter then
               (if Str.string_match (Str.regexp "^name:[ ]*\\([^ ].*\\)$") line 0
                then name_ref := Some (Str.matched_group 1 line)
                else if Str.string_match (Str.regexp "^description:[ ]*\\(\".*\"\\)$") line 0
                then desc_ref := Some (strip_quotes (Str.matched_group 1 line))
                else if Str.string_match (Str.regexp "^description:[ ]*\\([^ ].*\\)$") line 0
                then desc_ref := Some (Str.matched_group 1 line));
             lines := line :: !lines
         | exception End_of_file -> ()
       done;
     with _ -> ());
    close_in_noerr ic;
    (!name_ref, !desc_ref)
  with _ -> (None, None)

let get_skill_content dir name =
  let skill_md = Filename.concat dir (Filename.concat name "SKILL.md") in
  try
    let ic = open_in skill_md in
    let content = ref "" in
    (try
       while true do
         content := !content ^ input_line ic ^ "\n"
       done
     with End_of_file -> close_in ic | _ -> close_in_noerr ic);
    String.trim !content
  with _ -> ""

let list_skills_as_prompts () =
  let dir = skills_dir () in
  let names = list_skills () in
  List.map (fun name ->
    let (_, desc) = parse_skill_frontmatter dir name in
    `Assoc
      (("name", `String name)
       :: (match desc with Some d -> [("description", `String d)] | None -> []))
  ) names

let get_skill name =
  let dir = skills_dir () in
  let names = list_skills () in
  if not (List.mem name names) then None
  else
    let (_, desc) = parse_skill_frontmatter dir name in
    let content = get_skill_content dir name in
    let description = match desc with Some d -> d | None -> name in
    Some (description, content)

let handle_request ~broker_root json =
  let open Yojson.Safe.Util in
  let broker = Broker.create ~root:broker_root in
  let id =
    try
      let id_json = json |> member "id" in
      if id_json = `Null then None else Some id_json
    with _ -> None
  in
  let method_ = try json |> member "method" |> to_string with _ -> "" in
  let params = try json |> member "params" with _ -> `Null in
  match (id, method_) with
  | None, _ -> Lwt.return_none
  | Some id, "initialize" ->
      let result =
        `Assoc
          [ ("protocolVersion", `String supported_protocol_version)
          ; ("serverInfo", server_info ())
          ; ("instructions", instructions)
          ; ("capabilities", capabilities)
          ]
      in
      Lwt.return_some (jsonrpc_response ~id result)
  | Some id, "tools/list" ->
      let result = `Assoc [ ("tools", `List tool_definitions) ] in
      Lwt.return_some (jsonrpc_response ~id result)
  | Some id, "tools/call" ->
      let tool_name = try params |> member "name" |> to_string with _ -> "" in
      let arguments = try params |> member "arguments" with _ -> `Assoc [] in
      let session_id_override =
        request_session_id_override ~broker_root ~tool_name ~params
      in
      ensure_request_session_bootstrap ~broker_root ?session_id_override:session_id_override ();
      let open Lwt.Syntax in
      let* result =
        Lwt.catch
          (fun () ->
            handle_tool_call ~broker ~session_id_override ~tool_name ~arguments)
          (fun exn ->
            let msg =
              match exn with
              | Invalid_argument m -> m
              | Yojson.Safe.Util.Type_error (m, _) ->
                  Printf.sprintf "argument type error: %s" m
              | _ -> Printexc.to_string exn
            in
            Lwt.return (tool_err msg))
      in
      let is_error =
        (try Yojson.Safe.Util.(result |> member "isError" |> to_bool) with _ -> false)
      in
      log_rpc ~broker_root ~tool_name ~is_error;
      Lwt.return_some (jsonrpc_response ~id result)
  | Some id, "prompts/list" ->
      let prompts = list_skills_as_prompts () in
      Lwt.return_some (jsonrpc_response ~id (`Assoc [("prompts", `List prompts)]))
  | Some id, "prompts/get" ->
      let name = try params |> member "name" |> to_string with _ -> "" in
      (match get_skill name with
       | Some (description, content) ->
           let prompt_msg = `Assoc [("role", `String "user"); ("content", `Assoc [("type", `String "text"); ("text", `String content)])] in
           Lwt.return_some (jsonrpc_response ~id (`Assoc [("description", `String description); ("messages", `List [prompt_msg])]))
       | None ->
           Lwt.return_some (Json_util.jsonrpc_error ~id ~code:(-32602) ~message:("Unknown skill: " ^ name)))
  | Some id, "ping" ->
      (* MCP protocol keepalive — must respond with empty result, not an error.
         Claude Code sends periodic pings; an error response triggers "server unhealthy"
         and causes the 3-5min disconnect cycle observed in coder2-expert's session. *)
      Lwt.return_some (jsonrpc_response ~id (`Assoc []))
  | Some id, _ ->
      Lwt.return_some (Json_util.jsonrpc_error ~id ~code:(-32601) ~message:("Unknown method: " ^ method_))
