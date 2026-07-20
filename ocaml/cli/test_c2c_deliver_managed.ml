(* Hermetic tests for #35 phase 1 deliver-service scaffold.
   No adapters, no live brokers — lock / already-running / crash / doctor. *)

open Alcotest

let ( // ) = Filename.concat

let with_temp_dir f =
  let path = Filename.temp_file "c2c-deliver-managed-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command ("rm -rf " ^ Filename.quote path)))
    (fun () -> f path)

let with_env key value f =
  let saved = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv key (Option.value saved ~default:""))
    f

let wait_until ?(timeout = 5.0) pred =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if pred () then true
    else if Unix.gettimeofday () >= deadline then false
    else (Unix.sleepf 0.05; loop ())
  in
  loop ()

let with_home dir f =
  let old_home = Sys.getenv_opt "HOME" in
  let old_instances = Sys.getenv_opt "C2C_INSTANCES_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (match old_home with Some h -> Unix.putenv "HOME" h | None -> ());
      Unix.putenv "C2C_INSTANCES_DIR"
        (Option.value old_instances ~default:""))
    (fun () ->
      Unix.putenv "HOME" dir;
      Unix.putenv "C2C_INSTANCES_DIR" "";
      f ())

(* --- path / config unit tests --- *)

let test_machine_lock_is_name_independent () =
  with_env "HOME" "/tmp/c2c-i35-home" @@ fun () ->
  with_env "C2C_INSTANCES_DIR" "" @@ fun () ->
  check string "one machine resource"
    "/tmp/c2c-i35-home/.local/share/c2c/deliver-service"
    (C2c_deliver_managed.machine_lock_resource ())

let test_instances_dir_honors_override () =
  with_env "HOME" "/tmp/c2c-i35-home" @@ fun () ->
  with_env "C2C_INSTANCES_DIR" "  /tmp/c2c-i35-custom/instances  " @@ fun () ->
  check string "instances dir uses trimmed override"
    "/tmp/c2c-i35-custom/instances"
    (C2c_deliver_managed.instances_dir ());
  check string "machine lock follows override base"
    "/tmp/c2c-i35-custom/deliver-service"
    (C2c_deliver_managed.machine_lock_resource ())

let test_default_name () =
  check bool "canonical" true
    (C2c_deliver_managed.is_default_deliver_service_name
       C2c_deliver_managed.default_instance_name);
  check bool "trims" true
    (C2c_deliver_managed.is_default_deliver_service_name "  deliver-service  ");
  check bool "other" false
    (C2c_deliver_managed.is_default_deliver_service_name "relay-connect")

let test_parse_managed_config_recognises_deliver_service () =
  let json =
    `Assoc
      [ ("client", `String "deliver-service")
      ; ("scope", `String "machine")
      ; ("supervised", `Bool true)
      ; ("phase", `Int 1)
      ]
  in
  (match C2c_deliver_managed.parse_managed_config json with
   | Some mc -> check int "phase" 1 mc.C2c_deliver_managed.mc_phase
   | None -> fail "expected deliver-service config");
  let relay =
    `Assoc
      [ ("client", `String "relay-connect")
      ; ("scope", `String "machine")
      ; ("supervised", `Bool true)
      ]
  in
  check bool "relay-connect is not deliver-service" true
    (C2c_deliver_managed.parse_managed_config relay = None)

let test_supervisor_status_dead_when_absent () =
  with_temp_dir @@ fun home ->
  with_home home (fun () ->
    match C2c_deliver_managed.supervisor_status () with
    | Dead { reason } ->
        check bool "mentions pidfile" true
          (try
             ignore
               (Str.search_forward (Str.regexp_string "outer.pid") reason 0);
             true
           with Not_found -> false)
    | Alive _ -> fail "must be dead when never started")

(* --- cross-process lock tests --- *)

let ensure_lock_parent () =
  let path = C2c_deliver_managed.machine_lock_resource () in
  let rec mkdir_p p =
    if p = "" || p = "/" || Sys.file_exists p then ()
    else (mkdir_p (Filename.dirname p); try Unix.mkdir p 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p (Filename.dirname path);
  path

let test_singleton_second_acquire_refused () =
  with_temp_dir @@ fun dir ->
  with_home dir (fun () ->
    let path = ensure_lock_parent () in
    let held_r, held_w = Unix.pipe () in
    let done_r, done_w = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
        Unix.close held_r;
        Unix.close done_w;
        (match
           C2c_singleton_lock.try_acquire ~path
         with
         | Acquired _ ->
             ignore (Unix.write_substring held_w "1" 0 1);
             let b = Bytes.create 1 in
             ignore (Unix.read done_r b 0 1)
         | Already_running -> ());
        exit 0
    | child ->
        Unix.close held_w;
        Unix.close done_r;
        Fun.protect
          ~finally:(fun () ->
            (try ignore (Unix.write_substring done_w "1" 0 1) with _ -> ());
            (try Unix.close done_w with _ -> ());
            (try Unix.close held_r with _ -> ());
            (try ignore (Unix.waitpid [] child) with _ -> ()))
          (fun () ->
            let b = Bytes.create 1 in
            check int "child acquired" 1 (Unix.read held_r b 0 1);
            match C2c_singleton_lock.try_acquire ~path with
            | Already_running -> ()
            | Acquired _ ->
                fail "second acquire must be refused while child holds it"))

let test_crash_releases_lock () =
  with_temp_dir @@ fun dir ->
  with_home dir (fun () ->
    let path = ensure_lock_parent () in
    let held_r, held_w = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
        Unix.close held_r;
        (match C2c_singleton_lock.try_acquire ~path with
         | Acquired _ ->
             ignore (Unix.write_substring held_w "1" 0 1);
             (* Crash without explicit release — OS drops POSIX lock. *)
             Unix.kill (Unix.getpid ()) Sys.sigkill
         | Already_running -> exit 1);
        exit 0
    | child ->
        Unix.close held_w;
        Fun.protect
          ~finally:(fun () ->
            (try Unix.close held_r with _ -> ());
            (try ignore (Unix.waitpid [] child) with _ -> ()))
          (fun () ->
            let b = Bytes.create 1 in
            check int "child held lock" 1 (Unix.read held_r b 0 1);
            (* waitpid after SIGKILL *)
            (try ignore (Unix.waitpid [] child) with _ -> ());
            match C2c_singleton_lock.try_acquire ~path with
            | Acquired fd -> C2c_singleton_lock.release fd
            | Already_running ->
                fail "lock must release after crash (SIGKILL)"))

let test_run_owner_already_running_exits_1 () =
  with_temp_dir @@ fun dir ->
  with_home dir (fun () ->
    let path = ensure_lock_parent () in
    let held_r, held_w = Unix.pipe () in
    let done_r, done_w = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
        Unix.close held_r;
        Unix.close done_w;
        (match C2c_singleton_lock.try_acquire ~path with
         | Acquired _ ->
             ignore (Unix.write_substring held_w "1" 0 1);
             let b = Bytes.create 1 in
             ignore (Unix.read done_r b 0 1)
         | Already_running -> ());
        exit 0
    | child ->
        Unix.close held_w;
        Unix.close done_r;
        Fun.protect
          ~finally:(fun () ->
            (try ignore (Unix.write_substring done_w "1" 0 1) with _ -> ());
            (try Unix.close done_w with _ -> ());
            (try Unix.close held_r with _ -> ());
            (try ignore (Unix.waitpid [] child) with _ -> ()))
          (fun () ->
            let b = Bytes.create 1 in
            check int "holder ready" 1 (Unix.read held_r b 0 1);
            let code =
              C2c_deliver_managed.run_owner ~name:"deliver-service"
                ~foreground:true ~ready_fd:None
            in
            check int "Already_running → exit 1" 1 code))

let test_run_owner_acquires_writes_pid_and_stops () =
  with_temp_dir @@ fun dir ->
  with_home dir (fun () ->
    let name = "deliver-service" in
    match Unix.fork () with
    | 0 ->
        exit
          (C2c_deliver_managed.run_owner ~name ~foreground:true ~ready_fd:None)
    | child ->
        Fun.protect
          ~finally:(fun () ->
            (try Unix.kill child Sys.sigterm with Unix.Unix_error _ -> ());
            (try ignore (Unix.waitpid [] child) with _ -> ()))
          (fun () ->
            let pid_path =
              C2c_deliver_managed.instances_dir () // name // "outer.pid"
            in
            check bool "pidfile appears" true
              (wait_until (fun () -> Sys.file_exists pid_path));
            (match C2c_deliver_managed.supervisor_status ~name () with
             | Alive { pid; _ } ->
                 check int "status pid matches child" child pid
             | Dead { reason } -> fail ("expected alive: " ^ reason));
            (match C2c_deliver_managed.read_managed_config ~name with
             | Some mc ->
                 check int "phase 1 config" 1 mc.C2c_deliver_managed.mc_phase
             | None -> fail "config.json missing");
            Unix.kill child Sys.sigterm;
            let _, status = Unix.waitpid [] child in
            let code =
              match status with
              | Unix.WEXITED n -> n
              | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n
            in
            check int "clean stop" 0 code;
            check bool "status becomes dead" true
              (wait_until (fun () ->
                 match C2c_deliver_managed.supervisor_status ~name () with
                 | Dead _ -> true
                 | Alive _ -> false));
            (* Lock free after stop for re-acquire. *)
            match
              C2c_singleton_lock.try_acquire
                ~path:(C2c_deliver_managed.machine_lock_resource ())
            with
            | Acquired fd -> C2c_singleton_lock.release fd
            | Already_running -> fail "lock must free after clean stop"))

let test_stop_supervisor_noop_when_absent () =
  with_temp_dir @@ fun home ->
  with_home home (fun () ->
    check bool "stop with no supervisor returns true" true
      (C2c_deliver_managed.stop_supervisor ~name:"deliver-service"
         ~timeout_s:0.5))

let () =
  run "c2c deliver managed (#35 phase 1)"
    [ ( "paths"
      , [ test_case "machine lock ignores instance name" `Quick
            test_machine_lock_is_name_independent
        ; test_case "C2C_INSTANCES_DIR override" `Quick
            test_instances_dir_honors_override
        ; test_case "default name classifier" `Quick test_default_name
        ] )
    ; ( "config"
      , [ test_case "parse recognises deliver-service only" `Quick
            test_parse_managed_config_recognises_deliver_service
        ; test_case "supervisor_status dead when absent" `Quick
            test_supervisor_status_dead_when_absent
        ; test_case "stop_supervisor no-op when absent" `Quick
            test_stop_supervisor_noop_when_absent
        ] )
    ; ( "machine singleton"
      , [ test_case "second acquire refused (cross-process)" `Quick
            test_singleton_second_acquire_refused
        ; test_case "crash releases lock" `Quick test_crash_releases_lock
        ; test_case "run_owner Already_running exits 1" `Quick
            test_run_owner_already_running_exits_1
        ; test_case "run_owner pidfile + clean stop" `Quick
            test_run_owner_acquires_writes_pid_and_stops
        ] )
    ]
