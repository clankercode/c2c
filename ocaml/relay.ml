[@@@warning "-33-16-32"]
(* relay.ml — native OCaml in-memory relay backend *)

module Relay = struct

module RegistrationLease : sig
  type t
  val make : node_id:string -> session_id:string -> alias:string -> ?client_type:string -> ?ttl:float -> unit -> t
  val is_alive : t -> bool
  val touch : t -> unit  (* refresh last_seen *)
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

(* Error codes *)
let relay_err_unknown_alias = "unknown_alias"
let relay_err_alias_conflict = "alias_conflict"
let relay_err_recipient_dead = "recipient_dead"
let room_system_alias = "c2c-system"

let room_join_content alias room_id = alias ^ " joined room " ^ room_id

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
    leases : (string, RegistrationLease.t) Hashtbl.t;  (* alias -> lease *)
    inboxes : ((string * string), Yojson.Safe.t list) Hashtbl.t;  (* (node_id, session_id) -> messages *)
    dead_letter : Yojson.Safe.t Queue.t;
    rooms : (string, string list) Hashtbl.t;  (* room_id -> member aliases *)
    room_history : (string, Yojson.Safe.t list) Hashtbl.t;  (* room_id -> messages *)
    seen_ids : (string, bool) Hashtbl.t;  (* dedup: message_id -> seen *)
    dedup_window : int;
    seen_ids_fifo : string Queue.t;  (* ordered queue for FIFO eviction *)
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
    (* Simple UUID v4-like generator using Random.bits.
       Not cryptographically secure but sufficient for message dedup. *)
    let random_hex n =
      let chars = "0123456789abcdef" in
      String.init n (fun _ -> chars.[Random.int 16])
    in
    Printf.sprintf "%s-%s-4%s-%s-%s"
      (random_hex 8)
      (random_hex 3)
      (random_hex 3)
      (random_hex 4)
      (random_hex 12)

  let record_message_id t msg_id =
    if Hashtbl.mem t.seen_ids msg_id then false
    else (
      Hashtbl.replace t.seen_ids msg_id true;
      Queue.add msg_id t.seen_ids_fifo;
      (* FIFO eviction *)
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
           (* Same node — allow re-registration, refresh *)
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
          ("ts", `Float ts);
          ("message_id", `String msg_id);
          ("from_alias", `String from_alias);
          ("to_alias", `String to_alias);
          ("content", `String content);
          ("reason", `String "unknown_alias");
        ] in
        Queue.add dl t.dead_letter;
        `Error (relay_err_unknown_alias,
                Printf.sprintf "no registration for alias %S" to_alias)
      | Some lease when not (RegistrationLease.is_alive lease) ->
        let dl = `Assoc [
          ("ts", `Float ts);
          ("message_id", `String msg_id);
          ("from_alias", `String from_alias);
          ("to_alias", `String to_alias);
          ("content", `String content);
          ("reason", `String "recipient_dead");
        ] in
        Queue.add dl t.dead_letter;
        `Error (relay_err_recipient_dead,
                Printf.sprintf "alias %S is registered but lease has expired" to_alias)
      | Some lease ->
        (* Exactly-once: check dedup before appending *)
        if not (record_message_id t msg_id) then
          `Duplicate ts
        else begin
          let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
          let msg = `Assoc [
            ("message_id", `String msg_id);
            ("from_alias", `String from_alias);
            ("to_alias", `String to_alias);
            ("content", `String content);
            ("ts", `Float ts);
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
        `Error (relay_err_unknown_alias,
                Printf.sprintf "alias %S is not registered" alias)
      else begin
        let members = match Hashtbl.find_opt t.rooms room_id with
          | Some m -> m
          | None -> []
        in
        let already_member = List.mem alias members in
        let members' = if already_member then members else alias :: members in
        Hashtbl.replace t.rooms room_id members';
        if not (Hashtbl.mem t.room_history room_id) then
          Hashtbl.replace t.room_history room_id [];
        if not already_member then begin
          (* Broadcast room join *)
          let ts = Unix.gettimeofday () in
          let msg_id = generate_uuid () in
          let content = room_join_content alias room_id in
          let hist_msg = `Assoc [
            ("message_id", `String msg_id);
            ("from_alias", `String room_system_alias);
            ("room_id", `String room_id);
            ("content", `String content);
            ("ts", `Float ts);
          ] in
          let hist = Hashtbl.find t.room_history room_id in
          Hashtbl.replace t.room_history room_id (hist_msg :: hist);
          (* Deliver to each member *)
          List.iter (fun member_alias ->
            match Hashtbl.find_opt t.leases member_alias with
            | None ->
              let dl = `Assoc [
                ("message_id", `String msg_id);
                ("from_alias", `String room_system_alias);
                ("to_alias", `String (member_alias ^ "@" ^ room_id));
                ("content", `String content);
                ("ts", `Float ts);
                ("room_id", `String room_id);
                ("reason", `String "recipient_dead");
              ] in
              Queue.add dl t.dead_letter
            | Some lease ->
              if RegistrationLease.is_alive lease then
                let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
                let msg = `Assoc [
                  ("message_id", `String msg_id);
                  ("from_alias", `String room_system_alias);
                  ("to_alias", `String (member_alias ^ "@" ^ room_id));
                  ("content", `String content);
                  ("ts", `Float ts);
                  ("room_id", `String room_id);
                ] in
                let inbox = get_inbox t key in
                set_inbox t key (msg :: inbox)
              else
                let dl = `Assoc [
                  ("message_id", `String msg_id);
                  ("from_alias", `String room_system_alias);
                  ("to_alias", `String (member_alias ^ "@" ^ room_id));
                  ("content", `String content);
                  ("ts", `Float ts);
                  ("room_id", `String room_id);
                  ("reason", `String "recipient_dead");
                ] in
                Queue.add dl t.dead_letter
          ) members'
        end;
        `Ok
      end
    )

  let leave_room t ~alias ~room_id =
    with_lock t (fun () ->
      let members = match Hashtbl.find_opt t.rooms room_id with
        | Some m -> m
        | None -> []
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
        | Some m -> m
        | None -> []
      in
      if members = [] then
        `Ok (ts, [], [])
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
                ("message_id", `String msg_id);
                ("from_alias", `String from_alias);
                ("to_alias", `String (alias ^ "@" ^ room_id));
                ("content", `String content);
                ("ts", `Float ts);
                ("room_id", `String room_id);
                ("reason", `String "recipient_dead");
              ] in
              Queue.add dl t.dead_letter
            | Some lease ->
              if not (RegistrationLease.is_alive lease) then begin
                skipped := alias :: !skipped;
                let dl = `Assoc [
                  ("message_id", `String msg_id);
                  ("from_alias", `String from_alias);
                  ("to_alias", `String (alias ^ "@" ^ room_id));
                  ("content", `String content);
                  ("ts", `Float ts);
                  ("room_id", `String room_id);
                  ("reason", `String "recipient_dead");
                ] in
                Queue.add dl t.dead_letter
              end else begin
                delivered_to := alias :: !delivered_to;
                let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
                let msg = `Assoc [
                  ("message_id", `String msg_id);
                  ("from_alias", `String from_alias);
                  ("to_alias", `String (alias ^ "@" ^ room_id));
                  ("content", `String content);
                  ("ts", `Float ts);
                  ("room_id", `String room_id);
                ] in
                let inbox = get_inbox t key in
                set_inbox t key (msg :: inbox)
              end
          end
        ) members;
        (* Append to room history *)
        let hist_msg = `Assoc [
          ("message_id", `String msg_id);
          ("from_alias", `String from_alias);
          ("room_id", `String room_id);
          ("content", `String content);
          ("ts", `Float ts);
        ] in
        let hist = match Hashtbl.find_opt t.room_history room_id with
          | Some h -> h
          | None -> []
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
        else if not (RegistrationLease.is_alive lease) then begin
          skipped := alias :: !skipped
        end else begin
          delivered_to := alias :: !delivered_to;
          let key = inbox_key (RegistrationLease.node_id lease) (RegistrationLease.session_id lease) in
          let msg = `Assoc [
            ("message_id", `String msg_id);
            ("from_alias", `String from_alias);
            ("to_alias", `String alias);
            ("content", `String content);
            ("ts", `Float ts);
          ] in
          let inbox = get_inbox t key in
          set_inbox t key (msg :: inbox)
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
        (* Remove from all rooms *)
        Hashtbl.iter (fun _room_id members ->
          Hashtbl.replace t.rooms _room_id (List.filter ((!=) alias) members)
        ) t.rooms
      ) !expired;
      (* Prune inboxes for sessions with no matching live lease *)
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

end (* end of Relay module *)