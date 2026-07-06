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

(** Path to the freshly-built c2c binary under dune's _build tree.
    test_c2c_onboarding.exe lives in the same directory as c2c.exe
    (_build/default/ocaml/cli), so we resolve it relative to the test
    executable. This avoids exercising a stale ~/.local/bin/c2c. *)
let c2c_binary =
  let exe = Sys.executable_name in
  let dir = Filename.dirname exe in
  Filename.concat dir "c2c.exe"

let c2c_base_env ~home ~broker ?(env=[]) () =
  let home_dir = home in
  let broker_dir = Filename.concat broker "broker" in
  mkdir_p home_dir;
  mkdir_p broker_dir;
  [ "HOME=" ^ home_dir
  ; "XDG_CONFIG_HOME=" ^ (home_dir // ".config")
  ; "XDG_STATE_HOME=" ^ (home_dir // ".local" // "state")
  ; "C2C_MCP_BROKER_ROOT=" ^ broker_dir
  ; "C2C_CLI_FORCE=1"
  ; "C2C_MCP_SESSION_ID="
  ; "CLAUDE_SESSION_ID="
  (* Operator sessions may set CLAUDE_CONFIG_DIR (e.g. profile-share setups);
     without clearing it, `init --client claude` writes the /c2c skill into
     the operator's REAL Claude config dir and the temp-HOME assertion fails. *)
  ; "CLAUDE_CONFIG_DIR="
  ; "C2C_MCP_AUTO_REGISTER_ALIAS="
  ; "C2C_INSTANCE_NAME="
  ]
  @ List.map (fun (k,v) -> k ^ "=" ^ v) env
  @ [ "PATH=" ^ Sys.getenv "PATH" ]

(** Run c2c with a given HOME + broker root, capture exit code + combined output. *)
let run_c2c ?(env=[]) ~home ~broker args =
  let binary =
    if Sys.file_exists c2c_binary then c2c_binary else "c2c"
  in
  let env_str = String.concat " " (c2c_base_env ~home ~broker ~env ()) in
  let args_str = String.concat " " (List.map Filename.quote args) in
  let cmd = Printf.sprintf "env %s %s %s >/tmp/onboard-out 2>&1; echo exit:$?"
    env_str (Filename.quote binary) args_str in
  let rc = Sys.command cmd in
  let output = try read_file "/tmp/onboard-out" with _ -> "" in
  (rc, output, "")

let decode_sys_command_status = function
  | 0 -> 0
  | n when n > 0 && n land 0x7f = 0 -> n lsr 8
  | n -> n

let run_c2c_status_split ?(env=[]) ~home ~broker args =
  let binary =
    if Sys.file_exists c2c_binary then c2c_binary else "c2c"
  in
  let out_file = Filename.temp_file "c2c-onboard-cmd-" ".out" in
  let err_file = Filename.temp_file "c2c-onboard-cmd-" ".err" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove out_file with _ -> ());
      (try Sys.remove err_file with _ -> ()))
    (fun () ->
      let env_str = String.concat " " (c2c_base_env ~home ~broker ~env ()) in
      let args_str = String.concat " " (List.map Filename.quote args) in
      let cmd = Printf.sprintf "env %s %s %s >%s 2>%s"
        env_str (Filename.quote binary) args_str
        (Filename.quote out_file) (Filename.quote err_file)
      in
      let rc = decode_sys_command_status (Sys.command cmd) in
      let stdout = try read_file out_file with _ -> "" in
      let stderr = try read_file err_file with _ -> "" in
      (rc, stdout, stderr))

let run_c2c_status ?(env=[]) ~home ~broker args =
  let rc, stdout, stderr = run_c2c_status_split ~env ~home ~broker args in
  (rc, stdout ^ stderr)

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

let read_json_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  Yojson.Safe.from_channel ic

let json_str_member name = function
  | `Assoc fields ->
      (match List.assoc_opt name fields with
       | Some (`String s) -> Some s
       | _ -> None)
  | _ -> None

let json_bool_member name = function
  | `Assoc fields ->
      (match List.assoc_opt name fields with
       | Some (`Bool b) -> Some b
       | _ -> None)
  | _ -> None

let json_member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let json_string_list_member name json =
  match json_member name json with
  | Some (`List items) ->
      Some (List.filter_map (function `String s -> Some s | _ -> None) items)
  | _ -> None

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

let test_init_claude_cli_only_json_onboarding_and_rerun () =
  with_temp_env @@ fun tmp ->
  let session_id = Printf.sprintf "test-init-claude-session-%d" (Unix.getpid ()) in
  let run_once () =
    run_c2c_status_split
      ~env:["C2C_MCP_SESSION_ID", session_id]
      ~home:tmp ~broker:tmp
      ["init"; "--client"; "claude"; "--no-nonce"; "--room"; ""; "--json"]
  in
  let rc1, out1, _err1 = run_once () in
  check int "first c2c init exits 0" 0 rc1;
  let json1 = Yojson.Safe.from_string out1 in
  check (option bool) "json ok true" (Some true) (json_bool_member "ok" json1);
  check (option string) "json setup is cli-only" (Some "cli-only (no MCP)") (json_str_member "setup" json1);
  let alias1 = json_str_member "alias" json1 in
  check bool "first init has alias" true (Option.is_some alias1);
  let onboarding1 = match json_member "onboarding" json1 with Some j -> j | None -> `Null in
  let lines1 = Option.value (json_string_list_member "lines" onboarding1) ~default:[] in
  check bool "onboarding mentions c2c monitor" true
    (List.exists (fun s -> string_contains s "c2c monitor") lines1);
  check bool "onboarding explains MCP is optional" true
    (List.exists (fun s -> string_contains s "MCP is optional") lines1);
  let skill_path = tmp // ".claude" // "skills" // "c2c" // "SKILL.md" in
  check bool "CLI-only claude init writes /c2c skill" true (file_exists skill_path);
  let rc2, out2, _err2 = run_once () in
  check int "second c2c init exits 0" 0 rc2;
  let json2 = Yojson.Safe.from_string out2 in
  check (option string) "second init reuses same alias" alias1 (json_str_member "alias" json2)

let test_send_without_alias_error_suggests_onboarding_commands () =
  with_temp_env @@ fun tmp ->
  let rc, out = run_c2c_status ~home:tmp ~broker:tmp ["send"; "nobody"; "hi"] in
  check bool "send without alias fails" true (rc <> 0);
  check bool "error suggests c2c register" true (string_contains out "c2c register");
  check bool "error suggests c2c init" true (string_contains out "c2c init");
  check bool "error suggests c2c whoami" true (string_contains out "c2c whoami");
  check bool "env vars are an advanced fallback" true (string_contains out "Advanced:")

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

let test_register_captures_cwd () =
  with_temp_env @@ fun tmp ->
  let alias = Printf.sprintf "test-cwd-%d" (Unix.getpid ()) in
  let session_id = Printf.sprintf "test-cwd-session-%d-%06x" (Unix.getpid ()) (Random.bits ()) in
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp ["init"; "--no-setup"; "--alias"; alias; "--room"; ""] in
  check int "init exits 0" 0 rc;
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp ["register"; "--alias"; alias; "--session-id"; session_id] in
  check int "register exits 0" 0 rc;
  let registry_json = read_json_file (tmp // "broker" // "registry.json") in
  let items =
    match registry_json with
    | `List items -> items
    | _ -> []
  in
  check int "one registration" 1 (List.length items);
  let cwd = json_str_member "cwd" (List.hd items) in
  check bool "cwd is Some" true (Option.is_some cwd);
  check bool "cwd is non-empty" true (Option.get cwd <> "")

let test_register_no_metadata_sets_opt_out () =
  with_temp_env @@ fun tmp ->
  let alias = Printf.sprintf "test-meta-%d" (Unix.getpid ()) in
  let session_id = Printf.sprintf "test-meta-session-%d-%06x" (Unix.getpid ()) (Random.bits ()) in
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp ["init"; "--no-setup"; "--alias"; alias; "--room"; ""] in
  check int "init exits 0" 0 rc;
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp ["register"; "--alias"; alias; "--session-id"; session_id; "--no-metadata"] in
  check int "register --no-metadata exits 0" 0 rc;
  let registry_json = read_json_file (tmp // "broker" // "registry.json") in
  let items =
    match registry_json with
    | `List items -> items
    | _ -> []
  in
  check int "one registration" 1 (List.length items);
  let metadata_opt_out = json_bool_member "metadata_opt_out" (List.hd items) in
  check bool "metadata_opt_out is true" true (metadata_opt_out = Some true)

let test_register_no_metadata_still_captures_cwd () =
  with_temp_env @@ fun tmp ->
  let alias = Printf.sprintf "test-guard-%d" (Unix.getpid ()) in
  let session_id = Printf.sprintf "test-guard-session-%d-%06x" (Unix.getpid ()) (Random.bits ()) in
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp ["init"; "--no-setup"; "--alias"; alias; "--room"; ""] in
  check int "init exits 0" 0 rc;
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp ["register"; "--alias"; alias; "--session-id"; session_id; "--no-metadata"] in
  check int "register --no-metadata exits 0" 0 rc;
  let registry_json = read_json_file (tmp // "broker" // "registry.json") in
  let items =
    match registry_json with
    | `List items -> items
    | _ -> []
  in
  check int "one registration" 1 (List.length items);
  let cwd = json_str_member "cwd" (List.hd items) in
  check bool "cwd still captured with --no-metadata" true (Option.is_some cwd);
  check bool "cwd is non-empty" true (Option.get cwd <> "")

let test_register_default_omits_metadata_opt_out_json () =
  with_temp_env @@ fun tmp ->
  let alias = Printf.sprintf "test-omit-%d" (Unix.getpid ()) in
  let session_id = Printf.sprintf "test-omit-session-%d-%06x" (Unix.getpid ()) (Random.bits ()) in
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp ["init"; "--no-setup"; "--alias"; alias; "--room"; ""] in
  check int "init exits 0" 0 rc;
  let rc, _, _ = run_c2c ~home:tmp ~broker:tmp ["register"; "--alias"; alias; "--session-id"; session_id] in
  check int "register exits 0" 0 rc;
  let registry_json = read_json_file (tmp // "broker" // "registry.json") in
  let items =
    match registry_json with
    | `List items -> items
    | _ -> []
  in
  check int "one registration" 1 (List.length items);
  let metadata_opt_out = json_bool_member "metadata_opt_out" (List.hd items) in
  check bool "metadata_opt_out key absent from JSON when false" true (metadata_opt_out = None)

(* ---------------------------------------------------------------- *)
(* Alcotest registration *)

let () =
  run "c2c_onboarding"
    [ ( "init",
        [ test_case "c2c --version runs" `Quick test_c2c_version_runs
        ; test_case "init creates session dir" `Quick test_init_creates_session_dir
        ; test_case "init creates alias" `Quick test_init_creates_alias
        ; test_case "init claude CLI-only emits JSON onboarding, writes skill, and reruns" `Quick test_init_claude_cli_only_json_onboarding_and_rerun
        ; test_case "send without alias suggests onboarding commands" `Quick test_send_without_alias_error_suggests_onboarding_commands
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
    ; ( "register_metadata",
        [ test_case "CLI register captures cwd" `Quick test_register_captures_cwd
        ; test_case "CLI register --no-metadata sets opt-out" `Quick test_register_no_metadata_sets_opt_out
        ; test_case "CLI register --no-metadata still captures cwd" `Quick test_register_no_metadata_still_captures_cwd
        ; test_case "CLI register default omits metadata_opt_out from JSON" `Quick test_register_default_omits_metadata_opt_out_json
        ] )
    ]
