(* B332: B295 takeover leaves unremovable ghost room members feeding
   per-message dead-letter rows.

   Neither backend's pair-takeover path touched room membership (only the
   12-month release_alias did). After a rename takeover the shadowed alias
   keeps its room_members rows but has no lease: identity_pk_of returns None
   so its leave_room is rejected, no peer can kick it, and every send_room to
   that room skips the ghost (sqlite) or additionally appends a full-content
   recipient_dead dead-letter row per message (in-memory) — an unbounded,
   content-bearing log fed by other members' traffic.

   Fix under test: register's pair takeover removes the shadowed aliases from
   room membership in both backends, matching release_alias semantics. Pinned:
   - the shadowed alias is gone from the room roster after takeover;
   - send_room neither delivers to nor reports the ghost, and no dead-letter
     rows accumulate;
   - the NEW alias (joining after the takeover) is unaffected. *)

open Alcotest

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b332" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let members_strings (room : Yojson.Safe.t) =
  match room with
  | `Assoc fields ->
    (match List.assoc_opt "members" fields with
     | Some (`List ms) ->
       List.map (function `String s -> s | _ -> failwith "member not a string") ms
     | _ -> failwith "room entry missing members")
  | _ -> failwith "room entry not an object"

let find_room (rooms : Yojson.Safe.t list) room_id =
  let is_room r =
    match r with
    | `Assoc fields -> List.assoc_opt "room_id" fields = Some (`String room_id)
    | _ -> false
  in
  match List.find_opt is_room rooms with
  | Some r -> r
  | None -> failwith (room_id ^ " missing from room list")

let test_sqlite_takeover_removes_ghost_from_roster_and_fanout () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let reg node session alias =
      let status, _ =
        Relay.SqliteRelay.register t ~node_id:node ~session_id:session
          ~alias ()
      in
      check string (alias ^ ": register ok") "ok" status
    in
    reg "b332-n1" "b332-s1" "b332-owner";
    reg "b332-n2" "b332-s2" "b332-peer";
    reg "b332-n3" "b332-s3" "b332-old";
    List.iter
      (fun a ->
        match Relay.SqliteRelay.join_room t ~alias:a ~room_id:"b332-room" () with
        | `Ok -> ()
        | `Error (c, m) -> failf "%s join failed: %s %s" a c m)
      [ "b332-owner"; "b332-peer"; "b332-old" ];
    (* Rename takeover: the same session re-registers under a new alias. *)
    let status, _ =
      Relay.SqliteRelay.register t ~node_id:"b332-n3" ~session_id:"b332-s3"
        ~alias:"b332-new" ()
    in
    check string "b332-new: takeover register ok" "ok" status;
    (* list_rooms formats members as alias#room@relay on both backends. *)
    let members =
      members_strings (find_room (Relay.SqliteRelay.list_rooms t) "b332-room")
    in
    check bool "ghost alias removed from roster"
      (not (List.exists (starts_with ~prefix:"b332-old#") members)) true;
    check bool "surviving members intact"
      (List.exists (starts_with ~prefix:"b332-owner#") members
       && List.exists (starts_with ~prefix:"b332-peer#") members)
      true;
    (* Fan-out: no delivery, no skip report, no dead-letter for the ghost. *)
    let dl_before = List.length (Relay.SqliteRelay.dead_letter t) in
    (match
       Relay.SqliteRelay.send_room t ~from_alias:"b332-owner"
         ~room_id:"b332-room" ~content:"hello" ()
     with
     | `Ok (_ts, delivered, skipped) ->
       check bool "ghost not delivered"
         (not (List.mem "b332-old" delivered)) true;
       check bool "ghost not even reported skipped"
         (not (List.mem "b332-old" skipped)) true;
       check (list string) "peer still delivered" [ "b332-peer" ] delivered
     | _ -> fail "send_room should be Ok");
    check int "no dead-letter rows accumulated"
      dl_before (List.length (Relay.SqliteRelay.dead_letter t));
    (* The new alias joins and receives the next send. *)
    (match Relay.SqliteRelay.join_room t ~alias:"b332-new"
             ~room_id:"b332-room" () with
     | `Ok -> ()
     | `Error (c, m) -> failf "new alias join failed: %s %s" c m);
    match
      Relay.SqliteRelay.send_room t ~from_alias:"b332-owner"
        ~room_id:"b332-room" ~content:"again" ()
    with
    | `Ok (_ts, delivered, _skipped) ->
      check bool "new alias receives room mail"
        (List.mem "b332-new" delivered) true
    | _ -> fail "second send_room should be Ok")

let test_inmemory_takeover_removes_ghost_from_roster_and_fanout () =
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    let reg node session alias =
      let status, _ =
        Relay.InMemoryRelay.register t ~node_id:node ~session_id:session
          ~alias ()
      in
      check string (alias ^ ": register ok") "ok" status
    in
    reg "b332-n1" "b332-s1" "b332-owner";
    reg "b332-n2" "b332-s2" "b332-peer";
    reg "b332-n3" "b332-s3" "b332-old";
    List.iter
      (fun a ->
        match Relay.InMemoryRelay.join_room t ~alias:a ~room_id:"b332-room" () with
        | `Ok -> ()
        | `Error (c, m) -> failf "%s join failed: %s %s" a c m)
      [ "b332-owner"; "b332-peer"; "b332-old" ];
    let status, _ =
      Relay.InMemoryRelay.register t ~node_id:"b332-n3" ~session_id:"b332-s3"
        ~alias:"b332-new" ()
    in
    check string "b332-new: takeover register ok" "ok" status;
    (* In-memory list_rooms formats members as alias#room@relay. *)
    let members =
      members_strings (find_room (Relay.InMemoryRelay.list_rooms t) "b332-room")
    in
    check bool "ghost alias removed from roster"
      (not (List.exists (starts_with ~prefix:"b332-old#") members)) true;
    check bool "surviving members intact"
      (List.exists (starts_with ~prefix:"b332-owner#") members
       && List.exists (starts_with ~prefix:"b332-peer#") members)
      true;
    (* Fan-out: the in-memory backend used to append a full-content
       recipient_dead dead-letter row per send for the ghost. *)
    let dl_before = List.length (Relay.InMemoryRelay.dead_letter t) in
    (match
       Relay.InMemoryRelay.send_room t ~from_alias:"b332-owner"
         ~room_id:"b332-room" ~content:"hello" ()
     with
     | `Ok (_ts, delivered, skipped) ->
       check bool "ghost not delivered"
         (not (List.mem "b332-old" delivered)) true;
       check bool "ghost not reported skipped"
         (not (List.mem "b332-old" skipped)) true;
       check (list string) "peer still delivered" [ "b332-peer" ] delivered
     | _ -> fail "send_room should be Ok");
    check int "no dead-letter rows accumulated"
      dl_before (List.length (Relay.InMemoryRelay.dead_letter t));
    (match Relay.InMemoryRelay.join_room t ~alias:"b332-new"
             ~room_id:"b332-room" () with
     | `Ok -> ()
     | `Error (c, m) -> failf "new alias join failed: %s %s" c m);
    match
      Relay.InMemoryRelay.send_room t ~from_alias:"b332-owner"
        ~room_id:"b332-room" ~content:"again" ()
    with
    | `Ok (_ts, delivered, _skipped) ->
      check bool "new alias receives room mail"
        (List.mem "b332-new" delivered) true
    | _ -> fail "second send_room should be Ok")

let () =
  run "B332 takeover removes ghost room members in both backends"
    [ ("sqlite", [ test_case "ghost removed from roster and fan-out" `Quick
          test_sqlite_takeover_removes_ghost_from_roster_and_fanout ])
    ; ("in-memory", [ test_case "ghost removed from roster and fan-out" `Quick
          test_inmemory_takeover_removes_ghost_from_roster_and_fanout ])
    ]
