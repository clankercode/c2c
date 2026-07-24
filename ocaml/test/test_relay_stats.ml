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

(* B148: connected-section accessors. *)
let conn stats = assoc "connected" stats

let conn_int stats ~field =
  match assoc field (conn stats) with
  | `Int n -> n
  | _ -> Alcotest.failf "connected.%s is not an int" field

let conn_ct stats ct =
  match assoc ct (assoc "by_client_type" (conn stats)) with
  | `Int n -> n
  | _ -> Alcotest.failf "connected.by_client_type.%s is not an int" ct

(* B149: generic accessor for the connected count maps (by_version / by_os). *)
let conn_map stats ~map ~key =
  match assoc key (assoc map (conn stats)) with
  | `Int n -> n
  | _ -> Alcotest.failf "connected.%s.%s is not an int" map key

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
    R.stats_note_activity t ~machine_id:"zq-node-1" ~alias:"zq-stats-agent"
      ~ts:(now -. (10. *. day)) ();
    R.stats_note_activity t ~machine_id:"zq-node-1" ~alias:"zq-stats-agent"
      ~ts:(now -. 50.) ();
    let stats = R.stats t ~now in
    check_window stats ~window:"1d" ~messages:0 ~aliases:1 ~machines:1;
    check_window stats ~window:"ever" ~messages:0 ~aliases:1 ~machines:1

  let test_activity_window_by_last_seen () =
    let t = fresh () in
    (* A machine last active 10d ago is in 28d but not 7d/1d. *)
    R.stats_note_activity t ~machine_id:"zq-node-stale" ~alias:"zq-stats-stale"
      ~ts:(now -. (10. *. day)) ();
    R.stats_note_activity t ~machine_id:"zq-node-live" ~alias:"zq-stats-live"
      ~ts:(now -. 30.) ();
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

  (* B148: connected section — live leases only, machine dedup, client-type
     counts. register uses the real clock for last_seen, so query at real now. *)
  let test_connected_counts () =
    let t = fresh () in
    let real_now = Unix.gettimeofday () in
    (* Two claude leases on one machine (node dedup) + one codex on another. *)
    ignore
      (R.register t ~node_id:"zq-mach-A" ~session_id:"zq-cs1"
         ~alias:"zq-conn-a1" ~client_type:"claude" ());
    ignore
      (R.register t ~node_id:"zq-mach-A" ~session_id:"zq-cs2"
         ~alias:"zq-conn-a2" ~client_type:"claude" ());
    ignore
      (R.register t ~node_id:"zq-mach-B" ~session_id:"zq-cs3"
         ~alias:"zq-conn-b1" ~client_type:"codex" ());
    let stats = R.stats t ~now:real_now in
    Alcotest.(check int) "connected.clients" 3 (conn_int stats ~field:"clients");
    Alcotest.(check int) "connected.machines" 2 (conn_int stats ~field:"machines");
    Alcotest.(check int) "by_client_type.claude" 2 (conn_ct stats "claude");
    Alcotest.(check int) "by_client_type.codex" 1 (conn_ct stats "codex")

  (* B174: unique_machines / connected.machines key on opaque_host_id, not
     per-session node_id. CLI-style cli-<alias> node_ids must NOT inflate
     the machine count when they share a host id. *)
  let test_connected_machines_prefer_opaque_host () =
    let t = fresh () in
    let real_now = Unix.gettimeofday () in
    ignore
      (R.register t ~node_id:"cli-zq-a" ~session_id:"cli-zq-a"
         ~alias:"zq-host-a1" ~client_type:"cli"
         ~opaque_host_id:(Some "aabbccddeeff") ());
    ignore
      (R.register t ~node_id:"cli-zq-b" ~session_id:"cli-zq-b"
         ~alias:"zq-host-b1" ~client_type:"cli"
         ~opaque_host_id:(Some "aabbccddeeff") ());
    ignore
      (R.register t ~node_id:"cli-zq-c" ~session_id:"cli-zq-c"
         ~alias:"zq-host-c1" ~client_type:"cli"
         ~opaque_host_id:(Some "112233445566") ());
    let stats = R.stats t ~now:real_now in
    Alcotest.(check int) "B174 connected.clients" 3
      (conn_int stats ~field:"clients");
    Alcotest.(check int) "B174 connected.machines by host id" 2
      (conn_int stats ~field:"machines")

  (* B174: activity re-key retires a legacy node_id key once the real host
     id is known — unique_machines must not keep both forever. *)
  let test_activity_retires_legacy_node_key () =
    let t = fresh () in
    R.stats_note_activity t ~machine_id:"cli-zq-legacy" ~alias:"zq-leg"
      ~ts:(now -. 100.) ();
    R.stats_note_activity t ~machine_id:"aabbccddeeff"
      ~retire_key:"cli-zq-legacy" ~alias:"zq-leg" ~ts:(now -. 10.) ();
    let stats = R.stats t ~now in
    check_window stats ~window:"1d" ~messages:0 ~aliases:1 ~machines:1;
    check_window stats ~window:"ever" ~messages:0 ~aliases:1 ~machines:1

  (* B174: heartbeat can heal a lease that registered without opaque_host_id
     so connected.machines collapses without a full re-register. *)
  let test_heartbeat_heals_opaque_host () =
    let t = fresh () in
    let real_now = Unix.gettimeofday () in
    ignore
      (R.register t ~node_id:"cli-zq-heal-a" ~session_id:"cli-zq-heal-a"
         ~alias:"zq-heal-a" ~client_type:"cli" ());
    ignore
      (R.register t ~node_id:"cli-zq-heal-b" ~session_id:"cli-zq-heal-b"
         ~alias:"zq-heal-b" ~client_type:"cli" ());
    let before = R.stats t ~now:real_now in
    Alcotest.(check int) "pre-heal machines = clients (no host id)" 2
      (conn_int before ~field:"machines");
    ignore
      (R.heartbeat t ~node_id:"cli-zq-heal-a" ~session_id:"cli-zq-heal-a"
         ~opaque_host_id:"aabbccddeeff");
    ignore
      (R.heartbeat t ~node_id:"cli-zq-heal-b" ~session_id:"cli-zq-heal-b"
         ~opaque_host_id:"aabbccddeeff");
    let after = R.stats t ~now:real_now in
    Alcotest.(check int) "post-heal clients" 2 (conn_int after ~field:"clients");
    Alcotest.(check int) "post-heal machines collapse to host" 1
      (conn_int after ~field:"machines")

  (* B148: a lease drops out of connected once now advances past the alias
     release window (NOT alias_released is the liveness predicate). *)
  let test_connected_expiry () =
    let t = fresh () in
    let real_now = Unix.gettimeofday () in
    ignore
      (R.register t ~node_id:"zq-mach-exp" ~session_id:"zq-es1"
         ~alias:"zq-conn-exp" ~client_type:"kimi" ());
    let s1 = R.stats t ~now:real_now in
    Alcotest.(check int) "connected before release" 1
      (conn_int s1 ~field:"clients");
    let future = real_now +. Relay.alias_release_after_s +. 1000. in
    let s2 = R.stats t ~now:future in
    Alcotest.(check int) "connected clients after release" 0
      (conn_int s2 ~field:"clients");
    Alcotest.(check int) "connected machines after release" 0
      (conn_int s2 ~field:"machines")

  (* B149: by_version / by_os bucket client-reported register metadata; a
     lease registered without the fields (older client) lands in "unknown". *)
  let test_connected_versions () =
    let t = fresh () in
    let real_now = Unix.gettimeofday () in
    ignore
      (R.register t ~node_id:"zq-vmach-A" ~session_id:"zq-vs1"
         ~alias:"zq-ver-a1" ~client_type:"claude" ~client_version:"0.11.0"
         ~client_os:"linux" ());
    ignore
      (R.register t ~node_id:"zq-vmach-B" ~session_id:"zq-vs2"
         ~alias:"zq-ver-b1" ~client_type:"codex" ~client_version:"0.11.0"
         ~client_os:"darwin" ());
    ignore
      (R.register t ~node_id:"zq-vmach-C" ~session_id:"zq-vs3"
         ~alias:"zq-ver-c1" ~client_type:"kimi" ());
    let stats = R.stats t ~now:real_now in
    Alcotest.(check int) "by_version 0.11.0" 2
      (conn_map stats ~map:"by_version" ~key:"0.11.0");
    Alcotest.(check int) "by_version unknown" 1
      (conn_map stats ~map:"by_version" ~key:"unknown");
    Alcotest.(check int) "by_os linux" 1 (conn_map stats ~map:"by_os" ~key:"linux");
    Alcotest.(check int) "by_os darwin" 1
      (conn_map stats ~map:"by_os" ~key:"darwin");
    Alcotest.(check int) "by_os unknown" 1
      (conn_map stats ~map:"by_os" ~key:"unknown")

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
      Alcotest.test_case "connected counts live leases" `Quick
        test_connected_counts;
      Alcotest.test_case "connected machines prefer opaque host" `Quick
        test_connected_machines_prefer_opaque_host;
      Alcotest.test_case "activity retires legacy node key" `Quick
        test_activity_retires_legacy_node_key;
      Alcotest.test_case "heartbeat heals opaque host id" `Quick
        test_heartbeat_heals_opaque_host;
      Alcotest.test_case "connected drops released leases" `Quick
        test_connected_expiry;
      Alcotest.test_case "connected buckets version and os" `Quick
        test_connected_versions;
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

(* B148 (memory backend): stats survive a restart when persist_dir is set —
   mirror the sqlite reopen test. Real clock so the reload retention filter
   (relative to wall time) keeps the recent events. *)
let test_mem_persistence () =
  let dir = fresh_tmp_dir () in
  let real_now = Unix.gettimeofday () in
  let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
  Relay.InMemoryRelay.stats_note_message t ~from_alias:"zq-mp-sender"
    ~ts:(real_now -. 10.);
  Relay.InMemoryRelay.stats_note_activity t ~machine_id:"zq-mp-node"
    ~alias:"zq-mp-agent" ~ts:(real_now -. 10.) ();
  (* Reopen on the same dir: a fresh handle replays the persisted events. *)
  let t2 = Relay.InMemoryRelay.create ~persist_dir:dir () in
  let stats = Relay.InMemoryRelay.stats t2 ~now:real_now in
  (* 1 message, 2 distinct aliases (sender + activity agent), 1 machine. *)
  check_window stats ~window:"1d" ~messages:1 ~aliases:2 ~machines:1;
  check_window stats ~window:"ever" ~messages:1 ~aliases:2 ~machines:1

(* B148 (memory backend): messages_ever survives BOTH gc pruning AND a reopen —
   the pruned ancient event is gone from the windows, but the all-time counter
   (persisted in stats-totals.json) and the distinct-alias set survive. *)
let test_mem_ever_survives_gc_reopen () =
  let dir = fresh_tmp_dir () in
  let real_now = Unix.gettimeofday () in
  let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
  Relay.InMemoryRelay.stats_note_message t ~from_alias:"zq-mg-ancient"
    ~ts:(real_now -. (40. *. day));
  Relay.InMemoryRelay.stats_note_message t ~from_alias:"zq-mg-fresh"
    ~ts:(real_now -. 10.);
  (match Relay.InMemoryRelay.gc t with
   | `Ok _ -> ()
   | _ -> Alcotest.fail "gc failed");
  let t2 = Relay.InMemoryRelay.create ~persist_dir:dir () in
  let stats = Relay.InMemoryRelay.stats t2 ~now:real_now in
  Alcotest.(check int) "ever.messages survives gc+reopen" 2
    (count stats ~window:"ever" ~field:"messages");
  Alcotest.(check int) "ever.unique_aliases survives gc+reopen" 2
    (count stats ~window:"ever" ~field:"unique_aliases");
  (* 40d-old message pruned + its alias last_seen out of the 28d window. *)
  check_window stats ~window:"28d" ~messages:1 ~aliases:1 ~machines:0

(* B149 (memory backend): record_stats_snapshot appends one jsonl line per
   call to <persist_dir>/stats-history.jsonl, each carrying ts + the full
   stats object. *)
let test_mem_snapshot_history () =
  let dir = fresh_tmp_dir () in
  let real_now = Unix.gettimeofday () in
  let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
  Relay.InMemoryRelay.stats_note_message t ~from_alias:"zq-snap-sender"
    ~ts:(real_now -. 5.);
  Relay.InMemoryRelay.record_stats_snapshot t ~now:real_now;
  Relay.InMemoryRelay.record_stats_snapshot t ~now:(real_now +. 3600.);
  let path = Filename.concat dir "stats-history.jsonl" in
  let ic = open_in path in
  let lines = ref [] in
  (try
     while true do
       lines := input_line ic :: !lines
     done
   with End_of_file -> ());
  close_in ic;
  let lines = List.rev !lines in
  Alcotest.(check int) "two snapshot lines" 2 (List.length lines);
  let first = Yojson.Safe.from_string (List.hd lines) in
  (match assoc "ts" first with
   | `Float ts -> Alcotest.(check bool) "ts stamped" true (ts = real_now)
   | _ -> Alcotest.fail "snapshot ts missing");
  Alcotest.(check int) "snapshot embeds stats windows" 1
    (count (assoc "stats" first) ~window:"ever" ~field:"messages")

(* B149 (memory backend, no persist_dir): snapshot is a no-op, never raises. *)
let test_mem_snapshot_no_persist_dir () =
  let t = Relay.InMemoryRelay.create () in
  Relay.InMemoryRelay.record_stats_snapshot t ~now:(Unix.gettimeofday ())

(* B149 (sqlite): record_stats_snapshot appends rows to stats_snapshots. *)
let test_sqlite_snapshot_history () =
  let dir = fresh_tmp_dir () in
  let real_now = Unix.gettimeofday () in
  let t = Relay.SqliteRelay.create ~persist_dir:dir () in
  Relay.SqliteRelay.record_stats_snapshot t ~now:real_now;
  Relay.SqliteRelay.record_stats_snapshot t ~now:(real_now +. 3600.) ;
  let conn = Sqlite3.db_open (Filename.concat dir "c2c_relay.db") in
  let count = ref (-1) in
  let stmt = Sqlite3.prepare conn "SELECT COUNT(*), MIN(ts) FROM stats_snapshots" in
  (if Sqlite3.step stmt = Sqlite3.Rc.ROW then
     count := Sqlite3.Data.to_int_exn (Sqlite3.column stmt 0));
  Sqlite3.finalize stmt |> ignore;
  Sqlite3.db_close conn |> ignore;
  Alcotest.(check int) "two snapshot rows" 2 !count

(* B149 (sqlite): a pre-B149 database (leases table without client_version /
   client_os) is migrated in place by create — registration with version
   metadata then works and feeds connected.by_version. *)
let test_sqlite_migration_adds_version_columns () =
  let dir = fresh_tmp_dir () in
  let db_path = Filename.concat dir "c2c_relay.db" in
  (* Hand-build an old-shape leases table (pre-B149: 12 columns). *)
  let conn = Sqlite3.db_open db_path in
  Sqlite3.exec conn
    "CREATE TABLE leases (alias TEXT PRIMARY KEY, node_id TEXT NOT NULL, \
     session_id TEXT NOT NULL, client_type TEXT NOT NULL DEFAULT 'unknown', \
     registered_at REAL NOT NULL, last_seen REAL NOT NULL, ttl REAL NOT NULL, \
     identity_pk TEXT NOT NULL DEFAULT '', enc_pubkey TEXT NOT NULL DEFAULT '', \
     signed_at REAL NOT NULL DEFAULT 0, sig_b64 TEXT NOT NULL DEFAULT '', \
     opaque_host_id TEXT NOT NULL DEFAULT '')"
  |> ignore;
  Sqlite3.db_close conn |> ignore;
  let t = Relay.SqliteRelay.create ~persist_dir:dir () in
  ignore
    (Relay.SqliteRelay.register t ~node_id:"zq-migr-node"
       ~session_id:"zq-migr-s1" ~alias:"zq-migr-a1" ~client_type:"claude"
       ~client_version:"0.11.0" ~client_os:"linux" ());
  let stats = Relay.SqliteRelay.stats t ~now:(Unix.gettimeofday ()) in
  Alcotest.(check int) "migrated db buckets by_version" 1
    (conn_map stats ~map:"by_version" ~key:"0.11.0");
  (* Reopen: the metadata persists in the migrated columns. *)
  let t2 = Relay.SqliteRelay.create ~persist_dir:dir () in
  let stats2 = Relay.SqliteRelay.stats t2 ~now:(Unix.gettimeofday ()) in
  Alcotest.(check int) "by_version survives reopen" 1
    (conn_map stats2 ~map:"by_version" ~key:"0.11.0");
  Alcotest.(check int) "by_os survives reopen" 1
    (conn_map stats2 ~map:"by_os" ~key:"linux")

(* B148: humanize_ago boundary table (pure, clock-free). *)
let test_humanize_ago () =
  let check expected input =
    Alcotest.(check string)
      (Printf.sprintf "humanize_ago %g" input)
      expected
      (Relay.humanize_ago input)
  in
  check "just now" 0.;
  check "just now" 1.9;
  check "just now" (-5.);
  check "2s ago" 2.;
  check "42s ago" 42.;
  check "59s ago" 59.;
  check "1m ago" 60.;
  check "3m ago" 200.;
  check "59m ago" 3599.;
  check "1h ago" 3600.;
  check "2h ago" 7200.;
  check "23h ago" 86399.;
  check "1d ago" 86400.;
  check "5d ago" (5. *. day)

(* Sqlite-only: stats survive a relay restart (fresh handle, same DB). *)
let test_sqlite_persistence () =
  let dir = fresh_tmp_dir () in
  let t = Relay.SqliteRelay.create ~persist_dir:dir () in
  Relay.SqliteRelay.stats_note_message t ~from_alias:"zq-stats-persist"
    ~ts:(now -. 10.);
  Relay.SqliteRelay.stats_note_activity t ~machine_id:"zq-node-persist"
    ~alias:"zq-stats-persist" ~ts:(now -. 10.) ();
  let t2 = Relay.SqliteRelay.create ~persist_dir:dir () in
  let stats = Relay.SqliteRelay.stats t2 ~now in
  check_window stats ~window:"ever" ~messages:1 ~aliases:1 ~machines:1

(* B286: helper — read the "ts" float from a {"ts":..,"stats":..} snapshot. *)
let snapshot_ts j =
  match assoc "ts" j with
  | `Float f -> f
  | `Int i -> float_of_int i
  | _ -> Alcotest.fail "snapshot ts is not a number"

(* B286 (memory backend): query_stats_snapshots reads back recorded snapshots
   ascending by ts, honours the since filter and keeps the most-recent [limit]. *)
let test_mem_stats_history_query () =
  let dir = fresh_tmp_dir () in
  let real_now = Unix.gettimeofday () in
  let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
  Relay.InMemoryRelay.record_stats_snapshot t ~now:real_now;
  Relay.InMemoryRelay.record_stats_snapshot t ~now:(real_now +. 3600.);
  Relay.InMemoryRelay.record_stats_snapshot t ~now:(real_now +. 7200.);
  let all = Relay.InMemoryRelay.query_stats_snapshots t () in
  Alcotest.(check int) "three snapshots" 3 (List.length all);
  Alcotest.(check bool) "ascending ts + oldest first" true
    (snapshot_ts (List.nth all 0) = real_now
     && snapshot_ts (List.nth all 1) = real_now +. 3600.
     && snapshot_ts (List.nth all 2) = real_now +. 7200.);
  (* each element embeds a full /stats-shaped object. *)
  ignore (count (assoc "stats" (List.hd all)) ~window:"ever" ~field:"messages");
  let since =
    Relay.InMemoryRelay.query_stats_snapshots t ~since:(real_now +. 3600.) ()
  in
  Alcotest.(check int) "since keeps 2" 2 (List.length since);
  Alcotest.(check bool) "since lower bound" true
    (snapshot_ts (List.hd since) = real_now +. 3600.);
  let lim = Relay.InMemoryRelay.query_stats_snapshots t ~limit:1 () in
  Alcotest.(check int) "limit 1" 1 (List.length lim);
  Alcotest.(check bool) "limit keeps most recent" true
    (snapshot_ts (List.hd lim) = real_now +. 7200.)

(* B286 (memory backend): non-monotonic snapshot ts (clock rollback / backfill)
   must still come back ascending by ts, and limit must keep the ts-most-recent
   (not the file-most-recent). limit=0 returns nothing. *)
let test_mem_stats_history_nonmonotonic () =
  let dir = fresh_tmp_dir () in
  let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
  (* Write in file order 100, 300, 200 — deliberately out of ts order. *)
  List.iter
    (fun ts -> Relay.InMemoryRelay.record_stats_snapshot t ~now:ts)
    [ 100.; 300.; 200. ];
  let all = Relay.InMemoryRelay.query_stats_snapshots t () in
  Alcotest.(check (list (float 0.))) "ascending by ts, not file order"
    [ 100.; 200.; 300. ]
    (List.map snapshot_ts all);
  let lim = Relay.InMemoryRelay.query_stats_snapshots t ~limit:1 () in
  Alcotest.(check int) "limit 1 count" 1 (List.length lim);
  Alcotest.(check (float 0.)) "limit 1 keeps ts-most-recent" 300.
    (snapshot_ts (List.hd lim));
  Alcotest.(check int) "limit 0 yields empty" 0
    (List.length (Relay.InMemoryRelay.query_stats_snapshots t ~limit:0 ()))

(* B286 (memory backend): the ts-most-recent snapshot must survive selection
   even when it appears FIRST in file order and there are more rows than
   [limit] — a FIFO/last-N-by-file-order window would wrongly evict it. *)
let test_mem_stats_history_ring_boundary () =
  let dir = fresh_tmp_dir () in
  let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
  (* Largest ts (500) is written FIRST; four smaller ts follow. With limit=2
     the correct top-2 by ts is {13, 500}, not the last two file rows {12,13}. *)
  List.iter
    (fun ts -> Relay.InMemoryRelay.record_stats_snapshot t ~now:ts)
    [ 500.; 10.; 11.; 12.; 13. ];
  let lim2 = Relay.InMemoryRelay.query_stats_snapshots t ~limit:2 () in
  Alcotest.(check (list (float 0.)))
    "top-2 by ts keeps early large ts across the ring boundary"
    [ 13.; 500. ]
    (List.map snapshot_ts lim2)

(* B286 (sqlite): same non-monotonic + limit contract as the memory backend. *)
let test_sqlite_stats_history_nonmonotonic () =
  let dir = fresh_tmp_dir () in
  let t = Relay.SqliteRelay.create ~persist_dir:dir () in
  List.iter
    (fun ts -> Relay.SqliteRelay.record_stats_snapshot t ~now:ts)
    [ 100.; 300.; 200. ];
  let all = Relay.SqliteRelay.query_stats_snapshots t () in
  Alcotest.(check (list (float 0.))) "ascending by ts, not insert order"
    [ 100.; 200.; 300. ]
    (List.map snapshot_ts all);
  let lim = Relay.SqliteRelay.query_stats_snapshots t ~limit:1 () in
  Alcotest.(check int) "limit 1 count" 1 (List.length lim);
  Alcotest.(check (float 0.)) "limit 1 keeps ts-most-recent" 300.
    (snapshot_ts (List.hd lim));
  Alcotest.(check int) "limit 0 yields empty" 0
    (List.length (Relay.SqliteRelay.query_stats_snapshots t ~limit:0 ()))

(* B286 (memory backend, no persist_dir): history query is empty, never raises. *)
let test_mem_stats_history_no_persist () =
  let t = Relay.InMemoryRelay.create () in
  Alcotest.(check int) "no persist_dir yields empty history" 0
    (List.length (Relay.InMemoryRelay.query_stats_snapshots t ()))

(* B286 (sqlite): query_stats_snapshots mirrors the memory backend — ascending
   ts, since filter, most-recent limit, and survives a reopen. *)
let test_sqlite_stats_history_query () =
  let dir = fresh_tmp_dir () in
  let real_now = Unix.gettimeofday () in
  let t = Relay.SqliteRelay.create ~persist_dir:dir () in
  Relay.SqliteRelay.record_stats_snapshot t ~now:real_now;
  Relay.SqliteRelay.record_stats_snapshot t ~now:(real_now +. 3600.);
  Relay.SqliteRelay.record_stats_snapshot t ~now:(real_now +. 7200.);
  let all = Relay.SqliteRelay.query_stats_snapshots t () in
  Alcotest.(check int) "three snapshots" 3 (List.length all);
  Alcotest.(check bool) "ascending ts + oldest first" true
    (snapshot_ts (List.nth all 0) = real_now
     && snapshot_ts (List.nth all 1) = real_now +. 3600.
     && snapshot_ts (List.nth all 2) = real_now +. 7200.);
  ignore (count (assoc "stats" (List.hd all)) ~window:"ever" ~field:"messages");
  let since =
    Relay.SqliteRelay.query_stats_snapshots t ~since:(real_now +. 3600.) ()
  in
  Alcotest.(check int) "since keeps 2" 2 (List.length since);
  Alcotest.(check bool) "since lower bound" true
    (snapshot_ts (List.hd since) = real_now +. 3600.);
  let lim = Relay.SqliteRelay.query_stats_snapshots t ~limit:1 () in
  Alcotest.(check int) "limit 1" 1 (List.length lim);
  Alcotest.(check bool) "limit keeps most recent" true
    (snapshot_ts (List.hd lim) = real_now +. 7200.);
  (* Reopen: rows persist in the stats_snapshots table. *)
  let t2 = Relay.SqliteRelay.create ~persist_dir:dir () in
  Alcotest.(check int) "history survives reopen" 3
    (List.length (Relay.SqliteRelay.query_stats_snapshots t2 ()))

(* B286: /stats/history is anonymously readable — pin the classification. *)
let test_stats_history_route_is_anonymous () =
  (match
     Relay_server_auth.classify_route ~path:"/stats/history" ~include_dead:false
   with
   | Relay_server_auth.Anonymous_read -> ()
   | _ -> Alcotest.fail "/stats/history must classify as Anonymous_read");
  let allow, err =
    Relay_server_auth.auth_decision ~path:"/stats/history" ~include_dead:false
      ~token:(Some "prod-token") ~auth_header:None ~ed25519_verified:false
  in
  Alcotest.(check bool) "/stats/history allowed without credentials" true allow;
  Alcotest.(check (option string)) "/stats/history no auth error" None err

(* B286 (cross-backend, reviewer P1): two snapshots share ts=100 but differ in
   content (message count); a third at ts=200 is newest. With limit=2 the
   selection at the tied boundary must be deterministic AND identical across
   backends — the later-INSERTED ts=100 row (the one with the message, seq/rowid
   higher) survives, the earlier ts=100 row is evicted, and the series comes back
   ascending. A ts-only tie-break would pick an arbitrary/backend-specific row. *)
let history_ts_msg_pairs snapshots =
  List.map
    (fun e ->
      (snapshot_ts e, count (assoc "stats" e) ~window:"ever" ~field:"messages"))
    snapshots

let test_stats_history_tie_break_cross_backend () =
  let mem () =
    let dir = fresh_tmp_dir () in
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    Relay.InMemoryRelay.record_stats_snapshot t ~now:100.;
    Relay.InMemoryRelay.stats_note_message t ~from_alias:"zq-tie-sender" ~ts:50.;
    Relay.InMemoryRelay.record_stats_snapshot t ~now:100.;
    Relay.InMemoryRelay.record_stats_snapshot t ~now:200.;
    history_ts_msg_pairs (Relay.InMemoryRelay.query_stats_snapshots t ~limit:2 ())
  in
  let sql () =
    let dir = fresh_tmp_dir () in
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    Relay.SqliteRelay.record_stats_snapshot t ~now:100.;
    Relay.SqliteRelay.stats_note_message t ~from_alias:"zq-tie-sender" ~ts:50.;
    Relay.SqliteRelay.record_stats_snapshot t ~now:100.;
    Relay.SqliteRelay.record_stats_snapshot t ~now:200.;
    history_ts_msg_pairs (Relay.SqliteRelay.query_stats_snapshots t ~limit:2 ())
  in
  let expected = [ (100., 1); (200., 1) ] in
  let testable = Alcotest.(list (pair (float 0.) int)) in
  Alcotest.check testable
    "memory keeps later-inserted equal-ts row (msgs=1), ascending" expected
    (mem ());
  Alcotest.check testable
    "sqlite keeps later-inserted equal-ts row (msgs=1), ascending" expected
    (sql ())

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
      ( "in-memory",
        Mem_tests.cases
        @ [
            Alcotest.test_case "stats persist across reopen" `Quick
              test_mem_persistence;
            Alcotest.test_case "messages_ever survives gc + reopen" `Quick
              test_mem_ever_survives_gc_reopen;
            Alcotest.test_case "snapshot history appends jsonl" `Quick
              test_mem_snapshot_history;
            Alcotest.test_case "snapshot without persist_dir is a no-op" `Quick
              test_mem_snapshot_no_persist_dir;
            Alcotest.test_case "stats history query (since/limit/order)" `Quick
              test_mem_stats_history_query;
            Alcotest.test_case "stats history non-monotonic + limit" `Quick
              test_mem_stats_history_nonmonotonic;
            Alcotest.test_case "stats history ring-boundary top-k by ts" `Quick
              test_mem_stats_history_ring_boundary;
            Alcotest.test_case "stats history empty without persist_dir" `Quick
              test_mem_stats_history_no_persist;
          ] );
      ( "sqlite",
        Sql_tests.cases
        @ [
            Alcotest.test_case "stats persist across reopen" `Quick
              test_sqlite_persistence;
            Alcotest.test_case "snapshot history appends rows" `Quick
              test_sqlite_snapshot_history;
            Alcotest.test_case "pre-B149 db migrates version columns" `Quick
              test_sqlite_migration_adds_version_columns;
            Alcotest.test_case "stats history query (since/limit/order)" `Quick
              test_sqlite_stats_history_query;
            Alcotest.test_case "stats history non-monotonic + limit" `Quick
              test_sqlite_stats_history_nonmonotonic;
          ] );
      ( "humanize-ago",
        [ Alcotest.test_case "humanize_ago boundaries" `Quick test_humanize_ago ]
      );
      ( "history-cross-backend",
        [
          Alcotest.test_case "equal-ts tie-break agrees across backends" `Quick
            test_stats_history_tie_break_cross_backend;
        ] );
      ( "route-auth",
        [
          Alcotest.test_case "/stats is anonymous" `Quick
            test_stats_route_is_anonymous;
          Alcotest.test_case "/stats/history is anonymous" `Quick
            test_stats_history_route_is_anonymous;
        ] );
    ]
