(* test_broker_root_resolution.ml — unit tests for the #9 split-brain fix:
   broker-root resolution no longer honors generic XDG_STATE_HOME.

   New resolution order (C2c_repo_fp.resolve_broker_root):
     1. C2C_MCP_BROKER_ROOT   (explicit override)
     2. $C2C_STATE_HOME/c2c/repos/<fp>/broker   (c2c-specific escape hatch)
     3. $HOME/.c2c/repos/<fp>/broker            (canonical default)
     4. XDG default chain                       (HOME unset last resort)

   Background: agent harnesses (Claude Code profile-share) export a
   per-profile XDG_STATE_HOME (~/.local/state/cc-p), which used to send a
   session's broker to a private path while the rest of the swarm was on
   ~/.c2c — peers invisible to each other. These tests pin the fix.

   Env mutation is process-global; alcotest `Quick cases run sequentially in
   this binary, and every test sets all four relevant vars explicitly
   (empty string == unset for all trimmed readers). *)

open Alcotest

let ( // ) = Filename.concat

let saved_home = try Sys.getenv "HOME" with Not_found -> "/tmp"

let set_env ~home ~xdg ~c2c_state ~broker_override =
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" xdg;
  Unix.putenv "C2C_STATE_HOME" c2c_state;
  Unix.putenv "C2C_MCP_BROKER_ROOT" broker_override

let restore_env () =
  set_env ~home:saved_home ~xdg:"" ~c2c_state:"" ~broker_override:""

let with_restored_env f = Fun.protect ~finally:restore_env f

let temp_dir label =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-brr-%s-%08x" label (Random.bits ()) in
  C2c_mcp.mkdir_p dir;
  dir

let fp () = C2c_repo_fp.repo_fingerprint ()

(* 1. XDG_STATE_HOME set + HOME set → canonical HOME path chosen (the fix). *)
let test_xdg_no_longer_honored () =
  with_restored_env (fun () ->
    let home = temp_dir "home" and xdg = temp_dir "xdg" in
    set_env ~home ~xdg ~c2c_state:"" ~broker_override:"";
    let expected = home // ".c2c" // "repos" // fp () // "broker" in
    check string "XDG set: canonical HOME path still chosen" expected
      (C2c_repo_fp.resolve_broker_root ()))

(* 2. C2C_STATE_HOME is the supported relocation escape hatch. *)
let test_c2c_state_home_honored () =
  with_restored_env (fun () ->
    let home = temp_dir "home" and xdg = temp_dir "xdg" in
    let state = temp_dir "state" in
    set_env ~home ~xdg ~c2c_state:state ~broker_override:"";
    let expected = state // "c2c" // "repos" // fp () // "broker" in
    check string "C2C_STATE_HOME wins over HOME and XDG" expected
      (C2c_repo_fp.resolve_broker_root ()))

(* 3. C2C_MCP_BROKER_ROOT still wins over everything. *)
let test_explicit_override_wins () =
  with_restored_env (fun () ->
    let home = temp_dir "home" and override = temp_dir "override" in
    let state = temp_dir "state" in
    set_env ~home ~xdg:(temp_dir "xdg") ~c2c_state:state
      ~broker_override:override;
    check string "C2C_MCP_BROKER_ROOT wins" override
      (C2c_repo_fp.resolve_broker_root ()))

(* 4. HOME unset: XDG default chain remains the last resort. *)
let test_home_unset_falls_back_to_xdg () =
  with_restored_env (fun () ->
    let xdg = temp_dir "xdg" in
    set_env ~home:"" ~xdg ~c2c_state:"" ~broker_override:"";
    let expected = xdg // "c2c" // "repos" // fp () // "broker" in
    check string "no HOME: XDG last resort" expected
      (C2c_repo_fp.resolve_broker_root ()))

(* 5. Split-brain detection: orphaned XDG-profile broker with registry.json. *)
let test_split_brain_detected () =
  with_restored_env (fun () ->
    let home = temp_dir "home" and xdg = temp_dir "xdg" in
    set_env ~home ~xdg ~c2c_state:"" ~broker_override:"";
    let xdg_broker = xdg // "c2c" // "repos" // fp () // "broker" in
    (* No broker dir at all → no split-brain. *)
    check (option string) "no XDG broker dir: None" None
      (C2c_repo_fp.xdg_split_brain_broker ());
    (* Empty dir (no registry.json) → still no split-brain. *)
    C2c_mcp.mkdir_p xdg_broker;
    check (option string) "empty XDG broker dir: None" None
      (C2c_repo_fp.xdg_split_brain_broker ());
    (* registry.json present → real broker data → split-brain. *)
    let oc = open_out (xdg_broker // "registry.json") in
    output_string oc "{\"registrations\":[]}\n";
    close_out oc;
    check (option string) "registry.json present: Some xdg path"
      (Some xdg_broker)
      (C2c_repo_fp.xdg_split_brain_broker ()))

(* 6. C2C_STATE_HOME set = deliberate relocation → no split-brain warning. *)
let test_split_brain_suppressed_by_c2c_state_home () =
  with_restored_env (fun () ->
    let home = temp_dir "home" and xdg = temp_dir "xdg" in
    let state = temp_dir "state" in
    let xdg_broker = xdg // "c2c" // "repos" // fp () // "broker" in
    C2c_mcp.mkdir_p xdg_broker;
    let oc = open_out (xdg_broker // "registry.json") in
    output_string oc "{\"registrations\":[]}\n";
    close_out oc;
    set_env ~home ~xdg ~c2c_state:state ~broker_override:"";
    check (option string) "C2C_STATE_HOME set: split-brain not reported" None
      (C2c_repo_fp.xdg_split_brain_broker ()))

(* 7. XDG unset → never split-brain. *)
let test_split_brain_requires_xdg () =
  with_restored_env (fun () ->
    let home = temp_dir "home" in
    set_env ~home ~xdg:"" ~c2c_state:"" ~broker_override:"";
    check (option string) "XDG unset: None" None
      (C2c_repo_fp.xdg_split_brain_broker ()))

let () =
  Random.self_init ();
  run "broker_root_resolution"
    [ ( "resolution_order"
      , [ test_case "XDG_STATE_HOME no longer honored" `Quick test_xdg_no_longer_honored
        ; test_case "C2C_STATE_HOME honored"           `Quick test_c2c_state_home_honored
        ; test_case "C2C_MCP_BROKER_ROOT wins"         `Quick test_explicit_override_wins
        ; test_case "HOME unset: XDG last resort"      `Quick test_home_unset_falls_back_to_xdg
        ] )
    ; ( "split_brain_detection"
      , [ test_case "orphaned XDG broker detected"     `Quick test_split_brain_detected
        ; test_case "C2C_STATE_HOME suppresses"        `Quick test_split_brain_suppressed_by_c2c_state_home
        ; test_case "requires XDG set"                 `Quick test_split_brain_requires_xdg
        ] )
    ]
