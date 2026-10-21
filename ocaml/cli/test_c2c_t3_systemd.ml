open Alcotest

module S = C2c_t3_systemd

let contains hay needle =
  let n = String.length needle in
  let rec loop i = i + n <= String.length hay &&
    (String.sub hay i n = needle || loop (i + 1)) in
  loop 0

let test_unit_is_explicit () =
  let text = S.unit_text ~c2c_path:"/opt/c2c/bin/c2c" ~t3_home:"/srv/t3"
      ~config_dir:"/srv/c2c/config" ~state_dir:"/srv/c2c/state" () in
  check bool "absolute c2c path" true (String.contains text '/');
  check bool "foreground service" true (contains text "t3 service --foreground");
  check bool "T3 home" true (contains text "Environment=T3CODE_HOME=/srv/t3");
  check bool "state dir" true (contains text "Environment=C2C_T3_STATE_DIR=/srv/c2c/state");
  check bool "restart policy" true (contains text "Restart=always")

let test_systemd_fixture_runner () =
  let calls = ref [] in
  let run args = calls := args :: !calls; S.Systemctl_ok in
  check bool "fixture available" true (S.systemd_user_available ~run ());
  ignore (S.install ~run ~dry_run:true ~c2c_path:"/bin/c2c" ~t3_home:"/tmp/t3"
            ~config_dir:"/tmp/config" ~state_dir:"/tmp/state" ());
  check bool "availability and install queried" true (List.length !calls >= 2)

let test_unit_quotes_paths () =
  let text = S.unit_text ~c2c_path:"/opt/c2c bin/c2c" ~t3_home:"/srv/t3 home"
      ~config_dir:"/srv/c2c config" ~state_dir:"/srv/c2c state" () in
  check bool "quoted executable" true (contains text "ExecStart=\"/opt/c2c bin/c2c\"");
  check bool "quoted home" true (contains text "Environment=T3CODE_HOME=\"/srv/t3 home\"")

let with_fixture f =
  let root = Filename.temp_file "c2c-t3-supervision-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  let saved = List.map (fun key -> key, Sys.getenv_opt key)
      [ "HOME"; "XDG_CONFIG_HOME"; "T3CODE_HOME"; "C2C_T3_CONFIG_DIR"; "C2C_T3_STATE_DIR" ] in
  Unix.putenv "HOME" root;
  Unix.putenv "XDG_CONFIG_HOME" (Filename.concat root "xdg");
  Unix.putenv "T3CODE_HOME" (Filename.concat root "t3");
  Unix.putenv "C2C_T3_CONFIG_DIR" (Filename.concat root "config");
  Unix.putenv "C2C_T3_STATE_DIR" (Filename.concat root "state");
  Fun.protect ~finally:(fun () ->
    List.iter (fun (key, value) -> Unix.putenv key (Option.value value ~default:"")) saved;
    ignore (Sys.command ("rm -rf -- " ^ Filename.quote root)))
    (fun () -> f root)

let write path content =
  S.private_mkdir_p (Filename.dirname path);
  let oc = open_out_gen [ Open_wronly; Open_creat; Open_trunc ] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

let paths root =
  Filename.concat root "bin/c2c", Filename.concat root "t3",
  Filename.concat root "config", Filename.concat root "state"

let query_active args =
  if List.mem "MainPID" args then Some "55"
  else if List.mem "is-active" args then Some "active"
  else Some "enabled"

let test_install_requires_native_readiness () = with_fixture (fun root ->
  let c2c_path, t3_home, config_dir, state_dir = paths root in
  let calls = ref [] and readiness_calls = ref 0 in
  let run args = calls := args :: !calls; S.Systemctl_ok in
  let readiness ~pid () = incr readiness_calls; check int "MainPID passed" 55 pid; Ok () in
  let result = S.install ~run ~query:query_active ~readiness ~timeout:0.
      ~c2c_path ~t3_home ~config_dir ~state_dir () in
  check bool "installed only after readiness" true (match result with S.Installed _ -> true | _ -> false);
  check int "readiness was checked" 1 !readiness_calls;
  check bool "enable and start" true (List.mem [ "--user"; "enable"; "--now"; S.unit_name ] !calls);
  let failure = S.install ~run ~query:query_active
      ~readiness:(fun ~pid:_ () -> Error "unpaired API") ~timeout:0.
      ~c2c_path ~t3_home ~config_dir ~state_dir () in
  check bool "systemd active alone is insufficient" true (match failure with S.Failed _ -> true | _ -> false))

let test_install_missing_pid_and_dry_run () = with_fixture (fun root ->
  let c2c_path, t3_home, config_dir, state_dir = paths root in
  let calls = ref [] in
  let run args = calls := args :: !calls; S.Systemctl_ok in
  ignore (S.install ~run ~dry_run:true ~c2c_path ~t3_home ~config_dir ~state_dir ());
  check bool "dry run never creates unit" false (Sys.file_exists (S.unit_path ()));
  check bool "dry run never enables" false (List.exists (List.mem "enable") !calls);
  let query args = if List.mem "MainPID" args then None else Some "active" in
  let result = S.install ~run ~query ~timeout:0.
      ~readiness:(fun ~pid:_ () -> fail "missing MainPID must not invoke readiness")
      ~c2c_path ~t3_home ~config_dir ~state_dir () in
  check bool "missing PID fails" true (match result with S.Failed _ -> true | _ -> false))

let test_unavailable_manager_does_not_write () = with_fixture (fun root ->
  let c2c_path, t3_home, config_dir, state_dir = paths root in
  let run _ = S.Systemctl_failed "no user manager" in
  let result = S.install ~run ~c2c_path ~t3_home ~config_dir ~state_dir () in
  check bool "unavailable manager is explicit" true (match result with S.Skipped _ -> true | _ -> false);
  check bool "no unit written" false (Sys.file_exists (S.unit_path ())))

let test_scope_and_drift () = with_fixture (fun root ->
  let c2c_path, t3_home, config_dir, state_dir = paths root in
  write (S.unit_path ()) (S.unit_text ~c2c_path ~t3_home ~config_dir ~state_dir ());
  check bool "matching unit" true (S.unit_plan ~c2c_path ~t3_home ~config_dir ~state_dir () = Ok `Current);
  check bool "executable drift recognized" true
    (S.unit_plan ~c2c_path:(c2c_path ^ "-new") ~t3_home ~config_dir ~state_dir () = Ok `Drifted);
  check bool "different environment refused" true
    (Result.is_error (S.unit_plan ~c2c_path ~t3_home:(t3_home ^ "-other") ~config_dir ~state_dir ())))

let test_foreign_and_symlink_units_preserved () = with_fixture (fun root ->
  let target = Filename.concat root "foreign" in
  write target "foreign unit";
  S.private_mkdir_p (Filename.dirname (S.unit_path ()));
  Unix.symlink target (S.unit_path ());
  let run _ = fail "foreign unit must not invoke systemctl" in
  check bool "stop refuses symlink" true (match S.stop ~run () with S.Systemctl_failed _ -> true | _ -> false);
  check bool "uninstall refuses symlink" true (match S.uninstall ~run () with S.Systemctl_failed _ -> true | _ -> false);
  check bool "foreign target remains" true (Sys.file_exists target);
  check bool "nofollow read refuses target" true (Result.is_error (S.read_owned_regular ~max_bytes:1024 (S.unit_path ()))) )

let test_failed_stop_preserves_unit () = with_fixture (fun root ->
  let c2c_path, t3_home, config_dir, state_dir = paths root in
  write (S.unit_path ()) (S.unit_text ~c2c_path ~t3_home ~config_dir ~state_dir ());
  let run _ = S.Systemctl_failed "fixture stop failed" in
  check bool "uninstall reports failure" true (match S.uninstall ~run () with S.Systemctl_failed _ -> true | _ -> false);
  check bool "unit kept on failure" true (Sys.file_exists (S.unit_path ()));
  check bool "dry stop is harmless" true (S.stop ~run ~dry_run:true () = S.Systemctl_ok))

let test_scoped_stop_and_uninstall () = with_fixture (fun root ->
  let c2c_path, t3_home, config_dir, state_dir = paths root in
  let contents = S.unit_text ~c2c_path ~t3_home ~config_dir ~state_dir () in
  write (S.unit_path ()) contents;
  let run _ = fail "different environment must not invoke systemctl" in
  check bool "stop refuses marked foreign scope" true
    (match S.stop ~run ~t3_home:(t3_home ^ "-other") () with S.Systemctl_failed _ -> true | _ -> false);
  check bool "uninstall refuses marked foreign scope" true
    (match S.uninstall ~run ~state_dir:(state_dir ^ "-other") () with S.Systemctl_failed _ -> true | _ -> false);
  check bool "foreign scope unit kept" true
    (S.read_owned_regular ~max_bytes:65536 (S.unit_path ()) = Ok contents))

let test_install_rechecks_scope_after_reload () = with_fixture (fun root ->
  let c2c_path, t3_home, config_dir, state_dir = paths root in
  let foreign = S.unit_text ~c2c_path ~t3_home:(t3_home ^ "-other") ~config_dir ~state_dir () in
  let calls = ref [] in
  let run args =
    calls := args :: !calls;
    if List.mem "daemon-reload" args then write (S.unit_path ()) foreign;
    S.Systemctl_ok in
  let result = S.install ~run ~query:query_active ~timeout:0.
      ~readiness:(fun ~pid:_ () -> Ok ()) ~c2c_path ~t3_home ~config_dir ~state_dir () in
  check bool "replacement fails installation" true (match result with S.Failed _ -> true | _ -> false);
  check bool "foreign scope is not enabled" false (List.exists (List.mem "enable") !calls);
  check bool "foreign scope preserved" true (S.read_owned_regular ~max_bytes:65536 (S.unit_path ()) = Ok foreign))

let test_uninstall_rechecks_scope_after_stop () = with_fixture (fun root ->
  let c2c_path, t3_home, config_dir, state_dir = paths root in
  write (S.unit_path ()) (S.unit_text ~c2c_path ~t3_home ~config_dir ~state_dir ());
  let foreign = S.unit_text ~c2c_path ~t3_home ~config_dir:(config_dir ^ "-other") ~state_dir () in
  let run args =
    if List.mem "disable" args then (write (S.unit_path ()) foreign; S.Systemctl_ok)
    else fail "replacement must not be deleted or reloaded" in
  check bool "replacement refuses unlink" true
    (match S.uninstall ~run () with S.Systemctl_failed _ -> true | _ -> false);
  check bool "replacement remains" true (S.read_owned_regular ~max_bytes:65536 (S.unit_path ()) = Ok foreign))

let test_unit_lock_serializes_processes () = with_fixture (fun root ->
  let c2c_path, t3_home, config_dir, state_dir = paths root in
  write (S.unit_path ()) (S.unit_text ~c2c_path ~t3_home ~config_dir ~state_dir ());
  let result = S.with_unit_lock ~dry_run:false (fun () ->
    match Unix.fork () with
    | 0 ->
        let run _ = Unix._exit 2 in
        (match S.stop ~run () with S.Systemctl_failed _ -> Unix._exit 0 | _ -> Unix._exit 3)
    | child -> snd (Unix.waitpid [] child)) in
  check bool "competing process is refused under unit lock" true (result = Ok (Unix.WEXITED 0)))

let test_bounded_readiness_without_sleeps () =
  let ticks = ref 0. and calls = ref 0 in
  let readiness ~pid:_ () = incr calls; Error "not yet ready" in
  let result = S.await_readiness ~clock:(fun () -> !ticks)
      ~pause:(fun () -> ticks := !ticks +. 1.) ~timeout:2.
      ~query:query_active ~readiness () in
  check bool "bounded failure" true (Result.is_error result);
  check int "bounded checks" 3 !calls

let test_process_identity_and_monitor () = with_fixture (fun root ->
  let c2c_path, t3_home, config_dir, state_dir = paths root in
  write c2c_path "fixture executable identity";
  let proc_root = Filename.concat root "proc" in
  let proc = Filename.concat proc_root "55" in
  S.private_mkdir_p proc;
  Unix.symlink c2c_path (Filename.concat proc "exe");
  write (Filename.concat proc "cmdline") (c2c_path ^ "\000t3\000service\000--foreground\000");
  write (Filename.concat proc "environ")
    ("T3CODE_HOME=" ^ t3_home ^ "\000C2C_T3_CONFIG_DIR=" ^ config_dir ^ "\000C2C_T3_STATE_DIR=" ^ state_dir ^ "\000");
  let generation _ = C2c_pid_identity.Generation 99 in
  let check_process () = S.check_process ~proc_root ~generation ~pid:55
      ~c2c_path ~t3_home ~config_dir ~state_dir () in
  check bool "exact process passes" true (check_process () = Ok 99);
  write (Filename.concat proc "cmdline") (c2c_path ^ "\000t3\000service\000");
  check bool "default foreground invocation passes" true (check_process () = Ok 99);
  write (Filename.concat proc "cmdline") (c2c_path ^ "\000t3\000service\000--once\000");
  check bool "one shot is not a periodic owner" true (Result.is_error (check_process ()));
  write (Filename.concat proc "cmdline") (c2c_path ^ "\000t3\000service\000--foreground\000");
  check bool "wrong environment fails" true
    (Result.is_error (S.check_process ~proc_root ~generation ~pid:55 ~c2c_path
                       ~t3_home:(t3_home ^ "-other") ~config_dir ~state_dir ()));
  let json = `Assoc [ "pid", `Int 55; "pidGeneration", `Int 99;
                     "environmentId", `String (S.environment_id t3_home);
                     "completedAt", `Float 100.; "intervalSeconds", `Int 60;
                     "healthy", `Bool true ] in
  write (Filename.concat state_dir "service-status.json") (Yojson.Safe.to_string json);
  check bool "fresh owner sweep passes" true
    (S.check_monitor ~clock:(fun () -> 101.) ~pid:55 ~generation:99 ~t3_home ~state_dir () = Ok ());
  check bool "stale sweep fails" true
    (Result.is_error (S.check_monitor ~clock:(fun () -> 1000.) ~pid:55 ~generation:99 ~t3_home ~state_dir ()));
  check bool "wrong generation fails" true
    (Result.is_error (S.check_monitor ~clock:(fun () -> 101.) ~pid:55 ~generation:100 ~t3_home ~state_dir ()));
  let old_with_large_interval = match json with `Assoc fields ->
    `Assoc (("intervalSeconds", `Int 1000000000) :: List.remove_assoc "intervalSeconds" fields) | _ -> assert false in
  write (Filename.concat state_dir "service-status.json") (Yojson.Safe.to_string old_with_large_interval);
  check bool "large interval cannot bless old heartbeat" true
    (Result.is_error (S.check_monitor ~clock:(fun () -> 1000.) ~pid:55 ~generation:99 ~t3_home ~state_dir ()));
  Unix.unlink (Filename.concat proc "exe");
  let stale_binary = c2c_path ^ "-old" in write stale_binary "old bytes";
  Unix.symlink stale_binary (Filename.concat proc "exe");
  check bool "old running executable fails" true (Result.is_error (check_process ())))

let () =
  Alcotest.run "c2c_t3_systemd"
    [ ("unit", [ test_case "explicit unit paths" `Quick test_unit_is_explicit ]);
      ("fixture", [ test_case "systemd runner seam" `Quick test_systemd_fixture_runner;
                     test_case "paths are quoted" `Quick test_unit_quotes_paths;
                     test_case "install verifies readiness" `Quick test_install_requires_native_readiness;
                     test_case "missing PID and dry run" `Quick test_install_missing_pid_and_dry_run;
                     test_case "missing user manager" `Quick test_unavailable_manager_does_not_write;
                     test_case "scope and drift" `Quick test_scope_and_drift;
                     test_case "foreign unit preservation" `Quick test_foreign_and_symlink_units_preserved;
                     test_case "failed stop keeps unit" `Quick test_failed_stop_preserves_unit;
                     test_case "stop and uninstall exact scope" `Quick test_scoped_stop_and_uninstall;
                     test_case "install scope replacement" `Quick test_install_rechecks_scope_after_reload;
                     test_case "uninstall scope replacement" `Quick test_uninstall_rechecks_scope_after_stop;
                     test_case "unit operations serialize" `Quick test_unit_lock_serializes_processes;
                     test_case "bounded readiness clock" `Quick test_bounded_readiness_without_sleeps;
                     test_case "process and sweep identity" `Quick test_process_identity_and_monitor ]) ]
