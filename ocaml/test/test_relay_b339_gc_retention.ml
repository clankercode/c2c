(* B339: two unbounded relay stores get gc retention.

   1. relay_mobile_pair_nonce_cache.cleanup_nonce_cache had NO callers — the
      process-global mobile-pair replay cache grew forever. The gc sweep now
      calls it every tick with mobile_pair_nonce_window_s (3600s; pairing
      tokens are server-capped at 300s TTL).
   2. dead_letter was never pruned in either backend. Retention choice
      (recorded): age-based at dead_letter_retention_s (30 days — the
      content-bearing gc convention; stats events keep 28d+1d grace) AND a
      hard dead_letter_max_entries (10k) cap, newest kept, so a storm is
      bounded independent of age. Wired into BOTH backends' gc.

   Retention must cover BOTH backends: B337 just made sqlite send write
   dead_letter rows, so sqlite is no longer a passive observer here. *)

open Alcotest

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b339" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

let now = Unix.gettimeofday ()

let dl_row ~message_id ~content ~ts =
  `Assoc [ ("message_id", `String message_id); ("from_alias", `String "b339-from");
           ("to_alias", `String "b339-to"); ("content", `String content);
           ("ts", `Float ts); ("reason", `String "unknown_alias") ]

let contents dl =
  List.map
    (fun msg ->
       match Yojson.Safe.Util.member "content" msg with
       | `String c -> c
       | _ -> "")
    dl

(* --- in-memory dead_letter retention --- *)

let test_inmemory_gc_prunes_aged_dead_letter () =
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    Relay.InMemoryRelay.add_dead_letter t (dl_row ~message_id:"m-old" ~content:"old" ~ts:(now -. 40. *. 86_400.));
    Relay.InMemoryRelay.add_dead_letter t (dl_row ~message_id:"m-fresh" ~content:"fresh" ~ts:(now -. 3600.));
    let before = contents (Relay.InMemoryRelay.dead_letter t) in
    check bool "both rows present before gc" true
      (before = [ "old"; "fresh" ] || before = [ "fresh"; "old" ]);
    ignore (Relay.InMemoryRelay.gc t);
    check bool "aged row pruned, fresh row kept by gc" true
      (contents (Relay.InMemoryRelay.dead_letter t) = [ "fresh" ]))

let test_inmemory_gc_enforces_dead_letter_count_cap () =
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    let total = Relay.dead_letter_max_entries + 5 in
    for i = 1 to total do
      Relay.InMemoryRelay.add_dead_letter t
        (dl_row ~message_id:(Printf.sprintf "m%d" i) ~content:(string_of_int i) ~ts:(now -. float_of_int (total - i)))
    done;
    ignore (Relay.InMemoryRelay.gc t);
    let kept = contents (Relay.InMemoryRelay.dead_letter t) in
    check int "cap holds" Relay.dead_letter_max_entries (List.length kept);
    (* The NEWEST entries survive the cap: the 5 oldest are dropped. *)
    check bool "oldest dropped first" true (not (List.mem "1" kept));
    check bool "newest kept" true (List.mem (string_of_int total) kept))

(* --- sqlite dead_letter retention --- *)

let test_sqlite_gc_prunes_aged_dead_letter () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    Relay.SqliteRelay.add_dead_letter t (dl_row ~message_id:"s-old" ~content:"old" ~ts:(now -. 40. *. 86_400.));
    Relay.SqliteRelay.add_dead_letter t (dl_row ~message_id:"s-fresh" ~content:"fresh" ~ts:(now -. 3600.));
    ignore (Relay.SqliteRelay.gc t);
    check bool "sqlite: aged row pruned, fresh row kept by gc" true
      (contents (Relay.SqliteRelay.dead_letter t) = [ "fresh" ]))

let test_sqlite_gc_enforces_dead_letter_count_cap () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let total = Relay.dead_letter_max_entries + 5 in
    for i = 1 to total do
      Relay.SqliteRelay.add_dead_letter t
        (dl_row ~message_id:(Printf.sprintf "s%d" i) ~content:(string_of_int i) ~ts:(now -. float_of_int (total - i)))
    done;
    ignore (Relay.SqliteRelay.gc t);
    let kept = contents (Relay.SqliteRelay.dead_letter t) in
    check int "sqlite: cap holds" Relay.dead_letter_max_entries (List.length kept);
    check bool "sqlite: oldest dropped first" true (not (List.mem "1" kept));
    check bool "sqlite: newest kept" true (List.mem (string_of_int total) kept))

(* --- mobile-pair nonce cache rides the gc sweep --- *)

let test_gc_prunes_expired_pair_nonces () =
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    let pk = "b339-pk-expired" in
    Relay.record_nonce ~phone_pubkey:pk ~nonce:"n-old" ~now:(now -. 7200.);
    Relay.record_nonce ~phone_pubkey:pk ~nonce:"n-fresh" ~now;
    check bool "old nonce visible before gc" true
      (Relay.is_nonce_seen ~phone_pubkey:pk ~nonce:"n-old");
    ignore (Relay.InMemoryRelay.gc t);
    check bool "gc removed the past-window nonce" false
      (Relay.is_nonce_seen ~phone_pubkey:pk ~nonce:"n-old");
    check bool "gc kept the fresh nonce" true
      (Relay.is_nonce_seen ~phone_pubkey:pk ~nonce:"n-fresh"))

let test_gc_keeps_fresh_pair_nonces () =
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    let pk = "b339-pk-fresh" in
    Relay.record_nonce ~phone_pubkey:pk ~nonce:"n1" ~now:(now -. 60.);
    Relay.record_nonce ~phone_pubkey:pk ~nonce:"n2" ~now:(now -. 120.);
    ignore (Relay.InMemoryRelay.gc t);
    check bool "recent nonces survive gc" true
      (Relay.is_nonce_seen ~phone_pubkey:pk ~nonce:"n1"
       && Relay.is_nonce_seen ~phone_pubkey:pk ~nonce:"n2"))

let () =
  run "B339 gc retention: dead_letter age+cap, mobile-pair nonce window"
    [ ( "in-memory dead_letter retention",
        [ Alcotest.test_case "gc prunes aged rows, keeps fresh" `Quick
            test_inmemory_gc_prunes_aged_dead_letter
        ; Alcotest.test_case "gc enforces the count cap, newest kept" `Quick
            test_inmemory_gc_enforces_dead_letter_count_cap
        ] )
    ; ( "sqlite dead_letter retention",
        [ Alcotest.test_case "gc prunes aged rows, keeps fresh" `Quick
            test_sqlite_gc_prunes_aged_dead_letter
        ; Alcotest.test_case "gc enforces the count cap, newest kept" `Quick
            test_sqlite_gc_enforces_dead_letter_count_cap
        ] )
    ; ( "mobile-pair nonce cache",
        [ Alcotest.test_case "gc removes past-window nonces" `Quick
            test_gc_prunes_expired_pair_nonces
        ; Alcotest.test_case "gc keeps recent nonces" `Quick
            test_gc_keeps_fresh_pair_nonces
        ] )
    ]
