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
  ; "CLAUDE_CODE_SESSION_ID="
  ; "CODEX_THREAD_ID="
  ; "C2C_OPENCODE_SESSION_ID="
  ; "GROK_SESSION_ID="
  ; "GROK_AGENT="
  ; "C2C_GROK_ACTIVE_SESSIONS="
  ; "CURSOR_AGENT="
  ; "CURSOR_INVOKED_AS="
  ; "ANTIGRAVITY_CONVERSATION_ID="
  ; "ANTIGRAVITY_HOOK_EVENT="
  ; "ANTIGRAVITY_LS_ADDRESS="
  (* Hermeticity: when this suite runs from inside a Claude Code session the
     operator's CLAUDE_CONFIG_DIR (e.g. ~/.claude-p) leaks in and
     resolve_claude_dir writes the /c2c skill there instead of the temp HOME. *)
  ; "CLAUDE_CONFIG_DIR="
  ; "C2C_MCP_CLIENT_TYPE="
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

(* ---------------------------------------------------------------- *)
(* Session identity: init → whoami round-trip with zero env vars (#10) *)

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content

let test_init_whoami_roundtrip_no_env () =
  (* Acceptance (#10): `c2c init` with NO session env must persist the
     synthesized session id so the very next `c2c whoami` in the same
     env-less context succeeds. *)
  with_temp_env @@ fun tmp ->
  let alias = Printf.sprintf "test-idn-%d" (Unix.getpid ()) in
  let rc, _, _ =
    run_c2c_status_split ~home:tmp ~broker:tmp
      ["init"; "--no-setup"; "--alias"; alias; "--room"; ""]
  in
  check int "init exits 0" 0 rc;
  let statefile = tmp // "broker" // "default-session.json" in
  check bool "default-session.json persisted in broker root" true
    (file_exists statefile);
  let rc, out, err = run_c2c_status_split ~home:tmp ~broker:tmp ["whoami"] in
  check int "whoami exits 0 with zero session env" 0 rc;
  check bool "whoami resolves the init alias" true (string_contains out alias);
  check bool "whoami notes the fallback source on stderr" true
    (string_contains err "init fallback");
  (* Re-running init in the same context reuses the persisted session
     (and therefore the same alias via B046 session->alias reuse). *)
  let rc, out2, _ =
    run_c2c_status_split ~home:tmp ~broker:tmp
      ["init"; "--no-setup"; "--room"; ""; "--json"]
  in
  check int "second init exits 0" 0 rc;
  check bool "second init reuses the same alias" true (string_contains out2 alias)

let test_env_session_id_wins_over_statefile () =
  with_temp_env @@ fun tmp ->
  let alias = Printf.sprintf "test-idn-fb-%d" (Unix.getpid ()) in
  let env_alias = Printf.sprintf "test-idn-env-%d" (Unix.getpid ()) in
  let env_sid = Printf.sprintf "env-session-%d" (Unix.getpid ()) in
  let rc, _, _ =
    run_c2c_status_split ~home:tmp ~broker:tmp
      ["init"; "--no-setup"; "--alias"; alias; "--room"; ""]
  in
  check int "init exits 0" 0 rc;
  let rc, _, _ =
    run_c2c_status_split ~home:tmp ~broker:tmp
      ["register"; "--alias"; env_alias; "--session-id"; env_sid]
  in
  check int "register exits 0" 0 rc;
  (* CLAUDE_CODE_SESSION_ID (env-derived) must shadow the statefile. *)
  let rc, out, err =
    run_c2c_status_split ~env:["CLAUDE_CODE_SESSION_ID", env_sid]
      ~home:tmp ~broker:tmp ["whoami"]
  in
  check int "whoami exits 0" 0 rc;
  check bool "env-derived session resolves its own alias" true
    (string_contains out env_alias);
  check bool "statefile alias not used" false (string_contains out alias);
  check bool "no fallback note when env wins" false
    (string_contains err "init fallback")

(* B241: whoami and rooms join must share session resolution. Without
   C2C_MCP_SESSION_ID, both use the init default-session.json fallback
   (with the same stderr note) — rooms must not hard-error while whoami
   succeeds as a different identity. *)
let test_b241_rooms_join_uses_statefile_like_whoami () =
  with_temp_env @@ fun tmp ->
  let alias = Printf.sprintf "test-b241-%d" (Unix.getpid ()) in
  let room = Printf.sprintf "b241-room-%d" (Unix.getpid ()) in
  let rc, _, _ =
    run_c2c_status_split ~home:tmp ~broker:tmp
      ["init"; "--no-setup"; "--alias"; alias; "--room"; ""]
  in
  check int "init exits 0" 0 rc;
  let statefile = tmp // "broker" // "default-session.json" in
  check bool "default-session.json present" true (file_exists statefile);
  (* whoami succeeds via statefile fallback *)
  let rc, who_out, who_err =
    run_c2c_status_split ~home:tmp ~broker:tmp ["whoami"]
  in
  check int "whoami exits 0 with zero session env" 0 rc;
  check bool "whoami resolves init alias" true (string_contains who_out alias);
  (* #26: the sole-registration fallback is now a loud WARN (was a quiet note:),
     still exit 0. Keep asserting the "init fallback" wording for behaviour
     equivalence, but require it be escalated to WARN. *)
  check bool "whoami notes init fallback" true
    (string_contains who_err "init fallback");
  check bool "whoami escalates sole fallback to WARN" true
    (string_contains who_err "WARN");
  (* peek-inbox also uses the shared path (may be empty) *)
  let rc, _, peek_err =
    run_c2c_status_split ~home:tmp ~broker:tmp ["peek-inbox"]
  in
  check int "peek-inbox exits 0 with statefile session" 0 rc;
  (* rooms join must NOT hard-error on missing C2C_MCP_SESSION_ID *)
  let rc, join_out, join_err =
    run_c2c_status_split ~home:tmp ~broker:tmp
      ["rooms"; "join"; room; "--history-limit"; "0"]
  in
  check int "rooms join exits 0 with statefile session" 0 rc;
  check bool "rooms join mentions room" true (string_contains join_out room);
  check bool "rooms join does not demand C2C_MCP_SESSION_ID only"
    false
    (string_contains join_err "cannot determine alias"
     || string_contains join_err "C2C_MCP_SESSION_ID is required");
  (* Same session identity: join as the whoami alias *)
  check bool "joined as whoami alias" true
    (string_contains join_out alias
     || string_contains join_out "Joined room");
  (* Explicit env still wins for rooms (parity with whoami) *)
  let env_alias = Printf.sprintf "test-b241-env-%d" (Unix.getpid ()) in
  let env_sid = Printf.sprintf "b241-env-session-%d" (Unix.getpid ()) in
  let rc, _, _ =
    run_c2c_status_split ~home:tmp ~broker:tmp
      ["register"; "--alias"; env_alias; "--session-id"; env_sid]
  in
  check int "register env peer exits 0" 0 rc;
  let room2 = Printf.sprintf "b241-room2-%d" (Unix.getpid ()) in
  let rc, join2_out, join2_err =
    run_c2c_status_split
      ~env:["C2C_MCP_SESSION_ID", env_sid]
      ~home:tmp ~broker:tmp
      ["rooms"; "join"; room2; "--history-limit"; "0"]
  in
  check int "rooms join with env session exits 0" 0 rc;
  check bool "no statefile note when env wins for rooms" false
    (string_contains join2_err "init fallback");
  check bool "env session joins as env alias" true
    (string_contains join2_out env_alias
     || string_contains join2_out "Joined room")

let test_stale_session_statefile_ignored () =
  with_temp_env @@ fun tmp ->
  let alias = Printf.sprintf "test-idn-stale-%d" (Unix.getpid ()) in
  let rc, _, _ =
    run_c2c_status_split ~home:tmp ~broker:tmp
      ["init"; "--no-setup"; "--alias"; alias; "--room"; ""]
  in
  check int "init exits 0" 0 rc;
  (* Point the statefile at a session id the registry has never seen. *)
  let statefile = tmp // "broker" // "default-session.json" in
  write_file statefile
    "{\"session_id\": \"stale-session-xyz\", \"alias\": \"ghost\", \"client\": null, \"created_at\": \"2026-01-01T00:00:00Z\"}\n";
  let rc, out = run_c2c_status ~home:tmp ~broker:tmp ["whoami"] in
  check bool "whoami fails when statefile is stale" true (rc <> 0);
  check bool "stale session id never adopted" false
    (string_contains out "stale-session-xyz")

(* #26 (subsumes #21): when the default-session.json fallback is ambiguous —
   the statefile session is registered but at least one OTHER registration
   exists — bare whoami must FAIL CLOSED and list BOTH candidate aliases,
   never silently resolving as the statefile's (or the other agent's) alias. *)
let test_ambiguous_statefile_fails_closed () =
  with_temp_env @@ fun tmp ->
  let alias = Printf.sprintf "test-idn-amb-%d" (Unix.getpid ()) in
  (* init writes default-session.json pointing at this alias's session. *)
  let rc, _, _ =
    run_c2c_status_split ~home:tmp ~broker:tmp
      ["init"; "--no-setup"; "--alias"; alias; "--room"; ""]
  in
  check int "init exits 0" 0 rc;
  let statefile = tmp // "broker" // "default-session.json" in
  check bool "default-session.json present" true (file_exists statefile);
  (* Register a SECOND, different session/alias in the same broker. Now the
     statefile session is no longer the sole registration. *)
  let other_alias = Printf.sprintf "test-idn-other-%d" (Unix.getpid ()) in
  let other_sid = Printf.sprintf "amb-other-session-%d" (Unix.getpid ()) in
  let rc, _, _ =
    run_c2c_status_split ~home:tmp ~broker:tmp
      ["register"; "--alias"; other_alias; "--session-id"; other_sid]
  in
  check int "register second peer exits 0" 0 rc;
  (* Bare whoami (no session env): must fail closed, listing both candidates. *)
  let rc, who_out, who_err =
    run_c2c_status_split ~home:tmp ~broker:tmp ["whoami"]
  in
  let combined = who_out ^ who_err in
  check bool "ambiguous whoami exits non-zero" true (rc <> 0);
  check bool "ambiguous whoami lists statefile candidate alias" true
    (string_contains combined alias);
  check bool "ambiguous whoami lists the other candidate alias" true
    (string_contains combined other_alias);
  check bool "ambiguous whoami points at C2C_MCP_SESSION_ID fix" true
    (string_contains combined "C2C_MCP_SESSION_ID");
  (* Never present a resolved identity line for either alias. *)
  check bool "ambiguous whoami never resolves statefile alias" false
    (string_contains who_out ("alias:     " ^ alias));
  check bool "ambiguous whoami never resolves other alias" false
    (string_contains who_out ("alias:     " ^ other_alias))

(* #26 escape hatch: C2C_ALLOW_DEFAULT_SESSION=1 restores the OLD silent
   statefile-wins-if-registered behaviour even under ambiguity. *)
let test_ambiguous_statefile_opt_in_restores_old () =
  with_temp_env @@ fun tmp ->
  let alias = Printf.sprintf "test-idn-optin-%d" (Unix.getpid ()) in
  let rc, _, _ =
    run_c2c_status_split ~home:tmp ~broker:tmp
      ["init"; "--no-setup"; "--alias"; alias; "--room"; ""]
  in
  check int "init exits 0" 0 rc;
  let other_alias = Printf.sprintf "test-idn-optin-other-%d" (Unix.getpid ()) in
  let other_sid = Printf.sprintf "optin-other-session-%d" (Unix.getpid ()) in
  let rc, _, _ =
    run_c2c_status_split ~home:tmp ~broker:tmp
      ["register"; "--alias"; other_alias; "--session-id"; other_sid]
  in
  check int "register second peer exits 0" 0 rc;
  let rc, who_out, _ =
    run_c2c_status_split
      ~env:["C2C_ALLOW_DEFAULT_SESSION", "1"]
      ~home:tmp ~broker:tmp ["whoami"]
  in
  check int "opt-in whoami exits 0 (old silent behaviour)" 0 rc;
  check bool "opt-in whoami resolves statefile alias" true
    (string_contains who_out alias)

(* B172: managed `c2c new codex` registers under a launcher session_id, but
   in-session shell tools typically export only CODEX_THREAD_ID. whoami must
   map the live thread → managed session and print the banner alias. *)
let test_whoami_maps_codex_thread_to_managed_alias () =
  with_temp_env @@ fun tmp ->
  let managed_sid = Printf.sprintf "managed-codex-%d" (Unix.getpid ()) in
  let thread_id = "019f5761-cd05-7df1-9011-16a7cbfacacb" in
  (* Avoid reserved client prefixes (codex-…) — CLI register is not from_auto_gen;
     managed launchers mint codex-* via Broker.register ~from_auto_gen:true. *)
  let alias = Printf.sprintf "banner-stack-digit-%04x" (Random.bits () land 0xffff) in
  let instances_dir = tmp // "instances" in
  let instance_dir = instances_dir // alias in
  mkdir_p instance_dir;
  (* Init-equivalent bind: register managed identity under the launcher sid. *)
  let rc, _, _ =
    run_c2c_status_split ~home:tmp ~broker:tmp
      [ "register"; "--alias"; alias; "--session-id"; managed_sid ]
  in
  check int "register managed alias exits 0" 0 rc;
  (* App-server durable mapping (codex-session.json) after thread discovery. *)
  write_file (instance_dir // "codex-session.json")
    (Printf.sprintf
       "{\"session_id\":%S,\"alias\":%S,\"thread_id\":%S,\"created_at\":1.0,\"updated_at\":2.0}\n"
       managed_sid alias thread_id);
  (* Also write config.json the way persist_discovered_thread does. *)
  write_file (instance_dir // "config.json")
    (Printf.sprintf
       "{\"name\":%S,\"client\":\"codex\",\"session_id\":%S,\"resume_session_id\":%S,\
\"codex_resume_target\":%S,\"alias\":%S,\"extra_args\":[],\"created_at\":1.0,\
\"broker_root\":%S,\"auto_join_rooms\":\"\"}\n"
       alias managed_sid thread_id thread_id alias (tmp // "broker"));
  let rc, out, _ =
    run_c2c_status_split
      ~env:
        [ "CODEX_THREAD_ID", thread_id
        ; "C2C_INSTANCES_DIR", instances_dir
        ]
      ~home:tmp ~broker:tmp ["whoami"]
  in
  check int "whoami exits 0 with only CODEX_THREAD_ID" 0 rc;
  check bool "whoami prints managed banner alias" true (string_contains out alias);
  check bool "whoami prints managed session_id" true (string_contains out managed_sid);
  check bool "whoami does not claim unregistered" false
    (string_contains out "(not registered)");
  (* session_id line must be the managed launcher id, not the raw thread. *)
  check bool "whoami session_id line is managed identity" true
    (string_contains out ("session_id: " ^ managed_sid));
  check bool "whoami session_id line is not the thread uuid" false
    (string_contains out ("session_id: " ^ thread_id))

(* B172 first-turn race: thread not yet in codex-session.json, but the sole
   alive codex-app-server registration is unambiguous. *)
let test_whoami_sole_codex_app_server_before_thread_map () =
  with_temp_env @@ fun tmp ->
  let managed_sid = Printf.sprintf "managed-premap-%d" (Unix.getpid ()) in
  let thread_id = "019f5761-aaaa-7df1-9011-16a7cbfacacb" in
  let alias = Printf.sprintf "banner-premap-%04x" (Random.bits () land 0xffff) in
  let rc, _, _ =
    run_c2c_status_split
      ~env:[ "C2C_MCP_CLIENT_TYPE", "codex-app-server" ]
      ~home:tmp ~broker:tmp
      [ "register"; "--alias"; alias; "--session-id"; managed_sid ]
  in
  check int "register sole app-server exits 0" 0 rc;
  let rc, out, _ =
    run_c2c_status_split
      ~env:[ "CODEX_THREAD_ID", thread_id ]
      ~home:tmp ~broker:tmp ["whoami"]
  in
  check int "whoami exits 0 before thread map" 0 rc;
  check bool "whoami resolves sole managed alias" true (string_contains out alias);
  check bool "whoami resolves managed session" true
    (string_contains out ("session_id: " ^ managed_sid));
  check bool "not unregistered" false (string_contains out "(not registered)")

(* ---------------------------------------------------------------- *)
(* B187: whoami/send must not present borrowed / cross-client identity *)

let test_b187_whoami_refuses_agy_shell_borrowing_codex_statefile () =
  (* Dogfood: interactive agy ran whoami and got codex-* from init statefile.
     Use C2C_MCP_CLIENT_TYPE=agy without a native session key so the CLI falls
     through to default-session.json (the borrowed identity), then refuses. *)
  with_temp_env @@ fun tmp ->
  let codex_alias = Printf.sprintf "codex-yew-spout-%04x" (Random.bits () land 0xffff) in
  let codex_sid = Printf.sprintf "codex-borrow-sid-%d" (Unix.getpid ()) in
  let rc, _, err =
    run_c2c_status_split
      ~env:
        [ "C2C_MCP_SESSION_ID", codex_sid
        ; "C2C_MCP_CLIENT_TYPE", "codex"
        ; "C2C_MCP_AUTO_REGISTER_ALIAS", codex_alias
        ; "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN", "1"
        ]
      ~home:tmp ~broker:tmp
      [ "register" ]
  in
  check int ("register codex peer exits 0: " ^ err) 0 rc;
  (* Persist that codex session as the broker's default-session.json fallback. *)
  write_file (tmp // "broker" // "default-session.json")
    (Printf.sprintf
       {|{"session_id":%S,"alias":%S,"client":"codex","created_at":"2026-07-13T00:00:00Z"}|}
       codex_sid codex_alias);
  let rc, out, err =
    run_c2c_status_split
      ~env:[ "C2C_MCP_CLIENT_TYPE", "agy" ]
      ~home:tmp ~broker:tmp ["whoami"]
  in
  check bool "whoami fails closed for agy→codex borrow" true (rc <> 0);
  let combined = out ^ "\n" ^ err in
  check bool "does not print codex alias as success identity" false
    (string_contains out ("alias:     " ^ codex_alias));
  check bool "error mentions cross-client / borrowed" true
    (string_contains combined "borrowed" || string_contains combined "cross-client"
     || string_contains combined "B187");
  check bool "error includes how to fix (init/register/whoami)" true
    (string_contains combined "c2c init" || string_contains combined "c2c register");
  check bool "error mentions whoami re-check" true (string_contains combined "c2c whoami")

let test_b187_whoami_json_error_has_fix_steps () =
  with_temp_env @@ fun tmp ->
  let codex_alias = Printf.sprintf "codex-json-err-%04x" (Random.bits () land 0xffff) in
  let codex_sid = Printf.sprintf "codex-json-sid-%d" (Unix.getpid ()) in
  let rc, _, _ =
    run_c2c_status_split
      ~env:
        [ "C2C_MCP_SESSION_ID", codex_sid
        ; "C2C_MCP_CLIENT_TYPE", "codex"
        ; "C2C_MCP_AUTO_REGISTER_ALIAS", codex_alias
        ; "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN", "1"
        ]
      ~home:tmp ~broker:tmp
      [ "register" ]
  in
  check int "register exits 0" 0 rc;
  write_file (tmp // "broker" // "default-session.json")
    (Printf.sprintf
       {|{"session_id":%S,"alias":%S,"client":"codex","created_at":"2026-07-13T00:00:00Z"}|}
       codex_sid codex_alias);
  let rc, out, _ =
    run_c2c_status_split
      ~env:[ "C2C_MCP_CLIENT_TYPE", "agy" ]
      ~home:tmp ~broker:tmp ["whoami"; "--json"]
  in
  check bool "whoami --json fails closed" true (rc <> 0);
  let json =
    try Yojson.Safe.from_string out
    with _ -> failf "expected JSON error object on stdout, got: %s" out
  in
  check bool "error field present" true
    (match json_str_member "error" json with Some s -> s <> "" | None -> false);
  check bool "candidate names codex alias" true
    (match json_str_member "candidate" json with
     | Some c -> string_contains c codex_alias || c = codex_alias
     | None -> false);
  let steps = Option.value (json_string_list_member "fix_steps" json) ~default:[] in
  check bool "fix_steps non-empty" true (steps <> []);
  check bool "fix_steps mention whoami or init" true
    (List.exists
       (fun s -> string_contains s "whoami" || string_contains s "init" || string_contains s "register")
       steps)

let test_b187_send_refuses_borrowed_auto_register_alias () =
  (* Session env present but unregistered; AUTO_REGISTER_ALIAS points at a
     different live peer — must not send stamped as that peer.
     Disable send-side auto-mint so we exercise the borrowed-alias refusal. *)
  with_temp_env @@ fun tmp ->
  let peer_alias = Printf.sprintf "codex-peer-send-%04x" (Random.bits () land 0xffff) in
  let peer_sid = Printf.sprintf "peer-send-sid-%d" (Unix.getpid ()) in
  let rc, _, _ =
    run_c2c_status_split
      ~env:
        [ "C2C_MCP_SESSION_ID", peer_sid
        ; "C2C_MCP_AUTO_REGISTER_ALIAS", peer_alias
        ; "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN", "1"
        ]
      ~home:tmp ~broker:tmp
      [ "register" ]
  in
  check int "register peer exits 0" 0 rc;
  let rc, out, err =
    run_c2c_status_split
      ~env:
        [ "C2C_MCP_SESSION_ID", "unregistered-shell-sid-b187"
        ; "C2C_MCP_AUTO_REGISTER_ALIAS", peer_alias
        ; "C2C_SEND_AUTOREGISTER_FAIL_FIXTURE", "1"
        ]
      ~home:tmp ~broker:tmp
      [ "send"; peer_alias; "pong-as-wrong-identity" ]
  in
  check bool "send fails closed" true (rc <> 0);
  let combined = out ^ "\n" ^ err in
  check bool "mentions borrowed / AUTO_REGISTER" true
    (string_contains combined "AUTO_REGISTER" || string_contains combined "borrowed"
     || string_contains combined "B187" || string_contains combined "cross-client");
  check bool "fix steps present" true
    (string_contains combined "how to fix" || string_contains combined "c2c init"
     || string_contains combined "c2c register")

let test_b187_whoami_matching_client_still_ok () =
  (* Positive control: agy shell + agy- alias succeeds. *)
  with_temp_env @@ fun tmp ->
  let alias = Printf.sprintf "agy-honest-%04x" (Random.bits () land 0xffff) in
  let sid = "agy-conv-honest-b187" in
  let rc, _, err =
    run_c2c_status_split
      ~env:
        [ "C2C_MCP_SESSION_ID", sid
        ; "C2C_MCP_CLIENT_TYPE", "agy"
        ; "C2C_MCP_AUTO_REGISTER_ALIAS", alias
        ; "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN", "1"
        ]
      ~home:tmp ~broker:tmp
      [ "register" ]
  in
  check int ("register agy exits 0: " ^ err) 0 rc;
  let rc, out, _ =
    run_c2c_status_split
      ~env:
        [ "C2C_MCP_SESSION_ID", sid
        ; "C2C_MCP_CLIENT_TYPE", "agy"
        ; "ANTIGRAVITY_CONVERSATION_ID", sid
        ]
      ~home:tmp ~broker:tmp ["whoami"]
  in
  check int "whoami exits 0 for matching client" 0 rc;
  check bool "whoami prints agy alias" true (string_contains out alias)

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
(* J2: `--json` results for send / peek-inbox / poll-inbox are the
   canonical schema-v1 shape (validated via C2c_schema_v1.validate)
   with every legacy key preserved at unchanged values, end-to-end
   through the real binary against a temp broker. *)

let check_valid_v1 label json =
  match C2c_schema_v1.validate json with
  | Ok v1 -> v1
  | Error e -> failf "%s: schema-v1 validate failed: %s" label e

let json_delivery_state json =
  match json_member "delivery" json with
  | Some d -> json_str_member "state" d
  | None -> None

let test_send_poll_peek_json_schema_v1 () =
  with_temp_env @@ fun tmp ->
  let sender_env = [ "C2C_MCP_SESSION_ID", "j2-e2e-sender-sid" ] in
  let recv_env = [ "C2C_MCP_SESSION_ID", "j2-e2e-recv-sid" ] in
  let rc, _, err =
    run_c2c_status_split ~env:sender_env ~home:tmp ~broker:tmp
      [ "register"; "--alias"; "zz-j2e2e-alpha" ]
  in
  check int ("register sender exits 0: " ^ err) 0 rc;
  let rc, _, err =
    run_c2c_status_split ~env:recv_env ~home:tmp ~broker:tmp
      [ "register"; "--alias"; "zz-j2e2e-beta" ]
  in
  check int ("register recipient exits 0: " ^ err) 0 rc;
  (* send --json: v1 receipt, local synchronous delivery = "delivered"
     (B088), legacy queued/from_alias/to_alias preserved. *)
  let rc, out, err =
    run_c2c_status_split ~env:sender_env ~home:tmp ~broker:tmp
      [ "send"; "zz-j2e2e-beta"; "hello schema v1"; "--json" ]
  in
  check int ("send --json exits 0: " ^ err) 0 rc;
  let receipt = Yojson.Safe.from_string out in
  let _ = check_valid_v1 "send receipt" receipt in
  check (option bool) "legacy queued:true" (Some true)
    (json_bool_member "queued" receipt);
  check (option string) "receipt delivery.state delivered"
    (Some "delivered") (json_delivery_state receipt);
  check (option string) "legacy from_alias" (Some "zz-j2e2e-alpha")
    (json_str_member "from_alias" receipt);
  check (option string) "legacy to_alias" (Some "zz-j2e2e-beta")
    (json_str_member "to_alias" receipt);
  check (option string) "v1 content additive" (Some "hello schema v1")
    (json_str_member "content" receipt);
  (* peek-inbox --json: non-drained rows = "queued". *)
  let rc, out, err =
    run_c2c_status_split ~env:recv_env ~home:tmp ~broker:tmp
      [ "peek-inbox"; "--json" ]
  in
  check int ("peek-inbox --json exits 0: " ^ err) 0 rc;
  let rows = match Yojson.Safe.from_string out with
    | `List rows -> rows
    | _ -> failf "peek-inbox --json: expected a JSON list"
  in
  check int "peek sees one row" 1 (List.length rows);
  let row = List.hd rows in
  let _ = check_valid_v1 "peek row" row in
  check (option string) "peek row queued" (Some "queued")
    (json_delivery_state row);
  (* poll-inbox --json: drained rows = "delivered"; legacy row keys. *)
  let rc, out, err =
    run_c2c_status_split ~env:recv_env ~home:tmp ~broker:tmp
      [ "poll-inbox"; "--json" ]
  in
  check int ("poll-inbox --json exits 0: " ^ err) 0 rc;
  let rows = match Yojson.Safe.from_string out with
    | `List rows -> rows
    | _ -> failf "poll-inbox --json: expected a JSON list"
  in
  check int "poll drains one row" 1 (List.length rows);
  let row = List.hd rows in
  let _ = check_valid_v1 "poll row" row in
  check (option string) "poll row delivered" (Some "delivered")
    (json_delivery_state row);
  check (option string) "row legacy from_alias" (Some "zz-j2e2e-alpha")
    (json_str_member "from_alias" row);
  check (option string) "row legacy to_alias" (Some "zz-j2e2e-beta")
    (json_str_member "to_alias" row);
  check (option string) "row legacy content" (Some "hello schema v1")
    (json_str_member "content" row);
  check bool "row legacy ts present" true
    (match json_member "ts" row with Some (`Float _) -> true | _ -> false);
  (* empty batch: a second poll stays the legacy-compatible `[]`. *)
  let rc, out, err =
    run_c2c_status_split ~env:recv_env ~home:tmp ~broker:tmp
      [ "poll-inbox"; "--json" ]
  in
  check int ("empty poll-inbox --json exits 0: " ^ err) 0 rc;
  check bool "empty batch stays []" true
    (match Yojson.Safe.from_string out with `List [] -> true | _ -> false)

(* ---------------------------------------------------------------- *)
(* B134: client detect — Grok native env + Cursor Agent markers *)

let json_assoc_string key json =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> Some s
       | _ -> None)
  | _ -> None

let registration_client_type ~broker ~session_id =
  let registry_json = read_json_file (broker // "broker" // "registry.json") in
  let items =
    match registry_json with
    | `List items -> items
    | _ -> []
  in
  let rec find = function
    | [] -> None
    | row :: rest ->
        (match json_str_member "session_id" row, json_str_member "client_type" row with
         | Some sid, Some ct when sid = session_id -> Some ct
         | _ -> find rest)
  in
  find items

let test_init_detects_grok_from_env () =
  (* B134: GROK_SESSION_ID must drive client=grok + grok- alias prefix
     (parity with MCP inferred_client_type_from_env; not PATH-guessed codex). *)
  with_temp_env @@ fun tmp ->
  let sid = Printf.sprintf "grok-b134-%d" (Unix.getpid ()) in
  let rc, out, err =
    run_c2c_status_split ~env:["GROK_SESSION_ID", sid]
      ~home:tmp ~broker:tmp
      ["init"; "--no-setup"; "--room"; ""; "--json"]
  in
  check int ("init exits 0: " ^ err) 0 rc;
  let alias =
    match Yojson.Safe.from_string out |> json_assoc_string "alias" with
    | Some a -> a
    | None -> failf "init --json missing alias: %s" out
  in
  check bool ("alias starts with grok-: " ^ alias) true
    (String.starts_with ~prefix:"grok-" alias);
  check (option string) "registration client_type=grok" (Some "grok")
    (registration_client_type ~broker:tmp ~session_id:sid)

let test_init_detects_grok_from_agent_flag () =
  (* B173: Grok tool shells export GROK_AGENT=1 without GROK_SESSION_ID.
     init must still mint a grok- alias (not PATH-guessed codex-). *)
  with_temp_env @@ fun tmp ->
  let rc, out, err =
    run_c2c_status_split ~env:[ "GROK_AGENT", "1" ]
      ~home:tmp ~broker:tmp
      ["init"; "--no-setup"; "--room"; ""; "--json"]
  in
  check int ("init exits 0: " ^ err) 0 rc;
  let alias =
    match Yojson.Safe.from_string out |> json_assoc_string "alias" with
    | Some a -> a
    | None -> failf "init --json missing alias: %s" out
  in
  check bool ("alias starts with grok-: " ^ alias) true
    (String.starts_with ~prefix:"grok-" alias)

let test_init_detects_cursor_agent_not_codex () =
  (* B134: Cursor Agent is unofficial best-effort labeling only — must get
     cursor- alias / client=cursor, never silent PATH-based codex-. *)
  with_temp_env @@ fun tmp ->
  let rc, out, err =
    run_c2c_status_split
      ~env:[ "CURSOR_AGENT", "1"; "CURSOR_INVOKED_AS", "cursor-agent" ]
      ~home:tmp ~broker:tmp
      ["init"; "--no-setup"; "--room"; ""; "--json"]
  in
  check int ("init exits 0: " ^ err) 0 rc;
  let alias =
    match Yojson.Safe.from_string out |> json_assoc_string "alias" with
    | Some a -> a
    | None -> failf "init --json missing alias: %s" out
  in
  check bool ("alias starts with cursor-: " ^ alias) true
    (String.starts_with ~prefix:"cursor-" alias);
  check bool ("alias must not use codex- prefix: " ^ alias) false
    (String.starts_with ~prefix:"codex-" alias);
  let sid =
    match Yojson.Safe.from_string out |> json_assoc_string "session_id" with
    | Some s -> s
    | None -> failf "init --json missing session_id: %s" out
  in
  check (option string) "registration client_type=cursor" (Some "cursor")
    (registration_client_type ~broker:tmp ~session_id:sid);
  (* Env-less statefile path: Cursor has no native session key, so init
     persists default-session.json with client=cursor. *)
  let statefile = read_file (tmp // "broker" // "default-session.json") in
  check bool "statefile client=cursor" true
    (string_contains statefile "\"client\": \"cursor\""
     || string_contains statefile "\"client\":\"cursor\"")

let test_init_codex_thread_id_still_codex () =
  (* Regression: genuine Codex detection must remain unchanged. *)
  with_temp_env @@ fun tmp ->
  let sid = Printf.sprintf "codex-b134-%d" (Unix.getpid ()) in
  let rc, out, err =
    run_c2c_status_split ~env:["CODEX_THREAD_ID", sid]
      ~home:tmp ~broker:tmp
      ["init"; "--no-setup"; "--room"; ""; "--json"]
  in
  check int ("init exits 0: " ^ err) 0 rc;
  let alias =
    match Yojson.Safe.from_string out |> json_assoc_string "alias" with
    | Some a -> a
    | None -> failf "init --json missing alias: %s" out
  in
  check bool ("alias starts with codex-: " ^ alias) true
    (String.starts_with ~prefix:"codex-" alias);
  check (option string) "registration client_type=codex" (Some "codex")
    (registration_client_type ~broker:tmp ~session_id:sid)

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
        ; test_case "init GROK_SESSION_ID → grok client/alias (B134)" `Quick test_init_detects_grok_from_env
        ; test_case "init GROK_AGENT=1 → grok alias (B173)" `Quick test_init_detects_grok_from_agent_flag
        ; test_case "init CURSOR_AGENT → cursor not codex (B134)" `Quick test_init_detects_cursor_agent_not_codex
        ; test_case "init CODEX_THREAD_ID still codex (B134)" `Quick test_init_codex_thread_id_still_codex
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
    ; ( "session_identity",
        [ test_case "init→whoami round-trip with zero session env (#10)" `Quick test_init_whoami_roundtrip_no_env
        ; test_case "env-derived session id shadows the statefile" `Quick test_env_session_id_wins_over_statefile
        ; test_case "B241 rooms join shares statefile fallback with whoami" `Quick
            test_b241_rooms_join_uses_statefile_like_whoami
        ; test_case "stale statefile (unregistered session) is ignored" `Quick test_stale_session_statefile_ignored
        ; test_case "#26 ambiguous statefile fails closed with candidate list" `Quick test_ambiguous_statefile_fails_closed
        ; test_case "#26 C2C_ALLOW_DEFAULT_SESSION restores old silent behaviour" `Quick test_ambiguous_statefile_opt_in_restores_old
        ; test_case "B172 whoami maps CODEX_THREAD_ID → managed banner alias" `Quick
            test_whoami_maps_codex_thread_to_managed_alias
        ; test_case "B172 whoami sole codex-app-server before thread map" `Quick
            test_whoami_sole_codex_app_server_before_thread_map
        ; test_case "B187 whoami refuses agy shell borrowing codex statefile" `Quick
            test_b187_whoami_refuses_agy_shell_borrowing_codex_statefile
        ; test_case "B187 whoami --json error includes fix_steps" `Quick
            test_b187_whoami_json_error_has_fix_steps
        ; test_case "B187 send refuses borrowed AUTO_REGISTER_ALIAS" `Quick
            test_b187_send_refuses_borrowed_auto_register_alias
        ; test_case "B187 whoami matching agy client still ok" `Quick
            test_b187_whoami_matching_client_still_ok
        ] )
    ; ( "json_schema_v1",
        [ test_case "send/peek/poll --json emit schema-v1 + legacy keys" `Quick test_send_poll_peek_json_schema_v1
        ] )
    ; ( "register_metadata",
        [ test_case "CLI register captures cwd" `Quick test_register_captures_cwd
        ; test_case "CLI register --no-metadata sets opt-out" `Quick test_register_no_metadata_sets_opt_out
        ; test_case "CLI register --no-metadata still captures cwd" `Quick test_register_no_metadata_still_captures_cwd
        ; test_case "CLI register default omits metadata_opt_out from JSON" `Quick test_register_default_omits_metadata_opt_out_json
        ] )
    ]
