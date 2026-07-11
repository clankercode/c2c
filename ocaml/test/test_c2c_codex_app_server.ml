(* Fixture-gated tests for the codex app-server launcher primitive (T002).

   Default (env unset): scripted-backend tests exercise EVERY lifecycle
   transition deterministically with NO live process. A live auth-boundary /
   no-zombie proof runs only under C2C_CODEX_APPSERVER_LIVE=1 (spawns a real
   `codex app-server`). The full frontend-attach dogfood is the tmux receipt. *)

module A = C2c_codex_app_server
open A

let ( // ) = Filename.concat

let mkdir_p dir =
  let rec go d =
    if d <> "" && d <> "/" && not (Sys.file_exists d) then (
      go (Filename.dirname d);
      try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  go dir

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun n -> remove_tree (path // n)) (Sys.readdir path);
      try Unix.rmdir path with _ -> ())
    else try Sys.remove path with _ -> ()

let with_tmp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-t002-%08x" (Random.bits ()) in
  mkdir_p dir;
  Fun.protect ~finally:(fun () -> try remove_tree dir with _ -> ()) (fun () -> f dir)

(* ------------------------------------------------------------------ *)
(* Fake child + scripted backend                                       *)
(* ------------------------------------------------------------------ *)

type fake = { mutable status : child_status; mutable signals : int list; mutable reaped : int }

let mk_fake ?(id = 4242) (f : fake) : child =
  {
    child_id = id;
    poll_fn = (fun () -> f.status);
    signal_fn = (fun s -> f.signals <- s :: f.signals);
    reap_fn =
      (fun _ ->
        f.reaped <- f.reaped + 1;
        (match f.status with Running_ -> f.status <- Exited 0 | _ -> ());
        f.status);
  }

(* A scripted backend built around a shared mutable clock. Overridable fields
   let each test drive a specific transition. *)
let scripted_backend ~clock ?(codex_version = Ok "codex-cli 0.144.1")
    ?(capabilities = Ok ()) ?(alloc_port = Ok 40123)
    ?(gen_token = fun () -> "RAWT0KEN_secret_do_not_leak")
    ?(spawn_server = fun ~argv:_ ~env:_ ~log_path:_ -> Error "unset")
    ?(spawn_frontend = fun ~argv:_ ~env:_ -> Error "unset")
    ?(probe_ready = fun _ ~token:_ -> Ok ())
    ?(verify_owner = fun _ ~server_pid:_ -> true) () : backend =
  {
    now = (fun () -> !clock);
    sleep = (fun d -> clock := !clock +. d);
    gen_token;
    alloc_port = (fun () -> alloc_port);
    codex_version = (fun _ -> codex_version);
    capabilities = (fun _ -> capabilities);
    spawn_server;
    spawn_frontend;
    probe_ready;
    verify_owner;
  }

let cfg_for dir =
  { (default_config ~instance_name:"tst" ~instance_dir:dir ~cwd:dir) with
    readiness_timeout_s = 1.0 }

let diag_code_str = function Ok _ -> "ok" | Error (d : diagnostic) -> diag_code_to_string d.code

(* ------------------------------------------------------------------ *)
(* version parsing / gate                                              *)
(* ------------------------------------------------------------------ *)

let test_version_parse () =
  let eq name a b = Alcotest.(check (option (triple int int int))) name a b in
  eq "codex-cli 0.144.1" (Some (0, 144, 1)) (parse_version "codex-cli 0.144.1");
  eq "bare" (Some (1, 2, 3)) (parse_version "1.2.3");
  eq "v-prefix" (Some (2, 0, 0)) (parse_version "v2.0.0");
  eq "rc suffix" (Some (0, 144, 5)) (parse_version "codex-cli 0.144.5-rc1");
  eq "garbage" None (parse_version "not-a-version");
  Alcotest.(check bool) "ge same" true (version_ge (0, 144, 1) (0, 144, 0));
  Alcotest.(check bool) "ge below" false (version_ge (0, 143, 9) (0, 144, 0));
  Alcotest.(check bool) "ge major" true (version_ge (1, 0, 0) (0, 144, 0))

let test_version_gate_rejects_old () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let spawned = ref false in
      let bk =
        scripted_backend ~clock ~codex_version:(Ok "codex-cli 0.100.0")
          ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ -> spawned := true; Error "should not spawn")
          ()
      in
      let r = start ~backend:bk (cfg_for dir) in
      Alcotest.(check string) "code" "codex_version_unsupported" (diag_code_str r);
      Alcotest.(check bool) "no spawn before version gate" false !spawned)

let test_version_gate_not_found () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let bk = scripted_backend ~clock ~codex_version:(Error "ENOENT") () in
      let r = start ~backend:bk (cfg_for dir) in
      Alcotest.(check string) "code" "codex_not_found" (diag_code_str r))

let test_version_gate_unparseable () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let bk = scripted_backend ~clock ~codex_version:(Ok "weird build xyz") () in
      let r = start ~backend:bk (cfg_for dir) in
      Alcotest.(check string) "code" "codex_version_unsupported" (diag_code_str r))

(* ------------------------------------------------------------------ *)
(* happy path                                                          *)
(* ------------------------------------------------------------------ *)

let happy_backend ~clock ~server_fake ~frontend_fake ?(probe_ready = fun _ ~token:_ -> Ok ()) () =
  scripted_backend ~clock
    ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ -> Ok (mk_fake ~id:111 server_fake))
    ~spawn_frontend:(fun ~argv:_ ~env:_ -> Ok (mk_fake ~id:222 frontend_fake))
    ~probe_ready ()

let test_happy_path_to_running () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let sf = { status = Running_; signals = []; reaped = 0 } in
      let ff = { status = Running_; signals = []; reaped = 0 } in
      let bk = happy_backend ~clock ~server_fake:sf ~frontend_fake:ff () in
      match start ~backend:bk (cfg_for dir) with
      | Error d -> Alcotest.failf "expected Running, got %s" (diag_code_to_string d.code)
      | Ok h ->
          Alcotest.(check string) "state running" "running" (state_to_string (current_state h));
          (* persisted file reflects running + carries no secret *)
          let p = Option.get (load_persisted ~instance_dir:dir) in
          Alcotest.(check string) "persisted state" "running" (state_to_string p.state);
          Alcotest.(check (option string)) "no thread id yet" None p.thread_id;
          Alcotest.(check bool) "server pid recorded" true (p.server_pid = Some 111);
          Alcotest.(check bool) "frontend pid recorded" true (p.frontend_pid = Some 222))

(* ------------------------------------------------------------------ *)
(* failure transitions                                                 *)
(* ------------------------------------------------------------------ *)

let test_server_spawn_failure () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let fe_spawned = ref false in
      let bk =
        scripted_backend ~clock
          ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ -> Error "EACCES")
          ~spawn_frontend:(fun ~argv:_ ~env:_ -> fe_spawned := true; Error "x") ()
      in
      let r = start ~backend:bk (cfg_for dir) in
      Alcotest.(check string) "code" "server_spawn_failed" (diag_code_str r);
      Alcotest.(check bool) "frontend never spawned" false !fe_spawned)

let test_readiness_timeout () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let sf = { status = Running_; signals = []; reaped = 0 } in
      let fe_spawned = ref false in
      let bk =
        scripted_backend ~clock
          ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ -> Ok (mk_fake sf))
          ~spawn_frontend:(fun ~argv:_ ~env:_ -> fe_spawned := true; Error "x")
          ~probe_ready:(fun _ ~token:_ -> Error Re_not_yet) ()
      in
      let r = start ~backend:bk (cfg_for dir) in
      Alcotest.(check string) "code" "readiness_timeout" (diag_code_str r);
      Alcotest.(check bool) "server reaped (no orphan)" true (sf.reaped >= 1);
      Alcotest.(check bool) "frontend never spawned" false !fe_spawned)

let test_server_died_before_ready () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let sf = { status = Exited 3; signals = []; reaped = 0 } in
      let bk =
        scripted_backend ~clock
          ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ -> Ok (mk_fake sf))
          ~probe_ready:(fun _ ~token:_ -> Error Re_not_yet) ()
      in
      let r = start ~backend:bk (cfg_for dir) in
      Alcotest.(check string) "code" "server_died_before_ready" (diag_code_str r);
      Alcotest.(check bool) "dead server still reaped (no zombie)" true (sf.reaped >= 1))

let test_capability_gate_rejects () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let spawned = ref false in
      let bk =
        scripted_backend ~clock ~capabilities:(Error "missing --ws-token-sha256")
          ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ -> spawned := true; Error "x") ()
      in
      let r = start ~backend:bk (cfg_for dir) in
      Alcotest.(check string) "code" "codex_capability_unsupported" (diag_code_str r);
      Alcotest.(check bool) "no spawn when capability missing" false !spawned)

let test_ownership_unverified () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let sf = { status = Running_; signals = []; reaped = 0 } in
      let fe_spawned = ref false in
      let bk =
        scripted_backend ~clock
          ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ -> Ok (mk_fake sf))
          ~spawn_frontend:(fun ~argv:_ ~env:_ -> fe_spawned := true; Ok (mk_fake sf))
          ~probe_ready:(fun _ ~token:_ -> Ok ())
          ~verify_owner:(fun _ ~server_pid:_ -> false) ()   (* listener not ours -> refuse *)
      in
      let r = start ~backend:bk (cfg_for dir) in
      Alcotest.(check string) "code" "endpoint_ownership_unverified" (diag_code_str r);
      Alcotest.(check bool) "frontend NEVER spawned (no token leak)" false !fe_spawned;
      Alcotest.(check bool) "server reaped" true (sf.reaped >= 1))

let test_persistence_failure_tears_down () =
  with_tmp_dir (fun dir ->
      (* Make the instance dir uncreatable so the mandatory Running-persist fails. *)
      let ro = dir // "ro" in
      mkdir_p ro; Unix.chmod ro 0o500;
      let inst = ro // "sub" in
      let clock = ref 0.0 in
      let sf = { status = Running_; signals = []; reaped = 0 } in
      let ff = { status = Running_; signals = []; reaped = 0 } in
      let bk = happy_backend ~clock ~server_fake:sf ~frontend_fake:ff () in
      let cfg = { (default_config ~instance_name:"tst" ~instance_dir:inst ~cwd:dir) with
                  readiness_timeout_s = 1.0 } in
      let r = start ~backend:bk cfg in
      Unix.chmod ro 0o700;   (* restore for cleanup *)
      Alcotest.(check string) "code" "persistence_failed" (diag_code_str r);
      Alcotest.(check bool) "server reaped on persist failure" true (sf.reaped >= 1);
      Alcotest.(check bool) "frontend reaped on persist failure" true (ff.reaped >= 1))

let test_frontend_spawn_failure () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let sf = { status = Running_; signals = []; reaped = 0 } in
      let bk =
        scripted_backend ~clock
          ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ -> Ok (mk_fake sf))
          ~spawn_frontend:(fun ~argv:_ ~env:_ -> Error "ENOMEM")
          ~probe_ready:(fun _ ~token:_ -> Ok ()) ()
      in
      let r = start ~backend:bk (cfg_for dir) in
      Alcotest.(check string) "code" "frontend_spawn_failed" (diag_code_str r);
      Alcotest.(check bool) "server reaped on frontend fail (no orphan)" true (sf.reaped >= 1))

let test_auth_setup_failure () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let sf = { status = Running_; signals = []; reaped = 0 } in
      let bk =
        scripted_backend ~clock
          ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ -> Ok (mk_fake sf))
          ~probe_ready:(fun _ ~token:_ -> Error Re_unauthorized) ()
      in
      let r = start ~backend:bk (cfg_for dir) in
      Alcotest.(check string) "code" "auth_setup_failed" (diag_code_str r);
      Alcotest.(check bool) "server reaped" true (sf.reaped >= 1))

let test_endpoint_alloc_failure () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let bk = scripted_backend ~clock ~alloc_port:(Error "no ports") () in
      let r = start ~backend:bk (cfg_for dir) in
      Alcotest.(check string) "code" "endpoint_alloc_failed" (diag_code_str r))

(* ------------------------------------------------------------------ *)
(* supervision transitions                                             *)
(* ------------------------------------------------------------------ *)

let run_to_running dir clock =
  let sf = { status = Running_; signals = []; reaped = 0 } in
  let ff = { status = Running_; signals = []; reaped = 0 } in
  let bk = happy_backend ~clock ~server_fake:sf ~frontend_fake:ff () in
  match start ~backend:bk (cfg_for dir) with
  | Error d -> Alcotest.failf "setup: %s" (diag_code_to_string d.code)
  | Ok h -> (h, sf, ff)

let test_frontend_normal_exit () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let h, sf, ff = run_to_running dir clock in
      ff.status <- Exited 0;
      let r = supervise_step h in
      Alcotest.(check bool) "sv frontend exited" true (r = Sv_frontend_exited);
      Alcotest.(check string) "offline" "offline" (state_to_string (current_state h));
      Alcotest.(check bool) "server reaped" true (sf.reaped >= 1))

let test_frontend_signal_exit () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let h, sf, ff = run_to_running dir clock in
      ff.status <- Signaled Sys.sigterm;
      let r = supervise_step h in
      Alcotest.(check bool) "sv frontend exited (signal)" true (r = Sv_frontend_exited);
      Alcotest.(check bool) "server reaped" true (sf.reaped >= 1))

let test_server_crash_while_running () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let h, sf, ff = run_to_running dir clock in
      ignore sf;
      sf.status <- Exited 1;   (* app-server dies while frontend still runs *)
      let r = supervise_step h in
      Alcotest.(check bool) "sv server died" true (r = Sv_server_died);
      Alcotest.(check bool) "frontend reaped (unit torn down)" true (ff.reaped >= 1);
      Alcotest.(check string) "offline" "offline" (state_to_string (current_state h)))

let test_supervise_running_stays_running () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let h, _sf, _ff = run_to_running dir clock in
      Alcotest.(check bool) "still running" true (supervise_step h = Sv_running))

let test_parent_signal_stop () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let h, sf, ff = run_to_running dir clock in
      (* parent SIGTERM handler routes to stop *)
      stop h;
      Alcotest.(check string) "offline" "offline" (state_to_string (current_state h));
      Alcotest.(check bool) "server reaped" true (sf.reaped >= 1);
      Alcotest.(check bool) "frontend reaped" true (ff.reaped >= 1))

let test_stop_idempotent () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let h, sf, ff = run_to_running dir clock in
      stop h;
      let sr = sf.reaped and fr = ff.reaped in
      stop h;   (* second call must be a no-op *)
      Alcotest.(check int) "server not re-reaped" sr sf.reaped;
      Alcotest.(check int) "frontend not re-reaped" fr ff.reaped;
      Alcotest.(check string) "still offline" "offline" (state_to_string (current_state h)))

let test_supervise_until_exit_terminal () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let h, sf, ff = run_to_running dir clock in
      ff.status <- Exited 0;   (* frontend already exited -> loop observes it first pass *)
      let observed = ref None in
      let r = supervise_until_exit ~poll_interval_s:0.01 ~max_wall_s:5.0
                ~on_transition:(fun x -> observed := Some x) h in
      Alcotest.(check bool) "returns frontend_exited" true (r = Sv_frontend_exited);
      Alcotest.(check bool) "on_transition fired" true (!observed = Some Sv_frontend_exited);
      Alcotest.(check bool) "server reaped" true (sf.reaped >= 1);
      Alcotest.(check string) "offline" "offline" (state_to_string (current_state h)))

(* ------------------------------------------------------------------ *)
(* stale-state recovery                                                *)
(* ------------------------------------------------------------------ *)

let sample_persisted ?(server_pid = None) ?(frontend_pid = None) () : persisted =
  {
    unit_id = "u-1";
    instance_name = "tst";
    alias = Some "some-alias";
    codex_version = "codex-cli 0.144.1";
    endpoint = { transport = "ws"; host = "127.0.0.1"; port = 40123 };
    token_env_var = "C2C_CODEX_REMOTE_TOKEN_U_1";
    token_sha256 = String.make 64 'a';
    server_pid;
    frontend_pid;
    thread_id = None;
    state = Running;
    created_at = 1.0;
    updated_at = 2.0;
  }

let test_stale_state_starts_fresh () =
  (* A recovering process lacks the memory-only token: must NEVER attach. *)
  let p = sample_persisted ~server_pid:(Some 999999) ~frontend_pid:(Some 999998) () in
  (match classify_persisted ~reap_recorded:false p with
   | Start_fresh reason -> Alcotest.(check bool) "has reason" true (String.length reason > 0))

let test_stale_recovery_pid_reuse_safe () =
  (* classify_persisted must NOT signal a live pid whose /proc cmdline is not our
     codex-on-this-endpoint (guards against PID reuse killing a foreign process). *)
  let child = Unix.create_process "sleep" [| "sleep"; "30" |] Unix.stdin Unix.stdout Unix.stderr in
  Fun.protect
    ~finally:(fun () -> (try Unix.kill child Sys.sigkill with _ -> ());
                        (try ignore (Unix.waitpid [] child) with _ -> ()))
    (fun () ->
      let p = sample_persisted ~server_pid:(Some child) () in
      (match classify_persisted ~reap_recorded:true p with Start_fresh _ -> ());
      (* foreign 'sleep' must still be alive — recovery refused to kill it *)
      Alcotest.(check bool) "foreign pid not killed" true (pid_alive child))

let test_stale_state_roundtrip () =
  with_tmp_dir (fun dir ->
      let p = sample_persisted ~server_pid:(Some 42) () in
      (match write_persisted ~instance_dir:dir p with
       | Ok () -> () | Error e -> Alcotest.failf "write: %s" e);
      let p2 = Option.get (load_persisted ~instance_dir:dir) in
      Alcotest.(check string) "unit id" p.unit_id p2.unit_id;
      Alcotest.(check int) "port" p.endpoint.port p2.endpoint.port;
      Alcotest.(check string) "state" (state_to_string p.state) (state_to_string p2.state);
      Alcotest.(check string) "sha" p.token_sha256 p2.token_sha256)

(* ------------------------------------------------------------------ *)
(* SECRET HYGIENE — the load-bearing security test                     *)
(* ------------------------------------------------------------------ *)

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else
    let rec go i =
      if i + nl > hl then false
      else if String.sub haystack i nl = needle then true
      else go (i + 1)
    in
    go 0

let test_secret_hygiene () =
  with_tmp_dir (fun dir ->
      let clock = ref 0.0 in
      let raw = "RAWTOKEN_ULTRA_SECRET_zzz" in
      let sf = { status = Running_; signals = []; reaped = 0 } in
      let ff = { status = Running_; signals = []; reaped = 0 } in
      let srv_argv = ref [||] and srv_env = ref [||] in
      let fe_argv = ref [||] and fe_env = ref [||] in
      let bk =
        scripted_backend ~clock ~gen_token:(fun () -> raw)
          ~spawn_server:(fun ~argv ~env ~log_path:_ ->
            srv_argv := argv; srv_env := env; Ok (mk_fake sf))
          ~spawn_frontend:(fun ~argv ~env ->
            fe_argv := argv; fe_env := env; Ok (mk_fake ff))
          ~probe_ready:(fun _ ~token:_ -> Ok ()) ()
      in
      match start ~backend:bk (cfg_for dir) with
      | Error d -> Alcotest.failf "expected running: %s" (diag_code_to_string d.code)
      | Ok h ->
          let joined a = String.concat " " (Array.to_list a) in
          (* server argv must carry the sha256, NOT the raw token *)
          let sha = sha256_hex raw in
          Alcotest.(check bool) "server argv has sha256" true (contains ~needle:sha (joined !srv_argv));
          Alcotest.(check bool) "server argv lacks raw token" false (contains ~needle:raw (joined !srv_argv));
          Alcotest.(check bool) "server argv has ws-auth" true
            (contains ~needle:"--ws-auth" (joined !srv_argv));
          Alcotest.(check bool) "server argv loopback only" true
            (contains ~needle:"ws://127.0.0.1:" (joined !srv_argv));
          Alcotest.(check bool) "server argv not 0.0.0.0" false
            (contains ~needle:"0.0.0.0" (joined !srv_argv));
          (* server env must not carry the raw token *)
          Alcotest.(check bool) "server env lacks raw token" false
            (contains ~needle:raw (joined !srv_env));
          (* frontend argv must carry only the env var NAME, not the raw token *)
          Alcotest.(check bool) "frontend argv has --remote-auth-token-env" true
            (contains ~needle:"--remote-auth-token-env" (joined !fe_argv));
          Alcotest.(check bool) "frontend argv has env var name" true
            (contains ~needle:(token_env_var_of h) (joined !fe_argv));
          Alcotest.(check bool) "frontend argv lacks raw token" false
            (contains ~needle:raw (joined !fe_argv));
          (* frontend env carries the raw token exactly once, under the env var *)
          let hits =
            Array.to_list !fe_env
            |> List.filter (fun kv -> kv = token_env_var_of h ^ "=" ^ raw)
          in
          Alcotest.(check int) "raw token present once in frontend env" 1 (List.length hits);
          (* persisted state + diagnostic JSON must never contain the raw token *)
          let pj = Yojson.Safe.to_string (persisted_to_json (persisted_of h)) in
          Alcotest.(check bool) "persisted json lacks raw token" false (contains ~needle:raw pj);
          Alcotest.(check bool) "persisted json has sha256" true (contains ~needle:sha pj);
          let dj =
            Yojson.Safe.to_string
              (diagnostic_to_json
                 { code = Internal_error; message = "x"; codex_version = None;
                   min_codex_version = None })
          in
          Alcotest.(check bool) "diagnostic json lacks raw token" false (contains ~needle:raw dj);
          (* on-disk persisted file too *)
          let disk = Option.get (load_persisted ~instance_dir:dir) in
          let disk_j = Yojson.Safe.to_string (persisted_to_json disk) in
          Alcotest.(check bool) "on-disk file lacks raw token" false (contains ~needle:raw disk_j);
          stop h)

(* ------------------------------------------------------------------ *)
(* handshake offline behaviour (unbound port -> refused)               *)
(* ------------------------------------------------------------------ *)

let free_unbound_port () =
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let p = match Unix.getsockname fd with Unix.ADDR_INET (_, p) -> p | _ -> 0 in
  Unix.close fd;  (* now nothing listens on p *)
  p

let test_handshake_refused_when_no_server () =
  let ep = { transport = "ws"; host = "127.0.0.1"; port = free_unbound_port () } in
  let r = handshake ~timeout:1.0 ep ~token:(Some "x") in
  Alcotest.(check bool) "refused/error on dead port" true (r = Hs_refused || (match r with Hs_error _ -> true | _ -> false))

(* ------------------------------------------------------------------ *)
(* LIVE auth-boundary + no-zombie proof (gated)                        *)
(* ------------------------------------------------------------------ *)

let live_enabled () =
  match Sys.getenv_opt "C2C_CODEX_APPSERVER_LIVE" with Some "1" -> true | _ -> false

(* Spawn a REAL authed codex app-server via the module's building blocks and
   prove: authed handshake -> Ready; unauth handshake -> Unauthorized;
   wrong-token -> Unauthorized; then reap with no leftover. This is tty-
   independent (no frontend); the full frontend attach is the tmux dogfood. *)
let test_live_auth_boundary () =
  if not (live_enabled ()) then Alcotest.(check pass) "skipped (gate off)" () ()
  else
    with_tmp_dir (fun dir ->
        let bk = real_backend () in
        let cfg = { (default_config ~instance_name:"live" ~instance_dir:dir ~cwd:dir) with
                    readiness_timeout_s = 20.0 } in
        let port = match bk.alloc_port () with Ok p -> p | Error e -> Alcotest.failf "port: %s" e in
        let ep = { transport = "ws"; host = "127.0.0.1"; port } in
        let raw = bk.gen_token () in
        let sha = sha256_hex raw in
        let argv = build_server_argv cfg ep ~sha256:sha in
        let env = Unix.environment () in
        let log = dir // "srv.log" in
        let server = match bk.spawn_server ~argv ~env ~log_path:log with
          | Ok c -> c | Error e -> Alcotest.failf "spawn: %s" e in
        Fun.protect
          ~finally:(fun () -> ignore (child_reap ~timeout:5.0 server))
          (fun () ->
            (* wait for readiness with the correct token *)
            let deadline = Unix.gettimeofday () +. 20.0 in
            let rec wait () =
              match bk.probe_ready ep ~token:raw with
              | Ok () -> true
              | Error _ -> if Unix.gettimeofday () > deadline then false else (Unix.sleepf 0.2; wait ())
            in
            Alcotest.(check bool) "authed readiness" true (wait ());
            (* /proc listener-ownership check must confirm OUR server owns the
               port (startup-race gate proven against the real binary) *)
            Alcotest.(check bool) "real_verify_owner true for our server" true
              (real_verify_owner ep ~server_pid:server.child_id);
            (* authed handshake -> Ready *)
            Alcotest.(check bool) "authed handshake ready" true
              (handshake ep ~token:(Some raw) = Hs_ready);
            (* UNAUTH handshake (no token) -> Unauthorized (the T001 boundary) *)
            Alcotest.(check bool) "unauth rejected" true
              (handshake ep ~token:None = Hs_unauthorized);
            (* WRONG token -> Unauthorized *)
            Alcotest.(check bool) "wrong token rejected" true
              (handshake ep ~token:(Some "not-the-token") = Hs_unauthorized));
        (* after reap, server must be gone *)
        Alcotest.(check bool) "server reaped" true
          (match child_poll server with Running_ -> false | _ -> true))

(* ------------------------------------------------------------------ *)

(* B128: the codex app-server transport is the OTHER argv tail-assembly site
   (the hook-backed codex path + all non-codex clients go through
   C2c_start.prepare_launch_args' `args @ extra_args`; the app-server frontend
   goes through build_frontend_argv' `@ cfg.extra_frontend_args`). Prove that
   `c2c start codex -- <opts>` forwards <opts> verbatim as the
   frontend argv tail, after the fixed --remote/--remote-auth-token-env prefix,
   commas preserved. *)
let test_frontend_argv_appends_extra_frontend_args_verbatim_b128 () =
  with_tmp_dir (fun dir ->
    let extra = [ "--model"; "gpt-x,y"; "--profile"; "p,q" ] in
    let cfg =
      { (default_config ~instance_name:"b128" ~instance_dir:dir ~cwd:dir) with
        extra_frontend_args = extra }
    in
    let ep = { transport = "ws"; host = "127.0.0.1"; port = 40999 } in
    let argv =
      Array.to_list (build_frontend_argv cfg ep ~token_env_var:"C2C_TOK")
    in
    let ln = List.length argv and sn = List.length extra in
    let rec drop n l = if n <= 0 then l else match l with _ :: tl -> drop (n - 1) tl | [] -> [] in
    Alcotest.(check bool) "extra_frontend_args are the verbatim frontend argv tail"
      true (sn <= ln && drop (ln - sn) argv = extra);
    Alcotest.(check (list string)) "fixed prefix precedes the passthrough tail"
      [ cfg.codex_bin; "--remote"; endpoint_uri ep; "--remote-auth-token-env"; "C2C_TOK" ]
      (List.filteri (fun i _ -> i < ln - sn) argv))

let () =
  Random.self_init ();
  Alcotest.run "c2c_codex_app_server"
    [ ( "version",
        [ Alcotest.test_case "parse" `Quick test_version_parse;
          Alcotest.test_case "gate rejects old" `Quick test_version_gate_rejects_old;
          Alcotest.test_case "gate not found" `Quick test_version_gate_not_found;
          Alcotest.test_case "gate unparseable" `Quick test_version_gate_unparseable;
          Alcotest.test_case "capability gate rejects" `Quick test_capability_gate_rejects ] );
      ( "lifecycle-happy",
        [ Alcotest.test_case "to running" `Quick test_happy_path_to_running ] );
      ( "lifecycle-failures",
        [ Alcotest.test_case "endpoint alloc fail" `Quick test_endpoint_alloc_failure;
          Alcotest.test_case "server spawn fail" `Quick test_server_spawn_failure;
          Alcotest.test_case "readiness timeout" `Quick test_readiness_timeout;
          Alcotest.test_case "server died before ready" `Quick test_server_died_before_ready;
          Alcotest.test_case "ownership unverified (port race)" `Quick test_ownership_unverified;
          Alcotest.test_case "frontend spawn fail" `Quick test_frontend_spawn_failure;
          Alcotest.test_case "auth setup fail" `Quick test_auth_setup_failure;
          Alcotest.test_case "persistence failure tears down" `Quick test_persistence_failure_tears_down ] );
      ( "supervision",
        [ Alcotest.test_case "stays running" `Quick test_supervise_running_stays_running;
          Alcotest.test_case "frontend normal exit" `Quick test_frontend_normal_exit;
          Alcotest.test_case "frontend signal exit" `Quick test_frontend_signal_exit;
          Alcotest.test_case "server crash while running" `Quick test_server_crash_while_running;
          Alcotest.test_case "parent signal stop" `Quick test_parent_signal_stop;
          Alcotest.test_case "stop idempotent" `Quick test_stop_idempotent;
          Alcotest.test_case "supervise_until_exit terminal" `Quick test_supervise_until_exit_terminal ] );
      ( "recovery",
        [ Alcotest.test_case "stale starts fresh" `Quick test_stale_state_starts_fresh;
          Alcotest.test_case "pid-reuse safe" `Quick test_stale_recovery_pid_reuse_safe;
          Alcotest.test_case "persisted roundtrip" `Quick test_stale_state_roundtrip ] );
      ( "security",
        [ Alcotest.test_case "secret hygiene" `Quick test_secret_hygiene;
          Alcotest.test_case "handshake refused offline" `Quick test_handshake_refused_when_no_server;
          Alcotest.test_case "live auth boundary" `Quick test_live_auth_boundary ] );
      ( "passthrough",
        [ Alcotest.test_case "frontend argv appends extra_frontend_args verbatim (B128)"
            `Quick test_frontend_argv_appends_extra_frontend_args_verbatim_b128 ] )
    ]
