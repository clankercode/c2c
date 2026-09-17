(* B331: undelivered inbox stranded then GC-deleted on sqlite session
   re-register (in-memory carries it; prod loses mail sent during a restart).

   InMemoryRelay.register, when the alias's existing lease is alive under a
   different session_id, moves the old (node_id, session_id) inbox key's
   undelivered messages to the new key (relay.ml ~782-790). SqliteRelay.register
   has no equivalent: after a session restart re-registers the alias under a
   new session id, mail that arrived while the session was down sits under the
   old key, poll_inbox reads only the new key, and the gc stale-inbox sweep
   (every inboxes key not held by a live lease) destroys it.

   Pinned here:
   - sqlite: mail sent between "session down" and "re-register with a new
     session id" is readable from the new key after re-register;
   - sqlite: that mail also survives a gc pass (it must be carried, not
     stranded under a key the sweeper considers stale);
   - in-memory: same scenario delivers (pre-existing behaviour — parity pin
     so the backends cannot diverge again). *)

open Alcotest

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b331" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

let sql_reg t ~node_id ~session_id ~alias =
  let status, _lease =
    Relay.SqliteRelay.register t ~node_id ~session_id ~alias ()
  in
  check string (alias ^ ": register ok") "ok" status;
  match
    Relay.SqliteRelay.set_peer_discovery_visibility t ~alias
      ~visibility:Relay_backend_contract.Public
  with
  | Ok () -> ()
  | Error e -> failf "mark %s public: %s" alias e

let mem_reg t ~node_id ~session_id ~alias =
  let status, _lease =
    Relay.InMemoryRelay.register t ~node_id ~session_id ~alias ()
  in
  check string (alias ^ ": register ok") "ok" status;
  match
    Relay.InMemoryRelay.set_peer_discovery_visibility t ~alias
      ~visibility:Relay_backend_contract.Public
  with
  | Ok () -> ()
  | Error e -> failf "mark %s public: %s" alias e

let sql_send_ok t ~from_alias ~to_alias ~content =
  match
    Relay.SqliteRelay.send t ~from_alias ~to_alias ~content
      ~message_id:None ~pow_difficulty:(-1)
  with
  | `Ok _ -> ()
  | `Duplicate _ -> fail "b331: fresh send must not be Duplicate"
  | `Error (c, m) -> failf "send to %s failed: %s %s" to_alias c m

let mem_send_ok t ~from_alias ~to_alias ~content =
  match
    Relay.InMemoryRelay.send t ~from_alias ~to_alias ~content
      ~message_id:None ~pow_difficulty:(-1)
  with
  | `Ok _ -> ()
  | `Duplicate _ -> fail "b331: fresh send must not be Duplicate"
  | `Error (c, m) -> failf "send to %s failed: %s %s" to_alias c m

let contents_of (msgs : Yojson.Safe.t list) =
  List.map
    (fun (m : Yojson.Safe.t) ->
      match m with
      | `Assoc fields ->
        (match List.assoc_opt "content" fields with
         | Some (`String s) -> s
         | _ -> failwith "inbox entry missing content")
      | _ -> failwith "inbox entry not an object")
    msgs

let sql_contents t ~node_id ~session_id =
  contents_of
    (Relay.SqliteRelay.poll_inbox t ~node_id ~session_id)

let mem_contents t ~node_id ~session_id =
  contents_of
    (Relay.InMemoryRelay.poll_inbox t ~node_id ~session_id)

let test_sqlite_mail_survives_session_re_register () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    sql_reg t ~node_id:"b331-node" ~session_id:"b331-s1" ~alias:"b331-a";
    sql_reg t ~node_id:"b331-peer" ~session_id:"b331-peer-s" ~alias:"b331-peer";
    (* Mail arrives while the old session is still the lease holder. *)
    sql_send_ok t ~from_alias:"b331-peer" ~to_alias:"b331-a" ~content:"while-down";
    (* Session restarts with a fresh session id and re-registers. *)
    let status, _lease =
      Relay.SqliteRelay.register t ~node_id:"b331-node" ~session_id:"b331-s2"
        ~alias:"b331-a" ()
    in
    check string "re-register with new session id ok" "ok" status;
    check (list string) "mail sent while down is readable from the new key"
      [ "while-down" ]
      (sql_contents t ~node_id:"b331-node" ~session_id:"b331-s2"))

let test_sqlite_carried_mail_survives_gc () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    sql_reg t ~node_id:"b331-node" ~session_id:"b331-s1" ~alias:"b331-a";
    sql_reg t ~node_id:"b331-peer" ~session_id:"b331-peer-s" ~alias:"b331-peer";
    sql_send_ok t ~from_alias:"b331-peer" ~to_alias:"b331-a" ~content:"gc-bait";
    let status, _ =
      Relay.SqliteRelay.register t ~node_id:"b331-node" ~session_id:"b331-s2"
        ~alias:"b331-a" ()
    in
    check string "re-register ok" "ok" status;
    ignore (Relay.SqliteRelay.gc t);
    check (list string) "carried mail survives the gc stale-inbox sweep"
      [ "gc-bait" ]
      (sql_contents t ~node_id:"b331-node" ~session_id:"b331-s2"))

(* Parity pin: the in-memory backend already carried the inbox; it must keep
   doing so, with the same observable contract (old messages first). *)
let test_inmemory_mail_survives_session_re_register () =
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    mem_reg t ~node_id:"b331-node" ~session_id:"b331-s1" ~alias:"b331-a";
    mem_reg t ~node_id:"b331-peer" ~session_id:"b331-peer-s" ~alias:"b331-peer";
    mem_send_ok t ~from_alias:"b331-peer" ~to_alias:"b331-a" ~content:"while-down";
    let status, _ =
      Relay.InMemoryRelay.register t ~node_id:"b331-node" ~session_id:"b331-s2"
        ~alias:"b331-a" ()
    in
    check string "in-memory re-register with new session id ok" "ok" status;
    check (list string) "in-memory: mail sent while down is readable"
      [ "while-down" ]
      (mem_contents t ~node_id:"b331-node" ~session_id:"b331-s2"))

(* Same-session re-register must not duplicate or move anything: the old key
   IS the new key. *)
let test_sqlite_same_session_re_register_no_carry () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    sql_reg t ~node_id:"b331-node" ~session_id:"b331-s1" ~alias:"b331-a";
    sql_reg t ~node_id:"b331-peer" ~session_id:"b331-peer-s" ~alias:"b331-peer";
    sql_send_ok t ~from_alias:"b331-peer" ~to_alias:"b331-a" ~content:"one";
    let status, _ =
      Relay.SqliteRelay.register t ~node_id:"b331-node" ~session_id:"b331-s1"
        ~alias:"b331-a" ()
    in
    check string "same-session re-register ok" "ok" status;
    check (list string) "same session: exactly the original mail, once"
      [ "one" ]
      (sql_contents t ~node_id:"b331-node" ~session_id:"b331-s1"))

let () =
  run "B331 undelivered inbox carried across sqlite session re-register"
    [ ("sqlite session re-register carries inbox", [
        test_case "mail sent while down is readable from the new key" `Quick
          test_sqlite_mail_survives_session_re_register;
        test_case "carried mail survives gc stale-inbox sweep" `Quick
          test_sqlite_carried_mail_survives_gc;
        test_case "same-session re-register does not duplicate" `Quick
          test_sqlite_same_session_re_register_no_carry;
      ])
    ; ("in-memory parity pin", [
        test_case "mail sent while down is readable from the new key" `Quick
          test_inmemory_mail_survives_session_re_register;
      ])
    ]
