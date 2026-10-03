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

let claim dir ~sock ~thread ~pid ~alias ~sid ?(start_time = None)
    ?(now = 10.) ?(holder_live = live) () =
  S.try_claim ~owners_dir:dir ~socket_identity:sock ~thread_id:thread
    ~sidecar_pid:pid ~alias ~broker_session_id:sid ?sidecar_pid_start_time:start_time
    ~now ~holder_live ()

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
         | S.Held_live _ -> "Held_live"
         | S.Claim_uncertain reason -> "Claim_uncertain: " ^ reason)

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
  ignore
    (claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s"
       ~start_time:(Some 10) ~now:10. ());
  match
    claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s"
      ~start_time:(Some 10) ~now:20. ()
  with
  | S.Already_ours l -> check (float 1e-6) "heartbeat refreshed" 20. l.heartbeat_at
  | _ -> fail "same pid must be Already_ours"

let test_same_pid_different_generation_is_not_ours () =
  with_temp @@ fun dir ->
  ignore
    (claim dir ~sock:"/sock" ~thread:"t-generation" ~pid:100 ~alias:"old"
       ~sid:"s-old" ~start_time:(Some 10) ());
  match
    claim dir ~sock:"/sock" ~thread:"t-generation" ~pid:100 ~alias:"new"
      ~sid:"s-new" ~start_time:(Some 11) ~holder_live:dead ()
  with
  | S.Reclaimed l ->
      check int "reused pid generation replaces stale owner" 11
        (Option.get l.sidecar_pid_start_time);
      check string "new owner" "new" l.alias
  | _ -> fail "same numeric pid with a different generation must not be ours"

let test_heartbeat_requires_exact_generation_and_owner_identity () =
  with_temp @@ fun dir ->
  let pid = Unix.getpid () in
  let generation =
    match C2c_mcp.Broker.read_pid_start_time pid with
    | Some n -> n
    | None -> fail "current pid generation unavailable"
  in
  ignore
    (claim dir ~sock:"/sock" ~thread:"heartbeat" ~pid ~alias:"owner"
       ~sid:"owner-session" ~start_time:(Some generation) ());
  let heartbeat ?(start_time = generation) ?(alias = "owner")
      ?(sid = "owner-session") () =
    S.heartbeat ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"heartbeat"
      ~sidecar_pid:pid ~sidecar_pid_start_time:start_time ~alias
      ~broker_session_id:sid ~now:20. ()
  in
  check bool "matching heartbeat refreshes" true
    (Option.is_some (heartbeat ()));
  check bool "recycled generation cannot refresh" false
    (Option.is_some (heartbeat ~start_time:(generation + 1) ()));
  check bool "mismatched alias cannot refresh" false
    (Option.is_some (heartbeat ~alias:"other" ()));
  check bool "mismatched broker session cannot refresh" false
    (Option.is_some (heartbeat ~sid:"other-session" ()))

let test_mismatched_lease_filename_blocks_claim_and_cleanup () =
  with_temp @@ fun dir ->
  let source = S.lease_path ~owners_dir:dir ~socket_identity:"/wrong"
      ~thread_id:"wrong-thread" in
  ignore
    (claim dir ~sock:"/wrong" ~thread:"wrong-thread" ~pid:100 ~alias:"owner"
       ~sid:"target-session" ~start_time:(Some 10) ());
  let target = S.lease_path ~owners_dir:dir ~socket_identity:"/sock"
      ~thread_id:"target-thread" in
  Sys.rename source target;
  (match
     S.try_claim ~owners_dir:dir ~socket_identity:"/sock"
       ~thread_id:"target-thread" ~sidecar_pid:200 ~alias:"new"
       ~broker_session_id:"target-session" ~sidecar_pid_start_time:20 ()
   with
   | S.Claim_uncertain _ -> ()
   | _ -> fail "mismatched lease filename must block claim");
  check bool "mismatched lease remains" true (Sys.file_exists target);
  check bool "mismatched lease blocks cleanup" false
    (S.stop_for_session ~owners_dir:dir ~broker_session_id:"target-session");
  check bool "mismatched lease remains after cleanup" true
    (Sys.file_exists target)

let test_lease_symlink_is_not_an_exact_record () =
  with_temp @@ fun dir ->
  let canonical =
    S.lease_path ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"symlink"
  in
  ignore
    (claim dir ~sock:"/sock" ~thread:"symlink" ~pid:100 ~alias:"owner"
       ~sid:"symlink-session" ~start_time:(Some 10) ());
  let backing = dir // "backing.json" in
  Sys.rename canonical backing;
  Unix.symlink backing canonical;
  (match
     S.try_claim ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"symlink"
       ~sidecar_pid:200 ~alias:"new" ~broker_session_id:"symlink-session"
       ~sidecar_pid_start_time:20 ()
   with
   | S.Claim_uncertain _ -> ()
   | _ -> fail "a symlink lease path must remain uncertain");
  check bool "release does not unlink a different backing path" false
    (S.release ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"symlink"
       ~sidecar_pid:100 ~sidecar_pid_start_time:10 ());
  check bool "symlink lease remains" true (Sys.file_exists canonical);
  check bool "backing lease remains" true (Sys.file_exists backing)

let test_distinct_threads_independent () =
  with_temp @@ fun dir ->
  (match claim dir ~sock:"/sock" ~thread:"t1" ~pid:1 ~alias:"a" ~sid:"s1" () with
   | S.Claimed _ -> ()
   | _ -> fail "t1");
  match claim dir ~sock:"/sock" ~thread:"t2" ~pid:2 ~alias:"b" ~sid:"s2" () with
  | S.Claimed l -> check string "t2" "t2" l.thread_id
  | _ -> fail "distinct thread must claim independently"

let test_release_removes_exact_owner () =
  with_temp @@ fun dir ->
  ignore
    (claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s"
       ~start_time:(Some 10) ());
  check bool "release removes exact owner" true
    (S.release ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1"
       ~sidecar_pid:100 ~sidecar_pid_start_time:10 ());
  check bool "exact owner lease removed" false
    (Sys.file_exists
       (S.lease_path ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1"));
  match claim dir ~sock:"/sock" ~thread:"t1" ~pid:200 ~alias:"b" ~sid:"s2" () with
  | S.Claimed l -> check int "new owner claims after release" 200 l.sidecar_pid
  | _ -> fail "released exact owner must allow a new claim"

let test_release_confirms_missing_and_rejects_unreadable () =
  with_temp @@ fun dir ->
  check bool "already absent is confirmed" true
    (S.release ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"missing"
       ~sidecar_pid:100 ~sidecar_pid_start_time:10 ());
  let path =
    S.lease_path ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"bad"
  in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc "not-json\n");
  check bool "unreadable lease is uncertain" false
    (S.release ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"bad"
       ~sidecar_pid:100 ~sidecar_pid_start_time:10 ());
  check bool "unreadable lease retained" true (Sys.file_exists path)

let test_release_failure_retains_dependent_cleanup_state () =
  let cleanup_ran = ref false in
  check bool "release failure is reported" false
    (S.release_before_cleanup
       ~release:(fun () -> false)
       ~cleanup:(fun () -> cleanup_ran := true; true));
  check bool "dependent cleanup is retained for retry" false !cleanup_ran;
  check bool "successful release permits cleanup" true
    (S.release_before_cleanup
       ~release:(fun () -> true)
       ~cleanup:(fun () -> cleanup_ran := true; true));
  check bool "cleanup ran after release" true !cleanup_ran

let test_pending_cleanup_failure_retains_ownership_barrier () =
  (match
     S.arm_failed_after_pending_cleanup ~stopped:false ~lease_released:false
   with
   | S.Arm_failed_ownership_retained _ -> ()
   | _ -> fail "a live child must retain the ownership barrier");
  (match
     S.arm_failed_after_pending_cleanup ~stopped:true ~lease_released:false
   with
   | S.Arm_failed_ownership_retained _ -> ()
   | _ -> fail "an unreleased lease must retain the ownership barrier");
  (match
     S.arm_failed_after_pending_cleanup ~stopped:true ~lease_released:true
   with
   | S.Arm_failed _ -> ()
   | _ -> fail "fallback is allowed after exact child and lease cleanup")

let test_unreadable_lease_blocks_claim () =
  with_temp @@ fun dir ->
  let path = S.lease_path ~owners_dir:dir ~socket_identity:"/sock"
      ~thread_id:"blocked" in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc "not-json\n");
  (match
     S.try_claim ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"blocked"
       ~sidecar_pid:200 ~alias:"new" ~broker_session_id:"new-session" ()
   with
   | S.Claim_uncertain _ -> ()
   | _ -> fail "unreadable lease must block a new claim");
  check bool "unreadable lease remains" true (Sys.file_exists path)

let test_fractional_lease_integer_fields_block_claim () =
  with_temp @@ fun dir ->
  let path = S.lease_path ~owners_dir:dir ~socket_identity:"/sock"
      ~thread_id:"fractional" in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () ->
      output_string oc
        (Yojson.Safe.to_string
           (`Assoc [ ("socket_identity", `String "/sock")
                  ; ("thread_id", `String "fractional")
                  ; ("sidecar_pid", `Float 100.0)
                  ; ("sidecar_pid_start_time", `Int 10)
                  ; ("claimed_at", `Float 1.0)
                  ; ("heartbeat_at", `Float 1.0)
                  ; ("alias", `String "owner")
                  ; ("broker_session_id", `String "session") ])
         ^ "\n"));
  (match S.try_claim ~owners_dir:dir ~socket_identity:"/sock"
     ~thread_id:"fractional" ~sidecar_pid:200 ~alias:"new"
     ~broker_session_id:"session" ~sidecar_pid_start_time:20 () with
   | S.Claim_uncertain _ -> ()
   | _ -> fail "fractional lease PID must block claim");
  check bool "fractional lease remains" true (Sys.file_exists path)

let test_fractional_lease_generation_blocks_claim () =
  with_temp @@ fun dir ->
  let path = S.lease_path ~owners_dir:dir ~socket_identity:"/sock"
      ~thread_id:"fractional-generation" in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () ->
      output_string oc
        (Yojson.Safe.to_string
           (`Assoc [ ("socket_identity", `String "/sock")
                  ; ("thread_id", `String "fractional-generation")
                  ; ("sidecar_pid", `Int 100)
                  ; ("sidecar_pid_start_time", `Float 10.0)
                  ; ("claimed_at", `Float 1.0)
                  ; ("heartbeat_at", `Float 1.0)
                  ; ("alias", `String "owner")
                  ; ("broker_session_id", `String "session") ])
         ^ "\n"));
  (match S.try_claim ~owners_dir:dir ~socket_identity:"/sock"
     ~thread_id:"fractional-generation" ~sidecar_pid:200 ~alias:"new"
     ~broker_session_id:"session" ~sidecar_pid_start_time:20 () with
   | S.Claim_uncertain _ -> ()
   | _ -> fail "fractional lease generation must block claim");
  check bool "fractional lease generation remains" true (Sys.file_exists path)

let test_nonpositive_lease_identity_blocks_claim () =
  let cases = [ ("sidecar_pid", 0); ("sidecar_pid", -1);
                ("sidecar_pid_start_time", 0); ("sidecar_pid_start_time", -1) ] in
  List.iter
    (fun (field, value) ->
      with_temp @@ fun dir ->
      let thread = "invalid-" ^ field ^ "-" ^ string_of_int value in
      let path = S.lease_path ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:thread in
      let value_for key default = if key = field then value else default in
      let oc = open_out path in
      Fun.protect ~finally:(fun () -> close_out oc)
        (fun () ->
          output_string oc
            (Yojson.Safe.to_string
               (`Assoc [ ("socket_identity", `String "/sock")
                      ; ("thread_id", `String thread)
                      ; ("sidecar_pid", `Int (value_for "sidecar_pid" 100))
                      ; ("sidecar_pid_start_time",
                         `Int (value_for "sidecar_pid_start_time" 10))
                      ; ("claimed_at", `Float 1.0)
                      ; ("heartbeat_at", `Float 1.0)
                      ; ("alias", `String "owner")
                      ; ("broker_session_id", `String "session") ]) ^ "\n"));
      match S.try_claim ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:thread
              ~sidecar_pid:200 ~alias:"new" ~broker_session_id:"session"
              ~sidecar_pid_start_time:20 () with
      | S.Claim_uncertain _ -> ()
      | _ -> fail (field ^ " " ^ string_of_int value ^ " must block claim"))
    cases

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
  ignore
    (claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s"
       ~start_time:(Some 10) ());
  ignore
    (S.release ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1"
       ~sidecar_pid:999 ~sidecar_pid_start_time:10 ());
  match claim dir ~sock:"/sock" ~thread:"t1" ~pid:200 ~alias:"b" ~sid:"s2" () with
  | S.Held_live l -> check int "foreign release ignored" 100 l.sidecar_pid
  | _ -> fail "foreign release must not drop the lease"

let test_legacy_lease_is_unverifiable_and_blocks () =
  with_temp @@ fun dir ->
  (* This is the on-disk shape written by an older c2c. There is no safe
     generation comparison, so a new owner must remain blocked. *)
  ignore
    (S.try_claim ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"legacy"
       ~sidecar_pid:100 ~alias:"old" ~broker_session_id:"old-session" ~now:10.
       ());
  (match
     S.try_claim ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"legacy"
       ~sidecar_pid:200 ~alias:"new" ~broker_session_id:"new-session"
       ~sidecar_pid_start_time:20 ~now:20. ()
   with
   | S.Held_live l -> check int "legacy owner still blocks" 100 l.sidecar_pid
   | _ -> fail "legacy lease must fail closed");
  (* A caller without an exact generation cannot release even its numeric PID. *)
  ignore
    (S.release ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"legacy"
       ~sidecar_pid:100 ?sidecar_pid_start_time:None ());
  check bool "legacy lease retained" true
    (Sys.file_exists
       (S.lease_path ~owners_dir:dir ~socket_identity:"/sock"
          ~thread_id:"legacy"))

let test_stop_legacy_lease_retains_owner () =
  with_temp @@ fun dir ->
  ignore
    (S.try_claim ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"legacy"
       ~sidecar_pid:100 ~alias:"old" ~broker_session_id:"session" ~now:10.
       ());
  ignore
    (match S.peek ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"legacy" with
     | Some lease -> S.stop_lease ~owners_dir:dir lease
     | None -> fail "legacy lease missing");
  check bool "stop does not release unverifiable lease" true
    (Sys.file_exists
       (S.lease_path ~owners_dir:dir ~socket_identity:"/sock"
          ~thread_id:"legacy"))

let test_release_does_not_clear_newer_pid_generation () =
  with_temp @@ fun dir ->
  ignore (claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s"
            ~start_time:(Some 11) ());
  (* A stale cleanup for the reused PID must not remove the newer generation. *)
  check bool "stale release rejected" false
    (S.release ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1"
       ~sidecar_pid:100 ?sidecar_pid_start_time:(Some 10) ());
  (match S.peek ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1" with
   | Some l -> check int "new generation remains" 11 (Option.get l.sidecar_pid_start_time)
   | None -> fail "stale release removed newer generation");
  check bool "matching owner release succeeds" true
    (S.release ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1"
       ~sidecar_pid:100 ?sidecar_pid_start_time:(Some 11) ());
  check bool "matching owner lease is removed" false
    (Sys.file_exists (S.lease_path ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1"))

let test_release_lock_failure_retains_lease () =
  with_temp @@ fun dir ->
  ignore
    (claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s"
       ~start_time:(Some 10) ());
  let path = S.lease_path ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1" in
  let lease =
    match S.peek ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1" with
    | Some lease -> lease
    | None -> fail "lease missing before lock failure"
  in
  Sys.remove (path ^ ".lock");
  Unix.mkdir (path ^ ".lock") 0o700;
  check bool "release reports lock failure" false
    (S.release ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1"
       ~sidecar_pid:100 ~sidecar_pid_start_time:10 ());
  check bool "lease retained for retry" true (Sys.file_exists path);
  check bool "stop retains lease after lock failure" false
    (S.stop_lease ~owners_dir:dir lease)

let test_lease_publication_failure_does_not_fallback_unlocked () =
  with_temp @@ fun dir ->
  let path = S.lease_path ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1" in
  Unix.mkdir path 0o700;
  let failed =
    try
      match claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s" () with
      | S.Claim_uncertain _ -> true
      | _ -> false
    with Failure _ -> true
  in
  check bool "locked publication failure propagates" true failed;
  check bool "failed publication leaves no lease file" false
    (Sys.file_exists (path ^ ".tmp"))

let test_concurrent_claim_has_one_winner () =
  with_temp @@ fun dir ->
  let r, w = Unix.pipe () in
  let spawn () =
    match Unix.fork () with
    | 0 ->
        Unix.close r;
        let result =
          S.try_claim ~owners_dir:dir ~socket_identity:"/sock"
            ~thread_id:"race-thread" ~sidecar_pid:(Unix.getpid ())
            ~alias:"race" ~broker_session_id:"race-session"
            ~holder_live:(fun l -> l.sidecar_pid <> Unix.getpid ()) ()
        in
        let marker =
          match result with
          | S.Claimed _ | S.Reclaimed _ -> 'W'
          | S.Held_live _ -> 'L'
          | S.Claim_uncertain _ -> 'L'
          | S.Already_ours _ -> 'A'
        in
        let oc = Unix.out_channel_of_descr w in
        output_char oc marker;
        flush oc;
        close_out_noerr oc;
        exit 0
    | pid -> pid
  in
  let p1 = spawn () in
  let p2 = spawn () in
  Unix.close w;
  let ic = Unix.in_channel_of_descr r in
  let markers = really_input_string ic 2 in
  close_in_noerr ic;
  ignore (Unix.waitpid [] p1);
  ignore (Unix.waitpid [] p2);
  check bool "one claimant wins" true
    (String.contains markers 'W');
  check bool "the losing claimant observes the winner" true
    (String.contains markers 'L')

let test_registration_readback_is_required_for_arm_readiness () =
  with_temp @@ fun root ->
  let broker_root = root // "broker" in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let pid = Unix.getpid () in
  let start_time =
    match C2c_mcp.Broker.read_pid_start_time pid with
    | Some n -> n
    | None -> fail "test requires /proc pid start-time support"
  in
  check bool "missing registration is not operational" false
    (S.registration_is_live ~broker_root ~broker_session_id:"sid"
       ~alias:"alias" ~pid ~pid_start_time:start_time);
  C2c_mcp.Broker.register broker ~session_id:"sid" ~alias:"alias"
    ~pid:(Some pid) ~pid_start_time:(Some start_time) ~client_type:(Some "codex") ();
  check bool "persisted registration is operational" true
    (S.registration_is_live ~broker_root ~broker_session_id:"sid"
       ~alias:"alias" ~pid ~pid_start_time:start_time)

let test_refresh_registration_preserves_existing_metadata () =
  with_temp @@ fun root ->
  let broker_root = root // "broker" in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let pid = Unix.getpid () in
  let pid_start_time = C2c_mcp.Broker.read_pid_start_time pid in
  C2c_mcp.Broker.register broker ~session_id:"sidecar-refresh"
    ~alias:"refresh-sidecar" ~pid:(Some pid) ~pid_start_time
    ~client_type:(Some "legacy") ~metadata_opt_out:true
    ~registered_by:(Some "legacy-owner") ~cwd:(Some "/old") ();
  S.refresh_managed_registration ~broker_root
    ~broker_session_id:"sidecar-refresh" ~alias:"refresh-sidecar" ~pid
    ~pid_start_time ~alias_from_auto_gen:false ();
  match C2c_mcp.Broker.list_registrations broker with
  | [ row ] ->
      check bool "metadata opt-out survives sidecar refresh" true
        row.metadata_opt_out;
      check (option string) "registration owner survives"
        (Some "legacy-owner") row.registered_by;
      check (option string) "cwd survives" (Some "/old") row.cwd;
      check (option string) "client identity updates"
        (Some "codex-app-server") row.client_type
  | rows -> failf "expected one sidecar row, got %d" (List.length rows)

let test_pidfd_signal_is_owner_bound () =
  if not (C2c_pid_identity.pidfd_supported ()) then ()
  else
    match Unix.fork () with
    | 0 -> Unix.sleep 20; exit 0
    | pid ->
        Fun.protect
          ~finally:(fun () ->
            (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
            (try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ()))
          (fun () ->
            let start_time =
              match C2c_mcp.Broker.read_pid_start_time pid with
              | Some n -> n
              | None -> fail "child start-time unavailable"
            in
            check (option int) "generation readback agrees" (Some start_time)
              (C2c_mcp.Broker.read_pid_start_time pid);
            check bool "wrong generation is rejected" false
              (C2c_pid_identity.signal_pid_if_generation_matches
                 ~pid ~start_time:(start_time + 1) ~signal:Sys.sigterm);
            check bool "matching generation is signalled" true
              (C2c_pid_identity.signal_pid_if_generation_matches
                 ~pid ~start_time ~signal:Sys.sigterm);
            ignore (Unix.waitpid [] pid))

let test_claim_creates_stable_lock_file () =
  with_temp @@ fun dir ->
  ignore (claim dir ~sock:"/sock" ~thread:"t1" ~pid:100 ~alias:"a" ~sid:"s" ());
  let path = S.lease_path ~owners_dir:dir ~socket_identity:"/sock" ~thread_id:"t1" in
  check bool "lease exists" true (Sys.file_exists path);
  check bool "stable lock exists" true (Sys.file_exists (path ^ ".lock"))

let test_pending_arm_is_cancelled_without_a_lease () =
  if not (C2c_pid_identity.pidfd_supported ()) then ()
  else
    with_temp @@ fun dir ->
    let pid =
      match Unix.fork () with
      | 0 -> Unix.sleep 20; exit 0
      | child -> child
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
        (try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ()))
      (fun () ->
        let start_time =
          match C2c_mcp.Broker.read_pid_start_time pid with
          | Some n -> Some n
          | None -> fail "pending arm child start-time unavailable"
        in
        ignore
          (C2c_start.write_codex_daemon_sidecar_arm ~owners_dir:dir ~token:"pending-test"
             ~thread_id:"pending-thread" ~pid ~pid_start_time:start_time
             ~broker_session_id:"pending-session");
        check bool "pending arm record exists" true
          (Sys.file_exists
             (C2c_start.codex_daemon_sidecar_arm_pending_path ~owners_dir:dir
                ~token:"pending-test"));
        check bool "pending arm cancellation removes exact records" true
          (C2c_start.cancel_codex_daemon_sidecar_arms ~owners_dir:dir
             ~broker_session_id:"pending-session" ());
        check bool "pending arm record is removed" false
          (Sys.file_exists
             (C2c_start.codex_daemon_sidecar_arm_pending_path ~owners_dir:dir
                ~token:"pending-test"));
        check bool "pending arm cancellation marker is removed" false
          (Sys.file_exists
             (C2c_start.codex_daemon_sidecar_arm_cancel_path ~owners_dir:dir
                ~token:"pending-test"));
        match Unix.waitpid [ Unix.WNOHANG ] pid with
        | _, Unix.WEXITED _ | _, Unix.WSIGNALED _ -> ()
        | 0, _ -> fail "pending arm child survived cancellation"
        | _, Unix.WSTOPPED _ -> fail "pending arm child was only stopped"
        | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ())

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
        ; test_case "same pid different generation is not ours" `Quick
            test_same_pid_different_generation_is_not_ours
        ; test_case "heartbeat requires exact generation and owner" `Quick
            test_heartbeat_requires_exact_generation_and_owner_identity
        ; test_case "mismatched lease filename blocks claim and cleanup" `Quick
            test_mismatched_lease_filename_blocks_claim_and_cleanup
        ; test_case "lease symlink is not an exact record" `Quick
            test_lease_symlink_is_not_an_exact_record
        ; test_case "distinct threads independent" `Quick test_distinct_threads_independent
        ; test_case "release removes exact owner" `Quick test_release_removes_exact_owner
        ; test_case "release distinguishes missing from unreadable" `Quick
            test_release_confirms_missing_and_rejects_unreadable
        ; test_case "release failure retains dependent cleanup state" `Quick
            test_release_failure_retains_dependent_cleanup_state
        ; test_case "pending cleanup failure retains ownership barrier" `Quick
            test_pending_cleanup_failure_retains_ownership_barrier
        ; test_case "unreadable lease blocks claim" `Quick
            test_unreadable_lease_blocks_claim
        ; test_case "fractional lease integer fields block claim" `Quick
            test_fractional_lease_integer_fields_block_claim
        ; test_case "fractional lease generation blocks claim" `Quick
            test_fractional_lease_generation_blocks_claim
        ; test_case "nonpositive lease identity blocks claim" `Quick
            test_nonpositive_lease_identity_blocks_claim
        ; test_case "foreign release is noop" `Quick test_foreign_release_is_noop
        ; test_case "legacy lease is unverifiable and blocks" `Quick
            test_legacy_lease_is_unverifiable_and_blocks
        ; test_case "stop retains legacy lease" `Quick
            test_stop_legacy_lease_retains_owner
        ; test_case "release matches pid generation" `Quick
            test_release_does_not_clear_newer_pid_generation
        ; test_case "release lock failure retains lease" `Quick
            test_release_lock_failure_retains_lease
        ; test_case "publication failure does not fallback unlocked" `Quick
            test_lease_publication_failure_does_not_fallback_unlocked
        ; test_case "concurrent claim has one winner" `Quick
            test_concurrent_claim_has_one_winner
        ; test_case "registration readback gates arm readiness" `Quick
            test_registration_readback_is_required_for_arm_readiness
        ; test_case "refresh preserves existing metadata" `Quick
            test_refresh_registration_preserves_existing_metadata
        ; test_case "pidfd signalling is owner bound" `Quick
            test_pidfd_signal_is_owner_bound
        ; test_case "claim uses stable lock" `Quick test_claim_creates_stable_lock_file
        ; test_case "pending arm cancels without a lease" `Quick
            test_pending_arm_is_cancelled_without_a_lease
        ; test_case "unix endpoint missing path" `Quick test_unix_endpoint_missing
        ; test_case "select_owned_thread fail closed" `Quick
            test_select_owned_thread_fail_closed
        ] ) ]
