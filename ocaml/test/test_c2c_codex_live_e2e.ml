(* B144 / B168 — in-suite gate + skip proof for the two live Codex E2E transports.

   These two cases keep the live E2E paths inside the canonical `dune runtest`
   surface WITHOUT making the default suite non-hermetic:

     * gate OFF (default / CI): each case is a no-op skip
       (`Alcotest.(check pass) "skipped (gate off)"`), exactly like the live
       auth-boundary proof in test_c2c_codex_app_server.ml
       (C2C_CODEX_APPSERVER_LIVE). `dune runtest` stays green and launches no
       codex, no tmux, no herdr.
     * gate ON (explicit opt-in): the case shells out to the matching Python
       harness in `run` mode and asserts exit 0. The harness itself enforces
       the heavier prerequisites (tmux / herdr, codex >= 0.144, auth) and does
       the real work; this test is the thin in-suite entry point.

   Transports (deliberately distinct, per the task):
     * hooks+CLI     — scripts/codex-hooks-live-e2e.py, gate C2C_CODEX_HOOKS_LIVE
     * managed app-server — scripts/codex-managed-appserver-live-e2e.py,
       gate C2C_CODEX_APPSERVER_LIVE
       B168: harness defaults to model gpt-5.3-codex-spark and proves idle
       arrival-time inject + auto-turn (PostToolHook stays installed but is
       identity-only for app-server; the deliver loop owns idle/stale delivery).
       The 2-minute stale-inbox force-retry path is covered by unit tests with
       a compressed clock (waiting 2+ minutes in live e2e is not practical).

   The gate vocabulary reuses the established C2C_CODEX_APPSERVER_LIVE (already
   the live app-server gate in test_c2c_codex_app_server.ml) and a parallel
   C2C_CODEX_HOOKS_LIVE for the hook transport. *)

let gate_on env = match Sys.getenv_opt env with Some "1" -> true | _ -> false

(* Resolve the worktree/repo root from the test's runtime cwd. dune runtest runs
   in _build/default/ocaml/test, which is inside the worktree, so
   `git rev-parse --show-toplevel` yields the source root that holds scripts/.
   C2C_REPO_ROOT overrides (useful for out-of-tree runs). *)
let repo_root () =
  match Sys.getenv_opt "C2C_REPO_ROOT" with
  | Some r when r <> "" -> r
  | _ ->
      let ic = Unix.open_process_in "git rev-parse --show-toplevel 2>/dev/null" in
      let line = try input_line ic with End_of_file -> "" in
      ignore (Unix.close_process_in ic);
      if line <> "" then line else Sys.getcwd ()

let ( // ) = Filename.concat

(* The built c2c.exe sits next to the test executable's cli sibling under
   _build; hand it to the harness so it does not fall back to PATH. *)
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
  Printf.printf "[b144] gate %s=1 — invoking %s run\n%!" gate path;
  let rc = Sys.command cmd in
  Alcotest.(check int) (Printf.sprintf "%s run exit 0" script) 0 rc

let test_hooks_transport () =
  let gate = "C2C_CODEX_HOOKS_LIVE" in
  if not (gate_on gate) then Alcotest.(check pass) "skipped (gate off)" () ()
  else run_harness ~script:"codex-hooks-live-e2e.py" ~gate

let test_appserver_transport () =
  let gate = "C2C_CODEX_APPSERVER_LIVE" in
  if not (gate_on gate) then Alcotest.(check pass) "skipped (gate off)" () ()
  else run_harness ~script:"codex-managed-appserver-live-e2e.py" ~gate

let () =
  Alcotest.run "c2c_codex_live_e2e"
    [ ( "live-e2e",
        [ Alcotest.test_case "hooks+CLI transport (gated)" `Quick test_hooks_transport
        ; Alcotest.test_case "managed app-server transport (gated)" `Quick
            test_appserver_transport ] ) ]
