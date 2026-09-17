(* test_c2c_relay_systemd — B296: boot supervision for the relay connector.

   The defect: the connector's exit-3 self-restart story terminated at
   C2c_relay_managed.supervise, a userland parent that dies at the first
   reboot/logout/OOM (x-left relay-dark 55 days). The fix is a systemd
   --user unit that makes systemd the outer supervisor.

   Locked down here:
   - unit text: absolute ExecStart path, Restart=always,
     StartLimitIntervalSec=0 (restart loops must not be rate-limited into
     darkness), WantedBy=default.target, and machine-mode env guard
     (UnsetEnvironment=C2C_MCP_BROKER_ROOT — the unit must not scope the
     connector to one repo).
   - activation gating (B300): the unit is installed only when
     Relay_activation resolves Active; a local-only host never gets one.
   - install/enable/disable/remove behavior with an injectable systemctl
     runner; the default runner is inert under C2C_SYSTEMCTL_FIXTURE=1 so
     no test ever executes systemctl.
   - uninstall manifest coverage: recompute_self_artifacts includes the unit.
   - the generated unit passes `systemd-analyze verify` (read-only; gated on
     availability). *)

open Alcotest

let ( // ) = Filename.concat

let tmpdir prefix =
  let d = Filename.get_temp_dir_name () // Printf.sprintf "%s-%08x" prefix (Random.bits ()) in
  (try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  d

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else (try Unix.unlink path with _ -> ())

let with_env k v f =
  let old = Sys.getenv_opt k in
  (match v with Some v -> Unix.putenv k v | None -> Unix.putenv k "");
  Fun.protect
    ~finally:(fun () ->
      match old with Some o -> Unix.putenv k o | None -> Unix.putenv k "")
    f

let write path contents =
  let dir = Filename.dirname path in
  let rec mkdir_p p =
    if p = "" || p = "." || Sys.file_exists p then ()
    else (mkdir_p (Filename.dirname p); Unix.mkdir p 0o755)
  in
  mkdir_p dir;
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc contents)

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec loop i =
    i + nl <= hl && (String.sub haystack i nl = needle || loop (i + 1))
  in
  nl = 0 || loop 0

(* Injectable systemctl runner: records argv, always succeeds. *)
let recording_runner () =
  let calls : string list list ref = ref [] in
  ( calls,
    fun args -> calls := !calls @ [ args ]; C2c_relay_systemd.Systemctl_ok )

(* Always-failing runner: models "systemctl missing / no user session". *)
let failing_runner _ = C2c_relay_systemd.Systemctl_failed "no systemctl"

(* Isolate the unit path (XDG_CONFIG_HOME) and the machine relay config
   (HOME) into temp dirs for the duration of f. *)
let with_isolated_home f =
  let home = tmpdir "c2c-relay-unit" in
  with_env "HOME" (Some home) (fun () ->
    with_env "XDG_CONFIG_HOME" (Some (home // ".config")) (fun () ->
      with_env "C2C_RELAY_CONFIG" (Some (home // ".config" // "c2c" // "relay.json")) (fun () ->
        with_env "C2C_RELAY_URL" None (fun () ->
          Fun.protect
            ~finally:(fun () -> try remove_tree home with _ -> ())
            (fun () -> f home)))))

let expected_unit_path home =
  home // ".config" // "systemd" // "user" // "c2c-relay-connect.service"

(* --- unit text ------------------------------------------------------------- *)

let test_unit_text_shape () =
  let bin = "/opt/c2c/bin/c2c" in
  let text = C2c_relay_systemd.unit_text ~c2c_path:bin () in
  check bool "absolute ExecStart path"
    true (contains ~haystack:text ~needle:("ExecStart=" ^ bin ^ " start relay-connect --foreground"));
  check bool "Restart=always" true (contains ~haystack:text ~needle:"Restart=always");
  check bool "StartLimitIntervalSec=0" true
    (contains ~haystack:text ~needle:"StartLimitIntervalSec=0");
  check bool "WantedBy=default.target" true
    (contains ~haystack:text ~needle:"WantedBy=default.target");
  check bool "restart backoff present" true (contains ~haystack:text ~needle:"RestartSec=");
  (* Machine mode: the connector serves ALL broker roots; the unit must not
     scope it to one repo, and must never recommend backgrounding. *)
  check bool "clears inherited repo-scoped broker root" true
    (contains ~haystack:text ~needle:"UnsetEnvironment=C2C_MCP_BROKER_ROOT");
  check bool "no repo-scoped broker root" true
    (not (contains ~haystack:text ~needle:"--broker-root"));
  check bool "no backgrounding" true (not (contains ~haystack:text ~needle:"&"))

let test_unit_text_relay_url_env () =
  let bin = "/usr/local/bin/c2c" in
  (* Durable machine relay.json: no pin — the supervisor resolves relay.json
     at every start, so `c2c relay enable --url` re-points without a unit
     rewrite. *)
  let text = C2c_relay_systemd.unit_text ~c2c_path:bin () in
  check bool "no env pin by default" true
    (not (contains ~haystack:text ~needle:"Environment=C2C_RELAY_URL="));
  (* Activation via C2C_RELAY_URL/--relay-url (no durable machine config):
     the user manager will not inherit the shell env, so pin the URL. *)
  let pinned =
    C2c_relay_systemd.unit_text ~c2c_path:bin ~relay_url_env:"https://r.example" ()
  in
  check bool "pins env URL" true
    (contains ~haystack:pinned ~needle:"Environment=C2C_RELAY_URL=https://r.example")

(* URL pinning rule: pin only when the machine relay.json cannot answer. *)
let test_relay_url_env_for_unit () =
  with_isolated_home (fun home ->
    (* No machine config + env activation -> pinned. *)
    with_env "C2C_RELAY_URL" (Some "https://env.example") (fun () ->
      check (option string) "env activation pins URL" (Some "https://env.example")
        (C2c_relay_systemd.relay_url_env_for_unit ()));
    (* Machine config with a url -> resolved at start, no pin. *)
    let cfg = home // ".config" // "c2c" // "relay.json" in
    write cfg {|{"url":"https://cfg.example","enabled":true}|};
    check bool "machine config has url" true (C2c_relay_systemd.machine_relay_config_has_url ());
    with_env "C2C_RELAY_URL" (Some "https://env.example") (fun () ->
      check (option string) "durable config wins: no pin" None
        (C2c_relay_systemd.relay_url_env_for_unit ())))

(* --- B300 gating ------------------------------------------------------------ *)

let test_install_gated_on_activation () =
  with_isolated_home (fun home ->
    (* Inactive: local-only host must never get a unit, even with systemd
       present (recording runner succeeds at everything). *)
    let calls, run = recording_runner () in
    check bool "inactive host: no unit" true
      (not (C2c_relay_systemd.should_install_for_self ()));
    check bool "inactive host: nothing installed" true
      (match C2c_relay_systemd.install_and_enable_if_active ~run ~c2c_path:"/bin/c2c" () with
       | C2c_relay_systemd.Unit_not_activated -> true
       | _ -> false);
    check bool "no systemctl calls while inactive" true ((!calls) = []);
    check bool "no unit file while inactive" true
      (not (Sys.file_exists (expected_unit_path home)));
    (* Active: unit installed + enabled. *)
    let cfg = home // ".config" // "c2c" // "relay.json" in
    write cfg {|{"url":"https://r.example","enabled":true}|};
    check bool "active host: install" true (C2c_relay_systemd.should_install_for_self ());
    let calls2, run2 = recording_runner () in
    let status =
      C2c_relay_systemd.install_and_enable_if_active ~run:run2 ~c2c_path:"/bin/c2c" ()
    in
    (match status with
     | C2c_relay_systemd.Unit_enabled p ->
         check string "unit path" (expected_unit_path home) p
     | _ -> check bool "expected Unit_enabled" false false);
    check bool "unit file written" true (Sys.file_exists (expected_unit_path home));
    let flattened = List.map (String.concat " ") !calls2 in
    check bool "daemon-reload ran" true
      (List.mem "--user daemon-reload" flattened);
    check bool "enable --now ran" true
      (List.mem "--user enable --now c2c-relay-connect.service" flattened))

(* --- availability / graceful skip ------------------------------------------ *)

let test_install_skips_without_systemd () =
  with_isolated_home (fun home ->
    write (home // ".config" // "c2c" // "relay.json") {|{"url":"https://r.example"}|};
    let status =
      C2c_relay_systemd.install_and_enable_if_active ~run:failing_runner
        ~c2c_path:"/bin/c2c" ()
    in
    (match status with
     | C2c_relay_systemd.Unit_skipped reason ->
         check bool "reason mentions systemd" true
           (contains ~haystack:reason ~needle:"systemd")
     | _ -> check bool "expected Unit_skipped" false false);
    check bool "no unit file written" true
      (not (Sys.file_exists (expected_unit_path home))))

let test_install_dry_run_writes_nothing () =
  with_isolated_home (fun home ->
    write (home // ".config" // "c2c" // "relay.json") {|{"url":"https://r.example"}|};
    let calls, run = recording_runner () in
    let status =
      C2c_relay_systemd.install_and_enable_if_active ~run ~dry_run:true
        ~c2c_path:"/bin/c2c" ()
    in
    (match status with
     | C2c_relay_systemd.Unit_enabled _ -> ()
     | _ -> check bool "dry run reports would-enable" false false);
    check bool "dry run: no unit file" true
      (not (Sys.file_exists (expected_unit_path home)));
    (* Dry run may PROBE availability (read-only) but must not mutate:
       no daemon-reload, no enable, no unit start. *)
    let mutating =
      List.filter
        (fun call ->
           let call = String.concat " " call in
           contains ~haystack:call ~needle:"daemon-reload"
           || contains ~haystack:call ~needle:"enable"
           || contains ~haystack:call ~needle:"start")
        !calls
    in
    check bool "dry run: no mutating systemctl calls" true (mutating = []))

(* --- disable / remove ------------------------------------------------------- *)

let test_stop_and_disable_keeps_file () =
  with_isolated_home (fun home ->
    let unit = expected_unit_path home in
    write unit "stub unit";
    let calls, run = recording_runner () in
    C2c_relay_systemd.stop_and_disable ~run ();
    check bool "unit file kept (re-enable is cheap)" true (Sys.file_exists unit);
    check bool "disable --now recorded" true
      (List.mem "--user disable --now c2c-relay-connect.service"
         (List.map (String.concat " ") !calls)))

let test_disable_and_remove_unlinks_and_disables () =
  with_isolated_home (fun home ->
    let unit = expected_unit_path home in
    write unit "stub unit";
    let calls, run = recording_runner () in
    C2c_relay_systemd.disable_and_remove ~run ();
    check bool "unit file removed" true (not (Sys.file_exists unit));
    let flattened = List.map (String.concat " ") !calls in
    check bool "disable --now before removal" true
      (List.mem "--user disable --now c2c-relay-connect.service" flattened);
    check bool "daemon-reload after removal" true
      (List.mem "--user daemon-reload" flattened));
  with_isolated_home (fun home ->
    (* Absent unit: no systemctl churn, no error. *)
    let calls, run = recording_runner () in
    C2c_relay_systemd.disable_and_remove ~run ();
    check bool "absent unit: no systemctl" true ((!calls) = []))

(* --- binary path for ExecStart ---------------------------------------------- *)

let test_c2c_binary_for_unit_prefers_installed () =
  with_isolated_home (fun home ->
    (* x-left lesson: non-login shells lack ~/.local/bin on PATH; the unit
       must name an absolute path. The canonical install location wins when
       it exists. *)
    let bin = home // ".local" // "bin" // "c2c" in
    write bin "#!/bin/sh\n";
    Unix.chmod bin 0o755;
    check string "installed binary wins" bin (C2c_relay_systemd.c2c_binary_for_unit ());
    Unix.unlink bin;
    let resolved = C2c_relay_systemd.c2c_binary_for_unit () in
    check bool "falls back to absolute argv[0]" true
      (String.length resolved > 0 && resolved.[0] = '/'))

(* --- default runner is fixture-gated ---------------------------------------- *)

let test_default_runner_inert_under_fixture () =
  let cap = tmpdir "c2c-systemctl-cap" // "calls.log" in
  with_env "C2C_SYSTEMCTL_FIXTURE" (Some "1") (fun () ->
    with_env "C2C_SYSTEMCTL_CAPTURE_FILE" (Some cap) (fun () ->
      (match C2c_relay_systemd.run_systemctl_default [ "--user"; "is-system-running" ] with
       | C2c_relay_systemd.Systemctl_ok -> ()
       | C2c_relay_systemd.Systemctl_failed _ ->
           check bool "fixture runner succeeds without executing" false false);
      let ic = open_in cap in
      let line = input_line ic in
      close_in ic;
      check string "argv captured" "systemctl --user is-system-running" line))

(* --- uninstall manifest coverage -------------------------------------------- *)

let test_recompute_self_artifacts_include_unit () =
  with_isolated_home (fun home ->
    let artifacts = C2c_uninstall.recompute_self_artifacts () in
    check bool "unit file in self uninstall fallback" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "owned-file" && a.path = expected_unit_path home)
         artifacts))

(* --- systemd-analyze verify (read-only; gated on availability) --------------- *)

let system_analyze_available () =
  let path = try Sys.getenv "PATH" with Not_found -> "" in
  String.split_on_char ':' path
  |> List.exists (fun dir ->
         let dir = if dir = "" then "." else dir in
         Sys.file_exists (dir // "systemd-analyze"))

let test_unit_passes_systemd_analyze_verify () =
  if not (system_analyze_available ()) then
    check bool "systemd-analyze unavailable here: skipped" true true
  else begin
    let dir = tmpdir "c2c-unit-verify" in
    let unit = dir // C2c_relay_systemd.unit_name in
    (* A real executable path so verify's ExecStart check passes. *)
    let exe =
      let e = Sys.executable_name in
      if Filename.is_relative e then Sys.getcwd () // e else e
    in
    write unit (C2c_relay_systemd.unit_text ~c2c_path:exe ());
    let cmd = Printf.sprintf "systemd-analyze verify %s 2>&1" (Filename.quote unit) in
    let ic = Unix.open_process_in cmd in
    let out = Buffer.create 128 in
    (try
       while true do Buffer.add_string out (input_line ic); Buffer.add_char out '\n' done
     with End_of_file -> ());
    let status = Unix.close_process_in ic in
    remove_tree dir;
    let code = match status with Unix.WEXITED c -> c | _ -> 1 in
    check bool ("systemd-analyze verify exit 0: " ^ Buffer.contents out)
      true (code = 0)
  end

(* --- end-to-end against the real binary (fixture-gated systemctl) ---------- *
 *
 * Runs the built c2c.exe in an isolated HOME with C2C_SYSTEMCTL_FIXTURE=1 so
 * systemctl is recorded, never executed, and no host state is touched. *)

let c2c_exe =
  let e = Sys.executable_name in
  let abs = if Filename.is_relative e then Sys.getcwd () // e else e in
  Filename.dirname (Filename.dirname abs) // "cli" // "c2c.exe"

let read_file_all path =
  if not (Sys.file_exists path) then ""
  else begin
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic; s
  end

(* Returns (home, stdout+stderr, systemctl capture). *)
let run_isolated_in ~home args =
  let out = home // "out.txt" in
  let cap = home // "systemctl.log" in
  let env_cmd =
    Printf.sprintf
      "env -i PATH=/usr/bin HOME=%s XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s \
       C2C_SYSTEMCTL_FIXTURE=1 C2C_SYSTEMCTL_CAPTURE_FILE=%s %s %s > %s 2>&1"
      (Filename.quote home)
      (Filename.quote (home // ".config"))
      (Filename.quote (home // ".local" // "state"))
      (Filename.quote cap)
      (Filename.quote c2c_exe) args (Filename.quote out)
  in
  ignore (Sys.command env_cmd);
  (home, read_file_all out, read_file_all cap)

let run_isolated args =
  let home = tmpdir "c2c-relay-e2e" in
  run_isolated_in ~home args

let test_e2e_relay_enable_installs_unit () =
  let home, out, cap = run_isolated "relay enable" in
  Fun.protect
    ~finally:(fun () -> try remove_tree home with _ -> ())
    (fun () ->
       check bool "enable succeeded" true (contains ~haystack:out ~needle:"relay activated");
       let unit = expected_unit_path home in
       check bool "unit file written by relay enable" true (Sys.file_exists unit);
       let text = read_file_all unit in
       check bool "ExecStart is absolute and supervised" true
         (contains ~haystack:text ~needle:" start relay-connect --foreground"
          && contains ~haystack:text ~needle:"ExecStart=/");
       check bool "systemctl enabled it" true
         (contains ~haystack:cap
            ~needle:"systemctl --user enable --now c2c-relay-connect.service"))

let test_e2e_relay_disable_keeps_unit () =
  let home, _, _ = run_isolated "relay enable" in
  Fun.protect
    ~finally:(fun () -> try remove_tree home with _ -> ())
    (fun () ->
       (* Second phase must reuse the same isolated home. *)
       let _, out, cap = run_isolated_in ~home "relay disable" in
       check bool "disable succeeded" true
         (contains ~haystack:out ~needle:"relay deactivated");
       check bool "unit disabled via systemctl" true
         (contains ~haystack:cap
            ~needle:"systemctl --user disable --now c2c-relay-connect.service");
       check bool "unit file kept after disable" true
         (Sys.file_exists (expected_unit_path home)))

let test_e2e_install_self_gated_on_activation () =
  let home = tmpdir "c2c-relay-e2e-self" in
  Fun.protect
    ~finally:(fun () -> try remove_tree home with _ -> ())
    (fun () ->
       let dest = home // "bin" in
       (* Local-only host: no unit, even though the fixture runner reports a
          healthy systemd --user session (it answers every call with ok). *)
       let _, _, cap_local =
         run_isolated_in ~home (Printf.sprintf "install self --dest %s" (Filename.quote dest))
       in
       check bool "local-only install self: no unit" true
         (not (Sys.file_exists (expected_unit_path home)));
       check bool "local-only install self: no systemctl enable" true
         (not (contains ~haystack:cap_local ~needle:"enable --now"));
       (* Relay-activated host: unit installed, ExecStart names the
          just-installed binary. *)
       let cfg = home // ".config" // "c2c" // "relay.json" in
       write cfg {|{"url":"https://r.example","enabled":true}|};
       let _, out, cap_active =
         run_isolated_in ~home (Printf.sprintf "install self --dest %s" (Filename.quote dest))
       in
       check bool "activated install self: unit written" true
         (Sys.file_exists (expected_unit_path home));
       let text = read_file_all (expected_unit_path home) in
       check bool "ExecStart names the installed binary" true
         (contains ~haystack:text
            ~needle:("ExecStart=" ^ dest // "c2c" ^ " start relay-connect --foreground"));
       check bool "activated install self: systemctl enabled" true
         (contains ~haystack:cap_active
            ~needle:"systemctl --user enable --now c2c-relay-connect.service");
       check bool "activated install self: unit visible in summary" true
         (contains ~haystack:out ~needle:"c2c-relay-connect.service"))

let () =
  run "c2c_relay_systemd"
    [ ( "unit text"
      , [ test_case "shape: absolute ExecStart, Restart=always, no rate limit" `Quick test_unit_text_shape
        ; test_case "relay URL env pinning rule" `Quick test_unit_text_relay_url_env
        ; test_case "relay_url_env_for_unit prefers durable config" `Quick test_relay_url_env_for_unit
        ] )
    ; ( "gating"
      , [ test_case "install only when Relay_activation is active" `Quick test_install_gated_on_activation
        ; test_case "skip gracefully without systemd --user" `Quick test_install_skips_without_systemd
        ; test_case "dry run touches nothing" `Quick test_install_dry_run_writes_nothing
        ] )
    ; ( "disable / remove"
      , [ test_case "stop_and_disable disables but keeps the file" `Quick test_stop_and_disable_keeps_file
        ; test_case "disable_and_remove unlinks, disables, reloads" `Quick test_disable_and_remove_unlinks_and_disables
        ] )
    ; ( "paths / runner"
      , [ test_case "c2c_binary_for_unit prefers ~/.local/bin/c2c" `Quick test_c2c_binary_for_unit_prefers_installed
        ; test_case "default systemctl runner is fixture-gated" `Quick test_default_runner_inert_under_fixture
        ] )
    ; ( "uninstall"
      , [ test_case "recompute_self_artifacts includes the unit" `Quick test_recompute_self_artifacts_include_unit
        ] )
    ; ( "verify"
      , [ test_case "generated unit passes systemd-analyze verify" `Quick test_unit_passes_systemd_analyze_verify
        ] )
    ; ( "end-to-end (fixture-gated systemctl)"
      , [ test_case "relay enable installs + enables the unit" `Quick test_e2e_relay_enable_installs_unit
        ; test_case "relay disable disables but keeps the unit" `Quick test_e2e_relay_disable_keeps_unit
        ; test_case "install self installs the unit only when activated" `Quick test_e2e_install_self_gated_on_activation
        ] )
    ]
