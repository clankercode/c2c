module T = C2c_t3_client
module R = C2c_t3_recovery
module S = C2c_t3_state

let check condition message = if not condition then Alcotest.fail message

let error_item ?(source_thread = "root") ?(status = "failed") ?(message = "model unavailable")
    ?(item_id = "e1") ~run_id () =
  `Assoc
    [ ("itemType", `String "error"); ("itemId", `String item_id);
      ("runId", `String run_id); ("threadId", `String source_thread);
      ("status", `String status);
      ("failure", `Assoc [ ("message", `String message) ]) ]

let base_activity ?(thread_id = "root") ?(parent = T.Known None)
    ?(items = [ error_item ~run_id:"run-1" () ])
    ?(run_status = "failed") ?(active = T.Known None)
    ?(complete = true) ?(text_truncated = false)
    ?(runtime_mode = T.Known "auto") ?(pending = T.Known 0)
    ?(settled = T.Known false) ?(archived = T.Known false)
    ?(deleted = T.Known false) ?(snoozed = T.Known false)
    ?(runs_complete = true) () : T.activity =
  { thread_id; parent_thread_id = parent; runtime_mode;
    provider_instance_id = T.Known (Some "p1"); model = T.Known (Some "gpt");
    pending_request_count = pending; settled; archived; deleted; snoozed;
    active_run_id = active; items;
    recent_runs = [ { T.run_id = "run-1"; status = T.Known run_status; run_raw = `Assoc [] } ];
    runs_complete; complete; text_truncated; thread_raw = `Assoc [] }

let queue ?(ids = []) ?(complete = true) () : T.queue =
  { queued_run_ids = ids; queue_complete = complete }

let decide ?(activity = base_activity ()) ?(q = queue ()) ?(driver = Some "codex")
    ?(provider = Some "p1") ?(model = Some "gpt") () =
  R.decide ~environment_id:"env" ~credential_generation:4 ~thread_id:"root"
    ~driver_kind:driver ~provider_instance_id:provider ~model activity q

let test_matcher () =
  List.iter (fun s -> check (R.availability_message s) ("positive: " ^ s))
    [ "The selected model is unavailable right now";
      "model not available; retry later"; "model does not exist in this deployment";
      "temporary capacity: model is busy" ];
  List.iter (fun s -> check (not (R.availability_message s)) ("negative: " ^ s))
    [ "model access is unavailable for this account"; "quota exceeded";
      "authentication failed"; "context limit exceeded"; "transport timeout";
      "ordinary provider error"; "model selection is invalid" ]

let test_external_error_shape () =
  let activity =
    base_activity
      ~items:[ `Assoc [ ("type", `String "error"); ("itemId", `String "e-text");
                ("runId", `String "run-1"); ("sourceThreadId", `String "root");
                ("status", `String "failed"); ("text", `String "model unavailable") ] ] ()
  in
  match decide ~activity () with
  | R.Eligible candidate -> Alcotest.(check (list string)) "external item id" [ "e-text" ] candidate.error_ids
  | R.Held reason -> Alcotest.failf "external error shape held: %s" reason

let test_positive_and_dedupe () =
  match decide () with
  | R.Held reason -> Alcotest.failf "positive fixture held: %s" reason
  | R.Eligible candidate ->
      check (candidate.R.request_id <> "") "request id is present";
      let dir = Filename.temp_file "c2c-t3-recovery-state" "" in
      Sys.remove dir;
      Fun.protect
        ~finally:(fun () -> ignore (Sys.command ("/bin/rm -rf " ^ Filename.quote dir)))
        (fun () ->
          let state = match S.open_state ~dir () with Ok s -> s | Error _ -> Alcotest.fail "state" in
          (match R.enqueue ~state ~environment_id:"env" ~credential_generation:4 ~now:0. candidate with
           | Ok `Appended -> () | Ok `Duplicate | Error _ -> Alcotest.fail "first enqueue");
          (match R.enqueue ~state ~environment_id:"env" ~credential_generation:9 ~now:60. candidate with
           | Ok `Duplicate -> () | Ok `Appended | Error _ -> Alcotest.fail "dedupe enqueue");
          let entries = S.journal_pending ~kind:S.Recovery state in
          Alcotest.(check int) "one durable recovery" 1 (List.length entries);
          let payload = (List.hd entries).S.payload in
          Alcotest.(check string) "literal Continue" "Continue"
            (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "formatted" payload));
          Alcotest.(check string) "queue mode" "queue"
            (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "mode" payload));
          Alcotest.(check bool) "disable holds recovery" false
            (R.can_dispatch ~enabled:false (List.hd entries));
          let other = { candidate with R.key = "recovery:other-run"; run_id = "run-2" } in
          Alcotest.(check bool) "second run waits for pending recovery" true
            (R.hold_reason ~state ~thread_id:"root" ~candidate:other ~now:0. <> None);
          S.close state)

let test_holds () =
  let hold name activity q =
    match decide ~activity ~q () with
    | R.Held _ -> ()
    | R.Eligible _ -> Alcotest.fail ("expected hold: " ^ name)
  in
  hold "child" (base_activity ~parent:(T.Known (Some "parent")) ()) (queue ());
  hold "mixed child error"
    (base_activity ~items:[ error_item ~run_id:"run-1" (); error_item ~run_id:"run-1" ~source_thread:"child" ~item_id:"e2" () ] ()) (queue ());
  hold "nonmatching" (base_activity ~items:[ error_item ~run_id:"run-1" ~message:"quota exceeded" () ] ()) (queue ());
  hold "malformed error" (base_activity ~items:[ `Assoc [ ("itemType", `String "error"); ("runId", `String "run-1") ] ] ()) (queue ());
  hold "active" (base_activity ~active:(T.Known (Some "run-2")) ()) (queue ());
  hold "queued" (base_activity ()) (queue ~ids:[ "queued" ] ());
  hold "incomplete queue" (base_activity ()) (queue ~complete:false ());
  hold "truncated activity" (base_activity ~complete:false ()) (queue ());
  hold "truncated runs" (base_activity ~runs_complete:false ()) (queue ());
  hold "stop marker"
    (base_activity ~items:[ error_item ~run_id:"run-1" (); `Assoc [ ("itemType", `String "run_interrupt_request"); ("runId", `String "run-1"); ("threadId", `String "root") ] ] ())
    (queue ());
  hold "full access" (base_activity ~runtime_mode:(T.Known "full-access") ()) (queue ());
  (match decide ~driver:None () with R.Held _ -> () | R.Eligible _ -> Alcotest.fail "expected unknown provider hold");
  (match decide ~driver:(Some "claude") () with R.Held _ -> () | R.Eligible _ -> Alcotest.fail "expected non Codex hold")

let test_cadence () =
  let now = ref 10. in
  let c = R.create_cadence ~clock:(fun () -> !now) () in
  Alcotest.(check bool) "initial due" true (R.cadence_start c ~now:10.);
  Alcotest.(check bool) "no overlap" false (R.cadence_start c ~now:10.);
  R.cadence_finish c ~now:11.;
  (match R.cadence_due c ~now:11. with `Waiting delay -> check (delay >= 59.) "sixty second cadence" | _ -> Alcotest.fail "cadence due too early");
  Alcotest.(check bool) "due after interval" true (R.cadence_start c ~now:71.)

let test_sweep_seam_and_disable () =
  let dir = Filename.temp_file "c2c-t3-recovery-sweep" "" in
  Sys.remove dir;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("/bin/rm -rf " ^ Filename.quote dir)))
    (fun () ->
      let state = match S.open_state ~dir () with Ok s -> s | Error _ -> Alcotest.fail "state" in
      let calls = ref [] in
      let operations =
        { R.capabilities = (fun () ->
              calls := "capabilities" :: !calls;
              Lwt.return (Ok { T.runtime_mode = T.Known "auto"; interaction_mode = T.Unknown;
                               providers = [ { T.provider_instance_id = T.Known "p1";
                                                driver_kind = T.Known "codex"; models = [ "gpt" ] } ] }));
          read_activity = (fun id -> calls := ("read:" ^ id) :: !calls; Lwt.return (Ok (base_activity ~thread_id:id ())));
          list_queue = (fun id -> calls := ("queue:" ^ id) :: !calls; Lwt.return (Ok (queue ()))) }
      in
      let disabled = Lwt_main.run
        (R.sweep_with ~enabled:false ~operations ~state ~environment_id:"env"
           ~credential_generation:1 ~thread_ids:[ "root" ] ~clock:(fun () -> 0.) ())
      in
      Alcotest.(check int) "disabled no checks" 0 disabled.checked;
      Alcotest.(check (list string)) "disabled makes no calls" [] !calls;
      let result = Lwt_main.run
        (R.sweep_with ~operations ~state ~environment_id:"env" ~credential_generation:1
           ~thread_ids:[ "b"; "a" ] ~clock:(fun () -> 0.) ())
      in
      Alcotest.(check int) "two roots checked" 2 result.checked;
      Alcotest.(check (list string)) "sorted serialized reads"
        [ "queue:b"; "read:b"; "queue:a"; "read:a"; "capabilities" ] !calls;
      S.close state)

let () =
  Alcotest.run "c2c_t3_recovery"
    [ ("matcher", [ Alcotest.test_case "availability text" `Quick test_matcher;
                     Alcotest.test_case "external error shape" `Quick test_external_error_shape ]);
      ("policy", [ Alcotest.test_case "positive and durable dedupe" `Quick test_positive_and_dedupe;
                    Alcotest.test_case "holds" `Quick test_holds ]);
      ("cadence", [ Alcotest.test_case "initial, spacing and overlap" `Quick test_cadence ]);
      ("sweep", [ Alcotest.test_case "seam and disable" `Quick test_sweep_seam_and_disable ]) ]
