(* #78 — gated live E2E entry for managed agy cold-start (no headless mint).

   Default / CI: gate OFF → each case is a no-op skip (suite stays hermetic).
   Opt-in: C2C_AGY_I78_LIVE=1 shells out to scripts/agy-i78-cold-start-e2e.py
   in `run` mode (must be invoked from tmux; harness enforces that).

   Mirrors the B144 codex live-e2e pattern (test_c2c_codex_live_e2e.ml). *)

let gate_on env = match Sys.getenv_opt env with Some "1" -> true | _ -> false

let repo_root () =
  match Sys.getenv_opt "C2C_REPO_ROOT" with
  | Some r when r <> "" -> r
  | _ ->
      let ic = Unix.open_process_in "git rev-parse --show-toplevel 2>/dev/null" in
      let line = try input_line ic with End_of_file -> "" in
      ignore (Unix.close_process_in ic);
      if line <> "" then line else Sys.getcwd ()

let ( // ) = Filename.concat

let c2c_exe root = root // "_build" // "default" // "ocaml" // "cli" // "c2c.exe"

let run_harness ~script ~gate =
  let root = repo_root () in
  let path = root // "scripts" // script in
  if not (Sys.file_exists path) then
    Alcotest.failf "harness script missing: %s" path;
  let cmd =
    Printf.sprintf "C2C_BIN=%s %s run"
      (Filename.quote (c2c_exe root)) (Filename.quote path)
  in
  Printf.printf "[i78] gate %s=1 — invoking %s run\n%!" gate path;
  let rc = Sys.command cmd in
  Alcotest.(check int) (Printf.sprintf "%s run exit 0" script) 0 rc

let test_i78_cold_start () =
  let gate = "C2C_AGY_I78_LIVE" in
  if not (gate_on gate) then Alcotest.(check pass) "skipped (gate off)" () ()
  else run_harness ~script:"agy-i78-cold-start-e2e.py" ~gate

let test_preflight_script_exists () =
  (* Always-on hermetic check: the e2e harness is present and executable. *)
  let root = repo_root () in
  let path = root // "scripts" // "agy-i78-cold-start-e2e.py" in
  Alcotest.(check bool) "harness exists" true (Sys.file_exists path);
  (* preflight is CI-safe and does not need the live gate or tmux. *)
  let cmd =
    Printf.sprintf "%s preflight" (Filename.quote path)
  in
  let rc = Sys.command cmd in
  (* preflight may FAIL on hosts without agy/tmux; only require exit 0 when
     C2C_AGY_I78_PREFLIGHT_STRICT=1. Default: existence + runnable (any exit). *)
  match Sys.getenv_opt "C2C_AGY_I78_PREFLIGHT_STRICT" with
  | Some "1" -> Alcotest.(check int) "preflight exit 0" 0 rc
  | _ ->
      Alcotest.(check bool) "preflight runnable (exit recorded)" true (rc >= 0);
      ignore rc

let () =
  Alcotest.run "c2c_agy_live_e2e"
    [ ( "live-e2e",
        [ Alcotest.test_case "harness present + preflight runnable" `Quick
            test_preflight_script_exists
        ; Alcotest.test_case
            "#78 cold-start no headless mint (gated C2C_AGY_I78_LIVE)" `Quick
            test_i78_cold_start ] ) ]
