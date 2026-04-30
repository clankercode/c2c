(* #450 Slice 2: Rooms handler cluster hoisted out of [c2c_mcp.ml]'s
   [handle_tool_call]. Each room-related tool branch is now a top-level
   function here; [handle_tool_call] dispatches one-line into the
   corresponding [C2c_room_handlers.X] entrypoint.

   Mechanical move — no behavior change. The bodies are byte-for-byte
   identical to the original arms with free locals lifted into named
   parameters ([broker], [session_id_override], [arguments]). *)

open C2c_mcp_helpers
open C2c_mcp_helpers_post_broker
module Broker = C2c_broker

let prune_rooms ~broker ~session_id_override:_ ~arguments:_ =
  let evicted = Broker.prune_rooms broker in
  let content =
    `Assoc
      [ ( "evicted_room_members",
          `List
            (List.map
               (fun (room_id, alias) ->
                 `Assoc
                   [ ("room_id", `String room_id)
                   ; ("alias", `String alias)
                   ])
               evicted) )
      ]
    |> Yojson.Safe.to_string
  in
  Lwt.return (tool_ok content)

let join_room ~broker ~session_id_override ~arguments =
  let room_id = string_member "room_id" arguments in
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_member_alias_result "join_room")
   | Some alias ->
       with_session_lwt ~session_id_override broker arguments (fun ~session_id ->
       let members = Broker.join_room broker ~room_id ~alias ~session_id in
       let history_limit =
         match Broker.int_opt_member "history_limit" arguments with
         | Some n when n < 0 -> 0
         | Some n -> min n 200
         | None -> 20
       in
       let history =
         if history_limit = 0 then []
         else Broker.read_room_history broker ~room_id ~limit:history_limit ()
       in
       let content =
         `Assoc
           [ ("room_id", `String room_id)
           ; ("members",
              `List (List.map (fun (m : room_member) ->
                  `Assoc
                    [ ("alias", `String m.rm_alias)
                    ; ("session_id", `String m.rm_session_id)
                    ; ("joined_at", `Float m.joined_at)
                    ]) members))
           ; ("history",
              `List (List.map (fun (m : room_message) ->
                  `Assoc
                    [ ("ts", `Float m.rm_ts)
                    ; ("from_alias", `String m.rm_from_alias)
                    ; ("content", `String m.rm_content)
                    ]) history))
           ]
         |> Yojson.Safe.to_string
       in
       Lwt.return (tool_ok content)))

let leave_room ~broker ~session_id_override ~arguments =
  let room_id = string_member "room_id" arguments in
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_member_alias_result "leave_room")
   | Some alias ->
       (* #432: impersonation guard — sibling room handlers (send_room,
          send_room_invite, set_room_visibility) all reject when the
          supplied alias belongs to a different alive session. leave_room
          previously skipped this check, letting an unregistered caller
          evict any member by aliasing in. *)
       (match send_alias_impersonation_check ?session_id_override:session_id_override broker alias with
        | Some conflict ->
            Lwt.return
              (tool_result
                 ~content:
                   (Printf.sprintf
                      "leave_room rejected: alias '%s' is currently held by \
                       alive session '%s' — you cannot leave a room as another \
                       agent."
                      alias conflict.session_id)
                 ~is_error:true)
        | None ->
       with_session_lwt ~session_id_override broker arguments (fun ~session_id:_ ->
       let members = Broker.leave_room broker ~room_id ~alias in
       let content =
         `Assoc
           [ ("room_id", `String room_id)
           ; ("members",
              `List (List.map (fun (m : room_member) ->
                  `Assoc
                    [ ("alias", `String m.rm_alias)
                    ; ("session_id", `String m.rm_session_id)
                    ; ("joined_at", `Float m.joined_at)
                    ]) members))
           ]
         |> Yojson.Safe.to_string
       in
       Lwt.return (tool_ok content))))

let delete_room ~broker ~session_id_override ~arguments =
  let room_id = string_member "room_id" arguments in
  let force =
    match Yojson.Safe.Util.member "force" arguments with
    | `Bool b -> b
    | _ -> false
  in
  let caller_alias =
    match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
    | Some a -> a
    | None -> ""
  in
  (* #432: impersonation guard — sibling room-mutation handlers
     (send_room, send_room_invite, set_room_visibility) reject when the
     supplied alias belongs to a different alive session. delete_room
     previously skipped this check despite calling Broker.delete_room
     with caller_alias as the ACL principal. *)
  (match send_alias_impersonation_check ?session_id_override:session_id_override broker caller_alias with
   | Some conflict ->
       Lwt.return
         (tool_result
            ~content:
              (Printf.sprintf
                 "delete_room rejected: caller_alias '%s' is currently held by \
                  alive session '%s' — you cannot delete a room as another \
                  agent."
                 caller_alias conflict.session_id)
            ~is_error:true)
   | None ->
  (try
     Broker.delete_room broker ~room_id ~caller_alias ~force ();
     let content =
       `Assoc [ ("room_id", `String room_id); ("deleted", `Bool true) ]
       |> Yojson.Safe.to_string
     in
     Lwt.return (tool_ok content)
   with Invalid_argument msg ->
     let content = `Assoc [ ("error", `String msg) ] |> Yojson.Safe.to_string in
     Lwt.return (tool_err content)))

let send_room ~broker ~session_id_override ~arguments =
  let room_id = string_member "room_id" arguments in
  let content = string_member "content" arguments in
  (* #392 slice 4: optional tag arg. parse_send_tag normalizes
     None / "" → Ok None and validates known values. *)
  let raw_tag =
    match Yojson.Safe.Util.member "tag" arguments with
    | `String s -> Some s
    | _ -> None
  in
  (match parse_send_tag raw_tag with
   | Error msg ->
       Lwt.return (tool_err msg)
   | Ok parsed_tag ->
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_sender_alias_result "send_room")
   | Some from_alias ->
       (match send_alias_impersonation_check ?session_id_override:session_id_override broker from_alias with
        | Some conflict ->
            Lwt.return
              (tool_result
                 ~content:
                   (Printf.sprintf
                      "send_room rejected: from_alias '%s' is currently held by \
                       alive session '%s' — you cannot post to a room as another \
                       agent. Options: (1) register your own alias first — call \
                       register with {\"alias\":\"<new-name>\"}, \
                       (2) call whoami to see your current identity."
                      from_alias conflict.session_id)
                 ~is_error:true)
        | None ->
            with_session_lwt ~session_id_override broker arguments (fun ~session_id:_ ->
            let { Broker.sr_delivered_to; sr_skipped; sr_ts } =
              Broker.send_room ?tag:parsed_tag broker ~from_alias ~room_id ~content
            in
            let result_json =
              `Assoc
                [ ("delivered_to",
                   `List (List.map (fun a -> `String a) sr_delivered_to))
                ; ("skipped",
                   `List (List.map (fun a -> `String a) sr_skipped))
                ; ("ts", `Float sr_ts)
                ]
              |> Yojson.Safe.to_string
            in
            Lwt.return (tool_ok result_json)))))

let list_rooms ~broker ~session_id_override ~arguments:_ =
  let rooms = Broker.list_rooms broker in
  (* H2 rooms-acl: filter invite-only rooms the caller can't see.
     - Public: include as-is.
     - Invite_only + caller is a member: include as-is.
     - Invite_only + caller in invited_members but not yet joined:
       include but redact members/details/invited_members.
     - Invite_only + caller unrelated: exclude entirely. *)
  let caller_session_id =
    match session_id_override with
    | Some s -> Some s
    | None -> current_session_id ()
  in
  let caller_alias = current_registered_alias ?session_id_override:session_id_override broker in
  let filtered =
    List.filter_map
      (fun (r : Broker.room_info) ->
        match r.ri_visibility with
        | Public -> Some r
        | Invite_only ->
            let is_member_by_session =
              match caller_session_id with
              | None -> false
              | Some sid ->
                  List.exists (fun (d : Broker.room_member_info) -> d.rmi_session_id = sid) r.ri_member_details
            in
            let is_member_by_alias =
              match caller_alias with
              | None -> false
              | Some a -> List.mem a r.ri_members
            in
            if is_member_by_session || is_member_by_alias then Some r
            else
              let is_invited =
                match caller_alias with
                | None -> false
                | Some a -> List.mem a r.ri_invited_members
              in
              if is_invited then
                Some
                  { r with
                    ri_members = []
                  ; ri_member_details = []
                  ; ri_invited_members = []
                  ; ri_alive_member_count = 0
                  ; ri_dead_member_count = 0
                  ; ri_unknown_member_count = 0
                  }
              else None)
      rooms
  in
  let content =
    `List
      (List.map room_info_json filtered)
    |> Yojson.Safe.to_string
  in
  Lwt.return (tool_ok content)

let my_rooms ~broker ~session_id_override ~arguments:_ =
  (* Always resolve session_id from env — same isolation contract
     as `history`. A subagent that inherits a parent session_id
     env would see the parent's rooms, which is acceptable today
     (goal B — subagent access tokens — is the follow-up slice
     that closes that gap). Argument-level override is ignored. *)
  (match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
   | None ->
       Lwt.return
         (tool_result
            ~content:"my_rooms: no session_id in env (set C2C_MCP_SESSION_ID)"
            ~is_error:true)
   | Some session_id ->
       let rooms = Broker.my_rooms broker ~session_id in
       let content =
         `List
           (List.map room_info_json rooms)
         |> Yojson.Safe.to_string
       in
       Lwt.return (tool_ok content))

let room_history ~broker ~session_id_override ~arguments =
  let room_id = string_member "room_id" arguments in
  let limit =
    match Broker.int_opt_member "limit" arguments with
    | Some n -> n
    | None -> 50
  in
  let since = Broker.float_opt_member "since" arguments |> Option.value ~default:0.0 in
  (* H1 rooms-acl: invite-only rooms require caller membership.
     Public rooms have no read gate (public contract). *)
  let meta = Broker.load_room_meta broker ~room_id in
  let allow =
    match meta.visibility with
    | Public -> true
    | Invite_only ->
        let caller_session_id =
          match session_id_override with
          | Some s -> Some s
          | None -> current_session_id ()
        in
        let caller_alias = current_registered_alias ?session_id_override:session_id_override broker in
        let members = Broker.read_room_members broker ~room_id in
        let by_session =
          match caller_session_id with
          | None -> false
          | Some sid -> List.exists (fun m -> m.rm_session_id = sid) members
        in
        let by_alias =
          match caller_alias with
          | None -> false
          | Some a -> List.exists (fun m -> m.rm_alias = a) members
        in
        by_session || by_alias
  in
  if not allow then
    let content =
      `Assoc [ ("error", `String ("not a member of " ^ room_id)) ]
      |> Yojson.Safe.to_string
    in
    Lwt.return (tool_err content)
  else
  let history = Broker.read_room_history broker ~room_id ~limit ~since () in
  let content =
    `List
      (List.map
         (fun (m : room_message) ->
           `Assoc
             [ ("ts", `Float m.rm_ts)
             ; ("from_alias", `String m.rm_from_alias)
             ; ("content", `String m.rm_content)
             ])
         history)
    |> Yojson.Safe.to_string
  in
  Lwt.return (tool_ok content)

let send_room_invite ~broker ~session_id_override ~arguments =
  let room_id = string_member "room_id" arguments in
  let invitee_alias = string_member "invitee_alias" arguments in
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_sender_alias_result "send_room_invite")
   | Some from_alias ->
       (match send_alias_impersonation_check ?session_id_override:session_id_override broker from_alias with
        | Some conflict ->
            Lwt.return
              (tool_result
                 ~content:
                   (Printf.sprintf
                      "send_room_invite rejected: from_alias '%s' is currently held by \
                       alive session '%s' — you cannot invite as another agent."
                      from_alias conflict.session_id)
                 ~is_error:true)
        | None ->
            with_session_lwt ~session_id_override broker arguments (fun ~session_id:_ ->
            Broker.send_room_invite broker ~room_id ~from_alias ~invitee_alias;
            let content =
              `Assoc
                [ ("ok", `Bool true)
                ; ("room_id", `String room_id)
                ; ("invitee_alias", `String invitee_alias)
                ]
              |> Yojson.Safe.to_string
            in
            Lwt.return (tool_ok content))))

let set_room_visibility ~broker ~session_id_override ~arguments =
  let room_id = string_member "room_id" arguments in
  let visibility_str = string_member "visibility" arguments in
  let visibility =
    match visibility_str with
    | "invite_only" -> Invite_only
    | _ -> Public
  in
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_sender_alias_result "set_room_visibility")
   | Some from_alias ->
       (match send_alias_impersonation_check ?session_id_override:session_id_override broker from_alias with
        | Some conflict ->
            Lwt.return
              (tool_result
                 ~content:
                   (Printf.sprintf
                      "set_room_visibility rejected: from_alias '%s' is currently held by \
                       alive session '%s' — you cannot change visibility as another agent."
                      from_alias conflict.session_id)
                 ~is_error:true)
         | None ->
             with_session_lwt ~session_id_override broker arguments (fun ~session_id:_ ->
             Broker.set_room_visibility broker ~room_id ~from_alias ~visibility;
             let content =
               `Assoc
                [ ("ok", `Bool true)
                ; ("room_id", `String room_id)
                ; ("visibility",
                    match visibility with
                    | Public -> `String "public"
                    | Invite_only -> `String "invite_only")
                ]
              |> Yojson.Safe.to_string
             in
             Lwt.return (tool_ok content))))
