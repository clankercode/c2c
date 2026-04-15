[@@@warning "-33-16-32-26"]
(* relay_server.ml — native OCaml HTTP relay server using Cohttp_lwt_unix *)

open Lwt.Infix

module Relay_server : sig
  val make_callback :
    Relay.InMemoryRelay.t ->
    string option ->
    Conduit_lwt_unix.flow ->
    Cohttp.Request.t ->
    Cohttp_lwt.Body.t ->
    (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t

  val start_server :
    host:string ->
    port:int ->
    token:string option ->
    ?verbose:bool ->
    ?gc_interval:float ->
    unit ->
    unit Lwt.t
end = struct

  (* Error codes *)
  let err_bad_request = "bad_request"
  let err_unauthorized = "unauthorized"
  let err_not_found = "not_found"
  let err_internal_error = "internal_error"

  (* Relay error codes pass-through *)
  let relay_err_unknown_alias = "unknown_alias"
  let relay_err_alias_conflict = "alias_conflict"
  let relay_err_recipient_dead = "recipient_dead"

  (* --- JSON helpers --- *)

  let json_ok ?(ok=true) ?(error_code=None) ?(error_msg=None) fields =
    let base = ("ok", `Bool ok) :: fields in
    let base = match error_code with Some ec -> ("error_code", `String ec) :: base | None -> base in
    let base = match error_msg with Some em -> ("error", `String em) :: base | None -> base in
    `Assoc base

  let json_error ?(ok=false) error_code error_msg fields =
    `Assoc (("ok", `Bool ok) :: ("error_code", `String error_code) :: ("error", `String error_msg) :: fields)

  let json_error_str error_code msg =
    json_error error_code msg []

  let json_of_result = function
    | `Ok v -> json_ok [ ("result", v) ]
    | `Duplicate ts -> json_ok [ ("result", `String "duplicate"); ("ts", `Float ts) ]
    | `Error (code, msg) -> json_error code msg []

  let json_of_register_result (status, lease) =
    if status = "ok" then
      json_ok [ ("result", `String status); ("lease", Relay.RegistrationLease.to_json lease) ]
    else
      json_error status (Printf.sprintf "alias conflict with existing lease") [ ("existing_lease", Relay.RegistrationLease.to_json lease) ]

  let json_of_heartbeat_result (status, lease) =
    if status = "ok" then
      json_ok [ ("result", `String status); ("lease", Relay.RegistrationLease.to_json lease) ]
    else
      json_error status "unknown node" [ ("lease", Relay.RegistrationLease.to_json lease) ]

  let json_of_send_result = function
    | `Ok ts -> json_ok [ ("result", `String "ok"); ("ts", `Float ts) ]
    | `Duplicate ts -> json_ok [ ("result", `String "duplicate"); ("ts", `Float ts) ]
    | `Error (code, msg) -> json_error code msg []

  let json_of_send_all_result (ts, delivered, skipped) =
    json_ok [
      ("result", `String "ok");
      ("ts", `Float ts);
      ("delivered", `List (List.map (fun a -> `String a) delivered));
      ("skipped", `List (List.map (fun a -> `String a) skipped));
    ]

  let json_of_send_room_result (ts, delivered, skipped) =
    json_ok [
      ("result", `String "ok");
      ("ts", `Float ts);
      ("delivered", `List (List.map (fun a -> `String a) delivered));
      ("skipped", `List (List.map (fun a -> `String a) skipped));
    ]

  let json_of_room_join_result = function
    | `Ok -> json_ok [ ("result", `String "ok") ]
    | `Error (code, msg) -> json_error code msg []

  let json_of_gc_result (expired, pruned) =
    json_ok [
      ("expired", `List (List.map (fun a -> `String a) expired));
      ("pruned", `Int pruned);
    ]

  (* --- Auth helpers --- *)

  let check_auth token auth_header =
    match token with
    | None -> true
    | Some t ->
      match auth_header with
      | None -> false
      | Some h ->
        (match String.split_on_char ' ' h with
         | ["Bearer"; token'] -> token' = t
         | _ -> false)

  (* --- Request body parsing --- *)

  let read_json_body body =
    Cohttp_lwt.Body.to_string body >|= fun body_str ->
    try Ok (Yojson.Safe.from_string body_str)
    with Yojson.Json_error msg -> Error msg

  let require_field json field =
    match Yojson.Safe.Util.member field json with
    | `Null -> Error (Printf.sprintf "missing required field: %s" field)
    | v -> Ok (Yojson.Safe.to_string v)

  let opt_field json field convert =
    match Yojson.Safe.Util.member field json with
    | `Null -> Ok None
    | v ->
      try Ok (Some (convert v))
      with Failure msg -> Error (Printf.sprintf "invalid %s: %s" field msg)

  let get_string json field =
    Yojson.Safe.Util.to_string_option (Yojson.Safe.Util.member field json)
    |> Option.value ~default:""

  let get_opt_string json field =
    Yojson.Safe.Util.to_string_option (Yojson.Safe.Util.member field json)

  let get_int json field default =
    Yojson.Safe.Util.to_int_option (Yojson.Safe.Util.member field json)
    |> Option.value ~default

  (* --- Response helpers --- *)

  let respond_json ~status body =
    let body_str = Yojson.Safe.to_string body in
    Cohttp_lwt_unix.Server.respond_string
      ~status
      ~headers:(Cohttp.Header.of_list [("Content-Type", "application/json")])
      ~body:body_str
      ()

  let respond_ok body = respond_json ~status:`OK body
  let respond_bad_request body = respond_json ~status:`Bad_request body
  let respond_unauthorized body = respond_json ~status:`Unauthorized body
  let respond_not_found body = respond_json ~status:`Not_found body
  let respond_conflict body = respond_json ~status:`Conflict body
  let respond_internal_error body = respond_json ~status:`Internal_server_error body

  (* --- Route handlers --- *)

  let handle_health () =
    respond_ok (json_ok [])

  let handle_list relay =
    let peers = Relay.InMemoryRelay.list_peers relay ~include_dead:false |> List.map Relay.RegistrationLease.to_json in
    respond_ok (json_ok [ ("peers", `List peers) ])

  let handle_dead_letter relay =
    let dl = Relay.InMemoryRelay.dead_letter relay in
    respond_ok (json_ok [ ("dead_letter", `List dl) ])

  let handle_list_rooms relay =
    let rooms = Relay.InMemoryRelay.list_rooms relay in
    respond_ok (json_ok [ ("rooms", `List rooms) ])

  let handle_gc relay =
    match Relay.InMemoryRelay.gc relay with
    | `Ok (expired, pruned) -> respond_ok (json_of_gc_result (expired, pruned))

  let handle_register relay body =
    let node_id = get_string body "node_id" in
    let session_id = get_string body "session_id" in
    let alias = get_string body "alias" in
    if node_id = "" || session_id = "" || alias = "" then
      respond_bad_request (json_error_str err_bad_request "node_id, session_id, and alias are required")
    else
      let client_type = get_opt_string body "client_type" |> Option.value ~default:"unknown" in
      let ttl = float_of_int (get_int body "ttl" 300) in
      let result = Relay.InMemoryRelay.register relay ~node_id ~session_id ~alias ~client_type ~ttl in
      respond_ok (json_of_register_result result)

  let handle_heartbeat relay body =
    let node_id = get_string body "node_id" in
    let session_id = get_string body "session_id" in
    if node_id = "" || session_id = "" then
      respond_bad_request (json_error_str err_bad_request "node_id and session_id are required")
    else
      let result = Relay.InMemoryRelay.heartbeat relay ~node_id ~session_id in
      respond_ok (json_of_heartbeat_result result)

  let handle_send relay body =
    let from_alias = get_string body "from_alias" in
    let to_alias = get_string body "to_alias" in
    let content = get_string body "content" in
    if from_alias = "" || to_alias = "" || content = "" then
      respond_bad_request (json_error_str err_bad_request "from_alias, to_alias, and content are required")
    else
      let message_id = get_opt_string body "message_id" in
      let result = Relay.InMemoryRelay.send relay ~from_alias ~to_alias ~content ~message_id in
      respond_ok (json_of_send_result result)

  let handle_send_all relay body =
    let from_alias = get_string body "from_alias" in
    let content = get_string body "content" in
    if from_alias = "" || content = "" then
      respond_bad_request (json_error_str err_bad_request "from_alias and content are required")
    else
      let message_id = get_opt_string body "message_id" in
      match Relay.InMemoryRelay.send_all relay ~from_alias ~content ~message_id with
      | `Ok (ts, delivered, skipped) -> respond_ok (json_of_send_all_result (ts, delivered, skipped))

  let handle_poll_inbox relay body =
    let node_id = get_string body "node_id" in
    let session_id = get_string body "session_id" in
    if node_id = "" || session_id = "" then
      respond_bad_request (json_error_str err_bad_request "node_id and session_id are required")
    else
      let msgs = Relay.InMemoryRelay.poll_inbox relay ~node_id ~session_id in
      respond_ok (json_ok [ ("messages", `List msgs) ])

  let handle_peek_inbox relay body =
    let node_id = get_string body "node_id" in
    let session_id = get_string body "session_id" in
    if node_id = "" || session_id = "" then
      respond_bad_request (json_error_str err_bad_request "node_id and session_id are required")
    else
      let msgs = Relay.InMemoryRelay.peek_inbox relay ~node_id ~session_id in
      respond_ok (json_ok [ ("messages", `List msgs) ])

  let handle_join_room relay body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    if alias = "" || room_id = "" then
      respond_bad_request (json_error_str err_bad_request "alias and room_id are required")
    else
      let result = Relay.InMemoryRelay.join_room relay ~alias ~room_id in
      respond_ok (match result with
        | `Ok -> json_of_room_join_result `Ok
        | `Error (code, msg) -> json_error code msg [])

  let handle_leave_room relay body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    if alias = "" || room_id = "" then
      respond_bad_request (json_error_str err_bad_request "alias and room_id are required")
    else
      let result = Relay.InMemoryRelay.leave_room relay ~alias ~room_id in
      respond_ok (json_of_room_join_result result)

  and handle_send_room relay body =
    let from_alias = get_string body "from_alias" in
    let room_id = get_string body "room_id" in
    let content = get_string body "content" in
    if from_alias = "" || room_id = "" || content = "" then
      respond_bad_request (json_error_str err_bad_request "from_alias, room_id, and content are required")
    else
      let message_id = get_opt_string body "message_id" in
      match Relay.InMemoryRelay.send_room relay ~from_alias ~room_id ~content ~message_id with
      | `Ok (ts, delivered, skipped) -> respond_ok (json_of_send_room_result (ts, delivered, skipped))

  let handle_room_history relay body =
    let room_id = get_string body "room_id" in
    if room_id = "" then
      respond_bad_request (json_error_str err_bad_request "room_id is required")
    else
      let limit = get_int body "limit" 50 in
      let history = Relay.InMemoryRelay.room_history relay ~room_id ~limit in
      respond_ok (json_ok [ ("room_id", `String room_id); ("history", `List history) ])

  (* --- Main callback factory --- *)

  let make_callback relay token _conn req body =
    let open Cohttp in
    let open Cohttp_lwt_unix in
    let path = Uri.path (Request.uri req) in
    let meth = Request.meth req in
    let auth_header = Header.get (Request.headers req) "Authorization" in

    (* Auth check for protected routes *)
    let protected = not (List.mem path ["/health"]) in
    if protected && not (check_auth token auth_header) then
      respond_unauthorized (json_error_str err_unauthorized "missing or invalid Bearer token")
    else
      match meth, path with
      | `GET, "/health" ->
        handle_health ()

      | `GET, "/list" ->
        handle_list relay

      | `GET, "/dead_letter" ->
        handle_dead_letter relay

      | `GET, "/list_rooms" ->
        handle_list_rooms relay

      | `GET, "/gc" ->
        handle_gc relay

      | `POST, "/register" ->
        read_json_body body >>= fun json ->
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_register relay j)

      | `POST, "/heartbeat" ->
        read_json_body body >>= fun json ->
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_heartbeat relay j)

      | `POST, "/send" ->
        read_json_body body >>= fun json ->
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_send relay j)

      | `POST, "/send_all" ->
        read_json_body body >>= fun json ->
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_send_all relay j)

      | `POST, "/poll_inbox" ->
        read_json_body body >>= fun json ->
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_poll_inbox relay j)

      | `POST, "/peek_inbox" ->
        read_json_body body >>= fun json ->
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_peek_inbox relay j)

      | `POST, "/join_room" ->
        read_json_body body >>= fun json ->
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_join_room relay j)

      | `POST, "/leave_room" ->
        read_json_body body >>= fun json ->
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_leave_room relay j)

      | `POST, "/send_room" ->
        read_json_body body >>= fun json ->
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_send_room relay j)

      | `POST, "/room_history" ->
        read_json_body body >>= fun json ->
        (match json with
         | Error msg -> respond_bad_request (json_error_str err_bad_request ("invalid JSON: " ^ msg))
         | Ok j -> handle_room_history relay j)

      | _ ->
        respond_not_found (json_error_str err_not_found ("unknown endpoint: " ^ path))

  (* --- GC thread loop --- *)

  let rec gc_loop relay gc_interval =
    Lwt_unix.sleep gc_interval >>= fun () ->
    (try ignore (Relay.InMemoryRelay.gc relay :> _) with
     | _ -> ());
    gc_loop relay gc_interval

  (* --- Server startup --- *)

  let start_server ~host ~port ~token ?(verbose=false) ?(gc_interval=0.0) () =
    let relay = Relay.InMemoryRelay.create () in
    let callback = make_callback relay token in
    let gc_thread =
      if gc_interval > 0.0 then
        Lwt.async (fun () -> gc_loop relay gc_interval)
      else
        ()
    in
    let verbose_str = if verbose then " (verbose)" else "" in
    Printf.printf "c2c relay serving on http://%s:%d%s\n%!" host port verbose_str;
    (match token with
     | Some _ -> Printf.printf "auth: Bearer token required\n%!"
     | None -> Printf.printf "auth: DISABLED (no token set — do not expose publicly)\n%!");
    if gc_interval > 0.0 then
      Printf.printf "gc: running every %.0fs\n%!" gc_interval
    else
      Printf.printf "gc: disabled\n%!";
    let spec = Cohttp_lwt_unix.Server.make ~callback () in
    Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) spec

end
