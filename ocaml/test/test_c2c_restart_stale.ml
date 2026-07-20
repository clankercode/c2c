(* Hermetic CLI decision tests for `c2c restart-stale` (idea I010).

   Every command uses a fixture C2C_INSTANCES_DIR.  Process-image verdicts are
   deterministic without replacing the well-covered C2c_stale primitive:
   [sleep] is Stale, an unreaped exited child is Unknown, and a blocking child
   of the built c2c binary is Current.  App-server success uses the explicit
   owner-result fixture; no managed coding client is launched. *)

let ( // ) = Filename.concat

let write_file path contents =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let read_all_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic)
    (fun () ->
      let b = Buffer.create 256 in
      (try
         while true do
           Buffer.add_channel b ic 4096
         done
       with End_of_file -> ());
      Buffer.contents b)

let with_temp_dir f =
  let dir = Filename.temp_file "c2c_restart_stale" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      (* best-effort recursive rm *)
      let rec rm p =
        match Unix.lstat p with
        | { Unix.st_kind = Unix.S_DIR; _ } ->
            Array.iter (fun e -> rm (p // e)) (Sys.readdir p);
            (try Unix.rmdir p with _ -> ())
        | _ -> (try Sys.remove p with _ -> ())
        | exception _ -> ()
      in
      rm dir)
    (fun () -> f dir)

let built_c2c_binary () =
  let exe = Sys.executable_name in
  let exe =
    if Filename.is_relative exe then Filename.concat (Sys.getcwd ()) exe else exe
  in
  let exe = try Unix.realpath exe with _ -> exe in
  let test_dir = Filename.dirname exe in
  let ocaml_dir = Filename.dirname test_dir in
  ocaml_dir // "cli" // "c2c.exe"

(* A PID guaranteed not to exist right now. *)
let find_dead_pid () =
  let rec find p =
    if p <= 1 then 1
    else match Unix.kill p 0 with
      | () -> find (p - 1)
      | exception Unix.Unix_error _ -> p
  in
  find 999_999

let spawn_sleeper () =
  Unix.create_process "sleep" [| "sleep"; "300" |]
    Unix.stdin Unix.stdout Unix.stderr

let mk_instance dir ~name ~client ~pid =
  let inst = dir // name in
  Unix.mkdir inst 0o755;
  write_file (inst // "config.json")
    (Printf.sprintf {|{"client":"%s","name":"%s"}|} client name);
  write_file (inst // "outer.pid") (string_of_int pid);
  inst

let mk_app_server_instance dir ~name ~pid =
  let inst = mk_instance dir ~name ~client:"codex" ~pid in
  write_file (inst // "codex-session.json")
    (Printf.sprintf
       {|{"session_id":"fixture-%s","alias":"%s","created_at":0,"updated_at":0}|}
       name name);
  inst

let merged_env defaults overrides =
  List.fold_left
    (fun env (name, value) -> (name, value) :: List.remove_assoc name env)
    defaults overrides

let run_json_with_env ~env ~instances_dir ~args =
  let bin = built_c2c_binary () in
  if not (Sys.file_exists bin) then
    Alcotest.failf "expected built CLI at %s — run `dune build` first" bin;
  let out = Filename.temp_file "c2c-restart-stale-out" ".json" in
  let err = Filename.temp_file "c2c-restart-stale-err" ".txt" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove out with _ -> ());
      (try Sys.remove err with _ -> ()))
    (fun () ->
      let command_env =
        merged_env
          [ ("HOME", instances_dir)
          ; ("C2C_INSTANCES_DIR", instances_dir)
          ; ("C2C_MCP_BROKER_ROOT", instances_dir // "broker")
          ; ("C2C_INSTANCE_NAME", "")
          ; ("C2C_RESTART_STALE_OWNER_RESULT_FIXTURE", "") ]
          env
      in
      let assignments =
        command_env
        |> List.map (fun (name, value) -> name ^ "=" ^ Filename.quote value)
        |> String.concat " "
      in
      let cmd =
        Printf.sprintf "cd %s && %s %s restart-stale %s > %s 2> %s"
          (Filename.quote instances_dir) assignments (Filename.quote bin) args
          (Filename.quote out) (Filename.quote err)
      in
      let rc = Sys.command cmd in
      let raw = read_all_file out in
      let stderr = read_all_file err in
      let json =
        try Yojson.Safe.from_string raw with exn ->
          Alcotest.failf "invalid JSON (rc=%d): %s\nstdout: %s\nstderr: %s"
            rc (Printexc.to_string exn) raw stderr
      in
      (rc, json))

let run_json ~instances_dir ~args =
  run_json_with_env ~env:[] ~instances_dir ~args

let member k = function
  | `Assoc l -> ( match List.assoc_opt k l with Some v -> v | None -> `Null)
  | _ -> `Null

let str = function `String s -> s | _ -> "<not-a-string>"
let int_of = function `Int n -> n | _ -> -1
let bool_of = function `Bool b -> b | _ -> false

let list_of = function `List xs -> xs | _ -> []

let instance name j =
  match
    List.find_opt
      (fun row -> str (member "name" row) = name)
      (list_of (member "instances" j))
  with
  | Some row -> row
  | None -> Alcotest.failf "missing instance %S in %s" name (Yojson.Safe.to_string j)

let action_kind row = str (member "kind" (member "action" row))
let action_reason row = str (member "reason" (member "action" row))

let check_summary j ~restarted ~would_restart ~needs_manual_restart ~skipped
    ~failed =
  let summary = member "summary" j in
  Alcotest.(check int) "summary.restarted" restarted
    (int_of (member "restarted" summary));
  Alcotest.(check int) "summary.would_restart" would_restart
    (int_of (member "would_restart" summary));
  Alcotest.(check int) "summary.needs_manual_restart" needs_manual_restart
    (int_of (member "needs_manual_restart" summary));
  Alcotest.(check int) "summary.skipped" skipped
    (int_of (member "skipped" summary));
  Alcotest.(check int) "summary.failed" failed
    (int_of (member "failed" summary))

let check_json_shape ~ok ~dry_run ~instances j =
  let fields = match j with `Assoc fields -> fields | _ -> [] in
  let keys = List.map fst fields |> List.sort String.compare in
  Alcotest.(check (list string)) "top-level keys"
    [ "dry_run"; "instances"; "ok"; "summary" ] keys;
  Alcotest.(check bool) "ok" ok (bool_of (member "ok" j));
  Alcotest.(check bool) "dry_run" dry_run (bool_of (member "dry_run" j));
  Alcotest.(check int) "instances length" instances
    (List.length (list_of (member "instances" j)));
  (match member "summary" j with
   | `Assoc _ -> ()
   | _ -> Alcotest.fail "summary is not an object")

let kill_and_reap pid =
  (try Unix.kill pid Sys.sigkill with _ -> ());
  (try ignore (Unix.waitpid [] pid) with _ -> ())

let with_pid pid f = Fun.protect ~finally:(fun () -> kill_and_reap pid) f

let wait_until label pred =
  let rec loop attempts =
    if pred () then ()
    else if attempts = 0 then Alcotest.failf "timed out waiting for %s" label
    else begin
      Unix.sleepf 0.01;
      loop (attempts - 1)
    end
  in
  loop 200

let spawn_zombie () =
  let pid =
    Unix.create_process "/bin/true" [| "/bin/true" |]
      Unix.stdin Unix.stdout Unix.stderr
  in
  let is_zombie () =
    try
      let stat = read_all_file (Printf.sprintf "/proc/%d/stat" pid) in
      match String.index_opt stat ')' with
      | Some close when close + 2 < String.length stat -> stat.[close + 2] = 'Z'
      | _ -> false
    with _ -> false
  in
  (try wait_until "fixture child to become a zombie" is_zombie
   with exn -> kill_and_reap pid; raise exn);
  pid

let env_with overrides =
  let names = List.map fst overrides in
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter (fun entry ->
         match String.index_opt entry '=' with
         | None -> true
         | Some eq ->
             let name = String.sub entry 0 eq in
             not (List.mem name names))
  in
  Array.of_list
    (List.map (fun (name, value) -> name ^ "=" ^ value) overrides @ inherited)

let spawn_current_c2c instances_dir =
  let bin = built_c2c_binary () in
  let broker = instances_dir // "current-broker" in
  Unix.mkdir broker 0o755;
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  let pid =
    Fun.protect ~finally:(fun () -> Unix.close dev_null) (fun () ->
        Unix.create_process_env bin
          [| bin; "wait-inbox"; "--session-id"; "fixture-current";
             "--timeout"; "300"; "--poll-interval"; "0.1" |]
          (env_with
             [ ("HOME", instances_dir)
             ; ("C2C_MCP_BROKER_ROOT", broker)
             ; ("C2C_MCP_SESSION_ID", "fixture-current") ])
          dev_null dev_null dev_null)
  in
  let same_executable () =
    try
      let expected = Unix.stat bin in
      let actual = Unix.stat (Printf.sprintf "/proc/%d/exe" pid) in
      expected.Unix.st_dev = actual.Unix.st_dev
      && expected.Unix.st_ino = actual.Unix.st_ino
    with _ -> false
  in
  (try wait_until "fixture c2c child to exec" same_executable
   with exn -> kill_and_reap pid; raise exn);
  pid

let test_dry_run_reports_stale_tui_as_guided () =
  with_temp_dir (fun dir ->
      let pid = spawn_sleeper () in
      Fun.protect
        ~finally:(fun () ->
          (try Unix.kill pid Sys.sigkill with _ -> ());
          (try ignore (Unix.waitpid [] pid) with _ -> ()))
        (fun () ->
          ignore (mk_instance dir ~name:"stale-tui" ~client:"claude" ~pid);
          ignore
            (mk_instance dir ~name:"dead-one" ~client:"claude"
               ~pid:(find_dead_pid ()));
          let rc, j = run_json ~instances_dir:dir ~args:"--dry-run --json" in
          Alcotest.(check int) "exit 0 (no failures)" 0 rc;
          (* Only the alive instance is enumerated. *)
          let instances =
            match member "instances" j with `List xs -> xs | _ -> []
          in
          Alcotest.(check int) "one running instance listed" 1
            (List.length instances);
          let inst = List.hd instances in
          Alcotest.(check string) "instance name" "stale-tui"
            (str (member "name" inst));
          Alcotest.(check string) "verdict is stale" "stale"
            (str (member "verdict" inst));
          let action = member "action" inst in
          Alcotest.(check string) "action is guided (manual restart)" "guided"
            (str (member "kind" action));
          Alcotest.(check bool) "guided command names the instance" true
            (let c = str (member "command" action) in
             c = "c2c restart stale-tui");
          (* Summary: exactly one needs-manual, nothing restarted/failed. *)
          let summary = member "summary" j in
          Alcotest.(check int) "needs_manual_restart = 1" 1
            (int_of (member "needs_manual_restart" summary));
          Alcotest.(check int) "restarted = 0 (dry-run + TUI)" 0
            (int_of (member "restarted" summary));
          Alcotest.(check int) "failed = 0" 0 (int_of (member "failed" summary));
          Alcotest.(check bool) "dry_run flag echoed" true
            (match member "dry_run" j with `Bool b -> b | _ -> false)))

let test_no_instances_is_ok () =
  with_temp_dir (fun dir ->
      let rc, j = run_json ~instances_dir:dir ~args:"--json" in
      Alcotest.(check int) "exit 0" 0 rc;
      check_json_shape ~ok:true ~dry_run:false ~instances:0 j;
      check_summary j ~restarted:0 ~would_restart:0 ~needs_manual_restart:0
        ~skipped:0 ~failed:0)

let test_coordinator_last_and_excluded () =
  with_temp_dir (fun dir ->
      let pid = spawn_sleeper () in
      with_pid pid (fun () ->
          ignore (mk_instance dir ~name:"coordinator1" ~client:"claude" ~pid);
          ignore (mk_instance dir ~name:"worker-z" ~client:"claude" ~pid);
          let rc, j = run_json ~instances_dir:dir ~args:"--dry-run --json" in
          Alcotest.(check int) "ordered run exits 0" 0 rc;
          let names =
            list_of (member "instances" j)
            |> List.map (fun row -> str (member "name" row))
          in
          Alcotest.(check (list string)) "coordinator ordered last"
            [ "worker-z"; "coordinator1" ] names;
          Alcotest.(check bool) "coordinator marker" true
            (bool_of (member "coordinator" (instance "coordinator1" j)));
          Alcotest.(check bool) "worker is not coordinator" false
            (bool_of (member "coordinator" (instance "worker-z" j)));
          let rc, excluded =
            run_json ~instances_dir:dir
              ~args:"--dry-run --exclude-coordinator --json"
          in
          Alcotest.(check int) "excluded run exits 0" 0 rc;
          Alcotest.(check string) "worker remains eligible" "guided"
            (action_kind (instance "worker-z" excluded));
          let coordinator = instance "coordinator1" excluded in
          Alcotest.(check string) "coordinator skipped" "skipped"
            (action_kind coordinator);
          Alcotest.(check string) "exclusion reason"
            "coordinator excluded (--exclude-coordinator)"
            (action_reason coordinator);
          check_summary excluded ~restarted:0 ~would_restart:0
            ~needs_manual_restart:1 ~skipped:1 ~failed:0))

let test_self_is_skipped () =
  with_temp_dir (fun dir ->
      let pid = spawn_sleeper () in
      with_pid pid (fun () ->
          ignore (mk_instance dir ~name:"self-agent" ~client:"claude" ~pid);
          let rc, j =
            run_json_with_env ~instances_dir:dir
              ~env:[ ("C2C_INSTANCE_NAME", "self-agent") ]
              ~args:"--dry-run --json"
          in
          Alcotest.(check int) "exit 0" 0 rc;
          let self = instance "self-agent" j in
          Alcotest.(check string) "self action" "skipped" (action_kind self);
          Alcotest.(check string) "self reason"
            "self (cannot restart the running command's own session)"
            (action_reason self);
          check_summary j ~restarted:0 ~would_restart:0
            ~needs_manual_restart:0 ~skipped:1 ~failed:0))

let test_force_makes_current_and_unknown_eligible () =
  with_temp_dir (fun dir ->
      let current_pid = spawn_current_c2c dir in
      with_pid current_pid (fun () ->
          let zombie_pid = spawn_zombie () in
          Fun.protect
            ~finally:(fun () ->
              try ignore (Unix.waitpid [] zombie_pid) with _ -> ())
            (fun () ->
              ignore
                (mk_instance dir ~name:"current-tui" ~client:"claude"
                   ~pid:current_pid);
              ignore
                (mk_instance dir ~name:"unknown-tui" ~client:"claude"
                   ~pid:zombie_pid);
              let rc, normal =
                run_json ~instances_dir:dir ~args:"--dry-run --json"
              in
              Alcotest.(check int) "normal exit 0" 0 rc;
              Alcotest.(check string) "current verdict" "current"
                (str (member "verdict" (instance "current-tui" normal)));
              Alcotest.(check string) "current normally skipped" "skipped"
                (action_kind (instance "current-tui" normal));
              Alcotest.(check string) "unknown verdict" "unknown"
                (str (member "verdict" (instance "unknown-tui" normal)));
              Alcotest.(check string) "unknown normally skipped" "skipped"
                (action_kind (instance "unknown-tui" normal));
              let rc, forced =
                run_json ~instances_dir:dir
                  ~args:"--dry-run --force --json"
              in
              Alcotest.(check int) "forced exit 0" 0 rc;
              Alcotest.(check string) "current becomes eligible" "guided"
                (action_kind (instance "current-tui" forced));
              Alcotest.(check string) "unknown becomes eligible" "guided"
                (action_kind (instance "unknown-tui" forced));
              check_summary forced ~restarted:0 ~would_restart:0
                ~needs_manual_restart:2 ~skipped:0 ~failed:0)))

let test_owner_fixture_restarts_and_receives_force () =
  with_temp_dir (fun dir ->
      let pid = spawn_sleeper () in
      with_pid pid (fun () ->
          let inst = mk_app_server_instance dir ~name:"app-owner" ~pid in
          let rc, j =
            run_json_with_env ~instances_dir:dir
              ~env:[ ("C2C_RESTART_STALE_OWNER_RESULT_FIXTURE", "restarting") ]
              ~args:"--force --timeout 0 --json"
          in
          Alcotest.(check int) "successful restart exits 0" 0 rc;
          check_json_shape ~ok:true ~dry_run:false ~instances:1 j;
          let owner = instance "app-owner" j in
          Alcotest.(check string) "owner accepted action" "restarted"
            (action_kind owner);
          check_summary j ~restarted:1 ~would_restart:0
            ~needs_manual_restart:0 ~skipped:0 ~failed:0;
          let request = Yojson.Safe.from_file (inst // "restart.request.json") in
          Alcotest.(check bool) "--force passed to owner request" true
            (bool_of (member "force" request));
          Alcotest.(check bool) "request id recorded" true
            (str (member "request_id" request) <> "<not-a-string>")))

let test_failed_action_sets_json_error_and_exit_one () =
  with_temp_dir (fun dir ->
      let pid = spawn_sleeper () in
      with_pid pid (fun () ->
          ignore (mk_app_server_instance dir ~name:"app-timeout" ~pid);
          ignore (mk_instance dir ~name:"guided-tui" ~client:"claude" ~pid);
          let rc, j =
            run_json ~instances_dir:dir ~args:"--force --timeout 0 --json"
          in
          Alcotest.(check int) "any Failed makes exit 1" 1 rc;
          check_json_shape ~ok:false ~dry_run:false ~instances:2 j;
          Alcotest.(check string) "owner timeout is failed" "failed"
            (action_kind (instance "app-timeout" j));
          Alcotest.(check string) "nonfailure row still guided" "guided"
            (action_kind (instance "guided-tui" j));
          check_summary j ~restarted:0 ~would_restart:0
            ~needs_manual_restart:1 ~skipped:0 ~failed:1))

let () =
  Alcotest.run "c2c_restart_stale"
    [ ( "restart-stale",
        [ Alcotest.test_case "dry-run reports stale TUI as guided" `Quick
            test_dry_run_reports_stale_tui_as_guided;
          Alcotest.test_case "no running instances is ok" `Quick
            test_no_instances_is_ok;
          Alcotest.test_case "coordinator is last and can be excluded" `Quick
            test_coordinator_last_and_excluded;
          Alcotest.test_case "invoking instance is skipped" `Quick
            test_self_is_skipped;
          Alcotest.test_case "force includes current and unknown" `Quick
            test_force_makes_current_and_unknown_eligible;
          Alcotest.test_case "owner fixture restarts and receives force" `Quick
            test_owner_fixture_restarts_and_receives_force;
          Alcotest.test_case "Failed action controls JSON and exit" `Quick
            test_failed_action_sets_json_error_and_exit_one ] )
    ]
