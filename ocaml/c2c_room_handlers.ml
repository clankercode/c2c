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

(** Resolve the caller's session_id and registered alias for a room operation.
    Shared by list_rooms, room_history, send_room_invite, and set_room_visibility.
    The session_id_override wins if provided; otherwise falls back to the
    current session from the broker's request context. *)
let resolve_caller_identity ~broker ~session_id_override =
  let caller_session_id =
    match session_id_override with
    | Some s -> Some s
    | None -> current_session_id ()
  in
  let caller_alias = current_registered_alias ?session_id_override broker in
  (caller_session_id, caller_alias)

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
            let result =
              try
                Ok (Broker.send_room ?tag:parsed_tag broker ~from_alias ~room_id ~content)
              with Invalid_argument msg ->
                Error msg
            in
            match result with
            | Error msg ->
                Lwt.return (tool_err ("send_room failed: " ^ msg))
            | Ok { Broker.sr_delivered_to; sr_skipped; sr_ts; sr_warning } ->
                let result_fields =
                  [ ("delivered_to",
                     `List (List.map (fun a -> `String a) sr_delivered_to))
                  ; ("skipped",
                     `List (List.map (fun a -> `String a) sr_skipped))
                  ; ("ts", `Float sr_ts)
                  ]
                in
                let result_fields =
                  match sr_warning with
                  | Some w -> ("warning", `String w) :: result_fields
                  | None -> result_fields
                in
                let result_json = `Assoc result_fields |> Yojson.Safe.to_string in
                Lwt.return (tool_ok result_json)))))

let list_rooms ~broker ~session_id_override ~arguments:_ =
  let rooms = Broker.list_rooms broker in
  (* H2 rooms-acl: filter rooms the caller can't see (4-level model).
     - Public: include as-is (listed to everyone).
     - Unlisted: hidden from non-members. Member -> include as-is; non-member
       -> exclude entirely (still joinable by name, just not discoverable).
     - Gated: LISTED to everyone for discovery. Member -> include as-is;
       non-member -> include but redact the roster (members/details/invited/
       counts) so room_id + member_count remain visible but the membership is
       not leaked.
     - Private + caller is a member: include as-is.
     - Private + caller in invited_members but not yet joined: include but
       redact members/details/invited_members.
     - Private + caller unrelated: exclude entirely. *)
  let caller_session_id, caller_alias = resolve_caller_identity ~broker ~session_id_override in
  let filtered =
    List.filter_map
      (fun (r : Broker.room_info) ->
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
        let is_member = is_member_by_session || is_member_by_alias in
        let redacted_roster (r : Broker.room_info) : Broker.room_info =
          { r with
            ri_members = []
          ; ri_member_details = []
          ; ri_invited_members = []
          ; ri_alive_member_count = 0
          ; ri_dead_member_count = 0
          ; ri_unknown_member_count = 0
          }
        in
        match r.ri_visibility with
        | Public -> Some r
        | Unlisted -> if is_member then Some r else None
        | Gated ->
            (* Listed to everyone; roster redacted for non-members. *)
            if is_member then Some r else Some (redacted_roster r)
        | Private ->
            if is_member then Some r
            else
              let is_invited =
                match caller_alias with
                | None -> false
                | Some a -> List.mem a r.ri_invited_members
              in
              if is_invited then Some (redacted_roster r)
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
  (* H1 rooms-acl: gated and private rooms require caller membership to read
     history. Public and unlisted rooms have no read gate (open read). *)
  let meta = Broker.load_room_meta broker ~room_id in
  let is_member_read () =
    let caller_session_id, caller_alias = resolve_caller_identity ~broker ~session_id_override in
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
  let allow =
    match meta.visibility with
    | Public -> true
    (* Unlisted is hidden from list_rooms but not read-gated: anyone who knows
       the room id may read its history, same as a public room. *)
    | Unlisted -> true
    | Gated -> is_member_read ()
    | Private -> is_member_read ()
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
            try
              Broker.send_room_invite broker ~room_id ~from_alias ~invitee_alias;
              let content =
                `Assoc
                  [ ("ok", `Bool true)
                  ; ("room_id", `String room_id)
                  ; ("invitee_alias", `String invitee_alias)
                  ]
                |> Yojson.Safe.to_string
              in
              Lwt.return (tool_ok content)
            with Invalid_argument msg ->
              Lwt.return (tool_err msg))))

let room_knock_json (k : room_knock) =
  `Assoc
    [ ("requester_alias", `String k.requester_alias)
    ; ("requested_at", `Float k.requested_at)
    ]

let knock_room ~broker ~session_id_override ~arguments =
  let room_id = string_member "room_id" arguments in
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_member_alias_result "knock_room")
   | Some requester_alias ->
       (match send_alias_impersonation_check ?session_id_override:session_id_override broker requester_alias with
        | Some conflict ->
            Lwt.return
              (tool_result
                 ~content:
                   (Printf.sprintf
                      "knock_room rejected: alias '%s' is currently held by alive \
                       session '%s' — you cannot knock as another agent."
                      requester_alias conflict.session_id)
                 ~is_error:true)
        | None ->
            with_session_lwt ~session_id_override broker arguments (fun ~session_id:_ ->
            try
              let result =
                Broker.knock_room broker ~room_id ~requester_alias
              in
              let content =
                `Assoc
                  [ ("ok", `Bool true)
                  ; ("room_id", `String result.kr_room_id)
                  ; ("requester_alias", `String result.kr_requester_alias)
                  ; ("already_pending", `Bool result.kr_already_pending)
                  ; ( "notified",
                      `List
                        (List.map (fun a -> `String a) result.kr_notified) )
                  ]
                |> Yojson.Safe.to_string
              in
              Lwt.return (tool_ok content)
            with Invalid_argument msg ->
              Lwt.return (tool_err msg))))

let list_room_knocks ~broker ~session_id_override ~arguments =
  let room_id = string_member "room_id" arguments in
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_member_alias_result "list_room_knocks")
   | Some caller_alias ->
       (match send_alias_impersonation_check ?session_id_override:session_id_override broker caller_alias with
        | Some conflict ->
            Lwt.return
              (tool_result
                 ~content:
                   (Printf.sprintf
                      "list_room_knocks rejected: alias '%s' is currently held \
                       by alive session '%s' — you cannot list knocks as \
                       another agent."
                      caller_alias conflict.session_id)
                 ~is_error:true)
        | None ->
            with_session_lwt ~session_id_override broker arguments (fun ~session_id:_ ->
            try
              let knocks =
                Broker.list_room_knocks broker ~room_id ~caller_alias
              in
              let content =
                `List (List.map room_knock_json knocks)
                |> Yojson.Safe.to_string
              in
              Lwt.return (tool_ok content)
            with Invalid_argument msg ->
              Lwt.return (tool_err msg))))

let approve_room_knock ~broker ~session_id_override ~arguments =
  let room_id = string_member "room_id" arguments in
  let requester_alias = string_member "requester_alias" arguments in
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_member_alias_result "approve_room_knock")
   | Some approver_alias ->
       (match send_alias_impersonation_check ?session_id_override:session_id_override broker approver_alias with
        | Some conflict ->
            Lwt.return
              (tool_result
                 ~content:
                   (Printf.sprintf
                      "approve_room_knock rejected: alias '%s' is currently held \
                       by alive session '%s' — you cannot approve knocks as \
                       another agent."
                      approver_alias conflict.session_id)
                 ~is_error:true)
        | None ->
            with_session_lwt ~session_id_override broker arguments (fun ~session_id:_ ->
            try
              Broker.approve_room_knock broker ~room_id ~approver_alias
                ~requester_alias;
              let content =
                `Assoc
                  [ ("ok", `Bool true)
                  ; ("room_id", `String room_id)
                  ; ("requester_alias", `String requester_alias)
                  ; ("approved", `Bool true)
                  ]
                |> Yojson.Safe.to_string
              in
              Lwt.return (tool_ok content)
            with Invalid_argument msg ->
              Lwt.return (tool_err msg))))

let deny_room_knock ~broker ~session_id_override ~arguments =
  let room_id = string_member "room_id" arguments in
  let requester_alias = string_member "requester_alias" arguments in
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_member_alias_result "deny_room_knock")
   | Some denier_alias ->
       (match send_alias_impersonation_check ?session_id_override:session_id_override broker denier_alias with
        | Some conflict ->
            Lwt.return
              (tool_result
                 ~content:
                   (Printf.sprintf
                      "deny_room_knock rejected: alias '%s' is currently held by \
                       alive session '%s' — you cannot deny knocks as another \
                       agent."
                      denier_alias conflict.session_id)
                 ~is_error:true)
        | None ->
            with_session_lwt ~session_id_override broker arguments (fun ~session_id:_ ->
            try
              Broker.deny_room_knock broker ~room_id ~denier_alias
                ~requester_alias;
              let content =
                `Assoc
                  [ ("ok", `Bool true)
                  ; ("room_id", `String room_id)
                  ; ("requester_alias", `String requester_alias)
                  ; ("denied", `Bool true)
                  ]
                |> Yojson.Safe.to_string
              in
              Lwt.return (tool_ok content)
            with Invalid_argument msg ->
              Lwt.return (tool_err msg))))

let set_room_visibility ~broker ~session_id_override ~arguments =
  let room_id = string_member "room_id" arguments in
  let visibility_str = string_member "visibility" arguments in
  match
    (match visibility_str with
     | "public" -> Some Public
     | "unlisted" -> Some Unlisted
     | "gated" -> Some Gated
     | "private" -> Some Private
     | _ -> None)
  with
  | None ->
      (* Reject unknown tokens (matching the CLI and relay) rather than
         silently defaulting to Public — a silent default could turn an
         intended-restricted room public. *)
      Lwt.return
        (tool_err
           (Printf.sprintf
              "set_room_visibility rejected: unknown visibility '%s'. Use 'public', \
               'unlisted', 'gated', or 'private'."
              visibility_str))
  | Some visibility ->
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
                    | Unlisted -> `String "unlisted"
                    | Gated -> `String "gated"
                    | Private -> `String "private")
                ]
              |> Yojson.Safe.to_string
             in
             Lwt.return (tool_ok content))))
