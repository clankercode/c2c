(* test_relay_stats.ml — B147: relay usage stats (GET /stats backing).

   Exercises the RELAY-contract stats surface on both backends:
   - stats_note_message / stats_note_activity recording,
   - windowed aggregation over 1d/7d/28d/ever (caller-supplied clock),
   - distinct alias/machine counting via last_seen upserts,
   - gc pruning of message events without losing the 'ever' totals,
   - sqlite persistence across a reopen. *)

let day = 86_400.

(* Fixed fake clock — the stats API takes ~ts/~now explicitly. *)
let now = 1_000_000_000.

let assoc key json =
  match json with
  | `Assoc l ->
    (match List.assoc_opt key l with
     | Some v -> v
     | None -> Alcotest.failf "missing key %S in %s" key (Yojson.Safe.to_string json))
  | _ -> Alcotest.failf "expected object while looking up %S" key

let count stats ~window ~field =
  match assoc field (assoc window stats) with
  | `Int n -> n
  | _ -> Alcotest.failf "%s.%s is not an int" window field

let check_window stats ~window ~messages ~aliases ~machines =
  Alcotest.(check int) (window ^ ".messages") messages
    (count stats ~window ~field:"messages");
  Alcotest.(check int) (window ^ ".unique_aliases") aliases
    (count stats ~window ~field:"unique_aliases");
  Alcotest.(check int) (window ^ ".unique_machines") machines
    (count stats ~window ~field:"unique_machines")

module Tests (B : sig
  module R : Relay.RELAY
  val fresh : unit -> R.t
end) = struct
  open B

  let test_empty () =
    let t = fresh () in
    let stats = R.stats t ~now in
    List.iter
      (fun window ->
        check_window stats ~window ~messages:0 ~aliases:0 ~machines:0)
      [ "1d"; "7d"; "28d"; "ever" ]

  let test_message_windows () =
    let t = fresh () in
    (* One message per window band: fresh (1d), 2d old (7d), 10d old (28d). *)
    R.stats_note_message t ~from_alias:"zq-stats-recent" ~ts:(now -. 100.);
    R.stats_note_message t ~from_alias:"zq-stats-mid" ~ts:(now -. (2. *. day));
    R.stats_note_message t ~from_alias:"zq-stats-old" ~ts:(now -. (10. *. day));
    let stats = R.stats t ~now in
    check_window stats ~window:"1d" ~messages:1 ~aliases:1 ~machines:0;
    check_window stats ~window:"7d" ~messages:2 ~aliases:2 ~machines:0;
    check_window stats ~window:"28d" ~messages:3 ~aliases:3 ~machines:0;
    check_window stats ~window:"ever" ~messages:3 ~aliases:3 ~machines:0

  let test_activity_dedup () =
    let t = fresh () in
    (* Same machine + alias twice — distinct counts stay 1, last_seen moves. *)
    R.stats_note_activity t ~node_id:"zq-node-1" ~alias:"zq-stats-agent"
      ~ts:(now -. (10. *. day));
    R.stats_note_activity t ~node_id:"zq-node-1" ~alias:"zq-stats-agent"
      ~ts:(now -. 50.);
    let stats = R.stats t ~now in
    check_window stats ~window:"1d" ~messages:0 ~aliases:1 ~machines:1;
    check_window stats ~window:"ever" ~messages:0 ~aliases:1 ~machines:1

  let test_activity_window_by_last_seen () =
    let t = fresh () in
    (* A machine last active 10d ago is in 28d but not 7d/1d. *)
    R.stats_note_activity t ~node_id:"zq-node-stale" ~alias:"zq-stats-stale"
      ~ts:(now -. (10. *. day));
    R.stats_note_activity t ~node_id:"zq-node-live" ~alias:"zq-stats-live"
      ~ts:(now -. 30.);
    let stats = R.stats t ~now in
    check_window stats ~window:"1d" ~messages:0 ~aliases:1 ~machines:1;
    check_window stats ~window:"7d" ~messages:0 ~aliases:1 ~machines:1;
    check_window stats ~window:"28d" ~messages:0 ~aliases:2 ~machines:2;
    check_window stats ~window:"ever" ~messages:0 ~aliases:2 ~machines:2

  let test_message_upserts_sender_alias () =
    let t = fresh () in
    (* Two messages from one sender: messages counts events, aliases dedup. *)
    R.stats_note_message t ~from_alias:"zq-stats-sender" ~ts:(now -. 10.);
    R.stats_note_message t ~from_alias:"zq-stats-sender" ~ts:(now -. 5.);
    let stats = R.stats t ~now in
    check_window stats ~window:"1d" ~messages:2 ~aliases:1 ~machines:0;
    check_window stats ~window:"ever" ~messages:2 ~aliases:1 ~machines:0

  let test_gc_prunes_events_keeps_ever () =
    let t = fresh () in
    (* gc uses the real clock, so anchor these events to it. *)
    let real_now = Unix.gettimeofday () in
    R.stats_note_message t ~from_alias:"zq-stats-ancient"
      ~ts:(real_now -. (40. *. day));
    R.stats_note_message t ~from_alias:"zq-stats-fresh" ~ts:(real_now -. 10.);
    (match R.gc t with `Ok _ -> () | _ -> Alcotest.fail "gc failed");
    let stats = R.stats t ~now:real_now in
    (* The 40d-old event row is pruned (28d window unaffected either way),
       but the all-time message count survives pruning. *)
    check_window stats ~window:"28d" ~messages:1 ~aliases:1 ~machines:0;
    Alcotest.(check int) "ever.messages survives gc" 2
      (count stats ~window:"ever" ~field:"messages");
    Alcotest.(check int) "ever.unique_aliases survives gc" 2
      (count stats ~window:"ever" ~field:"unique_aliases")

  let cases =
    [
      Alcotest.test_case "empty stats are all zero" `Quick test_empty;
      Alcotest.test_case "messages bucket by window" `Quick test_message_windows;
      Alcotest.test_case "repeat activity dedups" `Quick test_activity_dedup;
      Alcotest.test_case "activity windows use last_seen" `Quick
        test_activity_window_by_last_seen;
      Alcotest.test_case "message upserts sender alias" `Quick
        test_message_upserts_sender_alias;
      Alcotest.test_case "gc prunes events, keeps ever" `Quick
        test_gc_prunes_events_keeps_ever;
    ]
end

let fresh_tmp_dir () =
  let path = Filename.temp_file "c2c_relay_stats_test" "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  path

module Mem_tests = Tests (struct
  module R = Relay.InMemoryRelay
  let fresh () = R.create ()
end)

module Sql_tests = Tests (struct
  module R = Relay.SqliteRelay
  let fresh () = R.create ~persist_dir:(fresh_tmp_dir ()) ()
end)

(* Sqlite-only: stats survive a relay restart (fresh handle, same DB). *)
let test_sqlite_persistence () =
  let dir = fresh_tmp_dir () in
  let t = Relay.SqliteRelay.create ~persist_dir:dir () in
  Relay.SqliteRelay.stats_note_message t ~from_alias:"zq-stats-persist"
    ~ts:(now -. 10.);
  Relay.SqliteRelay.stats_note_activity t ~node_id:"zq-node-persist"
    ~alias:"zq-stats-persist" ~ts:(now -. 10.);
  let t2 = Relay.SqliteRelay.create ~persist_dir:dir () in
  let stats = Relay.SqliteRelay.stats t2 ~now in
  check_window stats ~window:"ever" ~messages:1 ~aliases:1 ~machines:1

(* /stats is anonymously readable — pin the route classification so it can't
   silently regress to peer/admin auth. *)
let test_stats_route_is_anonymous () =
  (match Relay_server_auth.classify_route ~path:"/stats" ~include_dead:false with
   | Relay_server_auth.Anonymous_read -> ()
   | _ -> Alcotest.fail "/stats must classify as Anonymous_read");
  let allow, err =
    Relay_server_auth.auth_decision ~path:"/stats" ~include_dead:false
      ~token:(Some "prod-token") ~auth_header:None ~ed25519_verified:false
  in
  Alcotest.(check bool) "/stats allowed without credentials" true allow;
  Alcotest.(check (option string)) "/stats no auth error" None err

let () =
  Alcotest.run "relay_stats"
    [
      ("in-memory", Mem_tests.cases);
      ( "sqlite",
        Sql_tests.cases
        @ [
            Alcotest.test_case "stats persist across reopen" `Quick
              test_sqlite_persistence;
          ] );
      ( "route-auth",
        [
          Alcotest.test_case "/stats is anonymous" `Quick
            test_stats_route_is_anonymous;
        ] );
    ]
