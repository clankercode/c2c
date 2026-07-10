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

(* J4: canonical schema-v1 message objects on the MCP inbox surfaces.
   Room fan-out rows are recognised by the established broker convention
   of tagging [to_alias] as "<alias>#<room_id>" (Broker.fan_out_room_message,
   relay.ml). Classification delegates to [is_room_recipient] — the same
   canonical helper [format_reply_hint] uses — so a "<alias>#<12hexhash>"
   relay host-hash form is a DM, never a room. *)
let msg_type_of_to_alias to_alias : C2c_schema_v1.msg_type =
  if is_room_recipient ~to_alias then C2c_schema_v1.Room else C2c_schema_v1.Dm

(* Build one inbox row: canonical v1 document + legacy compatibility keys.
   [content] is passed explicitly because poll decrypts while peek returns
   the raw wire content. [source] is deliberately omitted — the broker
   inbox record carries no reliable transport-origin marker today (local
   enqueue also assigns message_id), so we do not claim one. *)
let inbox_row_json ~(m : message) ~(content : string) ~(delivery_state : C2c_schema_v1.delivery_state)
    ~(enc_status : string option) : Yojson.Safe.t =
  let v1 : C2c_schema_v1.t =
    { schema_version = C2c_schema_v1.schema_version
    ; msg_type = msg_type_of_to_alias m.to_alias
    ; message_id = m.message_id
    ; ts = Some m.ts
    ; from = { alias = m.from_alias; host_id = None; address = None }
    ; to_ = m.to_alias
    ; source = None
    ; content
    ; in_reply_to = None
    ; delivery_state = Some delivery_state
    }
  in
  let legacy = [ ("from_alias", `String m.from_alias); ("to_alias", `String m.to_alias) ] in
  let legacy = if m.deferrable then legacy @ [ ("deferrable", `Bool true) ] else legacy in
  let legacy = match enc_status with None -> legacy | Some es -> legacy @ [ ("enc_status", `String es) ] in
  C2c_schema_v1.serialize_with_legacy v1 ~legacy

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
  let process_msg (m : message) =
    (* [#432 §7] Inline decrypt block extracted to [decrypt_envelope]
       helper above; this site is the status-tracking call site (the
       push site discards _enc_status). Both formerly-duplicated
       blocks now share one definition.
       J4: rows are canonical schema-v1 documents (delivery.state =
       delivered — poll drains, i.e. hands the message to the recipient)
       with the legacy {from_alias,to_alias,content,deferrable?,enc_status?}
       keys preserved alongside. *)
    let (decrypted, enc_status) =
      decrypt_envelope ~our_x25519 ~our_ed25519 ~to_alias:m.to_alias ~content:m.content
    in
    inbox_row_json ~m ~content:decrypted ~delivery_state:C2c_schema_v1.Delivered ~enc_status
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
       (* J4: same canonical schema-v1 row shape as poll_inbox, except
          content is the raw wire content (peek does not decrypt) and
          delivery.state = queued (the message is still in the inbox). *)
       let content =
         `List
           (List.map
              (fun (m : message) ->
                inbox_row_json ~m ~content:m.content
                  ~delivery_state:C2c_schema_v1.Queued ~enc_status:None)
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
