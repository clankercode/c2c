(* CLI integration test for `c2c restart-stale` (idea I010).

   Drives the built binary against a fixture C2C_INSTANCES_DIR: one alive
   non-app-server instance (whose outer.pid points at a long-lived `sleep`, so
   its executable image is definitely NOT the c2c binary → Stale) and one dead
   instance (excluded because it is not running). In --dry-run the stale TUI
   instance must be reported as needing a manual restart, never auto-restarted. *)

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
  write_file (inst // "outer.pid") (string_of_int pid)

let run_json ~instances_dir ~args =
  let bin = built_c2c_binary () in
  if not (Sys.file_exists bin) then
    Alcotest.failf "expected built CLI at %s — run `dune build` first" bin;
  let out = Filename.temp_file "c2c-restart-stale-out" ".json" in
  let cmd =
    Printf.sprintf "C2C_INSTANCES_DIR=%s %s restart-stale %s > %s 2>/dev/null"
      (Filename.quote instances_dir) (Filename.quote bin) args (Filename.quote out)
  in
  let rc = Sys.command cmd in
  let raw = read_all_file out in
  Sys.remove out;
  (rc, Yojson.Safe.from_string raw)

let member k = function
  | `Assoc l -> ( match List.assoc_opt k l with Some v -> v | None -> `Null)
  | _ -> `Null

let str = function `String s -> s | _ -> "<not-a-string>"
let int_of = function `Int n -> n | _ -> -1

let test_dry_run_reports_stale_tui_as_guided () =
  with_temp_dir (fun dir ->
      let pid = spawn_sleeper () in
      Fun.protect
        ~finally:(fun () ->
          (try Unix.kill pid Sys.sigkill with _ -> ());
          (try ignore (Unix.waitpid [] pid) with _ -> ()))
        (fun () ->
          mk_instance dir ~name:"stale-tui" ~client:"claude" ~pid;
          mk_instance dir ~name:"dead-one" ~client:"claude" ~pid:(find_dead_pid ());
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
      Alcotest.(check bool) "ok true" true
        (match member "ok" j with `Bool b -> b | _ -> false);
      Alcotest.(check int) "no instances" 0
        (match member "instances" j with `List xs -> List.length xs | _ -> -1))

let () =
  Alcotest.run "c2c_restart_stale"
    [ ( "restart-stale",
        [ Alcotest.test_case "dry-run reports stale TUI as guided" `Quick
            test_dry_run_reports_stale_tui_as_guided;
          Alcotest.test_case "no running instances is ok" `Quick
            test_no_instances_is_ok ] )
    ]
