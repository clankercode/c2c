(* Hermetic tests for C2c_idle_contract (P2.M2.E1.T002). *)

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc contents)

let tmp_dir () =
  let path = Filename.temp_file "c2c_idle_contract" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let state_testable =
  Alcotest.testable
    (fun ppf s -> Format.pp_print_string ppf (C2c_idle_contract.idle_state_to_string s))
    (fun a b ->
      match (a, b) with
      | C2c_idle_contract.Idle, C2c_idle_contract.Idle
      | C2c_idle_contract.Busy, C2c_idle_contract.Busy ->
          true
      | C2c_idle_contract.Unknown ra, C2c_idle_contract.Unknown rb -> ra = rb
      | _ -> false)

let check_state = Alcotest.check state_testable

let iso_at epoch =
  (* Fixed RFC3339 for tests: epoch is unix seconds. *)
  let tm = Unix.gmtime epoch in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.000Z"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let write_opencode_state dir ~name ~is_idle ~updated_epoch =
  let path = Filename.concat dir "oc-plugin-state.json" in
  let ts = iso_at updated_epoch in
  let agent =
    match is_idle with
    | None -> `Assoc [ ("is_idle", `Null) ]
    | Some b -> `Assoc [ ("is_idle", `Bool b) ]
  in
  let json =
    `Assoc
      [ ("event", `String "state.snapshot")
      ; ("ts", `String ts)
      ; ( "state",
          `Assoc
            [ ("c2c_session_id", `String name)
            ; ("state_last_updated_at", `String ts)
            ; ("agent", agent)
            ] )
      ]
  in
  Yojson.Safe.to_file path json;
  path

let test_app_server_idle_busy_unknown () =
  let dir = tmp_dir () in
  check_state "app-server idle" C2c_idle_contract.Idle
    (C2c_idle_contract.query ~kind:Codex_app_server ~instance_dir:dir
       ~app_server_status:`Idle ());
  check_state "app-server busy" C2c_idle_contract.Busy
    (C2c_idle_contract.query ~kind:Codex_app_server ~instance_dir:dir
       ~app_server_status:`Active ());
  check_state "app-server status unknown"
    (C2c_idle_contract.Unknown "app-server thread status unknown")
    (C2c_idle_contract.query ~kind:Codex_app_server ~instance_dir:dir
       ~app_server_status:`Unknown ());
  check_state "app-server not queried"
    (C2c_idle_contract.Unknown "app-server status not queried")
    (C2c_idle_contract.query ~kind:Codex_app_server ~instance_dir:dir ())

let test_opencode_idle_busy_fresh () =
  let dir = tmp_dir () in
  let now = 1_700_000_000.0 in
  ignore (write_opencode_state dir ~name:"oc1" ~is_idle:(Some true)
            ~updated_epoch:now);
  check_state "opencode idle" C2c_idle_contract.Idle
    (C2c_idle_contract.query ~kind:OpenCode ~instance_dir:dir ~now ());
  ignore (write_opencode_state dir ~name:"oc1" ~is_idle:(Some false)
            ~updated_epoch:now);
  check_state "opencode busy" C2c_idle_contract.Busy
    (C2c_idle_contract.query ~kind:OpenCode ~instance_dir:dir ~now ())

let test_opencode_stale_and_null_fail_closed () =
  let dir = tmp_dir () in
  let now = 1_700_000_100.0 in
  ignore (write_opencode_state dir ~name:"oc1" ~is_idle:(Some true)
            ~updated_epoch:(now -. 200.0));
  (match
     C2c_idle_contract.query ~kind:OpenCode ~instance_dir:dir ~now
       ~opencode_freshness_s:90.0 ()
   with
   | C2c_idle_contract.Unknown reason ->
       Alcotest.(check bool) "stale mentions age" true
         (let rec contains s sub i =
            if i + String.length sub > String.length s then false
            else if String.sub s i (String.length sub) = sub then true
            else contains s sub (i + 1)
          in
          String.length reason > 0 && contains reason "stale" 0)
   | other ->
       Alcotest.failf "expected Unknown, got %s"
         (C2c_idle_contract.idle_state_to_string other));
  ignore (write_opencode_state dir ~name:"oc1" ~is_idle:None
            ~updated_epoch:now);
  check_state "null is_idle is unknown"
    (C2c_idle_contract.Unknown "opencode agent.is_idle absent (null/unknown)")
    (C2c_idle_contract.query ~kind:OpenCode ~instance_dir:dir ~now ())

let test_opencode_missing_statefile () =
  let dir = tmp_dir () in
  check_state "missing statefile"
    (C2c_idle_contract.Unknown "opencode statefile missing or unreadable")
    (C2c_idle_contract.query ~kind:OpenCode ~instance_dir:dir
       ~now:1_700_000_000.0 ())

let test_no_authoritative_tui_clients () =
  let dir = tmp_dir () in
  List.iter
    (fun (kind, name) ->
      match C2c_idle_contract.query ~kind ~instance_dir:dir () with
      | C2c_idle_contract.Unknown reason ->
          Alcotest.(check bool)
            (name ^ " fails closed") true
            (String.length reason > 0)
      | other ->
          Alcotest.failf "%s expected Unknown, got %s" name
            (C2c_idle_contract.idle_state_to_string other))
    [ C2c_idle_contract.Claude, "claude"
    ; C2c_idle_contract.Kimi, "kimi"
    ; C2c_idle_contract.Agy, "agy"
    ; C2c_idle_contract.Codex_hooks, "codex-hooks"
    ]

let test_auto_restart_allowed_policy () =
  Alcotest.(check bool) "idle allows" true
    (C2c_idle_contract.auto_restart_allowed Idle);
  Alcotest.(check bool) "busy denies" false
    (C2c_idle_contract.auto_restart_allowed Busy);
  Alcotest.(check bool) "unknown denies" false
    (C2c_idle_contract.auto_restart_allowed (Unknown "x"))

let test_resolve_codex_by_mapping () =
  Alcotest.(check bool) "mapping => app-server" true
    (C2c_idle_contract.resolve_client_kind ~client:"codex"
       ~has_app_server_mapping:true
     = Some C2c_idle_contract.Codex_app_server);
  Alcotest.(check bool) "no mapping => hooks" true
    (C2c_idle_contract.resolve_client_kind ~client:"codex"
       ~has_app_server_mapping:false
     = Some C2c_idle_contract.Codex_hooks)

let test_never_uses_activity_age_for_claude () =
  (* Even with a fabricated "recent activity" file, Claude stays Unknown —
     activity-age is not a substitute for authoritative idle. *)
  let dir = tmp_dir () in
  write_file (Filename.concat dir "last_activity") "9999999999";
  match C2c_idle_contract.query ~kind:Claude ~instance_dir:dir () with
  | C2c_idle_contract.Unknown _ -> ()
  | other ->
      Alcotest.failf "activity file must not mint Idle/Busy, got %s"
        (C2c_idle_contract.idle_state_to_string other)

let () =
  Alcotest.run "c2c_idle_contract"
    [ ( "idle-contract",
        [ Alcotest.test_case "app-server idle/busy/unknown" `Quick
            test_app_server_idle_busy_unknown
        ; Alcotest.test_case "opencode idle/busy when fresh" `Quick
            test_opencode_idle_busy_fresh
        ; Alcotest.test_case "opencode stale/null fail closed" `Quick
            test_opencode_stale_and_null_fail_closed
        ; Alcotest.test_case "opencode missing statefile" `Quick
            test_opencode_missing_statefile
        ; Alcotest.test_case "claude/kimi/agy/hooks unknown" `Quick
            test_no_authoritative_tui_clients
        ; Alcotest.test_case "auto_restart_allowed policy" `Quick
            test_auto_restart_allowed_policy
        ; Alcotest.test_case "resolve codex by mapping" `Quick
            test_resolve_codex_by_mapping
        ; Alcotest.test_case "no activity-age substitution" `Quick
            test_never_uses_activity_age_for_claude
        ] )
    ]
