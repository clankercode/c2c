(* Hermetic tests for C2c_codex_daemon_sidecar lease ownership. *)

open Alcotest
module S = C2c_codex_daemon_sidecar

let ( // ) = Filename.concat

let with_temp f =
  let dir =
    Filename.get_temp_dir_name ()
    // Printf.sprintf "c2c-codex-daemon-owner-%08x" (Random.bits ())
  in
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

let live _ = true
let dead _ = false

let claim dir ~sock ~thread ~pid ~alias ~sid ?(now = 10.) ?(holder_live = live) () =
  S.try_claim ~owners_dir:dir ~socket_identity:sock ~thread_id:thread
    ~sidecar_pid:pid ~alias ~broker_session_id:sid ~now ~holder_live ()

let test_key_stable_and_ignores_alias () =
  let k1 = S.lease_key ~socket_identity:"/tmp/sock" ~thread_id:"thr-a" in
  let k2 = S.lease_key ~socket_identity:"/tmp/sock" ~thread_id:"thr-a" in
  let k3 = S.lease_key ~socket_identity:"/tmp/sock" ~thread_id:"thr-b" in
  let k4 = S.lease_key ~socket_identity:"/other" ~thread_id:"thr-a" in
  check string "stable" k1 k2;
  check bool "thread distinguishes" true (k1 <> k3);
  check bool "socket distinguishes" true (k1 <> k4);
  check int "32 hex" 32 (String.length k1)

let test_first_claim_wins () =
  with_temp @@ fun dir ->
  match
    claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a1" ~sid:"s1" ()
  with
  | S.Claimed l ->
      check int "pid" 100 l.sidecar_pid;
      check string "thread" "t1" l.thread_id
  | _ -> fail "first claim must be Claimed"

let test_live_holder_blocks_other_pid () =
  with_temp @@ fun dir ->
  ignore (claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a1" ~sid:"s1" ());
  match
    claim dir ~sock:"/sock" ~thread:"t1" ~pid:200 ~alias:"a2" ~sid:"s2" ()
  with
  | S.Held_live l ->
      check int "still first pid" 100 l.sidecar_pid;
      check string "alias of holder" "a1" l.alias
  | other ->
      fail
        (match other with
         | S.Claimed _ -> "Claimed"
         | S.Already_ours _ -> "Already_ours"
         | S.Reclaimed _ -> "Reclaimed"
         | S.Held_live _ -> "Held_live")

let test_two_aliases_same_thread_fail_closed () =
  (* Lease key ignores c2c session/alias: second alias cannot own the thread. *)
  with_temp @@ fun dir ->
  ignore
    (claim dir ~sock:"/sock" ~thread:"shared-thread" ~pid:11 ~alias:"codex-one"
       ~sid:"sess-one" ());
  match
    claim dir ~sock:"/sock" ~thread:"shared-thread" ~pid:22 ~alias:"codex-two"
      ~sid:"sess-two" ()
  with
  | S.Held_live l -> check string "first alias keeps it" "codex-one" l.alias
  | _ -> fail "second alias must fail closed"

let test_stale_holder_reclaimed () =
  with_temp @@ fun dir ->
  ignore
    (claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"old" ~sid:"s-old" ());
  match
    claim dir ~sock:"/sock" ~thread:"t1" ~pid:200 ~alias:"new" ~sid:"s-new"
      ~holder_live:dead ()
  with
  | S.Reclaimed l ->
      check int "new pid" 200 l.sidecar_pid;
      check string "new alias" "new" l.alias
  | _ -> fail "stale holder must be Reclaimed"

let test_same_pid_is_already_ours () =
  with_temp @@ fun dir ->
  ignore (claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s" ~now:10. ());
  match
    claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s" ~now:20. ()
  with
  | S.Already_ours l -> check (float 1e-6) "heartbeat refreshed" 20. l.heartbeat_at
  | _ -> fail "same pid must be Already_ours"

let test_distinct_threads_independent () =
  with_temp @@ fun dir ->
  (match claim dir ~sock:"/sock" ~thread:"t1" ~pid:1 ~alias:"a" ~sid:"s1" () with
   | S.Claimed _ -> ()
   | _ -> fail "t1");
  match claim dir ~sock:"/sock" ~thread:"t2" ~pid:2 ~alias:"b" ~sid:"s2" () with
  | S.Claimed l -> check string "t2" "t2" l.thread_id
  | _ -> fail "distinct thread must claim independently"

let test_release_then_other_claims () =
  with_temp @@ fun dir ->
  ignore (claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s" ());
  S.release ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1"
    ~sidecar_pid:100;
  match claim dir ~sock:"/sock" ~thread:"t1" ~pid:200 ~alias:"b" ~sid:"s2" () with
  | S.Claimed l -> check int "after release" 200 l.sidecar_pid
  | _ -> fail "release must allow a new claim"

let test_select_owned_thread_fail_closed () =
  check (option string) "hint in loaded" (Some "thr-a")
    (S.select_owned_thread ~hint:"thr-a" ~loaded:[ "thr-b"; "thr-a" ]);
  check (option string) "hint missing" None
    (S.select_owned_thread ~hint:"sess-alias" ~loaded:[ "thr-a"; "thr-b" ]);
  check (option string) "empty hint" None
    (S.select_owned_thread ~hint:"" ~loaded:[ "thr-a" ]);
  check (option string) "empty loaded" None
    (S.select_owned_thread ~hint:"thr-a" ~loaded:[])

let test_unix_endpoint_missing () =
  check (option string) "missing path" None
    (Option.map (fun e -> e.C2c_codex_app_server.host)
       (S.unix_endpoint "/no/such/codex-daemon.sock"))

let test_foreign_release_is_noop () =
  with_temp @@ fun dir ->
  ignore (claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s" ());
  S.release ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1"
    ~sidecar_pid:999;
  match claim dir ~sock:"/sock" ~thread:"t1" ~pid:200 ~alias:"b" ~sid:"s2" () with
  | S.Held_live l -> check int "foreign release ignored" 100 l.sidecar_pid
  | _ -> fail "foreign release must not drop the lease"

let test_claim_creates_stable_lock_file () =
  with_temp @@ fun dir ->
  ignore (claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s" ());
  let path = S.lease_path ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1" in
  check bool "lease exists" true (Sys.file_exists path);
  check bool "stable lock exists" true (Sys.file_exists (path ^ ".lock"))

let () =
  run "c2c_codex_daemon_sidecar"
    [ ( "lease",
        [ test_case "key stable, ignores alias" `Quick test_key_stable_and_ignores_alias
        ; test_case "first claim wins" `Quick test_first_claim_wins
        ; test_case "live holder blocks other pid" `Quick test_live_holder_blocks_other_pid
        ; test_case "two aliases same thread fail closed" `Quick
            test_two_aliases_same_thread_fail_closed
        ; test_case "stale holder reclaimed" `Quick test_stale_holder_reclaimed
        ; test_case "same pid already ours" `Quick test_same_pid_is_already_ours
        ; test_case "distinct threads independent" `Quick test_distinct_threads_independent
        ; test_case "release then other claims" `Quick test_release_then_other_claims
        ; test_case "foreign release is noop" `Quick test_foreign_release_is_noop
        ; test_case "claim uses stable lock" `Quick test_claim_creates_stable_lock_file
        ; test_case "unix endpoint missing path" `Quick test_unix_endpoint_missing
        ; test_case "select_owned_thread fail closed" `Quick
            test_select_owned_thread_fail_closed
        ] ) ]
