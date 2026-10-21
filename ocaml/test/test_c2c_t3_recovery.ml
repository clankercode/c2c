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
      "model not available; retry later";
      "temporary capacity: model is busy" ];
  List.iter (fun s -> check (not (R.availability_message s)) ("negative: " ^ s))
    [ "model access is unavailable for this account"; "quota exceeded";
      "authentication failed"; "context limit exceeded"; "transport timeout";
      "ordinary provider error"; "model selection is invalid";
      "model does not exist in this deployment"; "unsupported model";
      "temporary capacity: model is available" ]

let test_version_gate () =
  Alcotest.(check bool) "measured version" true (R.supported_server_version (Some "0.1.0"));
  Alcotest.(check bool) "unknown version held" false (R.supported_server_version None);
  Alcotest.(check bool) "measured 0.1.1 version" true (R.supported_server_version (Some "0.1.1"));
  Alcotest.(check bool) "new version held" false (R.supported_server_version (Some "0.1.2"));
  Alcotest.(check (option string)) "known hold reason" None (R.version_hold_reason (Some "0.1.0"));
  Alcotest.(check bool) "unknown has hold reason" true
    (Option.is_some (R.version_hold_reason None))

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
          let state = match S.open_state ~environment_id:"env" ~dir () with Ok s -> s | Error _ -> Alcotest.fail "state" in
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
  hold "approval" (base_activity ~pending:(T.Known 1) ()) (queue ());
  hold "snoozed" (base_activity ~snoozed:(T.Known true) ()) (queue ());
  hold "settled" (base_activity ~settled:(T.Known true) ()) (queue ());
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
      let state = match S.open_state ~environment_id:"env" ~dir () with Ok s -> s | Error _ -> Alcotest.fail "state" in
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

let test_held_intent_reconciliation () =
  let dir = Filename.temp_file "c2c-t3-reconcile" "" in
  Sys.remove dir;
  let rec cleanup path =
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
      Array.iter (fun name -> cleanup (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else Unix.unlink path
  in
  Fun.protect ~finally:(fun () -> cleanup dir) (fun () ->
    let reopen () = match S.open_state ~environment_id:"env" ~dir () with
      | Ok s -> s | Error _ -> Alcotest.fail "state" in
    let state = ref (reopen ()) in
    Fun.protect ~finally:(fun () -> S.close !state) (fun () ->
      let activity = ref (base_activity ()) in
      let operations =
        { R.capabilities = (fun () -> Lwt.return (Ok
              { T.runtime_mode = T.Known "auto"; interaction_mode = T.Unknown;
                providers = [ { T.provider_instance_id = T.Known "p1";
                  driver_kind = T.Known "codex"; models = [ "gpt" ] } ] }));
          read_activity = (fun _ -> Lwt.return (Ok !activity));
          list_queue = (fun _ -> Lwt.return (Ok (queue ()))) } in
      let sweep () = Lwt_main.run (R.sweep_with ~operations ~state:!state
        ~environment_id:"env" ~credential_generation:4 ~thread_ids:[ "root" ]
        ~clock:(fun () -> 100.) ()) in
      ignore (sweep ());
      let original = List.hd (S.journal_pending !state) in
      let hold ?(attempts = 0) entry =
        let fields = Yojson.Safe.Util.to_assoc entry.S.payload in
        let changes = [ "status", `String "held"; "attempts", `Int attempts;
                        "reason", `String "preflight read failed" ] in
        let fields = changes @ List.filter (fun (k, _) -> not (List.mem_assoc k changes)) fields in
        check (S.journal_update !state ~seq:entry.seq ~payload:(`Assoc fields) = Ok true)
          "persist preflight hold" in
      hold original;
      S.close !state;
      state := reopen ();
      ignore (sweep ());
      let rearmed = List.hd (S.journal_pending !state) in
      Alcotest.(check string) "fresh same evidence rearms unsent intent" "pending"
        Yojson.Safe.Util.(to_string (member "status" rearmed.payload));
      Alcotest.(check string) "same run key" original.key rearmed.key;
      Alcotest.(check string) "same request identity"
        Yojson.Safe.Util.(to_string (member "request_id" original.payload))
        Yojson.Safe.Util.(to_string (member "request_id" rearmed.payload));
      activity := { !activity with T.items =
        [ error_item ~run_id:"run-1" ~message:"The model is not available right now" () ] };
      ignore (sweep ());
      let refreshed = List.hd (S.journal_pending !state) in
      Alcotest.(check int) "same run keeps intent slot" rearmed.seq refreshed.seq;
      check (Yojson.Safe.Util.member "error_fingerprint" refreshed.payload <>
             Yojson.Safe.Util.member "error_fingerprint" rearmed.payload)
        "never submitted evidence refreshed";
      hold rearmed;
      activity := { !activity with T.items = [ error_item ~run_id:"run-2" ~item_id:"e2" () ];
        recent_runs = [ { T.run_id = "run-2"; status = T.Known "failed"; run_raw = `Assoc [] } ] };
      let second = sweep () in
      Alcotest.(check int) "new failure not blocked by never submitted hold" 1 (List.length second.enqueued);
      Alcotest.(check int) "one pending intent" 1 (List.length (S.journal_pending !state));
      Alcotest.(check int) "obsolete intent audit retained" 1 (List.length (S.journal_acked !state));
      let attempted = List.hd (S.journal_pending !state) in
      hold ~attempts:1 attempted;
      activity := { !activity with T.items = [ error_item ~run_id:"run-3" ~item_id:"e3" () ];
        recent_runs = [ { T.run_id = "run-3"; status = T.Known "failed"; run_raw = `Assoc [] } ] };
      let uncertain = sweep () in
      Alcotest.(check int) "uncertain submission still blocks new recovery" 0 (List.length uncertain.enqueued);
      Alcotest.(check string) "uncertain intent retained" attempted.key
        (List.hd (S.journal_pending !state)).key))

let test_final_preflight () =
  let candidate =
    match decide () with
    | R.Eligible candidate -> candidate
    | R.Held reason -> Alcotest.failf "fixture unexpectedly held: %s" reason
  in
  let activity =
    { (base_activity ~thread_id:"root" ()) with
      T.thread_raw = `Assoc [ ("threadId", `String "root") ] }
  in
  let capabilities () =
    Lwt.return
      (Ok { T.runtime_mode = T.Known "auto"; interaction_mode = T.Unknown;
            providers = [ { T.provider_instance_id = T.Known "p1";
                            driver_kind = T.Known "codex"; models = [ "gpt" ] } ] })
  in
  let operations =
    { R.capabilities; read_activity = (fun _ -> Lwt.return (Ok activity));
      list_queue = (fun _ -> Lwt.return (Ok (queue ()))) }
  in
  (match Lwt_main.run
     (R.preflight_with ~operations ~environment_id:"env" ~credential_generation:4 ~candidate ()) with
   | Ok () -> ()
   | Error reason -> Alcotest.failf "unchanged candidate rejected: %s" reason);
  let changed_activity =
    { activity with
      T.items = [ error_item ~run_id:"run-1" ~message:"quota exceeded" () ] }
  in
  let changed_operations =
    { operations with read_activity = (fun _ -> Lwt.return (Ok changed_activity)) }
  in
  (match Lwt_main.run
     (R.preflight_with ~operations:changed_operations ~environment_id:"env"
        ~credential_generation:4 ~candidate ()) with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "changed failure evidence was accepted");
  let foreign_activity =
    { activity with T.thread_raw = `Assoc [ ("threadId", `String "other") ] }
  in
  let foreign_operations =
    { operations with read_activity = (fun _ -> Lwt.return (Ok foreign_activity)) }
  in
  (match Lwt_main.run
     (R.preflight_with ~operations:foreign_operations ~environment_id:"env"
        ~credential_generation:4 ~candidate ()) with
   | Error reason -> check (String.length reason > 0) "foreign identity has reason"
   | Ok () -> Alcotest.fail "foreign thread identity was accepted")

let test_sweep_diagnostics () =
  let open Yojson.Safe.Util in
  let result : R.sweep_result =
    { checked = 3; enqueued = []; duplicates = [];
      held = [ ("a-held", "activity error text is truncated");
               ("c-held", "PRIVATE-TRANSCRIPT-SENTINEL") ];
      errors = [ ("b-error", "PRIVATE-TOKEN-SENTINEL") ] } in
  let report = R.sweep_diagnostics ~enabled:true
      ~thread_ids:[ "c-held"; "b-error"; "a-held"; "a-held" ]
      ~checked_at:120. ~next_due_at:180. result in
  let rows = report |> member "threads" |> to_list in
  Alcotest.(check int) "distinct threads" 3 (report |> member "totalThreads" |> to_int);
  Alcotest.(check string) "sorted first" "a-held" (List.hd rows |> member "threadId" |> to_string);
  Alcotest.(check string) "safe policy reason" "activity error text is truncated"
    (List.hd rows |> member "holdReason" |> to_string);
  Alcotest.(check (float 0.)) "completed check time" 120.
    (List.hd rows |> member "lastCheckAt" |> to_float);
  Alcotest.(check (float 0.)) "next due" 180.
    (List.hd rows |> member "nextDueAt" |> to_float);
  Alcotest.(check string) "failed read visible" "read_failed"
    (List.nth rows 1 |> member "outcome" |> to_string);
  let encoded = Yojson.Safe.to_string report in
  check (not (String.contains encoded 'P')) "no private error or transcript sentinel";
  let many = List.init 70 (Printf.sprintf "root-%03d") in
  let bounded = R.sweep_diagnostics ~enabled:true ~thread_ids:many
      ~checked_at:120. ~next_due_at:180. result in
  Alcotest.(check int) "bounded rows" 64 (bounded |> member "threads" |> to_list |> List.length);
  Alcotest.(check int) "omitted count" 6 (bounded |> member "omittedThreads" |> to_int);
  let disabled = R.sweep_diagnostics ~enabled:false ~thread_ids:[ "root" ]
      ~checked_at:120. ~next_due_at:180. result in
  let row = disabled |> member "threads" |> to_list |> List.hd in
  check ((row |> member "lastCheckAt") = `Null) "disabled sweep does not claim a check";
  Alcotest.(check string) "disabled reason" "recovery disabled" (row |> member "holdReason" |> to_string);
  let unsafe_id = "PRIVATE-THREAD-SENTINEL\n" in
  let redacted = R.sweep_diagnostics ~enabled:true ~thread_ids:[ unsafe_id ]
      ~checked_at:120. ~next_due_at:180. result in
  let id = redacted |> member "threads" |> to_list |> List.hd |> member "threadId" |> to_string in
  check (String.starts_with ~prefix:"sha256:" id) "unsafe or oversized identifiers are hashed"

let () =
  Alcotest.run "c2c_t3_recovery"
    [ ("matcher", [ Alcotest.test_case "availability text" `Quick test_matcher;
                     Alcotest.test_case "version gate" `Quick test_version_gate;
                     Alcotest.test_case "external error shape" `Quick test_external_error_shape ]);
      ("policy", [ Alcotest.test_case "positive and durable dedupe" `Quick test_positive_and_dedupe;
                    Alcotest.test_case "holds" `Quick test_holds ]);
      ("cadence", [ Alcotest.test_case "initial, spacing and overlap" `Quick test_cadence ]);
      ("sweep", [ Alcotest.test_case "held intent reconciliation" `Quick test_held_intent_reconciliation;
                   Alcotest.test_case "bounded redacted diagnostics" `Quick test_sweep_diagnostics;
                   Alcotest.test_case "seam and disable" `Quick test_sweep_seam_and_disable;
                   Alcotest.test_case "final preflight" `Quick test_final_preflight ]) ]
