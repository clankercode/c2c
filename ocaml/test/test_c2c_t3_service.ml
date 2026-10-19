(* Focused lifecycle tests for C2c_t3_service.  These tests use the public
   pure seams so list races and permission policy stay deterministic. *)

module S = C2c_t3_service
module State = C2c_t3_state

let check_ok = function
  | Ok value -> value
  | Error message -> Alcotest.failf "unexpected error: %s" message

let json ?(parent = `Null) ?(settled = false) ?(archived = false)
    ?(runtime = "auto") ?(title = "thread") ?(deleted = false) id =
  `Assoc
    [ ("threadId", `String id); ("title", `String title);
      ("parentThreadId", parent); ("settled", `Bool settled);
      ("archived", `Bool archived); ("runtimeMode", `String runtime);
      ("deleted", `Bool deleted); ("updatedAt", `String "2026-01-01T00:00:00Z") ]

let thread ?(project = "p") ?(parent = None) ?(archived = false) ?(settled = false)
    ?(deleted = false) ?(runtime = Some "auto") id : S.thread =
  { project_id = project; thread_id = id; title = "title-" ^ id;
    parent_thread_id = parent; parent_known = true; lifecycle_known = true;
    archived; settled; deleted;
    runtime_mode = runtime; updated_at = Some "2026-01-01T00:00:00Z" }

let mapping ~id ~alias ?(tombstone = None) () : State.mapping =
  { thread_id = id; alias; created_at = 1.; tombstone }

let test_root_and_fork () =
  let root = check_ok (S.thread_of_json ~project_id:"p" ~require_lifecycle:true (json "root")) in
  let fork =
    check_ok
      (S.thread_of_json ~project_id:"p" ~require_lifecycle:true
         (json ~parent:(`String "root") "fork"))
  in
  Alcotest.(check bool) "root" true (S.is_open_root root);
  Alcotest.(check bool) "fork excluded" false (S.is_open_root fork);
  Alcotest.(check bool) "missing lineage rejected" true
    (match S.thread_of_json ~project_id:"p" ~require_lifecycle:false (`Assoc [ ("threadId", `String "x") ]) with
     | Error _ -> true | Ok _ -> false)

let test_lifecycle_and_permission () =
  let access mode t = S.eligibility ~credential_access:mode t in
  Alcotest.(check bool) "open" true
    (access (Some "auto") (thread "open") = S.Routable);
  Alcotest.(check bool) "full access held" true
    (match access (Some "auto") (thread ~runtime:(Some "full-access") "full") with
     | S.Permission_ineligible _ -> true | _ -> false);
  Alcotest.(check bool) "settled retired" true
    (match access (Some "auto") (thread ~settled:true "settled") with
     | S.Retired _ -> true | _ -> false)

let test_point_read_error_contract () =
  Alcotest.(check bool) "thread not found" true
    (S.error_is_same_environment_not_found
       (C2c_t3_client.Tool_rejected
          { tool = "t3_thread_read"; code = "thread_not_found" }));
  Alcotest.(check bool) "other tool error held" false
    (S.error_is_same_environment_not_found
       (C2c_t3_client.Tool_rejected
          { tool = "t3_thread_read"; code = "not_found" }));
  Alcotest.(check bool) "auth held" false
    (S.error_is_same_environment_not_found
       (C2c_t3_client.Auth_denied { status = 401 }))

let test_partial_scan_never_retires () =
  let old = mapping ~id:"missing" ~alias:"t3-old" () in
  let plan =
    S.plan_reconciliation
      ~scan:({ listed = [ thread "listed" ]; project_ids = [ "p" ]; complete = false; errors = [] } : S.scan)
      ~mappings:[ old ] ~point_reads:[] ()
  in
  Alcotest.(check int) "no retirement on partial" 0 (List.length plan.retire);
  Alcotest.(check bool) "degraded" true (plan.degraded <> [])

let test_complete_scan_requires_point_read () =
  let old = mapping ~id:"missing" ~alias:"t3-old" () in
  let base : S.scan =
    { listed = [ thread "listed" ]; project_ids = [ "p" ]; complete = true; errors = [] }
  in
  Alcotest.(check (list string)) "missing ids are point-read" [ "missing" ]
    (S.missing_bound_thread_ids ~scan:base ~mappings:[ old ]);
  let no_read = S.plan_reconciliation ~scan:base ~mappings:[ old ] ~point_reads:[] () in
  Alcotest.(check int) "missing point read retained" 0 (List.length no_read.retire);
  Alcotest.(check bool) "missing read degraded" true (no_read.degraded <> []);
  let gone =
    S.plan_reconciliation ~scan:base ~mappings:[ old ]
      ~point_reads:[ ("missing", S.Not_found_same_environment) ] ()
  in
  Alcotest.(check int) "definitive not found retires" 1 (List.length gone.retire);
  let moved = thread "missing" in
  let still_open =
    S.plan_reconciliation ~scan:base ~mappings:[ old ]
      ~point_reads:[ ("missing", S.Present moved) ] ()
  in
  Alcotest.(check int) "point read keeps moved thread" 2 (List.length still_open.routable)

let test_title_change_duplicate_names () =
  let a = thread "a" and b = thread "b" in
  let a = { a with title = "same" } and b = { b with title = "same" } in
  let plan =
    S.plan_reconciliation
      ~scan:({ listed = [ a; b ]; project_ids = [ "p" ]; complete = true; errors = [] } : S.scan)
      ~mappings:[] ~point_reads:[] ()
  in
  Alcotest.(check (list string)) "ids remain distinct" [ "a"; "b" ]
    (List.map (fun c -> c.S.thread.thread_id) plan.routable)

let test_state_environment_alias_and_reopen () =
  let path = Filename.temp_file "c2c-t3-service-state" "" in
  Sys.remove path;
  let remove () =
    (try Sys.remove (Filename.concat path "state.json") with _ -> ());
    (try Sys.remove (Filename.concat path "t3-state.lock") with _ -> ());
    (try Unix.rmdir path with _ -> ())
  in
  Fun.protect ~finally:remove (fun () ->
    let state =
      match State.open_state ~dir:path () with
      | Ok value -> value
      | Error _ -> Alcotest.fail "open state"
    in
    let alias = State.alias_of_environment_thread ~environment_id:"env-a" ~thread_id:"t1" in
    let m = check_ok (State.ensure_mapping_with_alias state ~thread_id:"t1" ~alias) in
    check_ok (State.tombstone state ~thread_id:"t1" ~reason:"archived");
    let reopened = check_ok (State.revive_mapping state ~thread_id:"t1") in
    Alcotest.(check string) "alias retained" m.alias reopened.alias;
    Alcotest.(check bool) "environment namespaces" true
      (alias <> State.alias_of_environment_thread ~environment_id:"env-b" ~thread_id:"t1");
    State.close state)

let test_locator () =
  let m = mapping ~id:"thread-1" ~alias:"t3-abcd" () in
  let registered = [ "t3-abcd"; "real" ] in
  Alcotest.(check bool) "literal alias wins" true
    (S.resolve_locator ~mappings:[ m ] ~registered_aliases:registered "t3-abcd" = S.Alias "t3-abcd");
  Alcotest.(check bool) "thread convenience" true
    (S.resolve_locator ~mappings:[ m ] ~registered_aliases:registered "t3.thread-1" = S.Thread_alias "t3-abcd");
  Alcotest.(check bool) "remote unchanged" true
    (S.resolve_locator ~mappings:[ m ] ~registered_aliases:registered "peer@host" = S.Alias "peer@host");
  let tomb = { m with tombstone = Some { State.tombstoned_at = 2.; reason = "gone" } } in
  Alcotest.(check bool) "tombstone not resolved" true
    (match S.resolve_locator ~mappings:[ tomb ] ~registered_aliases:[] "t3.thread-1" with
     | S.Unknown_thread "thread-1" -> true | _ -> false)

let test_service_owned_registration () =
  let root = Filename.temp_file "c2c-t3-broker" "" in
  Sys.remove root;
  let cleanup () =
    ignore (Sys.command (Printf.sprintf "/bin/rm -rf %s" (Filename.quote root)))
  in
  Fun.protect ~finally:cleanup (fun () ->
    let broker = C2c_mcp.Broker.create ~root in
    let owner =
      { S.environment_id = "env"; broker; pid = Some (Unix.getpid ());
        pid_start_time = C2c_mcp.Broker.capture_pid_start_time (Some (Unix.getpid ())) ;
        cwd = None; opaque_host_id = None }
    in
    let m = mapping ~id:"thread" ~alias:"t3-service-test" () in
    let missing_owner = { owner with S.pid = None } in
    Alcotest.(check bool) "requires ownership proof" true
      (match S.publish_mapping ~owner:missing_owner ~mapping:m with
       | Error _ -> true | Ok () -> false);
    check_ok (S.publish_mapping ~owner ~mapping:m);
    let rows = C2c_mcp.Broker.list_registrations broker in
    Alcotest.(check int) "one row" 1 (List.length rows);
    let row = List.hd rows in
    Alcotest.(check (option string)) "service marker" (Some S.service_registered_by)
      row.C2c_mcp.registered_by;
    check_ok (S.unpublish_mapping ~owner ~mapping:m);
    Alcotest.(check int) "removed" 0
      (List.length (C2c_mcp.Broker.list_registrations broker));
    C2c_mcp.Broker.register broker ~session_id:"foreign" ~alias:m.alias ~pid:None
      ~pid_start_time:None ~registered_by:(Some "other") ();
    Alcotest.(check bool) "foreign preserved" true
      (match S.unpublish_mapping ~owner ~mapping:m with Error _ -> true | Ok () -> false);
    Alcotest.(check int) "foreign row remains" 1
      (List.length (C2c_mcp.Broker.list_registrations broker)))

let test_apply_retire_and_reopen () =
  let state_dir = Filename.temp_file "c2c-t3-apply-state" "" in
  Sys.remove state_dir;
  let broker_root = Filename.temp_file "c2c-t3-apply-broker" "" in
  Sys.remove broker_root;
  let cleanup () =
    ignore (Sys.command (Printf.sprintf "/bin/rm -rf %s %s"
      (Filename.quote state_dir) (Filename.quote broker_root)))
  in
  Fun.protect ~finally:cleanup (fun () ->
    let state =
      match State.open_state ~dir:state_dir () with
      | Ok state -> state
      | Error _ -> Alcotest.fail "open state"
    in
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    let pid = Some (Unix.getpid ()) in
    let owner =
      { S.environment_id = "env"; broker; pid;
        pid_start_time = C2c_mcp.Broker.capture_pid_start_time pid;
        cwd = None; opaque_host_id = None }
    in
    let candidate = { S.thread = thread "root"; mapping = None } in
    let first =
      S.apply_plan ~owner ~state
        ~plan:{ routable = [ candidate ]; unroutable = []; retire = []; degraded = [] }
    in
    Alcotest.(check int) "published" 1 (List.length first.published);
    let mapping =
      match State.find_by_thread state ~thread_id:"root" with
      | Some mapping -> mapping
      | None -> Alcotest.fail "mapping was not persisted"
    in
    let retired =
      S.apply_plan ~owner ~state
        ~plan:{ routable = []; unroutable = []; retire = [ (mapping, "archived") ]; degraded = [] }
    in
    Alcotest.(check int) "retired" 1 (List.length retired.retired);
    let tombstoned =
      match State.find_by_thread state ~thread_id:"root" with
      | Some mapping -> mapping
      | None -> Alcotest.fail "tombstone missing"
    in
    Alcotest.(check bool) "tombstone" true (tombstoned.State.tombstone <> None);
    let reopened =
      S.apply_plan ~owner ~state
        ~plan:{ routable = [ { candidate with mapping = Some tombstoned } ];
                unroutable = []; retire = []; degraded = [] }
    in
    Alcotest.(check int) "reopened" 1 (List.length reopened.published);
    let final_mapping = Option.get (State.find_by_thread state ~thread_id:"root") in
    Alcotest.(check string) "alias retained" mapping.alias final_mapping.alias;
    Alcotest.(check bool) "active" true (final_mapping.State.tombstone = None);
    State.close state)

let () =
  Alcotest.run "c2c_t3_service"
    [ ("decode", [ Alcotest.test_case "root and fork" `Quick test_root_and_fork;
                    Alcotest.test_case "lifecycle" `Quick test_lifecycle_and_permission;
                    Alcotest.test_case "point read errors" `Quick test_point_read_error_contract ]);
      ("reconcile", [ Alcotest.test_case "partial" `Quick test_partial_scan_never_retires;
                       Alcotest.test_case "point reads" `Quick test_complete_scan_requires_point_read;
                       Alcotest.test_case "titles" `Quick test_title_change_duplicate_names ]);
      ("state", [ Alcotest.test_case "environment alias" `Quick test_state_environment_alias_and_reopen ]);
      ("locator", [ Alcotest.test_case "resolve" `Quick test_locator ]);
      ("broker", [ Alcotest.test_case "owned registration" `Quick test_service_owned_registration;
                    Alcotest.test_case "apply retire reopen" `Quick test_apply_retire_and_reopen ]) ]
