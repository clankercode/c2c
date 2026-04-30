(* #450 Slice 5: Inbox cluster hoisted out of [c2c_mcp.ml]'s
   [handle_tool_call]. Each inbox-inspection tool branch is now a
   top-level function here; [handle_tool_call] dispatches one-line
   into the corresponding [C2c_inbox_handlers.X] entrypoint.

   Mechanical move — no behavior change. The bodies are byte-for-byte
   identical to the original arms with free locals lifted into named
   parameters ([broker], [session_id_override], [arguments]). *)

open C2c_mcp_helpers
open C2c_mcp_helpers_post_broker
module Broker = C2c_broker

let poll_inbox ~broker ~session_id_override ~arguments =
  let req_sid = optional_string_member "session_id" arguments in
  let caller_sid =
    match session_id_override with
    | Some sid -> Some sid
    | None -> current_session_id ()
  in
  if req_sid <> None && caller_sid <> None && req_sid <> caller_sid then
    Lwt.return (tool_err "poll_inbox: session_id argument does not match caller's MCP session (C2C_MCP_SESSION_ID)")
  else begin
  with_session_lwt ~session_id_override broker arguments (fun ~session_id ->
  Broker.confirm_registration broker ~session_id;
  let messages = Broker.drain_inbox ~drained_by:"poll_inbox" broker ~session_id in
  let our_x25519 =
    match List.find_opt (fun r -> r.session_id = session_id) (Broker.list_registrations broker) with
    | None -> None
    | Some reg ->
        (match Relay_enc.load_or_generate ~alias:reg.alias () with
         | Ok k -> Some k
         | Error _ -> None)
  in
  let our_ed25519 = Some (Broker.load_or_create_ed25519_identity ()) in
  let process_msg ({ from_alias; to_alias; content; deferrable } : message) =
    (* [#432 §7] Inline decrypt block extracted to [decrypt_envelope]
       helper above; this site is the status-tracking call site (the
       push site discards _enc_status). Both formerly-duplicated
       blocks now share one definition. *)
    let (decrypted, enc_status) =
      decrypt_envelope ~our_x25519 ~our_ed25519 ~to_alias ~content
    in
    let base = [ ("from_alias", `String from_alias); ("to_alias", `String to_alias); ("content", `String decrypted) ] in
    let base = if deferrable then base @ [("deferrable", `Bool true)] else base in
    let base = match enc_status with None -> base | Some es -> base @ [("enc_status", `String es)] in
    `Assoc base
  in
  let content = `List (List.map process_msg messages) |> Yojson.Safe.to_string in
  Lwt.return (tool_ok content))
  end

let peek_inbox ~broker ~session_id_override ~arguments:_ =
  (* Like poll_inbox but does not drain. Resolves session_id from
     env only (ignores argument overrides) — same isolation contract
     as `history` and `my_rooms`. *)
  (match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
   | None ->
       Lwt.return
         (tool_result
            ~content:"peek_inbox: no session_id in env (set C2C_MCP_SESSION_ID)"
            ~is_error:true)
   | Some session_id ->
       Broker.touch_session broker ~session_id;
       let messages =
         Broker.with_inbox_lock broker ~session_id (fun () ->
             Broker.read_inbox broker ~session_id)
       in
       let content =
         `List
           (List.map
              (fun ({ from_alias; to_alias; content; deferrable } : message) ->
                let base =
                  [ ("from_alias", `String from_alias)
                  ; ("to_alias", `String to_alias)
                  ; ("content", `String content)
                  ]
                in
                `Assoc (if deferrable then base @ [("deferrable", `Bool true)] else base))
              messages)
         |> Yojson.Safe.to_string
       in
       Lwt.return (tool_ok content))

let history ~broker ~session_id_override ~arguments =
  (* Deliberately bypass resolve_session_id — it would honor a
     session_id argument override, which would let the caller read
     any session's history. For `history`, the caller can only see
     their own archived messages, keyed by the MCP env session id.
     (Subagent-level isolation — preventing a forked child from
     inheriting the parent's env — is goal B, tracked separately in
     the archive-and-subagent-goals findings doc.) *)
  (match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
   | None ->
       Lwt.return
         (tool_result
            ~content:"history: no session_id in env (set C2C_MCP_SESSION_ID)"
            ~is_error:true)
   | Some session_id ->
       let limit =
         match Broker.int_opt_member "limit" arguments with
         | Some n -> n
         | None -> 50
       in
       let entries = Broker.read_archive broker ~session_id ~limit in
       let content =
         `List
           (List.map
              (fun ({ Broker.ae_drained_at
                    ; ae_from_alias
                    ; ae_to_alias
                    ; ae_content
                    ; ae_deferrable = _
                    } : Broker.archive_entry) ->
                `Assoc
                  [ ("drained_at", `Float ae_drained_at)
                  ; ("from_alias", `String ae_from_alias)
                  ; ("to_alias", `String ae_to_alias)
                  ; ("content", `String ae_content)
                  ])
              entries)
         |> Yojson.Safe.to_string
       in
       Lwt.return (tool_ok content))

let tail_log ~broker ~session_id_override:_ ~arguments =
  let limit =
    match Broker.int_opt_member "limit" arguments with
    | Some n when n < 1 -> 1
    | Some n -> min n 500
    | None -> 50
  in
  let log_path = Filename.concat (Broker.root broker) "broker.log" in
  let content =
    if not (Sys.file_exists log_path) then "[]"
    else begin
      (* Read all lines, take last `limit`, parse each as JSON *)
      let lines =
        let ic = open_in log_path in
        Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
          let buf = Buffer.create 4096 in
          (try while true do
               let line = String.trim (input_line ic) in
               if line <> "" then begin
                 Buffer.add_string buf line;
                 Buffer.add_char buf '\n'
               end
             done with End_of_file -> ());
          String.split_on_char '\n' (Buffer.contents buf)
          |> List.filter (fun s -> String.trim s <> ""))
      in
      let n = List.length lines in
      let tail = if n <= limit then lines
                 else
                   let drop = n - limit in
                   let rec skip i = function
                     | [] -> []
                     | _ :: rest when i > 0 -> skip (i - 1) rest
                     | lst -> lst
                   in
                   skip drop lines
      in
      let parsed =
        List.filter_map
          (fun line ->
            try Some (Yojson.Safe.from_string line)
            with _ -> None)
          tail
      in
      `List parsed |> Yojson.Safe.to_string
    end
  in
  Lwt.return (tool_ok content)

let server_info ~broker:_ ~session_id_override:_ ~arguments:_ =
  let content = Yojson.Safe.to_string (server_info ()) in
  Lwt.return (tool_ok content)

let sweep ~broker ~session_id_override:_ ~arguments:_ =
  let { Broker.dropped_regs; deleted_inboxes; preserved_messages } =
    Broker.sweep broker
  in
  let dead_sids =
    List.map (fun r -> r.session_id) dropped_regs
  in
  let dead_aliases =
    List.map (fun r -> r.alias) dropped_regs
  in
  let evicted_room_members =
    Broker.evict_dead_from_rooms broker ~dead_session_ids:dead_sids
      ~dead_aliases
  in
  let content =
    `Assoc
      [ ( "dropped_regs",
          `List
            (List.map
               (fun { session_id; alias; _ } ->
                 `Assoc
                   [ ("session_id", `String session_id)
                   ; ("alias", `String alias)
                   ])
               dropped_regs) )
      ; ( "deleted_inboxes",
          `List (List.map (fun sid -> `String sid) deleted_inboxes) )
      ; ("preserved_messages", `Int preserved_messages)
      ; ( "evicted_room_members",
          `List
            (List.map
               (fun (room_id, alias) ->
                 `Assoc
                   [ ("room_id", `String room_id)
                   ; ("alias", `String alias)
                   ])
               evicted_room_members) )
      ]
    |> Yojson.Safe.to_string
  in
  Lwt.return (tool_ok content)
