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
      ~properties:[]
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
      ~properties:[ prop "content" "Message body to broadcast."; arr_prop "exclude_aliases" "Array of aliases to skip." ]
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
  ]

let tool_definitions =
  if Build_flags.mcp_debug_tool_enabled
  then base_tool_definitions @ [ debug_tool_definition ]
  else base_tool_definitions


module Memory_handlers = C2c_memory_handlers
(* #450 Slice 1: body hoisted to [c2c_memory_handlers.ml]. Module-alias
   preserves [Memory_handlers.handle_memory_*] callers below. *)

let handle_tool_call ~(broker : Broker.t) ~session_id_override ~tool_name ~arguments =
  match tool_name with
  | "register" ->
      let session_id = resolve_session_id ?session_id_override:session_id_override arguments in
      let alias =
        match optional_string_member "alias" arguments with
        | Some a -> a
        | None ->
            (match auto_register_alias () with
             | Some a -> a
             | None -> invalid_arg "alias is required (pass {\"alias\":\"your-name\"} or set C2C_MCP_AUTO_REGISTER_ALIAS)")
      in
      (* Reserved aliases — always blocked. *)
      if List.mem alias Broker.reserved_system_aliases then
        Lwt.return (tool_err (Printf.sprintf
          "register rejected: '%s' is a reserved system alias and cannot be registered" alias))
      else if not (C2c_name.is_valid alias) then
        Lwt.return (tool_err (Printf.sprintf "register rejected: %s"
          (C2c_name.error_message "alias" alias)))
      else
      let pid =
        match current_client_pid () with
        | Some pid -> Some pid
        | None -> Some (Unix.getppid ())
      in
      let client_type = optional_string_member "client_type" arguments in
      (* Detect whether this is a brand-new registration (no existing row for
         this session_id). Used below to emit peer_register broadcast. *)
      let is_new_registration =
        not (List.exists (fun r -> r.session_id = session_id)
               (Broker.list_registrations broker))
      in
      (* Detect alias rename before registering so we can notify rooms.
         A rename is genuine when the same process (matched by PID) re-registers
         under a new alias.  When both the old and new registration have a real
         PID set, they must agree — a differing PID means a new process reused
         the same session_id (common with `c2c start`), not an intentional rename.
         When the old registration has pid=None (legacy / no-PID registration),
         we allow the rename so that pre-PID entries are not permanently frozen. *)
      let old_alias_opt =
        let existing =
          List.find_opt
            (fun reg ->
              reg.session_id = session_id
              && reg.alias <> alias
              && (match reg.pid, pid with
                  | Some old_pid, Some new_pid -> old_pid = new_pid
                  | None, _ -> true   (* legacy no-PID row — allow rename *)
                  | Some _, None -> false))   (* new has no pid — can't confirm same process *)
            (Broker.list_registrations broker)
        in
        match existing with
        | Some reg -> Some reg.alias
        | None -> None
      in
      (* Capture rooms BEFORE re-registering (membership still uses old alias). *)
      let rooms_to_notify =
        match old_alias_opt with
        | None -> []
        | Some _ ->
            List.map (fun ri -> ri.Broker.ri_room_id)
              (Broker.my_rooms broker ~session_id)
      in
      let pid_start_time = Broker.capture_pid_start_time pid in
      (* Guard: refuse to evict a CONFIRMED-alive registration that owns this alias
         under a different session_id. An agent re-registering its own alias (same
         session_id, e.g. after a PID change) is always allowed. This prevents
         confused or malicious agents from hijacking another agent's alias.
         Use registration_liveness_state (tristate) so that pidless/Unknown entries
         do NOT block — registration_is_alive returns true for pid=None, which would
         permanently strand an alias held by a stale pidless row. We also block when
         pid is set and process exists but pid_start_time is missing (conservative:
         can't verify PID reuse, so protect the alias). *)
      let alias_hijack_conflict =
        (* #432 follow-up (slate-coder 2026-04-29): compare case-folded
           aliases. The eviction predicate at L1898 is case-fold, so a
           raw `=` here was an asymmetric guard — an attacker could
           register `slate-coder` against a victim holding `Slate-Coder`
           and the eviction would still fire, hijacking the victim's
           inbox. See
           .collab/findings/2026-04-29T14-25-00Z-slate-coder-alias-casefold-guard-asymmetry-takeover.md. *)
        let target = Broker.alias_casefold alias in
        List.find_opt
          (fun reg ->
            Broker.alias_casefold reg.alias = target
            && reg.session_id <> session_id
            && Option.is_some reg.pid
            && Broker.registration_is_alive reg)
          (Broker.list_registrations broker)
      in
      (match alias_hijack_conflict with
       | Some conflict ->
           let suggested_opt = Broker.suggest_alias_for_alias broker ~alias in
           let content =
             match suggested_opt with
             | Some suggested ->
                 Yojson.Safe.to_string
                   (`Assoc
                     [ ("error", `String
                          (Printf.sprintf
                             "register rejected: alias '%s' is currently held by \
                              an alive session '%s'. Suggested free alias: '%s'. \
                              Options: (1) register with {\"alias\":\"%s\"}, \
                              (2) wait for the current holder's process to exit, \
                              (3) call list to see all current registrations."
                             alias conflict.session_id suggested suggested))
                     ; ("collision", `Bool true)
                     ; ("contested_alias", `String alias)
                     ; ("holder_session_id", `String conflict.session_id)
                     ; ("suggested_alias", `String suggested)
                     ])
             | None ->
                 Yojson.Safe.to_string
                   (`Assoc
                     [ ("error", `String
                          (Printf.sprintf
                             "register rejected: alias '%s' is currently held by \
                              an alive session '%s', and all prime-suffixed \
                              candidates are also taken. Choose a different base alias."
                             alias conflict.session_id))
                     ; ("collision", `Bool true)
                     ; ("collision_exhausted", `Bool true)
                     ; ("contested_alias", `String alias)
                     ; ("holder_session_id", `String conflict.session_id)
                     ])
           in
            Lwt.return (tool_err content)
         | None ->
             let prior_owner_has_pending =
               Broker.pending_permission_exists_for_alias broker alias
             in
              if prior_owner_has_pending then
                Lwt.return (tool_err (Printf.sprintf
                  "register rejected: alias '%s' has pending permission state \
                   from a prior owner. \
                   Wait for the pending reply to arrive or for it to timeout before claiming this alias."
                  alias))
            else begin
              let plugin_version = optional_string_member "plugin_version" arguments in
              let role = optional_string_member "role" arguments in
              let tmux_location_arg = optional_string_member "tmux_location" arguments in
              let tmux_location =
                match tmux_location_arg with
                | Some _ -> tmux_location_arg
                | None -> Sys.getenv_opt "C2C_TMUX_LOCATION"
              in
              let broker_root = Broker.root broker in
              let keys_dir = Filename.concat broker_root "keys" in
              let enc_pubkey =
                match Relay_enc.load_or_generate ~alias () with
                | Ok enc -> Some (Relay_enc.public_key_b64 enc)
                | Error e ->
                    Printf.eprintf "[register] warning: could not load X25519 key: %s\n%!" e;
                    None
              in
              let ed25519_pubkey, pubkey_signed_at, pubkey_sig =
                match enc_pubkey with
                | None -> (None, None, None)
                | Some x25519_b64 ->
                    let priv_path = Filename.concat keys_dir (alias ^ ".ed25519") in
                    let ed_identity_opt =
                      if Sys.file_exists priv_path then
                        (* File exists but load failed — permissions error or corruption.
                           Do not clobber: operator must resolve manually. *)
                        (match Relay_identity.load ~path:priv_path () with
                         | Ok id -> Some id
                         | Error e ->
                             Printf.eprintf "[register] warning: cannot load Ed25519 key at %s: %s\n%!" priv_path e;
                             None)
                      else
                        (* No such file — lazy-create is safe. *)
                        (try
                           let () = mkdir_p ~mode:0o700 keys_dir in
                           Some (Relay_identity.load_or_create_at ~path:priv_path ~alias_hint:alias)
                         with e ->
                           Printf.eprintf "[register] warning: could not create Ed25519 identity at %s: %s\n%!" priv_path (Printexc.to_string e);
                           None)
                    in
                    match ed_identity_opt with
                    | None -> (None, None, None)
                    | Some ed_identity ->
                        let ed_pubkey_b64 = Relay_identity.b64url_encode ed_identity.Relay_identity.public_key in
                        let signed_at = Unix.gettimeofday () in
                        let signed_at_str =
                          let tm = Unix.gmtime signed_at in
                          Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
                            (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
                            tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
                        in
                        let canonical_msg =
                          Relay_identity.canonical_msg ~ctx:Relay.pubkey_binding_sign_ctx
                            [ alias; ed_pubkey_b64; x25519_b64; signed_at_str ]
                        in
                        let sig_raw = Relay_identity.sign ed_identity canonical_msg in
                        let sig_b64 = Relay_identity.b64url_encode sig_raw in
                        (Some ed_pubkey_b64, Some signed_at, Some sig_b64)
              in
              (* E2E S2: check both TOFU pins before registering.
                 If either mismatches, reject the registration.
                 CRIT-2 register-path observability: on each mismatch
                 emit a structured broker.log line via
                 [log_relay_e2e_register_pin_mismatch] so operators can
                 grep for register-path attacks across the swarm. *)
              let ed25519_mismatch =
                match ed25519_pubkey with
                | None -> None
                | Some ed_pk ->
                    (match Broker.pin_ed25519_sync ~alias ~pk:ed_pk with
                     | `Mismatch ->
                         let pinned = Broker.get_pinned_ed25519 alias in
                         Some ("ed25519", pinned, ed_pk)
                     | `Already_pinned | `New_pin -> None)
              in
              let x25519_mismatch =
                match enc_pubkey with
                | None -> None
                | Some xb64 ->
                    (match Broker.pin_x25519_sync ~alias ~pk:xb64 with
                     | `Mismatch ->
                         let pinned = Broker.get_pinned_x25519 alias in
                         Some ("x25519", pinned, xb64)
                     | `Already_pinned | `New_pin -> None)
              in
              let emit_register_pin_mismatch_audit (key_class, pinned_opt, claimed) =
                match Broker.get_relay_pins_root () with
                | None -> ()
                | Some broker_root ->
                    let pinned_b64 = Option.value pinned_opt ~default:"" in
                    log_relay_e2e_register_pin_mismatch
                      ~broker_root
                      ~alias
                      ~key_class
                      ~pinned_b64
                      ~claimed_b64:claimed
                      ~ts:(Unix.gettimeofday ())
              in
              match ed25519_mismatch, x25519_mismatch with
              | Some ((ed_k, _, _) as ed_info), Some ((x_k, _, _) as x_info) ->
                  emit_register_pin_mismatch_audit ed_info;
                  emit_register_pin_mismatch_audit x_info;
                  Lwt.return (tool_result
                    ~content:(Printf.sprintf
                      "register rejected: %s and %s pubkey mismatch — explicit rotation required \
                       (both pubkeys differ from previously pinned values for this alias)"
                      ed_k x_k)
                    ~is_error:true)
              | Some ((key_kind, _, _) as info), None
              | None, Some ((key_kind, _, _) as info) ->
                  emit_register_pin_mismatch_audit info;
                  Lwt.return (tool_result
                    ~content:(Printf.sprintf
                      "register rejected: %s pubkey mismatch — explicit rotation required \
                       (pubkey differs from previously pinned value for this alias)"
                      key_kind)
                    ~is_error:true)
              | None, None ->
                  Broker.register broker ~session_id ~alias ~pid ~pid_start_time
                    ~client_type ~plugin_version ~enc_pubkey ~ed25519_pubkey
                    ~pubkey_signed_at ~pubkey_sig ~role ~tmux_location ();
                  Broker.touch_session broker ~session_id;
              List.iter
                (fun room_id ->
                  try
                    ignore
                      (Broker.rename_room_member_alias broker ~room_id ~session_id
                         ~new_alias:alias)
                  with _ -> ())
                rooms_to_notify;
              (match old_alias_opt with
               | None -> ()
               | Some old_alias ->
                   let content =
                     Printf.sprintf
                       "%s renamed to %s {\"type\":\"peer_renamed\",\"old_alias\":\"%s\",\"new_alias\":\"%s\"}"
                       old_alias alias old_alias alias
                   in
                   List.iter
                     (fun room_id ->
                       (try
                          ignore
                            (Broker.send_room broker ~from_alias:"c2c-system"
                               ~room_id ~content)
                        with _ -> ()))
                     rooms_to_notify);
              let new_reg_unconfirmed =
                match List.find_opt (fun r -> r.session_id = session_id)
                        (Broker.list_registrations broker) with
                | Some reg -> Broker.is_unconfirmed reg
                | None -> false
              in
              (if is_new_registration && not new_reg_unconfirmed then begin
                let social_rooms =
                  let auto_rooms =
                    match Sys.getenv_opt "C2C_MCP_AUTO_JOIN_ROOMS" with
                    | Some v ->
                        String.split_on_char ',' v
                        |> List.map String.trim
                        |> List.filter (fun s -> s <> "" && Broker.valid_room_id s)
                    | None -> []
                  in
                  List.sort_uniq String.compare ("swarm-lounge" :: auto_rooms)
                in
                let content =
                  Printf.sprintf
                    "%s registered {\"type\":\"peer_register\",\"alias\":\"%s\"}"
                    alias alias
                in
                List.iter
                  (fun room_id ->
                    try ignore (Broker.send_room broker ~from_alias:"c2c-system" ~room_id ~content)
                    with _ -> ())
                  social_rooms
              end);
              let redelivered =
                Broker.redeliver_dead_letter_for_session broker ~session_id ~alias
              in
              (match Broker.write_allowed_signers_entry broker ~alias with
               | Ok () -> ()
               | Error e -> Printf.eprintf "[allowed_signers] warning: %s\n%!" e);
              let response_content =
                if redelivered > 0 then
                  Printf.sprintf "registered %s (redelivered %d dead-letter message%s)"
                    alias redelivered (if redelivered = 1 then "" else "s")
                else
                  "registered " ^ alias
              in
              Lwt.return (tool_ok response_content)
            end)
  | "list" ->
      let registrations = Broker.list_registrations broker in
      let content =
        `List
          (List.map
             (fun reg ->
               let { session_id; alias; pid; pid_start_time = _; registered_at } = reg in
               let base =
                 [ ("session_id", `String session_id); ("alias", `String alias) ]
               in
               let with_pid =
                 match pid with
                 | Some n -> base @ [ ("pid", `Int n) ]
                 | None -> base
               in
               (* Tristate `alive`: Bool true / Bool false / Null for
                  legacy pidless rows. Operators can filter on this
                  to identify zombie peers before broadcasting. *)
               let alive_field =
                  match Broker.registration_liveness_state reg with
                 | Broker.Alive -> `Bool true
                 | Broker.Dead -> `Bool false
                 | Broker.Unknown -> `Null
               in
               let with_alive = with_pid @ [ ("alive", alive_field) ] in
               let with_ra =
                 match registered_at with
                 | Some ts -> with_alive @ [ ("registered_at", `Float ts) ]
                 | None -> with_alive
               in
               let fields =
                 match reg.canonical_alias with
                 | Some ca -> with_ra @ [ ("canonical_alias", `String ca) ]
                 | None -> with_ra
               in
               `Assoc fields)
             registrations)
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_ok content)
  | "send" ->
      let to_alias = string_member_any [ "to_alias"; "alias" ] arguments in
      let content = string_member "content" arguments in
      (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
       | None ->
           Lwt.return (missing_sender_alias_result "send")
       | Some from_alias ->
           (match send_alias_impersonation_check ?session_id_override:session_id_override broker from_alias with
            | Some conflict ->
                Lwt.return
                  (tool_result
                     ~content:
                       (Printf.sprintf
                          "send rejected: from_alias '%s' is currently held by \
                           alive session '%s' — you cannot send as another agent. \
                           Options: (1) register your own alias first — call \
                           register with {\"alias\":\"<new-name>\"}, \
                           (2) call whoami to see your current identity."
                          from_alias conflict.session_id)
                     ~is_error:true)
              | None ->
                 if from_alias = to_alias then
                   Lwt.return (tool_err "error: cannot send a message to yourself")
                 else
                 let deferrable =
                   try match Yojson.Safe.Util.member "deferrable" arguments with
                     | `Bool b -> b | _ -> false
                   with _ -> false
                 in
                 let ephemeral =
                   try match Yojson.Safe.Util.member "ephemeral" arguments with
                     | `Bool b -> b | _ -> false
                   with _ -> false
                 in
                 (* #392: optional `tag` for fail/blocking/urgent body prefix. *)
                 let tag_arg =
                   try match Yojson.Safe.Util.member "tag" arguments with
                     | `String s -> Some s | _ -> None
                   with _ -> None
                 in
                 (match parse_send_tag tag_arg with
                   | Error msg ->
                     Lwt.return (tool_err (Printf.sprintf "send rejected: %s" msg))
                  | Ok tag_opt ->
                 let content = (tag_to_body_prefix tag_opt) ^ content in
let ts = Unix.gettimeofday () in
                  let effective_content =
                    (* #432: case-insensitive alias matching mirrors
                       [resolve_live_session_id_by_alias] so the
                       enc-pubkey lookup cannot disagree with the
                       inbox-write target. *)
                    let to_alias_cf = Broker.alias_casefold to_alias in
                    let recipient_reg =
                      Broker.list_registrations broker
                      |> List.find_opt (fun r -> Broker.alias_casefold r.alias = to_alias_cf)
                    in
                    match recipient_reg with
                    | Some _ -> `Plain content
                    | None ->
                      let recipient_reg =
                        Broker.list_registrations broker
                        |> List.find_opt (fun r -> Broker.alias_casefold r.alias = to_alias_cf && r.enc_pubkey <> None)
                      in
                      match recipient_reg with
                      | None -> `Plain content
                      | Some reg ->
                        match reg.enc_pubkey with
                        | None -> `Plain content
                        | Some recipient_pk_b64 ->
                          (match Broker.get_pinned_x25519 to_alias with
                        | Some pinned when pinned <> recipient_pk_b64 ->
                          `Key_changed to_alias
                        | _ ->
                          let _session_id =
                            match session_id_override with
                            | Some sid -> sid
                            | None ->
                                (match current_session_id () with
                                 | Some sid -> sid
                                 | None -> from_alias)
                          in
                          (match Relay_enc.load_or_generate ~alias:from_alias () with
                            | Error e ->
                              Printf.eprintf "send: load_or_generate x25519 failed: %s\n" e;
                              `Plain content
                             | Ok our_x25519 ->
                              let sender_pk_b64 = Relay_enc.b64url_encode our_x25519.public_key in
                              Broker.pin_x25519_sync ~alias:to_alias ~pk:recipient_pk_b64 |> ignore;
                              let our_ed25519 = Broker.load_or_create_ed25519_identity () in
                              let our_ed_pubkey_b64 = Relay_enc.b64url_encode our_ed25519.public_key in
                              Broker.pin_ed25519_sync ~alias:from_alias ~pk:our_ed_pubkey_b64 |> ignore;
                              let sk_seed = our_x25519.private_key_seed in
                             match Relay_e2e.encrypt_for_recipient
                                     ~pt:content
                                     ~recipient_pk_b64:recipient_pk_b64
                                     ~our_sk_seed:sk_seed with
                             | None -> `Plain content
                             | Some (ct_b64, nonce_b64) ->
                               let recipient_entry = Relay_e2e.make_recipient
                                 ~alias:to_alias ~ct_b64 ~nonce:nonce_b64
                               in
                               let our_ed25519_pk_b64 =
                                 Relay_e2e.b64_encode our_ed25519.public_key
                               in
                               let envelope : Relay_e2e.envelope = {
                                 from_ = from_alias;
                                 from_x25519 = Some sender_pk_b64;
                                 from_ed25519 = Some our_ed25519_pk_b64;
                                 to_ = Some to_alias;
                                 room = None;
                                 ts = Int64.of_float ts;
                                 enc = "box-x25519-v1";
                                 recipients = [ recipient_entry ];
                                 sig_b64 = "";
                                 envelope_version = Relay_e2e.current_envelope_version;
                               } in
                               let signed = Relay_e2e.set_sig envelope ~sk_seed:our_ed25519.private_key_seed in
                               `Encrypted (Yojson.Safe.to_string (Relay_e2e.envelope_to_json signed))))
                 in
                 match effective_content with
                 | `Key_changed alias ->
                   let err = Printf.sprintf "send rejected: enc_status:key-changed — %s's x25519 key differs from known pin (possible relay tamper). Re-send after trust --repin %s." alias alias in
                   Lwt.return (tool_err err)
                  | `Plain s | `Encrypted s ->
                    (* Compute peer_pass_claim first so we can use it to
                       suppress self_pass_warning false-positives on the
                       canonical "peer-PASS by <reviewer>, SHA=<X>" handoff
                       when the reviewer's alias matches from_alias but the
                       SHA was authored by someone else (= legitimate cross-
                       agent peer-PASS announcement). #163. *)
                    let peer_pass_claim = Peer_review.claim_of_content content in
                    let self_pass_warning =
                      match check_self_pass_content ~from_alias content with
                      | None -> None
                      | Some msg ->
                          (* Cross-check: if the body claims a peer-PASS for
                             a SHA whose git author != from_alias, this is a
                             cross-agent review announcement, not a self-
                             pass. Suppress the warning. *)
                          let sha_author_differs_from_sender =
                            match peer_pass_claim with
                            | None -> false
                            | Some (_claimed_alias, sha) ->
                                (match Git_helpers.git_commit_author_name sha with
                                 | None -> false
                                 | Some author ->
                                     String.lowercase_ascii author
                                     <> String.lowercase_ascii from_alias)
                          in
                          if sha_author_differs_from_sender then None
                          else if self_pass_detector_strictness () = `Strict
                          then Some (`Reject msg)
                          else Some (`Warn msg)
                    in
                    let peer_pass_pin_path =
                      Filename.concat (Broker.root broker) "peer-pass-trust.json"
                    in
                    let peer_pass_verification =
                      match peer_pass_claim with
                      | None -> None
                      | Some (alias, sha) ->
                          (* #29 H2b: pin-aware variant. The plain
                             [verify_claim] only validates the signature
                             against the artifact-embedded reviewer_pk, so
                             a fresh-keypair forgery passed strict-mode H2.
                             [verify_claim_with_pin] adds TOFU pubkey-pin
                             enforcement: artifact pubkey must match the
                             pin for this alias (or be first-seen). *)
                          match
                            Peer_review.verify_claim_with_pin
                              ~path:peer_pass_pin_path ~alias ~sha ()
                          with
                          | Peer_review.Claim_valid msg -> Some (`Ok msg)
                          | Peer_review.Claim_missing m -> Some (`Missing m)
                          | Peer_review.Claim_invalid m -> Some (`Invalid m)
                    in
                    let invalid_peer_pass =
                      match peer_pass_verification with
                      | Some (`Invalid m) ->
                          let claim_alias, claim_sha = match peer_pass_claim with
                            | Some (a, s) -> a, s
                            | None -> "", ""
                          in
                          (* Detailed reason -> stderr + broker.log only.
                             User-facing message (below) is generic to
                             avoid echoing attacker-placed artifact contents
                             back to the sender (I3 from slate's review). *)
                          Printf.eprintf
                            "[peer-pass] WARN: rejecting forged peer-pass DM from=%s to=%s alias=%s sha=%s: %s\n%!"
                            from_alias to_alias claim_alias claim_sha m;
                          log_peer_pass_reject
                            ~broker_root:(Broker.root broker)
                            ~from_alias ~to_alias
                            ~claim_alias ~claim_sha ~reason:m
                            ~ts:(Unix.gettimeofday ());
                          Some m
                      | _ -> None
                    in
                    match invalid_peer_pass, self_pass_warning with
                    | Some _m, _ ->
                        Lwt.return
                          (tool_result
                             ~content:
                               "send rejected: peer-pass verification failed \
                                (H2b: forged or pin-mismatched peer-pass DM not enqueued; \
                                see broker.log for details)"
                             ~is_error:true)
                    | None, Some (`Reject msg) ->
                        Lwt.return (tool_err ("send rejected: " ^ msg))
                    | None, (Some (`Warn _) | None) ->
                        Broker.enqueue_message broker ~from_alias ~to_alias ~content:s ~deferrable ~ephemeral ();
                        (match session_id_override with
                         | Some sid -> Broker.touch_session broker ~session_id:sid
                         | None ->
                           (match current_session_id () with
                            | Some sid -> Broker.touch_session broker ~session_id:sid
                            | None -> ()));
                        let ts = Unix.gettimeofday () in
                        (* #432: case-insensitive alias match for sidebar
                           lookups; otherwise dnd / compacting status can be
                           read from a different row than the one
                           [enqueue_message] writes to. *)
                        let to_alias_cf = Broker.alias_casefold to_alias in
                        let recipient_dnd =
                          match Broker.list_registrations broker
                                |> List.find_opt (fun r -> Broker.alias_casefold r.alias = to_alias_cf) with
                          | Some r -> Broker.is_dnd broker ~session_id:r.session_id
                          | None -> false
                        in
                        let recipient_compacting =
                          match Broker.list_registrations broker
                                |> List.find_opt (fun r -> Broker.alias_casefold r.alias = to_alias_cf) with
                          | Some r ->
                              (match Broker.is_compacting broker ~session_id:r.session_id with
                               | Some c ->
                                   let dur = Unix.gettimeofday () -. c.started_at in
                                   Some (dur, c.reason)
                               | None -> None)
                          | None -> None
                        in
                        let receipt_fields =
                          [ ("queued", `Bool true)
                          ; ("ts", `Float ts)
                          ; ("from_alias", `String from_alias)
                          ; ("to_alias", `String to_alias)
                          ]
                        in
                        let receipt_fields =
                          match self_pass_warning with
                          | Some (`Warn msg) -> receipt_fields @ [("self_pass_warning", `String msg)]
                          | _ -> receipt_fields
                        in
                        let receipt_fields =
                          match peer_pass_verification with
                          | Some (`Ok msg) -> receipt_fields @ [("peer_pass_verification", `String msg)]
                          | Some (`Missing m) -> receipt_fields @ [("peer_pass_verification", `String ("missing: " ^ m))]
                          | Some (`Invalid m) -> receipt_fields @ [("peer_pass_verification", `String ("invalid: " ^ m))]
                          | None -> receipt_fields
                        in
                        let receipt_fields =
                          if recipient_dnd then receipt_fields @ [("recipient_dnd", `Bool true)]
                          else receipt_fields
                        in
                        let receipt_fields =
                          match recipient_compacting with
                          | Some (dur, reason) ->
                              let reason_str = match reason with Some r -> " (" ^ r ^ ")" | None -> "" in
                              let warning = Printf.sprintf "recipient compacting for %.0fs%s" dur reason_str in
                              receipt_fields @ [("compacting_warning", `String warning)]
                          | None -> receipt_fields
                        in
                        let receipt_fields =
                          if deferrable then receipt_fields @ [("deferrable", `Bool true)]
                          else receipt_fields
                        in
                        let receipt = `Assoc receipt_fields |> Yojson.Safe.to_string in
                        Lwt.return (tool_ok receipt))))
  | "send_all" ->
      let content = string_member "content" arguments in
      (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
       | None -> Lwt.return (missing_sender_alias_result "send_all")
       | Some from_alias ->
           (match send_alias_impersonation_check ?session_id_override:session_id_override broker from_alias with
            | Some conflict ->
                Lwt.return
                  (tool_result
                     ~content:
                       (Printf.sprintf
                          "send_all rejected: from_alias '%s' is currently held by \
                           alive session '%s' — you cannot broadcast as another agent. \
                           Options: (1) register your own alias first — call \
                           register with {\"alias\":\"<new-name>\"}, \
                           (2) call whoami to see your current identity."
                          from_alias conflict.session_id)
                     ~is_error:true)
            | None ->
                let exclude_aliases =
                  let open Yojson.Safe.Util in
                  try
                    match arguments |> member "exclude_aliases" with
                    | `List items ->
                        List.filter_map
                          (fun item ->
                            match item with `String s -> Some s | _ -> None)
                          items
                    | _ -> []
                  with _ -> []
                in
                let { Broker.sent_to; skipped } =
                  Broker.send_all broker ~from_alias ~content ~exclude_aliases
                in
                (match session_id_override with Some sid -> Broker.touch_session broker ~session_id:sid | None -> (match current_session_id () with Some sid -> Broker.touch_session broker ~session_id:sid | None -> ()));
                let result_json =
                  `Assoc
                    [ ( "sent_to",
                        `List (List.map (fun alias -> `String alias) sent_to) )
                    ; ( "skipped",
                        `List
                          (List.map
                             (fun (alias, reason) ->
                               `Assoc
                                 [ ("alias", `String alias)
                                 ; ("reason", `String reason)
                                 ])
                             skipped) )
                    ]
                  |> Yojson.Safe.to_string
                in
                Lwt.return (tool_ok result_json)))
  | "whoami" ->
      let session_id = resolve_session_id ?session_id_override:session_id_override arguments in
      let reg_opt =
        Broker.list_registrations broker
        |> List.find_opt (fun reg -> reg.session_id = session_id)
      in
      let content =
        match reg_opt with
        | None -> ""
        | Some reg ->
            (match reg.canonical_alias with
             | Some ca ->
                 `Assoc [ ("alias", `String reg.alias); ("canonical_alias", `String ca) ]
                 |> Yojson.Safe.to_string
             | None -> reg.alias)
      in
      Lwt.return (tool_ok content)
  | "debug" ->
      let action = string_member "action" arguments in
      if not Build_flags.mcp_debug_tool_enabled then
        Lwt.return (tool_err "unknown tool")
      else
        (match action with
         | "send_msg_to_self" ->
             let session_id = resolve_session_id ?session_id_override:session_id_override arguments in
             let sender_alias =
               match current_registered_alias ?session_id_override:session_id_override broker with
               | Some alias -> alias
               | None ->
                   (match auto_register_alias () with
                    | Some alias -> alias
                    | None ->
                        raise
                          (Invalid_argument
                             "debug.send_msg_to_self: current session is not registered"))
             in
             let payload_json =
               optional_member "payload" arguments |> Option.value ~default:`Null
             in
             let content =
               `Assoc
                 [ ("kind", `String "c2c_debug")
                 ; ("action", `String action)
                 ; ("payload", payload_json)
                 ; ("ts", `Float (Unix.gettimeofday ()))
                 ; ("session_id", `String session_id)
                 ; ("alias", `String sender_alias)
                 ]
               |> Yojson.Safe.to_string
             in
             Broker.enqueue_message broker ~from_alias:sender_alias
               ~to_alias:sender_alias ~content ();
             let result_json =
               `Assoc
                 [ ("ok", `Bool true)
                 ; ("action", `String action)
                 ; ("session_id", `String session_id)
                 ; ("alias", `String sender_alias)
                 ; ("delivered_to", `String sender_alias)
                 ; ("content_preview", `String content)
                 ]
               |> Yojson.Safe.to_string
             in
             Lwt.return (tool_ok result_json)
         | "send_raw_to_self" ->
             (* Like send_msg_to_self, but content is the payload string verbatim
                — no JSON wrapping, no c2c_debug envelope. The body that arrives in
                the channel notification is exactly the payload. Use case: probe
                whether a Claude harness treats raw channel body as user input
                (e.g. payload="/compact" to test slash-command firing). *)
             let session_id = resolve_session_id ?session_id_override:session_id_override arguments in
             let sender_alias =
               match current_registered_alias ?session_id_override:session_id_override broker with
               | Some alias -> alias
               | None ->
                   (match auto_register_alias () with
                    | Some alias -> alias
                    | None ->
                        raise
                          (Invalid_argument
                             "debug.send_raw_to_self: current session is not registered"))
             in
             let payload =
               match optional_member "payload" arguments with
               | Some (`String s) -> s
               | Some _ ->
                   raise
                     (Invalid_argument
                        "debug.send_raw_to_self: payload must be a string")
               | None ->
                   raise
                     (Invalid_argument
                        "debug.send_raw_to_self: payload is required")
             in
             Broker.enqueue_message broker ~from_alias:sender_alias
               ~to_alias:sender_alias ~content:payload ();
             let preview =
               if String.length payload <= 200 then payload
               else String.sub payload 0 200 ^ "…"
             in
             let result_json =
               `Assoc
                 [ ("ok", `Bool true)
                 ; ("action", `String action)
                 ; ("session_id", `String session_id)
                 ; ("alias", `String sender_alias)
                 ; ("delivered_to", `String sender_alias)
                 ; ("payload_length", `Int (String.length payload))
                 ; ("content_preview", `String preview)
                 ]
               |> Yojson.Safe.to_string
             in
             Lwt.return (tool_ok result_json)
          | "get_env" ->
              let prefix =
                match optional_string_member "prefix" arguments with
                | Some p -> p
                | None -> "C2C_"
              in
              let env_vars =
                Array.to_list (Unix.environment ())
                |> List.filter (fun entry ->
                  String.length entry > String.length prefix
                  && String.sub entry 0 (String.length prefix) = prefix)
                |> List.map (fun entry ->
                  match String.index_opt entry '=' with
                  | Some i ->
                      let key = String.sub entry 0 i in
                      let value = String.sub entry (i + 1) (String.length entry - i - 1) in
                      (key, value)
                  | None -> (entry, ""))
                |> List.sort (fun (k1,_) (k2,_) -> String.compare k1 k2)
              in
              let result_json =
                `Assoc (
                  ("ok", `Bool true)
                  :: ("action", `String "get_env")
                  :: ("prefix", `String prefix)
                  :: ("count", `Int (List.length env_vars))
                  :: (List.map (fun (k,v) -> (k, `String v)) env_vars)
                )
                |> Yojson.Safe.to_string
              in
              Lwt.return (tool_ok result_json)
          | _ ->
              Lwt.return
                (tool_result
                   ~content:(Printf.sprintf "debug: unknown action '%s'" action)
                   ~is_error:true))
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
