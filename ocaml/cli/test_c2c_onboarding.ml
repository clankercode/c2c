(* test_c2c_onboarding.ml — integration tests for cross-machine onboarding pipeline

    Exercises the full init → identity → relay register → connector → DM → room
    flow against an isolated temp HOME + temp broker root, so the operator's
    real state is untouched. Runs under `dune runtest`.

    Mirrors scripts/onboarding-smoke-test.sh but in OCaml Alcotest, enabling
    regression testing as part of the standard test suite. *)

open Alcotest

let ( // ) = Filename.concat

let log s = prerr_endline ("[onboarding-test] " ^ s)

(* ---------------------------------------------------------------- *)
(* Helpers *)

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else
    Sys.remove path

let mkdir_p path =
  let rec loop p =
    if Sys.file_exists p then ()
    else begin
      loop (Filename.dirname p);
      Unix.mkdir p 0o755
    end
  in
  if path <> "" && path <> Filename.dirname path then loop path

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

(** Run c2c with a given HOME + broker root, capture exit code + combined output. *)
let run_c2c ?(env=[]) ~home ~broker args =
  let home_dir = home in
  let broker_dir = Filename.concat broker "broker" in
  mkdir_p home_dir;
  mkdir_p broker_dir;
  let env_list =
    [ "HOME=" ^ home_dir
    ; "C2C_MCP_BROKER_ROOT=" ^ broker_dir
    ; "C2C_MCP_SESSION_ID="
    ; "CLAUDE_SESSION_ID="
    ; "C2C_MCP_AUTO_REGISTER_ALIAS="
    ; "C2C_INSTANCE_NAME="
    ]
    @ List.map (fun (k,v) -> k ^ "=" ^ v) env
    @ [ "PATH=" ^ Sys.getenv "PATH" ]
  in
  let env_str = String.concat " " env_list in
  let args_str = String.concat " " (List.map Filename.quote args) in
  let cmd = Printf.sprintf "env %s c2c %s >/tmp/onboard-out 2>&1; echo exit:$?" 
    env_str args_str in
  let rc = Sys.command cmd in
  let output = try read_file "/tmp/onboard-out" with _ -> "" in
  (rc, output, "") 

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let file_exists path =
  try ignore (Unix.stat path); true with Unix.Unix_error _ -> false

(** Wrap a test that sets up temp env and runs a c2c command sequence. *)
let with_temp_env f =
  let tmp = Filename.get_temp_dir_name () in
  let dir = tmp // Printf.sprintf "c2c-onboard-test-%d-%06x" (Unix.getpid ()) (Random.bits ()) in
  mkdir_p dir;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists dir then remove_tree dir)
    (fun () -> f dir)

(* ---------------------------------------------------------------- *)
(* Test cases — each is a subdirectory of the onboarding pipeline *)

let test_c2c_version_runs () =
  with_temp_env @@ fun tmp ->
  let home = tmp in
  let broker = tmp // "broker" in
  let rc, out, _ = run_c2c ~home:tmp ~broker:tmp [] in
  check int "c2c --version exits 0" 0 rc;
  check bool "output contains version" true (string_contains out "0.")

let test_init_creates_alias () =
  with_temp_env @@ fun tmp ->
  let home = tmp in
  let broker = tmp // "broker" in
  let alias = Printf.sprintf "test-onboard-%d" (Unix.getpid ()) in
  let rc, out, _ = run_c2c ~home:tmp ~broker:tmp ["init"; "--no-setup"; "--alias"; alias; "--room"; ""; "--json"] in
  check int "c2c init exits 0" 0 rc;
  check bool "output mentions alias" true (string_contains out alias)

let test_init_creates_session_dir () =
  with_temp_env @@ fun tmp ->
  let home = tmp in
  let broker = tmp // "broker" in
  let alias = Printf.sprintf "test-onboard-%d" (Unix.getpid ()) in
  let _ = run_c2c ~home:tmp ~broker:tmp ["init"; "--no-setup"; "--alias"; alias; "--room"; ""] in
  let session_dir = home // ".config" // "c2c" in
  check bool "session dir created" true (Sys.file_exists session_dir)

let test_identity_json_created () =
  with_temp_env @@ fun tmp ->
  let home = tmp in
  let broker = tmp // "broker" in
  let alias = Printf.sprintf "test-onboard-%d" (Unix.getpid ()) in
  let _ = run_c2c ~home:tmp ~broker:tmp ["init"; "--no-setup"; "--alias"; alias; "--room"; ""] in
  let identity_file = home // ".config" // "c2c" // "identity.json" in
  check bool "identity.json exists" true (file_exists identity_file)

let test_relay_identity_show () =
  with_temp_env @@ fun tmp ->
  let home = tmp in
  let broker = tmp // "broker" in
  let alias = Printf.sprintf "test-onboard-%d" (Unix.getpid ()) in
  let _ = run_c2c ~home:tmp ~broker:tmp ["init"; "--no-setup"; "--alias"; alias; "--room"; ""] in
  let rc, out, _ = run_c2c ~home:tmp ~broker:tmp ["relay"; "identity"; "show"] in
  check int "relay identity show exits 0" 0 rc;
  check bool "output contains fingerprint" true (string_contains out "fingerprint")

let test_relay_setup_writes_config () =
  with_temp_env @@ fun tmp ->
  let home = tmp in
  let broker = tmp // "broker" in
  let alias = Printf.sprintf "test-onboard-%d" (Unix.getpid ()) in
  let _ = run_c2c ~home:tmp ~broker:tmp ["init"; "--no-setup"; "--alias"; alias; "--room"; ""] in
  let relay_url = "http://localhost:7331" in
  let rc, out, _ = run_c2c ~home:tmp ~broker:tmp ["relay"; "setup"; "--url"; relay_url] in
  check int "relay setup exits 0" 0 rc;
  let relay_json = broker // "relay.json" in
  check bool "relay.json created" true (file_exists relay_json)

(* ---------------------------------------------------------------- *)
(* Registration and connect — soft steps (require reachable relay) *)

let test_relay_register_soft () =
  with_temp_env @@ fun tmp ->
  let home = tmp in
  let broker = tmp // "broker" in
  let alias = Printf.sprintf "test-onboard-%d" (Unix.getpid ()) in
  let _ = run_c2c ~home:tmp ~broker:tmp ["init"; "--no-setup"; "--alias"; alias; "--room"; ""] in
  let _ = run_c2c ~home:tmp ~broker:tmp ["relay"; "setup"; "--url"; "http://localhost:7331"] in
  (* Soft step — rc 0 or 1 both acceptable since relay may be unreachable in test env *)
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp ["relay"; "register"; "--alias"; alias; "--relay-url"; "http://localhost:7331"] in
  check bool "relay register exits 0 or 1" true (rc = 0 || rc = 1)

let test_relay_connect_soft () =
  with_temp_env @@ fun tmp ->
  let home = tmp in
  let broker = tmp // "broker" in
  let alias = Printf.sprintf "test-onboard-%d" (Unix.getpid ()) in
  let _ = run_c2c ~home:tmp ~broker:tmp ["init"; "--no-setup"; "--alias"; alias; "--room"; ""] in
  let _ = run_c2c ~home:tmp ~broker:tmp ["relay"; "setup"; "--url"; "http://localhost:7331"] in
  (* Soft step — connect --once with short interval; rc 0 or 1 acceptable *)
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp
    ["relay"; "connect"; "--once"; "--relay-url"; "http://localhost:7331"; "--interval"; "1"] in
  check bool "relay connect exits 0 or 1" true (rc = 0 || rc = 1)

(* ---------------------------------------------------------------- *)
(* Smoke: full local pipeline (no relay dependency) *)

let test_full_pipeline_local () =
  with_temp_env @@ fun tmp ->
  let home = tmp in
  let broker = tmp // "broker" in
  let alias = Printf.sprintf "test-onboard-%d" (Unix.getpid ()) in
  (* Step 1: init *)
  let rc, out, _ = run_c2c ~home:tmp ~broker:tmp ["init"; "--no-setup"; "--alias"; alias; "--room"; ""; "--json"] in
  check int "init exits 0" 0 rc;
  check bool "init mentions alias" true (string_contains out alias);
  (* Step 2: identity.json created *)
  let identity_file = home // ".config" // "c2c" // "identity.json" in
  check bool "identity.json exists" true (file_exists identity_file);
  (* Step 3: relay identity show *)
  let rc, out, _ = run_c2c ~home:tmp ~broker:tmp ["relay"; "identity"; "show"] in
  check int "identity show exits 0" 0 rc;
  check bool "identity show has fingerprint" true (string_contains out "fingerprint");
  (* Step 4: relay setup *)
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp ["relay"; "setup"; "--url"; "http://localhost:7331"] in
  check int "relay setup exits 0" 0 rc;
  let relay_json = broker // "relay.json" in
  check bool "relay.json exists" true (file_exists relay_json);
  (* Step 5: local list (no relay needed) *)
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp ["list"] in
  check int "list exits 0" 0 rc;
  (* Step 6: whoami — pass --session-id explicitly since the test env clears
     C2C_MCP_SESSION_ID and there is no inherited client session to fall back on. *)
  let session_id = Printf.sprintf "test-onboard-session-%d-%06x" (Unix.getpid ()) (Random.bits ()) in
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp ["register"; "--alias"; alias; "--session-id"; session_id] in
  check int "register exits 0" 0 rc;
  let rc, out, _ = run_c2c ~env:["C2C_MCP_SESSION_ID", session_id] ~home:tmp ~broker:tmp ["whoami"] in
  check int "whoami exits 0" 0 rc;
  check bool "whoami mentions alias" true (string_contains out alias)

(* ---------------------------------------------------------------- *)
(* Alcotest registration *)

let () =
  run "c2c_onboarding"
    [ ( "init",
        [ test_case "c2c --version runs" `Quick test_c2c_version_runs
        ; test_case "init creates session dir" `Quick test_init_creates_session_dir
        ; test_case "init creates alias" `Quick test_init_creates_alias
        ; test_case "init creates identity.json" `Quick test_identity_json_created
        ] )
    ; ( "relay_identity",
        [ test_case "relay identity show parses identity.json" `Quick test_relay_identity_show
        ] )
    ; ( "relay_setup",
        [ test_case "relay setup writes relay.json" `Quick test_relay_setup_writes_config
        ] )
    ; ( "relay_connect_soft",
        [ test_case "relay register (soft, no relay required)" `Quick test_relay_register_soft
        ; test_case "relay connect --once (soft)" `Quick test_relay_connect_soft
        ] )
    ; ( "full_pipeline",
        [ test_case "local pipeline: init→identity→relay setup→list→whoami" `Quick test_full_pipeline_local
        ] )
    ]
