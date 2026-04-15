[@@@warning "-33-16-32-26"]
(* relay.ml — native OCaml HTTP relay server using Cohttp_lwt_unix *)

open Lwt.Infix

(* Error codes *)
let relay_err_unknown_alias = "unknown_alias"
let relay_err_alias_conflict = "alias_conflict"
let relay_err_recipient_dead = "recipient_dead"
let room_system_alias = "c2c-system"
let room_join_content alias room_id = alias ^ " joined room " ^ room_id

(* --- RegistrationLease --- *)

module RegistrationLease : sig
  type t
  val make : node_id:string -> session_id:string -> alias:string -> ?client_type:string -> ?ttl:float -> unit -> t
  val is_alive : t -> bool
  val touch : t -> unit
  val to_json : t -> Yojson.Safe.t
  val node_id : t -> string
  val session_id : t -> string
  val alias : t -> string
end = struct
  type t = {
    node_id : string;
    session_id : string;
    alias : string;
    client_type : string;
    registered_at : float;
    mutable last_seen : float;
    ttl : float;
  }

  let make ~node_id ~session_id ~alias ?(client_type = "unknown") ?(ttl = 300.0) () =
    let now = Unix.gettimeofday () in
    { node_id; session_id; alias; client_type; registered_at = now; last_seen = now; ttl }

  let is_alive t =
    let now = Unix.gettimeofday () in
    (t.last_seen +. t.ttl) >= now

  let touch t =
    t.last_seen <- Unix.gettimeofday ()

  let to_json t =
    `Assoc [
      ("node_id", `String t.node_id);
      ("session_id", `String t.session_id);
      ("alias", `String t.alias);
      ("client_type", `String t.client_type);
      ("registered_at", `Float t.registered_at);
      ("last_seen", `Float t.last_seen);
      ("ttl", `Float t.ttl);
      ("alive", `Bool (is_alive t));
    ]

  let node_id t = t.node_id
  let session_id t = t.session_id
  let alias t = t.alias
end

(* --- InMemoryRelay --- *)

module InMemoryRelay : sig
  type t
  val create : ?dedup_window:int -> unit -> t
  val register : t -> node_id:string -> session_id:string -> alias:string -> ?client_type:string -> ?ttl:float -> (string * RegistrationLease.t)
  val heartbeat : t -> node_id:string -> session_id:string -> (string * RegistrationLease.t)
  val list_peers : t -> ?include_dead:bool -> RegistrationLease.t list
  val send : t -> from_alias:string -> to_alias:string -> content:string -> ?message_id:string option -> [> `Ok of float | `Duplicate of float | `Error of string * string]
  val poll_inbox : t -> node_id:string -> session_id:string -> Yojson.Safe.t list
  val peek_inbox : t -> node_id:string -> session_id:string -> Yojson.Safe.t list
  val send_all : t -> from_alias:string -> content:string -> ?message_id:string option -> [> `Ok of float * string list * string list]
  val join_room : t -> alias:string -> room_id:string -> [> `Ok | `Error of string * string]
  val leave_room : t -> alias:string -> room_id:string -> [> `Ok | `Error of string * string]
  val send_room : t -> from_alias:string -> room_id:string -> content:string -> ?message_id:string option -> [> `Ok of float * string list * string list]
  val room_history : t -> room_id:string -> ?limit:int -> Yojson.Safe.t list
  val gc : t -> [> `Ok of string list * int]
  val dead_letter : t -> Yojson.Safe.t list
  val list_rooms : t -> Yojson.Safe.t list
end = struct
  type t = {
    mutex : Mutex.t;
    leases : (string, RegistrationLease.t) Hashtbl.t;
    inboxes : ((string * string), Yojson.Safe.t list) Hashtbl.t;
    dead_letter : Yojson.Safe.t Queue.t;
    rooms : (string, string list) Hashtbl.t;
    room_history : (string, Yojson.Safe.t list) Hashtbl.t;
    seen_ids : (string, bool) Hashtbl.t;
    dedup_window : int;
    seen_ids_fifo : string Queue.t;
  }

  let create ?(dedup_window = 10000) () = {
    mutex = Mutex.create ();
    leases = Hashtbl.create 16;
    inboxes = Hashtbl.create 16;
    dead_letter = Queue.create ();
    rooms = Hashtbl.create 16;
    room_history = Hashtbl.create 16;
    seen_ids = Hashtbl.create 64;
    seen_ids_fifo = Queue.create ();
    dedup_window;
  }

  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

  let generate_uuid () =
    let random_hex n =
      let chars = "0123456789abcdef" in
      String.init n (fun _ -> chars.[Random.int 16])
    in
    Printf.sprintf "%s-%s-4%s-%s-%s"
      (random_hex 8) (random_hex 3) (random_hex 3) (random_hex 4) (random_hex 12)

  let record_message_id t msg_id =
    if Hashtbl.mem t.seen_ids msg_id then false
    else (
      Hashtbl.replace t.seen_ids msg_id true;
      Queue.add msg_id t.seen_ids_fifo;
      if Queue.length t.seen_ids_fifo > t.dedup_window then (
        match Queue.take_opt t.seen_ids_fifo with
        | None -> ()
        | Some old -> Hashtbl.remove t.seen_ids old
      );
      true
    )

  let inbox_key node_id session_id = (node_id, session_id)

  let get_inbox t key =
    match Hashtbl.find_opt t.inboxes key with
    | Some msgs -> msgs
    | None -> []

  let set_inbox t key msgs =
    Hashtbl.replace t.inboxes key msgs

  let register t ~node_id ~session_id ~alias ?(client_type = "unknown") ?(ttl = 300.0) =
    with_lock t (fun () ->
      let existing = Hashtbl.find_opt t.leases alias in
      (match existing with
       | Some ex when RegistrationLease.is_alive ex ->
         if RegistrationLease.node_id ex <> node_id then
           (relay_err_alias_conflict, ex)
         else
           let lease = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~ttl () in
           Hashtbl.replace t.leases alias lease;
           let key = inbox_key node_id session_id in
           if not (Hashtbl.mem t.inboxes key) then set_inbox t key [];
           ("ok", lease)
       | _ ->
         let lease = RegistrationLease.make ~node_id ~session_id ~alias ~client_type ~ttl () in
         Hashtbl.replace t.leases alias lease;
         let key = inbox_key node_id session_id in
         if not (Hashtbl.mem t.inboxes key) then set_inbox t key [];
         ("ok", lease))
    )

  let heartbeat t ~node_id ~session_id =
    with_lock t (fun () ->
      let found = ref None in
      Hashtbl.iter (fun _alias lease ->
        if RegistrationLease.node_id lease = node_id
           && RegistrationLease.session_id lease = session_id then
          found := Some lease
      ) t.leases;
      match !found with
      | None ->
         let dummy_lease = RegistrationLease.make ~node_id ~session_id ~alias:"_error" () in
         (relay_err_unknown_alias, dummy_lease)
      | Some lease ->
         RegistrationLease.touch lease;
         ("ok", lease)
    )

  let list_peers t ?(include_dead = false) =
    with_lock t (fun () ->
      Hashtbl.fold (fun _ lease acc ->
        if include_dead || RegistrationLease.is_alive lease then
          lease :: acc
        else acc
      ) t.leases []
    )

  let send t ~from_alias ~to_alias ~content ?(message_id = None) =
    with_lock t (fun () ->
      let msg_id = match message_id with Some id -> id | None -> generate_uuid () in
      let ts = Unix.gettimeofday () in
      let recipient = Hashtbl.find_opt t.leases to_alias in
      match recipient with
      | None ->
        let dl = `Assoc [
          ("ts", `Float ts); ("message_id", `String msg_id);
          ("from_alias", `String from_alias); ("to_alias", `String to_alias);
          ("content", `String content); ("reason", `String "unknown_alias");
        ] in
        Queue.add dl t.dead_letter;
        `Error (relay_err_unknown_alias, Printf.sprintf "no registration for alias %S" to_alias)
      | Some lease when not (RegistrationLease.is_alive lease) ->
        let dl = `Assoc [
          ("ts", `Float ts); ("message_id", `String msg_id);
          ("from_alias", `String from_alias); ("to_alias", `String to_alias);
          ("content", `String content); ("reason", `String "recipient_dead");
        ] in
        Queue.add dl t.dead_letter;
        `Error (relay_err_recipient_dead, Printf.sprintf "alias %S is registered but lease has expired" to_alias)
      | Some lease ->
        if not (record_message_id t msg_id) then
          `Duplicate ts
        else begin
          let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
          let msg = `Assoc [
            ("message_id", `String msg_id); ("from_alias", `String from_alias);
            ("to_alias", `String to_alias); ("content", `String content); ("ts", `Float ts);
          ] in
          let inbox = get_inbox t key in
          set_inbox t key (msg :: inbox);
          `Ok ts
        end
    )

  let poll_inbox t ~node_id ~session_id =
    with_lock t (fun () ->
      let key = inbox_key node_id session_id in
      let msgs = get_inbox t key in
      set_inbox t key [];
      msgs
    )

  let peek_inbox t ~node_id ~session_id =
    with_lock t (fun () ->
      let key = inbox_key node_id session_id in
      get_inbox t key
    )

  let dead_letter t =
    with_lock t (fun () ->
      List.rev (Queue.fold (fun acc x -> x :: acc) [] t.dead_letter)
    )

  let join_room t ~alias ~room_id =
    with_lock t (fun () ->
      if not (Hashtbl.mem t.leases alias) then
        `Error (relay_err_unknown_alias, Printf.sprintf "alias %S is not registered" alias)
      else begin
        let members = match Hashtbl.find_opt t.rooms room_id with
          | Some m -> m | None -> []
        in
        let already_member = List.mem alias members in
        let members' = if already_member then members else alias :: members in
        Hashtbl.replace t.rooms room_id members';
        if not (Hashtbl.mem t.room_history room_id) then
          Hashtbl.replace t.room_history room_id [];
        if not already_member then begin
          let ts = Unix.gettimeofday () in
          let msg_id = generate_uuid () in
          let content = room_join_content alias room_id in
          let hist_msg = `Assoc [
            ("message_id", `String msg_id); ("from_alias", `String room_system_alias);
            ("room_id", `String room_id); ("content", `String content); ("ts", `Float ts);
          ] in
          let hist = Hashtbl.find t.room_history room_id in
          Hashtbl.replace t.room_history room_id (hist_msg :: hist);
          List.iter (fun member_alias ->
            match Hashtbl.find_opt t.leases member_alias with
            | None ->
              let dl = `Assoc [
                ("message_id", `String msg_id); ("from_alias", `String room_system_alias);
                ("to_alias", `String (member_alias ^ "@" ^ room_id)); ("content", `String content);
                ("ts", `Float ts); ("room_id", `String room_id); ("reason", `String "recipient_dead");
              ] in Queue.add dl t.dead_letter
            | Some lease ->
              if RegistrationLease.is_alive lease then
                let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
                let msg = `Assoc [
                  ("message_id", `String msg_id); ("from_alias", `String room_system_alias);
                  ("to_alias", `String (member_alias ^ "@" ^ room_id)); ("content", `String content);
                  ("ts", `Float ts); ("room_id", `String room_id);
                ] in
                let inbox = get_inbox t key in set_inbox t key (msg :: inbox)
              else
                let dl = `Assoc [
                  ("message_id", `String msg_id); ("from_alias", `String room_system_alias);
                  ("to_alias", `String (member_alias ^ "@" ^ room_id)); ("content", `String content);
                  ("ts", `Float ts); ("room_id", `String room_id); ("reason", `String "recipient_dead");
                ] in Queue.add dl t.dead_letter
          ) members'
        end;
        `Ok
      end
    )

  let leave_room t ~alias ~room_id =
    with_lock t (fun () ->
      let members = match Hashtbl.find_opt t.rooms room_id with
        | Some m -> m | None -> []
      in
      let removed = List.mem alias members in
      let members' = if removed then List.filter ((!=) alias) members else members in
      Hashtbl.replace t.rooms room_id members';
      `Ok
    )

  let send_room t ~from_alias ~room_id ~content ?(message_id = None) =
    with_lock t (fun () ->
      let msg_id = match message_id with Some id -> id | None -> generate_uuid () in
      let ts = Unix.gettimeofday () in
      let members = match Hashtbl.find_opt t.rooms room_id with
        | Some m -> m | None -> []
      in
      if members = [] then `Ok (ts, [], [])
      else begin
        let delivered_to = ref [] in
        let skipped = ref [] in
        List.iter (fun alias ->
          if alias = from_alias then ()
          else begin
            match Hashtbl.find_opt t.leases alias with
            | None ->
              skipped := alias :: !skipped;
              let dl = `Assoc [
                ("message_id", `String msg_id); ("from_alias", `String from_alias);
                ("to_alias", `String (alias ^ "@" ^ room_id)); ("content", `String content);
                ("ts", `Float ts); ("room_id", `String room_id); ("reason", `String "recipient_dead");
              ] in Queue.add dl t.dead_letter
            | Some lease ->
              if not (RegistrationLease.is_alive lease) then begin
                skipped := alias :: !skipped;
                let dl = `Assoc [
                  ("message_id", `String msg_id); ("from_alias", `String from_alias);
                  ("to_alias", `String (alias ^ "@" ^ room_id)); ("content", `String content);
                  ("ts", `Float ts); ("room_id", `String room_id); ("reason", `String "recipient_dead");
                ] in Queue.add dl t.dead_letter
              end else begin
                delivered_to := alias :: !delivered_to;
                let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
                let msg = `Assoc [
                  ("message_id", `String msg_id); ("from_alias", `String from_alias);
                  ("room_id", `String room_id); ("content", `String content); ("ts", `Float ts);
                ] in
                let inbox = get_inbox t key in set_inbox t key (msg :: inbox)
              end
          end
        ) members;
        let hist_msg = `Assoc [
          ("message_id", `String msg_id); ("from_alias", `String from_alias);
          ("room_id", `String room_id); ("content", `String content); ("ts", `Float ts);
        ] in
        let hist = match Hashtbl.find_opt t.room_history room_id with
          | Some h -> h | None -> []
        in
        Hashtbl.replace t.room_history room_id (hist_msg :: hist);
        `Ok (ts, List.rev !delivered_to, List.rev !skipped)
      end
    )

  let room_history t ~room_id ?(limit = 50) =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.room_history room_id with
      | None -> []
      | Some hist ->
        let len = List.length hist in
        if limit >= len then List.rev hist
        else
          let rec drop n lst = if n = 0 then lst else drop (n - 1) (List.tl lst) in
          List.rev (drop (len - limit) hist)
    )

  let list_rooms t =
    with_lock t (fun () ->
      Hashtbl.fold (fun room_id members acc ->
        `Assoc [
          ("room_id", `String room_id);
          ("member_count", `Int (List.length members));
          ("members", `List (List.map (fun a -> `String a) members));
        ] :: acc
      ) t.rooms []
    )

  let send_all t ~from_alias ~content ?(message_id = None) =
    with_lock t (fun () ->
      let msg_id = match message_id with Some id -> id | None -> generate_uuid () in
      let ts = Unix.gettimeofday () in
      let delivered_to = ref [] in
      let skipped = ref [] in
      Hashtbl.iter (fun alias lease ->
        if alias = from_alias then ()
        else if not (RegistrationLease.is_alive lease) then skipped := alias :: !skipped
        else begin
          delivered_to := alias :: !delivered_to;
          let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
          let msg = `Assoc [
            ("message_id", `String msg_id); ("from_alias", `String from_alias);
            ("to_alias", `String alias); ("content", `String content); ("ts", `Float ts);
          ] in
          let inbox = get_inbox t key in set_inbox t key (msg :: inbox)
        end
      ) t.leases;
      `Ok (ts, List.rev !delivered_to, List.rev !skipped)
    )

  let gc t =
    with_lock t (fun () ->
      let expired = ref [] in
      Hashtbl.iter (fun alias lease ->
        if not (RegistrationLease.is_alive lease) then
          expired := alias :: !expired
      ) t.leases;
      List.iter (fun alias ->
        Hashtbl.remove t.leases alias;
        Hashtbl.iter (fun _room_id members ->
          Hashtbl.replace t.rooms _room_id (List.filter ((!=) alias) members)
        ) t.rooms
      ) !expired;
      let live_keys = ref [] in
      Hashtbl.iter (fun _ lease ->
        live_keys := (RegistrationLease.node_id lease, RegistrationLease.session_id lease) :: !live_keys
      ) t.leases;
      let stale_keys = ref [] in
      Hashtbl.iter (fun key _ ->
        if not (List.mem key !live_keys) then
          stale_keys := key :: !stale_keys
      ) t.inboxes;
      let pruned = List.length !stale_keys in
      List.iter (fun k -> Hashtbl.remove t.inboxes k) !stale_keys;
      `Ok (List.rev !expired, pruned)
    )
end

(* --- Relay_server HTTP layer --- *)

module Relay_server : sig
  val make_callback :
    InMemoryRelay.t ->
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
  let err_not_found = "not_not_found"
  let err_internal_error = "internal_error"

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
      json_ok [ ("result", `String status); ("lease", RegistrationLease.to_json lease) ]
    else
      json_error status (Printf.sprintf "alias conflict with existing lease") [ ("existing_lease", RegistrationLease.to_json lease) ]

  let json_of_heartbeat_result (status, lease) =
    if status = "ok" then
      json_ok [ ("result", `String status); ("lease", RegistrationLease.to_json lease) ]
    else
      json_error status "unknown node" [ ("lease", RegistrationLease.to_json lease) ]

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
    let peers = InMemoryRelay.list_peers relay ~include_dead:false |> List.map RegistrationLease.to_json in
    respond_ok (json_ok [ ("peers", `List peers) ])

  let handle_dead_letter relay =
    let dl = InMemoryRelay.dead_letter relay in
    respond_ok (json_ok [ ("dead_letter", `List dl) ])

  let handle_list_rooms relay =
    let rooms = InMemoryRelay.list_rooms relay in
    respond_ok (json_ok [ ("rooms", `List rooms) ])

  let handle_gc relay =
    match InMemoryRelay.gc relay with
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
      let result = InMemoryRelay.register relay ~node_id ~session_id ~alias ~client_type ~ttl in
      respond_ok (json_of_register_result result)

  let handle_heartbeat relay body =
    let node_id = get_string body "node_id" in
    let session_id = get_string body "session_id" in
    if node_id = "" || session_id = "" then
      respond_bad_request (json_error_str err_bad_request "node_id and session_id are required")
    else
      let result = InMemoryRelay.heartbeat relay ~node_id ~session_id in
      respond_ok (json_of_heartbeat_result result)

  let handle_send relay body =
    let from_alias = get_string body "from_alias" in
    let to_alias = get_string body "to_alias" in
    let content = get_string body "content" in
    if from_alias = "" || to_alias = "" || content = "" then
      respond_bad_request (json_error_str err_bad_request "from_alias, to_alias, and content are required")
    else
      let message_id = get_opt_string body "message_id" in
      let result = InMemoryRelay.send relay ~from_alias ~to_alias ~content ~message_id in
      respond_ok (json_of_send_result result)

  let handle_send_all relay body =
    let from_alias = get_string body "from_alias" in
    let content = get_string body "content" in
    if from_alias = "" || content = "" then
      respond_bad_request (json_error_str err_bad_request "from_alias and content are required")
    else
      let message_id = get_opt_string body "message_id" in
      match InMemoryRelay.send_all relay ~from_alias ~content ~message_id with
      | `Ok (ts, delivered, skipped) -> respond_ok (json_of_send_all_result (ts, delivered, skipped))

  let handle_poll_inbox relay body =
    let node_id = get_string body "node_id" in
    let session_id = get_string body "session_id" in
    if node_id = "" || session_id = "" then
      respond_bad_request (json_error_str err_bad_request "node_id and session_id are required")
    else
      let msgs = InMemoryRelay.poll_inbox relay ~node_id ~session_id in
      respond_ok (json_ok [ ("messages", `List msgs) ])

  let handle_peek_inbox relay body =
    let node_id = get_string body "node_id" in
    let session_id = get_string body "session_id" in
    if node_id = "" || session_id = "" then
      respond_bad_request (json_error_str err_bad_request "node_id and session_id are required")
    else
      let msgs = InMemoryRelay.peek_inbox relay ~node_id ~session_id in
      respond_ok (json_ok [ ("messages", `List msgs) ])

  let handle_join_room relay body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    if alias = "" || room_id = "" then
      respond_bad_request (json_error_str err_bad_request "alias and room_id are required")
    else
      let result = InMemoryRelay.join_room relay ~alias ~room_id in
      respond_ok (match result with
        | `Ok -> json_of_room_join_result `Ok
        | `Error (code, msg) -> json_error code msg [])

  let handle_leave_room relay body =
    let alias = get_string body "alias" in
    let room_id = get_string body "room_id" in
    if alias = "" || room_id = "" then
      respond_bad_request (json_error_str err_bad_request "alias and room_id are required")
    else
      let result = InMemoryRelay.leave_room relay ~alias ~room_id in
      respond_ok (json_of_room_join_result result)

  and handle_send_room relay body =
    let from_alias = get_string body "from_alias" in
    let room_id = get_string body "room_id" in
    let content = get_string body "content" in
    if from_alias = "" || room_id = "" || content = "" then
      respond_bad_request (json_error_str err_bad_request "from_alias, room_id, and content are required")
    else
      let message_id = get_opt_string body "message_id" in
      match InMemoryRelay.send_room relay ~from_alias ~room_id ~content ~message_id with
      | `Ok (ts, delivered, skipped) -> respond_ok (json_of_send_room_result (ts, delivered, skipped))

  let handle_room_history relay body =
    let room_id = get_string body "room_id" in
    if room_id = "" then
      respond_bad_request (json_error_str err_bad_request "room_id is required")
    else
      let limit = get_int body "limit" 50 in
      let history = InMemoryRelay.room_history relay ~room_id ~limit in
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
    (try ignore (InMemoryRelay.gc relay :> _) with
     | _ -> ());
    gc_loop relay gc_interval

  (* --- Server startup --- *)

  let start_server ~host ~port ~token ?(verbose=false) ?(gc_interval=0.0) () =
    let relay = InMemoryRelay.create () in
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