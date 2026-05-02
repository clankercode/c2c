(* #450 Slice 3: DND/Compact/Stop agent-state cluster hoisted out of
   [c2c_mcp.ml]'s [handle_tool_call]. Each agent-state tool branch is
   now a top-level function here; [handle_tool_call] dispatches
   one-line into the corresponding [C2c_agent_state_handlers.X]
   entrypoint.

   Mechanical move — no behavior change. The bodies are byte-for-byte
   identical to the original arms with free locals lifted into named
   parameters ([broker], [session_id_override], [arguments]). *)

open C2c_mcp_helpers
open C2c_mcp_helpers_post_broker
module Broker = C2c_broker

let set_dnd ~broker ~session_id_override ~arguments =
  let on =
    try
      match bool_of_arg (Yojson.Safe.Util.member "on" arguments) with
      | Some b -> b
      | None -> false
    with _ -> false
  in
  let until_epoch =
    try
      match Yojson.Safe.Util.member "until_epoch" arguments with
      | `Float f -> Some f
      | `Int i -> Some (float_of_int i)
      | _ -> None
    with _ -> None
  in
  with_session_lwt ~session_id_override broker arguments (fun ~session_id ->
  let new_dnd = Broker.set_dnd broker ~session_id ~dnd:on ?until:until_epoch () in
  let content =
    (match new_dnd with
     | None ->
         `Assoc [ ("ok", `Bool false); ("error", `String "session not registered") ]
     | Some dnd_val ->
         `Assoc [ ("ok", `Bool true); ("dnd", `Bool dnd_val) ])
    |> Yojson.Safe.to_string
  in
  Lwt.return (tool_ok content))

let dnd_status ~broker ~session_id_override ~arguments =
  with_session_lwt ~session_id_override broker arguments (fun ~session_id ->
  let reg_opt =
    Broker.list_registrations broker
    |> List.find_opt (fun r -> r.session_id = session_id)
  in
  let content =
    (match reg_opt with
     | None ->
         `Assoc [ ("dnd", `Bool false) ]
     | Some reg ->
         let dnd_active = Broker.is_dnd broker ~session_id in
         let fields = [ ("dnd", `Bool dnd_active) ] in
         let fields =
           match reg.dnd_since with
           | Some ts when dnd_active -> fields @ [ ("dnd_since", `Float ts) ]
           | _ -> fields
         in
         let fields =
           match reg.dnd_until with
           | Some ts when dnd_active -> fields @ [ ("dnd_until", `Float ts) ]
           | _ -> fields
         in
         `Assoc fields)
    |> Yojson.Safe.to_string
  in
  Lwt.return (tool_ok content))

let set_compact ~broker ~session_id_override ~arguments =
  (match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
   | None ->
       Lwt.return (tool_err "{\"error\": \"no session ID; set C2C_MCP_SESSION_ID\"}")
   | Some session_id ->
       let reason = optional_string_member "reason" arguments in
       let compacting = Broker.set_compacting broker ~session_id ?reason () in
       let content =
         match compacting with
         | None ->
             `Assoc [ ("compacting", `Null) ]
             |> Yojson.Safe.to_string
         | Some c ->
             `Assoc
               [ ("compacting",
                  `Assoc
                    [ ("started_at", `Float c.started_at)
                    ; ("reason", match c.reason with Some r -> `String r | None -> `Null)
                    ])
               ]
             |> Yojson.Safe.to_string
       in
       Lwt.return (tool_ok content))

let clear_compact ~broker ~session_id_override ~arguments:_ =
  (match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
   | None ->
       Lwt.return (tool_err "{\"error\": \"no session ID; set C2C_MCP_SESSION_ID\"}")
   | Some session_id ->
       let ok = Broker.clear_compacting broker ~session_id in
       let content =
         `Assoc [ ("ok", `Bool ok) ]
         |> Yojson.Safe.to_string
       in
       Lwt.return (tool_ok content))

let stop_self ~broker ~session_id_override ~arguments =
  let reason = match optional_string_member "reason" arguments with Some r -> r | None -> "" in
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_sender_alias_result "stop_self")
   | Some name ->
       (* #432: impersonation guard — stop_self previously SIGTERM'd the
          outer.pid file under instances_dir/<name>/, but `name` came from
          alias_for_current_session_or_argument with arg fallback. An
          unregistered caller (or any caller who can list aliases) could
          terminate any peer's outer process — a DoS vector against the
          swarm. The fix: refuse if the supplied name names an instance
          whose registered session_id is NOT the calling session's. The
          tool name is "stop_SELF"; cross-instance termination must go
          through a CLI/admin path, not the MCP surface.

          The send_alias_impersonation_check helper implements exactly
          this predicate (alias-match, different-session, has-pid, alive)
          and folds in the legacy/system "no session context — let
          through" short-circuit via its first match arm
          (None current_sid -> None). Using the helper here unifies
          stop_self with delete_room / leave_room / send / send_room /
          send_room_invite / set_room_visibility, which all already
          call it. Reduces duplication and ensures any future change
          to the predicate (e.g. case-fold consistency, pidless-zombie
          policy) lands at one site. *)
        (match send_alias_impersonation_check ?session_id_override:session_id_override broker name with
         | Some conflict ->
             Lwt.return
               (tool_result
                  ~content:
                    (Printf.sprintf
                       "stop_self rejected: name '%s' is currently registered to \
                        alive session '%s' — stop_self only stops the calling \
                        session's own instance. Use a CLI/admin path to stop a \
                        different instance."
                       name conflict.session_id)
                  ~is_error:true)
         | None ->
        (* Reconstruct outer.pid path without creating a C2c_start dep cycle. *)
        let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
        let instances_dir =
          match Sys.getenv_opt "C2C_INSTANCES_DIR" with
          | Some d when String.trim d <> "" -> String.trim d
          | _ -> Filename.concat home ".local/share/c2c/instances"
        in
        let pid_path = Filename.concat (Filename.concat instances_dir name) "outer.pid" in
        let ok, is_error =
          if not (Sys.file_exists pid_path) then false, false
          else
            try
              let ic = open_in pid_path in
              let line = try input_line ic with End_of_file -> "" in
              close_in_noerr ic;
              match int_of_string_opt (String.trim line) with
              | Some pid ->
                (try Unix.kill pid Sys.sigterm; true, false
                 with Unix.Unix_error _ -> false, false)
              | None -> false, true  (* malformed pid file content = handler error *)
            with _ -> false, true    (* I/O error reading pid file = handler error *)
        in
        let content =
          `Assoc [ ("ok", `Bool ok); ("name", `String name); ("reason", `String reason);
                   ("pid_path", `String pid_path) ]
          |> Yojson.Safe.to_string
        in
        Lwt.return (tool_result ~content ~is_error)))
