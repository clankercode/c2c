(* c2c_stop_hook — Stop hook for c2c auto-delivery in Claude Code
 *
 * Delivers queued c2c messages on text-only turns (no tool call).
 * When messages exist, blocks the stop so Claude continues and the model
 * sees the messages as the block reason. When no messages, exits silently
 * without blocking.
 *
 * Reuses the same stdin session_id parsing and global broker drain logic
 * as c2c_inbox_hook (PostToolUse), via c2c_hook_lib.
 *
 * Env vars:
 *   C2C_MCP_SESSION_ID   — broker session id (fallback if stdin has none)
 *   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir
 *   C2C_SESSIONS_BROKER_ROOT — optional test/global sessions broker override
 *
 * Exit codes:
 *   0 — success (no messages, or messages delivered)
 *   1 — error (missing env, file error, etc.)
 *)

let () =
  (* B042: skip hook entirely for the explicit C2C_NO_AUTO_REGISTER opt-out. *)
  if C2c_hook_lib.is_subagent_quiet () then exit 0;
  (* B130: suppress on a subagent turn (non-empty stdin agent_id). Defensive —
     Claude Code fires SubagentStop (not Stop) at a subagent turn end. *)
  if C2c_hook_lib.stdin_is_subagent_turn () then exit 0;
  let session_id =
    match C2c_hook_lib.resolve_session_id () with
    | Ok sid -> sid
    | Error _ -> exit 0
  in
  let broker_root = C2c_hook_lib.resolve_hook_broker_root () in
  (* Fast path: if no session can be resolved, exit silently. *)
  if session_id = "" then exit 0;

  try
    let repo_broker, messages, _alias =
      (* Stop is a turn boundary: full drain, deferrable included (mid-turn
         PostToolUse is the push-only path). *)
      C2c_hook_lib.drain_all_messages ~push_only:false ~session_id
        ~broker_root ()
    in

    (* If no messages, exit silently — don't block the stop. *)
    if messages = [] then exit 0;

    (* Format messages as c2c envelope text *)
    let messages_text = C2c_hook_lib.format_messages_as_text ~repo_broker messages in

    (* Block the stop so Claude continues and sees the messages.
       The "reason" field surfaces to the model as context. *)
    let json : Yojson.Safe.t =
      `Assoc
        [ ("decision", `String "block")
        ; ("reason", `String messages_text)
        ]
    in
    Printf.printf "%s\n" (Yojson.Safe.to_string json);
    exit 0
  with e ->
    prerr_endline (Printexc.to_string e);
    exit 1
