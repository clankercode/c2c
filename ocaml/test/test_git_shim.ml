(* test_git_shim.ml — regression tests for git attribution + pre-reset shims.

   Catches the v1/v2/v3 incident classes (2026-05-02):
   - bash -n syntax check (v1 escaped-quote, v2 local-outside-function)
   - Strict-mode subshell invocation (v2 set -euo pipefail breakage)
   - Timeout-based recursion / fork-bomb detection (v3 rev-parse storm)
   - Delegation marker content check (shim identity for find_real_git)

   Shims are generated into a tmpdir via
   C2c_start.ensure_swarm_git_shim_installed() with C2C_GIT_SHIM_DIR
   overridden, so the test exercises the real install path. *)

let ( // ) = Filename.concat

let tmpdir prefix =
  let base = Filename.get_temp_dir_name () //
    Printf.sprintf "%s_%d_%d" prefix (Unix.getpid ()) (Random.int 100000) in
  Unix.mkdir base 0o755;
  base

let rmrf dir =
  Array.iter (fun name ->
    let p = dir // name in
    if Sys.is_directory p then begin
      Array.iter (fun s -> Sys.remove (p // s)) (Sys.readdir p);
      Unix.rmdir p
    end else Sys.remove p
  ) (Sys.readdir dir);
  Unix.rmdir dir

(** Run a shell command, return (stdout, exit_code). *)
let shell cmd =
  let ic = Unix.open_process_in cmd in
  let lines = ref [] in
  (try while true do lines := input_line ic :: !lines done with End_of_file -> ());
  let rc = match Unix.close_process_in ic with
    | Unix.WEXITED n -> n | _ -> 128 in
  (List.rev !lines, rc)

(** Generate both shims into a fresh tmpdir using the real install path.
    Returns the tmpdir path. Caller must [rmrf] when done. *)
let generate_shims () =
  Git_helpers.reset_git_circuit_breaker ();
  let dir = tmpdir "test_git_shim" in
  let old_env = Sys.getenv_opt "C2C_GIT_SHIM_DIR" in
  Unix.putenv "C2C_GIT_SHIM_DIR" dir;
  let result =
    try Ok (ignore (C2c_start.ensure_swarm_git_shim_installed ()))
    with exn -> Error exn in
  (match old_env with
   | Some v -> Unix.putenv "C2C_GIT_SHIM_DIR" v
   | None -> (try Unix.putenv "C2C_GIT_SHIM_DIR" "" with _ -> ()));
  match result with
  | Ok () -> dir
  | Error exn -> rmrf dir; raise exn

(* ── bash -n syntax checks (catches v1 + v2 class) ───── *)

let test_attribution_shim_syntax () =
  let dir = generate_shims () in
  let shim = dir // "git" in
  let _, rc = shell (Printf.sprintf "bash -n %s 2>&1" (Filename.quote shim)) in
  Alcotest.(check int) "attribution shim passes bash -n" 0 rc;
  rmrf dir

let test_pre_reset_shim_syntax () =
  let dir = generate_shims () in
  let shim = dir // "git-pre-reset" in
  let _, rc = shell (Printf.sprintf "bash -n %s 2>&1" (Filename.quote shim)) in
  Alcotest.(check int) "pre-reset shim passes bash -n" 0 rc;
  rmrf dir

(* ── strict-mode subshell (catches v2 class) ──────────── *)

let test_attribution_strict_mode () =
  let dir = generate_shims () in
  let _, rc = shell (Printf.sprintf
    "bash -c 'set -euo pipefail; PATH=%s:\"$PATH\" git --version' 2>&1"
    (Filename.quote dir)) in
  Alcotest.(check int) "attribution shim under strict mode" 0 rc;
  rmrf dir

let test_pre_reset_strict_mode () =
  let dir = generate_shims () in
  let _, rc = shell (Printf.sprintf
    "bash -c 'set -euo pipefail; PATH=%s:\"$PATH\" git-pre-reset --version' 2>&1"
    (Filename.quote dir)) in
  Alcotest.(check int) "pre-reset shim under strict mode" 0 rc;
  rmrf dir

(* ── recursion / spawn-count guard (catches v3 class) ── *)

let test_no_recursion_timeout () =
  let dir = generate_shims () in
  (* Clear the recursion guard so the shim runs its full path.
     If recursion exists, timeout will kill it → rc=124. *)
  let _, rc = shell (Printf.sprintf
    "timeout 5 env PATH=%s:\"$PATH\" C2C_GIT_SHIM_ACTIVE= git --version 2>&1"
    (Filename.quote dir)) in
  Alcotest.(check bool) "completes within 5s (no recursion)" true (rc = 0);
  rmrf dir

let test_recursion_guard_bypass () =
  let dir = generate_shims () in
  (* With ACTIVE=1, shim should exec real git immediately. *)
  let lines, rc = shell (Printf.sprintf
    "env PATH=%s:\"$PATH\" C2C_GIT_SHIM_ACTIVE=1 git --version 2>&1"
    (Filename.quote dir)) in
  Alcotest.(check int) "bypass with ACTIVE=1" 0 rc;
  let has_version = List.exists (fun l ->
    let len = String.length l in
    len >= 11 && String.sub l 0 11 = "git version") lines in
  Alcotest.(check bool) "output contains git version" true has_version;
  rmrf dir

(* ── delegation marker (shim identity for find_real_git) ─ *)

(* Must match Git_helpers.shim_marker / C2c_start.write_git_shim.
   Inlined here so the test compiles against origin/master before the
   marker constant landed on the remote. *)
let shim_marker = "# Delegation shim: git attribution for managed sessions."

let test_attribution_has_marker () =
  let dir = generate_shims () in
  let shim = dir // "git" in
  let content =
    let ic = open_in shim in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      really_input_string ic (in_channel_length ic)) in
  let marker = shim_marker in
  let marker_len = String.length marker in
  let content_len = String.length content in
  let rec scan i =
    if i + marker_len > content_len then false
    else if String.sub content i marker_len = marker then true
    else scan (i + 1) in
  Alcotest.(check bool) "attribution shim contains delegation marker"
    true (scan 0);
  rmrf dir

let () =
  Alcotest.run "git_shim" [
    "syntax", [
      Alcotest.test_case "attribution shim bash -n" `Quick
        test_attribution_shim_syntax;
      Alcotest.test_case "pre-reset shim bash -n" `Quick
        test_pre_reset_shim_syntax;
    ];
    "strict_mode", [
      Alcotest.test_case "attribution under set -euo pipefail" `Quick
        test_attribution_strict_mode;
      Alcotest.test_case "pre-reset under set -euo pipefail" `Quick
        test_pre_reset_strict_mode;
    ];
    "recursion", [
      Alcotest.test_case "no recursion (timeout guard)" `Quick
        test_no_recursion_timeout;
      Alcotest.test_case "recursion guard bypass (ACTIVE=1)" `Quick
        test_recursion_guard_bypass;
    ];
    "marker", [
      Alcotest.test_case "attribution shim has delegation marker" `Quick
        test_attribution_has_marker;
    ];
  ]
