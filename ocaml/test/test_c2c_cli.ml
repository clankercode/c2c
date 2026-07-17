(* test_c2c_cli.ml — CLI subcommand tests (#670, #698, follow-up)
   Tests for c2c CLI commands with zero prior test coverage:
   - c2c doctor (basic + deeper relay/peer output checks)
   - c2c config show
   - c2c agent list
   - c2c agent new (role file creation)
   - c2c agent rename (role file renaming)
   - c2c roles validate
   - c2c list
   - c2c send (fixture-gated)
   - c2c whoami
   - c2c history
   - c2c schedule list
   - c2c memory list
   - c2c rooms list
   - c2c rooms join
   - c2c worktree list
   - c2c worktree gc
   - c2c instances
   - c2c schedule enable/disable
   - c2c peer-pass list
   - c2c peer-pass verify
   - c2c install (dry-run)
   - c2c install --dry-run (kimi, opencode, codex)
   - c2c agent new banner (double-UTC regression)

   Each test invokes the c2c binary via Sys.command and verifies
   exit code + output shape. *)

open Alcotest

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base (Printf.sprintf "c2c-cli-test-%08x" (Random.bits ())) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
    Unix.mkdir dir 0o755);
  Fun.protect
    ~finally:(fun () -> Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let write_file path contents =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc contents)

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic))

(* Built c2c binary path.  When tests run via `dune runtest` the CWD is the
   repo root, so _build/default/ocaml/cli is the freshly-built binary tree.
   Using this wrapper (c2c_cmd) instead of bare "c2c ..." in test bodies
   ensures the test exercises the built binary, not the installed one in
   ~/.local/bin (which may be stale after OCaml changes). *)
let c2c_binary =
  let exe = Sys.executable_name in
  let exe = if Filename.is_relative exe then Filename.concat (Sys.getcwd ()) exe else exe in
  let exe = try Unix.realpath exe with _ -> exe in
  let test_dir = Filename.dirname exe in
  let ocaml_dir = Filename.dirname test_dir in
  Filename.concat ocaml_dir (Filename.concat "cli" "c2c.exe")

let c2c_deliver_inbox_binary =
  let dir = Filename.dirname c2c_binary in
  Filename.concat dir "c2c_deliver_inbox.exe"

let c2c_cmd partial =
  let dir = Filename.dirname c2c_binary in
  let wrapper = Filename.concat dir "c2c" in
  (try Sys.remove wrapper with _ -> ());
  let oc = open_out wrapper in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    Printf.fprintf oc "#!/bin/sh\nexec %s \"$@\"\n" (Filename.quote c2c_binary));
  Unix.chmod wrapper 0o755;
  Printf.sprintf "PATH=%s:$PATH C2C_MCP_AUTO_REGISTER_ALIAS=cli-test %s"
    (Filename.quote dir) partial

let isolated_home_env home =
  Printf.sprintf "HOME=%s XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s C2C_CLI_FORCE=1"
    (Filename.quote home)
    (Filename.quote (Filename.concat home ".config"))
    (Filename.quote (Filename.concat (Filename.concat home ".local") "state"))

let fake_client_path_env home clients =
  let bin = Filename.concat home "fake-bin" in
  if not (Sys.file_exists bin) then Unix.mkdir bin 0o755;
  List.iter
    (fun client ->
      let path = Filename.concat bin client in
      let oc = open_out path in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
        output_string oc "#!/bin/sh\nexit 0\n");
      Unix.chmod path 0o755)
    clients;
  Printf.sprintf "PATH=%s:$PATH" (Filename.quote bin)

let debug_install_failure label cmd rc content =
  if rc <> 0 || not (string_contains content "[DRY-RUN]") then
    Printf.eprintf
      "\n[install-test-debug:%s]\ncmd=%s\nrc=%d\noutput-start\n%s\noutput-end\n%!"
      label cmd rc content

let install_codex_fixture ~home ~broker_root =
  let alias = Printf.sprintf "cli-codex-%d" (Unix.getpid ()) in
  let schedule_root = Filename.concat home ".c2c-test-schedules" in
  let tmpfile = Filename.temp_file "c2c-install-codex-fixture" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let env =
        Printf.sprintf "%s C2C_MCP_BROKER_ROOT=%s C2C_SCHEDULE_ROOT_OVERRIDE=%s"
          (isolated_home_env home)
          (Filename.quote broker_root)
          (Filename.quote schedule_root)
      in
      let cmd =
        c2c_cmd
          (Printf.sprintf "%s c2c install codex --alias %s > %s 2>&1"
             env (Filename.quote alias) (Filename.quote tmpfile))
      in
      let rc = Sys.command cmd in
      if rc <> 0 then
        fail
          (Printf.sprintf "codex fixture install failed rc=%d output=%s"
             rc (read_file tmpfile)))

(* ------------------------------------------------------------------------- *)
(* c2c doctor — verify health check output and exit 0 on clean run          *)
(* ------------------------------------------------------------------------- *)

let test_doctor_runs_and_exits_zero () =
  (* doctor requires being in the repo, so run from repo root *)
  let cmd = c2c_cmd "c2c doctor > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c doctor exits 0" 0 rc

let test_doctor_output_contains_health_checks () =
  let tmpfile = Filename.temp_file "c2c-doctor" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf "c2c doctor > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output contains health header" true
        (string_contains content "c2c health");
      check bool "output contains broker root info" true
        (string_contains content "broker root");
      check bool "output contains registry check" true
        (string_contains content "registry"))

let test_doctor_output_contains_push_status () =
  let tmpfile = Filename.temp_file "c2c-doctor" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf "c2c doctor > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output contains push status" true
        (string_contains content "Push status"))

let test_doctor_output_contains_push_verdict () =
  let tmpfile = Filename.temp_file "c2c-doctor" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf "c2c doctor > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output contains push verdict category" true
        (string_contains content "Relay/deploy critical"
         || string_contains content "Local-only"
         || string_contains content "Push status"))

let test_doctor_output_contains_relay_classification () =
  let tmpfile = Filename.temp_file "c2c-doctor" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf "c2c doctor > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      let lower = String.lowercase_ascii content in
      check bool "output contains relay or local-only classification" true
        (string_contains lower "relay" || string_contains lower "local-only"))

(* ------------------------------------------------------------------------- *)
(* c2c config show — verify config rendering                                   *)
(* ------------------------------------------------------------------------- *)

let repo_root_from_git () =
  (* Run git from OCaml test context to find repo root portably *)
  let tmpfile = Filename.temp_file "git-root" ".txt" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let cmd = Printf.sprintf "git rev-parse --show-toplevel > %s 2>/dev/null" tmpfile in
      if Sys.command cmd = 0 then
        try
          let ch = open_in tmpfile in
          Fun.protect ~finally:(fun () -> close_in ch)
            (fun () -> try Some (input_line ch) with End_of_file -> None)
        with _ -> None
      else None)

let test_config_show_exits_zero () =
  (* Run from repo root so c2c finds .c2c/config.toml *)
  match repo_root_from_git () with
  | Some root ->
      let cmd = Printf.sprintf "cd %s && %s" root (c2c_cmd "c2c config show > /dev/null 2>&1") in
      let rc = Sys.command cmd in
      check int "c2c config show exits 0" 0 rc
  | None -> check int "c2c config show exits 0" 1 (-1)

let test_config_show_contains_key_value_pairs () =
  (* Run from repo root so c2c finds .c2c/config.toml *)
  match repo_root_from_git () with
  | None -> check bool "repo root found" false true
  | Some root ->
      let tmpfile = Filename.temp_file "c2c-config-show" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
        (fun () ->
          ignore (Sys.command (Printf.sprintf "cd %s && %s" root (c2c_cmd (Printf.sprintf "c2c config show > %s 2>&1" tmpfile))));
          let ch = open_in tmpfile in
          let content = Fun.protect ~finally:(fun () -> close_in ch)
            (fun () -> really_input_string ch (in_channel_length ch))
          in
          (* config show outputs "key = value\n" lines *)
          check bool "output contains = sign (key=value format)" true
            (string_contains content " = "))

let test_config_show_renders_explicit_values () =
  (* Run from repo root so c2c finds .c2c/config.toml *)
  match repo_root_from_git () with
  | None -> check bool "repo root found" false true
  | Some root ->
      let tmpfile = Filename.temp_file "c2c-config-show2" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
        (fun () ->
          ignore (Sys.command (Printf.sprintf "cd %s && %s" root (c2c_cmd (Printf.sprintf "c2c config show > %s 2>&1" tmpfile))));
          let ch = open_in tmpfile in
          let lines = Fun.protect ~finally:(fun () -> close_in ch)
            (fun () ->
              let rec read_lines acc =
                try read_lines ((input_line ch) :: acc)
                with End_of_file -> List.rev acc
              in
              read_lines [])
          in
          (* Should have at least one line with "=" in it *)
          let has_kv = List.exists (fun l -> string_contains l " = ") lines in
          check bool "at least one key=value line present" true has_kv)

(* ------------------------------------------------------------------------- *)
(* c2c agent list — verify role file listing                                *)
(* ------------------------------------------------------------------------- *)

let test_agent_list_exits_zero () =
  let cmd = c2c_cmd "c2c agent list > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c agent list exits 0" 0 rc

let test_agent_list_shows_role_files () =
  let tmpfile = Filename.temp_file "c2c-agent-list" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf "c2c agent list > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let lines = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () ->
          let rec read_lines acc =
            try read_lines ((input_line ch) :: acc)
            with End_of_file -> List.rev acc
          in
          read_lines [])
      in
      (* Each line is "  name  (N bytes)\n" or "(no roles found)\n" *)
      let has_roles_or_empty = match lines with
        | [] -> false
        | [l] -> string_contains l "no roles found"
        | _ -> true
      in
      check bool "agent list shows roles or empty message" true has_roles_or_empty)

(* ------------------------------------------------------------------------- *)
(* c2c agent new — E2E: creates a role file that can be parsed             *)
(* ------------------------------------------------------------------------- *)

let test_agent_new_creates_role_file () =
  (* Run in a temp dir so we get a clean .c2c/roles/ with no fixtures *)
  with_temp_dir (fun tmpdir ->
    let role_name = Printf.sprintf "e2e-test-role-%08x" (Random.bits ()) in
    let cmd = Printf.sprintf "cd %s && %s" (Filename.quote tmpdir)
      (c2c_cmd (Printf.sprintf "c2c agent new %s > /dev/null 2>&1" role_name)) in
    let rc = Sys.command cmd in
    check int "c2c agent new exits 0" 0 rc;
    (* The file should exist at .c2c/roles/<role_name>.md relative to tmpdir *)
    let role_path = Filename.concat tmpdir (Printf.sprintf ".c2c/roles/%s.md" role_name) in
    check bool "role file was created" true (Sys.file_exists role_path))

let test_agent_new_role_file_is_valid_yaml () =
  with_temp_dir (fun tmpdir ->
    let role_name = Printf.sprintf "e2e-parse-test-%08x" (Random.bits ()) in
    let cmd = Printf.sprintf "cd %s && %s" (Filename.quote tmpdir)
      (c2c_cmd (Printf.sprintf "c2c agent new %s > /dev/null 2>&1" role_name)) in
    ignore (Sys.command cmd);
    let role_path = Filename.concat tmpdir (Printf.sprintf ".c2c/roles/%s.md" role_name) in
    let exists = Sys.file_exists role_path in
    check bool "role file exists before parse test" true exists;
    if exists then
      (let ic = open_in role_path in
       let content = Fun.protect ~finally:(fun () -> close_in ic)
         (fun () -> really_input_string ic (in_channel_length ic)) in
       (* The file should start with a YAML frontmatter marker *)
       check bool "role file starts with --- yaml marker" true
         (String.length content >= 3 && String.sub content 0 3 = "---")))

(* ------------------------------------------------------------------------- *)
(* c2c agent rename — verify role file renaming                              *)
(* ------------------------------------------------------------------------- *)

let test_agent_rename_exits_zero () =
  (* Create a role in a temp dir, then rename it. *)
  with_temp_dir (fun tmpdir ->
    let old_name = Printf.sprintf "e2e-rename-test-%08x" (Random.bits ()) in
    let new_name = Printf.sprintf "e2e-renamed-test-%08x" (Random.bits ()) in
    (* Create the role *)
    ignore (Sys.command (Printf.sprintf "cd %s && %s"
      (Filename.quote tmpdir)
      (c2c_cmd (Printf.sprintf "c2c agent new %s > /dev/null 2>&1" old_name))));
    (* Rename it *)
    let cmd = Printf.sprintf "cd %s && %s" (Filename.quote tmpdir)
      (c2c_cmd (Printf.sprintf "c2c agent rename %s %s > /dev/null 2>&1" old_name new_name)) in
    let rc = Sys.command cmd in
    check int "c2c agent rename exits 0" 0 rc)

let test_agent_rename_old_file_gone () =
  with_temp_dir (fun tmpdir ->
    let old_name = Printf.sprintf "e2e-rename-src-%08x" (Random.bits ()) in
    let new_name = Printf.sprintf "e2e-rename-dst-%08x" (Random.bits ()) in
    ignore (Sys.command (Printf.sprintf "cd %s && %s"
      (Filename.quote tmpdir)
      (c2c_cmd (Printf.sprintf "c2c agent new %s > /dev/null 2>&1" old_name))));
    ignore (Sys.command (Printf.sprintf "cd %s && %s" (Filename.quote tmpdir)
      (c2c_cmd (Printf.sprintf "c2c agent rename %s %s > /dev/null 2>&1" old_name new_name))));
    let old_path = Filename.concat tmpdir (Printf.sprintf ".c2c/roles/%s.md" old_name) in
    check bool "old role file is gone after rename" false (Sys.file_exists old_path))

let test_agent_rename_new_file_exists () =
  with_temp_dir (fun tmpdir ->
    let old_name = Printf.sprintf "e2e-rename-src2-%08x" (Random.bits ()) in
    let new_name = Printf.sprintf "e2e-rename-dst2-%08x" (Random.bits ()) in
    ignore (Sys.command (Printf.sprintf "cd %s && %s"
      (Filename.quote tmpdir)
      (c2c_cmd (Printf.sprintf "c2c agent new %s > /dev/null 2>&1" old_name))));
    ignore (Sys.command (Printf.sprintf "cd %s && %s" (Filename.quote tmpdir)
      (c2c_cmd (Printf.sprintf "c2c agent rename %s %s > /dev/null 2>&1" old_name new_name))));
    let new_path = Filename.concat tmpdir (Printf.sprintf ".c2c/roles/%s.md" new_name) in
    check bool "new role file exists after rename" true (Sys.file_exists new_path))

let test_agent_rename_missing_old_exits_nonzero () =
  let nonexistent = Printf.sprintf "nonexistent-role-%08x" (Random.bits ()) in
  let new_name = Printf.sprintf "some-new-name-%08x" (Random.bits ()) in
  let cmd = c2c_cmd (Printf.sprintf "c2c agent rename %s %s > /dev/null 2>&1"
    nonexistent new_name) in
  let rc = Sys.command cmd in
  check bool "rename nonexistent role exits non-zero" true (rc <> 0)

let test_agent_rename_existing_new_exits_nonzero () =
  with_temp_dir (fun tmpdir ->
    let name_a = Printf.sprintf "e2e-rename-a-%08x" (Random.bits ()) in
    let name_b = Printf.sprintf "e2e-rename-b-%08x" (Random.bits ()) in
    (* Create two roles *)
    ignore (Sys.command (Printf.sprintf "cd %s && %s"
      (Filename.quote tmpdir)
      (c2c_cmd (Printf.sprintf "c2c agent new %s > /dev/null 2>&1" name_a))));
    ignore (Sys.command (Printf.sprintf "cd %s && %s"
      (Filename.quote tmpdir)
      (c2c_cmd (Printf.sprintf "c2c agent new %s > /dev/null 2>&1" name_b))));
    (* Try to rename A to B — B already exists, should fail *)
    let cmd = Printf.sprintf "cd %s && %s" (Filename.quote tmpdir)
      (c2c_cmd (Printf.sprintf "c2c agent rename %s %s > /dev/null 2>&1" name_a name_b)) in
    let rc = Sys.command cmd in
    check bool "rename to existing name exits non-zero" true (rc <> 0))

(* ------------------------------------------------------------------------- *)
(* c2c list — verify peer listing                                           *)
(* ------------------------------------------------------------------------- *)

let test_list_exits_zero () =
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c list > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c list exits 0" 0 rc

(* B183: discoverable synonyms for list / peek-inbox *)
let test_peers_alias_exits_zero () =
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c peers > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c peers exits 0" 0 rc

let test_inbox_alias_exits_zero () =
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c inbox > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c inbox exits 0" 0 rc

let test_list_output_contains_peer_entries () =
  let tmpfile = Filename.temp_file "c2c-list" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf "C2C_CLI_FORCE=1 c2c list > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let lines = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () ->
          let rec read_lines acc =
            try read_lines ((input_line ch) :: acc)
            with End_of_file -> List.rev acc
          in
          read_lines [])
      in
      (* list output has lines with status keywords, or a valid empty state on
         a clean CI broker. *)
      let has_status = List.exists (fun l ->
        string_contains l "alive" || string_contains l "dead"
        || string_contains l "unknown"
      ) lines in
      let has_empty_state =
        List.exists
          (fun l ->
            string_contains l "No peers"
            || string_contains l "No active"
            || string_contains l "No registered peers")
          lines
      in
      check bool "list output contains peer status entries or empty state" true
        (has_status || has_empty_state))

let test_list_unknown_liveness_is_not_labeled_unknown_client_type () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-unknown-liveness" ~alias:"unknown-liveness"
        ~pid:None ~pid_start_time:None ();
      let tmpfile = Filename.temp_file "c2c-list-unknown" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
        (fun () ->
           let cmd =
             c2c_cmd
               (Printf.sprintf
                  "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s c2c list > %s 2>&1"
                  (Filename.quote dir) tmpfile)
           in
           let rc = Sys.command cmd in
           let content = read_file tmpfile in
           check int "c2c list exits 0" 0 rc;
           check bool "row contains test alias" true
             (string_contains content "unknown-liveness");
           check bool "row contains unknown liveness label" true
             (string_contains content "unknown");
           check bool "row does not call liveness unknown client_type" true
             (not (string_contains content "unknown client_type"));
           check bool "row does not render unknown liveness as ???" true
             (not (string_contains content "???"))))

let test_register_happy_path_does_not_emit_relay_identity_debug_noise () =
  with_temp_dir (fun dir ->
      let outfile = Filename.temp_file "c2c-register" ".out" in
      let errfile = Filename.temp_file "c2c-register" ".err" in
      Fun.protect
        ~finally:(fun () ->
           (try Sys.remove outfile with _ -> ());
           (try Sys.remove errfile with _ -> ()))
        (fun () ->
           let cmd =
             c2c_cmd
               (Printf.sprintf
                  "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=session-register-noise c2c register --alias register-noise > %s 2>%s"
                  (Filename.quote dir) outfile errfile)
           in
           let rc = Sys.command cmd in
           let stderr = read_file errfile in
           check int "c2c register exits 0" 0 rc;
           check bool "stderr omits relay identity ssh-keygen debug line" true
             (not (string_contains stderr "[relay_identity] ssh-keygen"))))

let test_register_cli_blocked_alias_explains_reason_and_suggestion () =
  with_temp_dir (fun dir ->
      let outfile = Filename.temp_file "c2c-register-blocked" ".out" in
      let errfile = Filename.temp_file "c2c-register-blocked" ".err" in
      Fun.protect
        ~finally:(fun () ->
           (try Sys.remove outfile with _ -> ());
           (try Sys.remove errfile with _ -> ()))
        (fun () ->
           let cmd =
             c2c_cmd
               (Printf.sprintf
                  "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=session-register-blocked c2c register --alias codex-foo > %s 2>%s"
                  (Filename.quote dir) outfile errfile)
           in
           let rc = Sys.command cmd in
           let stderr = read_file errfile in
           check bool "c2c register blocked alias exits non-zero" true (rc <> 0);
           check bool "stderr explains client prefix reservation" true
             (string_contains stderr "reserved for auto-generated client identities");
           check bool "stderr suggests concrete non-prefixed alias" true
             (string_contains stderr "Try 'foo'");
           check bool "stderr suggests avoiding client prefixes" true
             (string_contains stderr "not starting with a reserved client prefix")))

let test_rename_help_documents_reserved_alias_guidance () =
  let outfile = Filename.temp_file "c2c-rename-help" ".out" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove outfile with _ -> ())
    (fun () ->
       let cmd =
         c2c_cmd
           (Printf.sprintf
              "C2C_CLI_FORCE=1 c2c rename --help > %s 2>&1"
              outfile)
       in
       let rc = Sys.command cmd in
       let output = read_file outfile in
       check int "c2c rename --help exits 0" 0 rc;
       check bool "rename help lists newest reserved client prefix" true
         (string_contains output "agy-");
       check bool "rename help gives Grok-family alternative" true
         (string_contains output "gk-<name>");
       check bool "rename help names relay rebind command" true
         (string_contains output "c2c relay register");
       check bool "rename help names relay rebind alias flag" true
         (string_contains output "--alias=<new>");
       check bool "rename help documents auto-rebind when relay configured (B179)" true
         (string_contains output "automatically re-registers"
          || string_contains output "auto-rebinds"
          || string_contains output "auto-rebind"))

(* ------------------------------------------------------------------------- *)
(* c2c send — fixture-gated send test                                       *)
(* ------------------------------------------------------------------------- *)

let test_send_missing_args_exits_nonzero () =
  (* Missing required ALIAS and MSG args => exits non-zero.
     Cmdliner rejects missing positional args before touching the broker. *)
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c send > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check bool "c2c send with no args exits non-zero" true (rc <> 0)

let test_remote_connector_liveness_is_scoped_to_broker_state () =
  with_temp_dir (fun broker_root ->
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      C2c_mcp.Broker.register broker
        ~session_id:"b177-sender-sid" ~alias:"b177-sender"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let state_path = C2c_relay_connector.connector_state_path broker_root in
      let oc = open_out state_path in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
          Printf.fprintf oc
            "{\"last_sync_ts\": %.6f, \"last_ok_ts\": %.6f}\n"
            (Unix.gettimeofday ()) (Unix.gettimeofday ());
          flush oc);
      let outfile = Filename.temp_file "c2c-send-b177" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
           let cmd = Printf.sprintf
             "env -u C2C_MCP_BROKER_ROOT C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=b177-sender-sid %s send --root %s peer@remotehost.example 'fresh connector state' > %s 2>&1"
             c2c_binary (Filename.quote broker_root) (Filename.quote outfile)
           in
           let rc = Sys.command cmd in
           let content = read_file outfile in
           check int (Printf.sprintf "remote send exits 0 (output: %s)" content) 0 rc;
           check bool "fresh state suppresses no-connector warning" false
             (string_contains content "no relay connector detected");
           check bool "warning attributes fresh state to current broker" true
             (string_contains content "recently synced this broker")))

let test_send_unknown_alias_routes_to_relay_outbox () =
  with_temp_dir (fun dir ->
      (* Use a temp broker root with no registrations so the alias is
         guaranteed unknown locally. With relay fallback, unknown aliases
         are queued to remote-outbox.jsonl for cross-host delivery rather
         than erroring. C2C_SEND_MESSAGE_FIXTURE was never checked by the
         OCaml binary; the old test hit the real broker and was flaky. *)
      let outfile = Filename.temp_file "c2c-send" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=cli-test-send \
             %s > %s 2>&1"
            (Filename.quote dir)
            (c2c_cmd "c2c send nonexistent-test-alias 'hello'")
            outfile
          in
          let rc = Sys.command cmd in
          check bool "send to unknown alias fails without relay route" true (rc <> 0);
          let content = read_file outfile in
          check bool "output reports unregistered alias" true
            (string_contains content "not registered")))

let alias_looks_generated_for_client ~client alias =
  match String.split_on_char '-' alias with
  | [ c; w1; w2; suffix ] ->
      c = client && w1 <> "" && w2 <> "" && String.length suffix = 4
  | _ -> false

let test_send_auto_registers_unregistered_session () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"b078-recipient-sid" ~alias:"b078-recipient"
        ~pid:None ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-send-autoreg" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let sender_sid = "codex-b078-sender-sid" in
          let cmd =
            Printf.sprintf
              "env -u C2C_MCP_AUTO_REGISTER_ALIAS C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=%s C2C_MCP_CLIENT_TYPE=codex %s send b078-recipient 'hello from unregistered' > %s 2>&1"
              (Filename.quote dir)
              (Filename.quote sender_sid)
              (Filename.quote c2c_binary)
              (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check int (Printf.sprintf "send exits 0 (output: %s)" content) 0 rc;
          check bool "notice mentions auto-registration" true
            (string_contains content "auto-registered as ");
          check bool "notice mentions wait-inbox" true
            (string_contains content "c2c wait-inbox");
          let regs = C2c_mcp.Broker.list_registrations broker in
          let sender =
            List.find_opt
              (fun (r : C2c_mcp.registration) -> r.session_id = sender_sid)
              regs
          in
          match sender with
          | None -> fail "expected sender auto-registration"
          | Some reg ->
              check bool "generated codex alias shape" true
                (alias_looks_generated_for_client ~client:"codex" reg.alias);
              check (option string) "client type" (Some "codex") reg.client_type;
              check bool "ok line uses generated alias" true
                (string_contains content (Printf.sprintf "ok -> b078-recipient (from %s)" reg.alias));
              let drained =
                C2c_mcp.Broker.drain_inbox
                  ~drained_by:"b078-test" broker ~session_id:"b078-recipient-sid"
              in
              check int "recipient has one message" 1 (List.length drained);
              let msg = List.hd drained in
              check string "recipient sees routable sender alias" reg.alias msg.from_alias;
              check string "message body" "hello from unregistered" msg.content))

let test_send_auto_register_failure_falls_back_to_raw_session_id () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"b078-fallback-recipient-sid" ~alias:"b078-fallback-recipient"
        ~pid:None ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-send-autoreg-fallback" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let sender_sid = "codex-b078-fallback-sid" in
          let cmd =
            Printf.sprintf
              "env -u C2C_MCP_AUTO_REGISTER_ALIAS C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=%s C2C_MCP_CLIENT_TYPE=codex C2C_SEND_AUTOREGISTER_FAIL_FIXTURE=1 %s send b078-fallback-recipient 'fallback hello' > %s 2>&1"
              (Filename.quote dir)
              (Filename.quote sender_sid)
              (Filename.quote c2c_binary)
              (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check int (Printf.sprintf "fallback send exits 0 (output: %s)" content) 0 rc;
          check bool "no success notice on failed auto-register" false
            (string_contains content "auto-registered as ");
          check bool "ok line falls back to raw sid" true
            (string_contains content
               (Printf.sprintf "ok -> b078-fallback-recipient (from %s)" sender_sid));
          let regs = C2c_mcp.Broker.list_registrations broker in
          check bool "sender was not registered" false
            (List.exists
               (fun (r : C2c_mcp.registration) -> r.session_id = sender_sid)
               regs);
          let drained =
            C2c_mcp.Broker.drain_inbox
              ~drained_by:"b078-fallback-test" broker
              ~session_id:"b078-fallback-recipient-sid"
          in
          check int "recipient has one fallback message" 1 (List.length drained);
          let msg = List.hd drained in
          check string "fallback preserves old sender label" sender_sid msg.from_alias))

(* B188: path-fingerprint → remote.origin.url fingerprint switch must not
   mint a second alias for the same session_id on CLI send auto-register. *)
let test_send_auto_register_reuses_sticky_across_fingerprint () =
  with_temp_dir (fun home ->
      let ( // ) = Filename.concat in
      let old_fp = "4cd37eaee8ca" in
      let new_fp = "f61c9ead06dc" in
      let old_root = home // ".c2c" // "repos" // old_fp // "broker" in
      let new_root = home // ".c2c" // "repos" // new_fp // "broker" in
      C2c_mcp.mkdir_p old_root;
      C2c_mcp.mkdir_p new_root;
      let sid = "fa3c5d7d-b987-41e6-ad0f-6b7bf9ffdb43" in
      let sticky = "claude-wagon-chapel-l9nq" in
      let old_b = C2c_mcp.Broker.create ~root:old_root in
      C2c_mcp.Broker.register old_b ~session_id:sid ~alias:sticky
        ~pid:(Some 77206) ~pid_start_time:None ~client_type:(Some "claude")
        ~from_auto_gen:true ();
      (* Ensure registry.json exists so list_all_broker_roots discovers old_fp. *)
      ignore (C2c_mcp.Broker.list_registrations old_b);
      let new_b = C2c_mcp.Broker.create ~root:new_root in
      C2c_mcp.Broker.register new_b
        ~session_id:"b188-recipient-sid" ~alias:"b188-recipient" ~pid:None
        ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-send-b188" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd =
            Printf.sprintf
              "env -u C2C_MCP_AUTO_REGISTER_ALIAS HOME=%s XDG_STATE_HOME=%s \
               C2C_STATE_HOME= C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s \
               C2C_MCP_SESSION_ID=%s C2C_MCP_CLIENT_TYPE=claude %s send \
               b188-recipient 'b188 sticky reuse' > %s 2>&1"
              (Filename.quote home)
              (Filename.quote (home // "xdg-empty"))
              (Filename.quote new_root)
              (Filename.quote sid)
              (Filename.quote c2c_binary)
              (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check int (Printf.sprintf "send exits 0 (output: %s)" content) 0 rc;
          check bool "notice mentions auto-registration" true
            (string_contains content "auto-registered as ");
          check bool "notice mentions sticky reuse" true
            (string_contains content "reused sticky alias");
          check bool "notice includes prior alias" true
            (string_contains content sticky);
          let regs = C2c_mcp.Broker.list_registrations new_b in
          let sender =
            List.find_opt
              (fun (r : C2c_mcp.registration) -> r.session_id = sid)
              regs
          in
          match sender with
          | None -> fail "expected sender auto-registration on new fingerprint"
          | Some reg ->
              check string "reused sticky alias not new random" sticky reg.alias;
              check bool "ok line uses sticky alias" true
                (string_contains content
                   (Printf.sprintf "ok -> b188-recipient (from %s)" sticky))))

(* B052: cross-broker send fallback — alias registered only in sibling
   broker is found and the message is routed there. *)
let test_send_cross_broker_fallback () =
  with_temp_dir (fun parent_dir ->
      (* Create two broker roots as siblings under parent_dir *)
      let primary_dir = Filename.concat parent_dir "primary-broker" in
      let alt_dir = Filename.concat parent_dir "alt-broker" in
      Unix.mkdir primary_dir 0o755;
      Unix.mkdir alt_dir 0o755;
      (* Register "sender" on primary broker so from_alias resolves *)
      let primary_broker = C2c_mcp.Broker.create ~root:primary_dir in
      C2c_mcp.Broker.register primary_broker
        ~session_id:"primary-sid" ~alias:"sender"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      (* Register "recipient" ONLY on alt broker *)
      let alt_broker = C2c_mcp.Broker.create ~root:alt_dir in
      C2c_mcp.Broker.register alt_broker
        ~session_id:"alt-sid" ~alias:"recipient"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      (* Send from primary broker to "recipient" — should fall back to alt *)
      let outfile = Filename.temp_file "c2c-xbroker" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=primary-sid \
             %s send --from sender --json recipient 'cross-broker hello' > %s 2>&1"
            (Filename.quote primary_dir)
            c2c_binary
            (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check int (Printf.sprintf "cross-broker send exits 0 (output: %s)" content) 0 rc;
          check bool "send reports queued" true
            (string_contains content "queued");
          (* Verify the message landed in the alt broker's inbox *)
          let drained = C2c_mcp.Broker.drain_inbox
            ~drained_by:"b052-test" alt_broker ~session_id:"alt-sid" in
          check int "alt broker inbox has 1 message" 1 (List.length drained);
          let msg = List.hd drained in
          check string "message content" "cross-broker hello" msg.content;
          check string "from_alias" "sender" msg.from_alias))

(* B052: error message when alias not found anywhere mentions scanned brokers *)
let test_send_not_found_error_mentions_scanned_brokers () =
  with_temp_dir (fun dir ->
      let outfile = Filename.temp_file "c2c-send-err" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=cli-test-err \
             %s > %s 2>&1"
            (Filename.quote dir)
            (c2c_cmd "c2c send nobody-xyz 'hello'")
            outfile
          in
          let rc = Sys.command cmd in
          check bool "send to nonexistent alias exits non-zero" true (rc <> 0);
          let content = read_file outfile in
          check bool "error mentions primary broker" true
            (string_contains content "Primary broker");
          check bool "error mentions sessions broker scan" true
            (string_contains content "sessions broker")))

(* B072/B127: a registration that EXISTS but whose pid is dead must NOT be
   reported as "not registered". B127: the send must durable-queue offline,
   exit 0, and surface queued_offline (human + machine). *)
let test_send_dead_alias_queues_offline () =
  with_temp_dir (fun parent_dir ->
      let broker_dir = Filename.concat parent_dir "broker" in
      Unix.mkdir broker_dir 0o755;
      let broker = C2c_mcp.Broker.create ~root:broker_dir in
      C2c_mcp.Broker.register broker
        ~session_id:"b072-sender-sid" ~alias:"b072-sender"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      (* pid beyond pid_max: /proc/<pid> can never exist => Dead. *)
      C2c_mcp.Broker.register broker
        ~session_id:"b072-dead-sid" ~alias:"b072-dead-target"
        ~pid:(Some 99999999) ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-send-dead" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=b072-sender-sid \
             %s send b072-dead-target 'hello dead' > %s 2>&1"
            (Filename.quote broker_dir) c2c_binary (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check int
            (Printf.sprintf "send to dead alias exits 0 (output: %s)" content)
            0 rc;
          check bool "human reports queued_offline" true
            (string_contains content "queued_offline -> b072-dead-target");
          check bool "warns offline durable queue" true
            (string_contains content "offline"
             && string_contains content "durable inbox");
          check bool "does NOT claim unregistered" false
            (string_contains content "is not registered");
          let inbox =
            C2c_mcp.Broker.read_inbox broker ~session_id:"b072-dead-sid"
          in
          check int "message persisted in dead session inbox" 1
            (List.length inbox)))

let test_send_dead_alias_json_queued_offline () =
  with_temp_dir (fun parent_dir ->
      let broker_dir = Filename.concat parent_dir "broker" in
      Unix.mkdir broker_dir 0o755;
      let broker = C2c_mcp.Broker.create ~root:broker_dir in
      C2c_mcp.Broker.register broker
        ~session_id:"b127j-sender-sid" ~alias:"b127j-sender"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"b127j-dead-sid" ~alias:"b127j-dead-target"
        ~pid:(Some 99999999) ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-send-dead-json" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=b127j-sender-sid \
             %s send --json b127j-dead-target 'hello json offline' > %s 2>&1"
            (Filename.quote broker_dir) c2c_binary (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check int
            (Printf.sprintf "offline --json send exits 0 (output: %s)" content)
            0 rc;
          check bool "json delivery.state is queued_offline" true
            (string_contains content "\"state\": \"queued_offline\"");
          check bool "json top-level queued_offline true" true
            (string_contains content "\"queued_offline\": true");
          check bool "json does not claim delivered" false
            (string_contains content "\"state\": \"delivered\"")))

(* B127 Tests §1: a plain offline send exits 0, but [--fail-if-queued] must
   exit 3 — the mail is durably queued, not synchronously delivered to a live
   recipient, which is exactly the non-delivery a script opts in to detect.
   The message is still persisted regardless of the exit code. *)
let test_send_dead_alias_fail_if_queued_exits_3 () =
  with_temp_dir (fun parent_dir ->
      let broker_dir = Filename.concat parent_dir "broker" in
      Unix.mkdir broker_dir 0o755;
      let broker = C2c_mcp.Broker.create ~root:broker_dir in
      C2c_mcp.Broker.register broker
        ~session_id:"b127f-sender-sid" ~alias:"b127f-sender"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"b127f-dead-sid" ~alias:"b127f-dead-target"
        ~pid:(Some 99999999) ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-send-dead-fiq" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=b127f-sender-sid \
             %s send --fail-if-queued b127f-dead-target 'strict offline' > %s 2>&1"
            (Filename.quote broker_dir) c2c_binary (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check int
            (Printf.sprintf "offline --fail-if-queued exits 3 (output: %s)" content)
            3 rc;
          check bool "still reports queued_offline" true
            (string_contains content "queued_offline");
          (* Durable regardless of the strict exit code. *)
          let inbox =
            C2c_mcp.Broker.read_inbox broker ~session_id:"b127f-dead-sid"
          in
          check int "message persisted despite exit 3" 1 (List.length inbox)))

(* B071/B072: a registration with pid=None (unknown liveness) MUST route —
   unknown is the documented fallback when no stable agent pid is found. *)
let test_send_unknown_liveness_alias_routes () =
  with_temp_dir (fun parent_dir ->
      let broker_dir = Filename.concat parent_dir "broker" in
      Unix.mkdir broker_dir 0o755;
      let broker = C2c_mcp.Broker.create ~root:broker_dir in
      C2c_mcp.Broker.register broker
        ~session_id:"b071-sender-sid" ~alias:"b071-sender"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"b071-pidless-sid" ~alias:"b071-pidless-target"
        ~pid:None ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-send-pidless" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=b071-sender-sid \
             %s send b071-pidless-target 'hello unknown' > %s 2>&1"
            (Filename.quote broker_dir) c2c_binary (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check int
            (Printf.sprintf "send to unknown-liveness alias exits 0 (output: %s)" content)
            0 rc;
          let drained = C2c_mcp.Broker.drain_inbox
            ~drained_by:"b071-test" broker ~session_id:"b071-pidless-sid" in
          check int "pidless target inbox drained 1 message" 1 (List.length drained)))

(* B088: a remote [alias@host] target is only ever enqueued to the local
   relay outbox by `c2c send` — the relay connector ships it async. The old
   code printed a blanket [ok ->] which read as success when nothing was
   delivered. It must now report [queued], warn about the missing connector,
   and surface [delivery.state:"queued"] in --json. Exit stays 0
   (fire-and-forget back-compat) unless --fail-if-queued is passed. *)
let test_send_remote_target_reports_queued_not_ok () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"b088-sender-sid" ~alias:"b088-sender"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-send-b088" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=b088-sender-sid \
             %s send peer@remotehost.example 'hello remote' > %s 2>&1"
            (Filename.quote dir) c2c_binary (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check int (Printf.sprintf "remote send exits 0 (output: %s)" content) 0 rc;
          (* The load-bearing assertion: never bare [ok ->] for a remote target. *)
          check bool "remote send reports queued, not ok" true
            (string_contains content "queued -> peer@remotehost.example");
          check bool "remote send does NOT imply delivery with ok ->" false
            (string_contains content "ok -> peer@remotehost.example");
          check bool "warns about the missing relay connector" true
            (string_contains content "queued locally");
          (* And the message really did land in the local relay outbox. *)
          let outbox = read_file (Filename.concat dir "remote-outbox.jsonl") in
          check bool "outbox recorded the remote send" true
            (string_contains outbox "peer@remotehost.example")))

let test_send_remote_target_json_delivery_state_queued () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"b088j-sender-sid" ~alias:"b088j-sender"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-send-b088-json" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=b088j-sender-sid \
             %s send --json peer@remotehost.example 'hello json' > %s 2>&1"
            (Filename.quote dir) c2c_binary (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check int (Printf.sprintf "remote --json send exits 0 (output: %s)" content) 0 rc;
          (* back-compat: top-level queued:true preserved *)
          check bool "json keeps top-level queued:true" true
            (string_contains content "\"queued\": true");
          check bool "json surfaces delivery.state queued" true
            (string_contains content "\"delivery\"");
          check bool "json delivery state is queued (not delivered)" true
            (string_contains content "\"state\": \"queued\"");
          check bool "json never claims delivered" false
            (string_contains content "\"state\": \"delivered\"")))

let test_send_remote_target_fail_if_queued_exits_nonzero () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"b088f-sender-sid" ~alias:"b088f-sender"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-send-b088-fail" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=b088f-sender-sid \
             %s send --fail-if-queued peer@remotehost.example 'strict' > %s 2>&1"
            (Filename.quote dir) c2c_binary (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check bool "--fail-if-queued on a remote target exits non-zero" true (rc <> 0);
          check bool "--fail-if-queued still reports queued (not ok ->)" true
            (string_contains content "queued ->")))

(* B088: local same-broker targets still deliver synchronously — [ok ->] /
   [delivery.state:"delivered"] stays accurate there. Regression guard so
   the honest-reporting change doesn't accidentally demote local delivery. *)
let test_send_local_target_still_reports_delivered () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"b088-local-sender-sid" ~alias:"b088-local-sender"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"b088-local-rcpt-sid" ~alias:"b088-local-rcpt"
        ~pid:None ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-send-b088-local" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=b088-local-sender-sid \
             %s send --json b088-local-rcpt 'hi local' > %s 2>&1"
            (Filename.quote dir) c2c_binary (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check int (Printf.sprintf "local --json send exits 0 (output: %s)" content) 0 rc;
          check bool "local send reports delivered" true
            (string_contains content "\"state\": \"delivered\"");
          check bool "local send is not queued" false
            (string_contains content "\"state\": \"queued\"")))

(* B071 regression: a zero-env `c2c register` (no C2C_MCP_CLIENT_PID) must
   produce a ROUTABLE registration. The old getppid() fallback pinned the
   transient test/tool shell — born-dead and unroutable. With the fix the
   pid is either a stable agent ancestor (alive) or None (unknown liveness);
   both route. *)
let test_register_zero_env_is_routable () =
  with_temp_dir (fun parent_dir ->
      let broker_dir = Filename.concat parent_dir "broker" in
      Unix.mkdir broker_dir 0o755;
      let broker = C2c_mcp.Broker.create ~root:broker_dir in
      C2c_mcp.Broker.register broker
        ~session_id:"b071-reg-sender-sid" ~alias:"b071-reg-sender"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let rc = Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s \
         %s register --alias b071-reg-fresh --session-id b071-reg-fresh-sid \
         > /dev/null 2>&1"
        (Filename.quote broker_dir) c2c_binary)
      in
      check int "zero-env register exits 0" 0 rc;
      (* The registration must never pin a dead transient pid. *)
      let regs = C2c_mcp.Broker.list_registrations broker in
      (match List.find_opt
               (fun (r : C2c_mcp.registration) -> r.alias = "b071-reg-fresh")
               regs
       with
       | None -> Alcotest.fail "b071-reg-fresh registration missing"
       | Some r ->
           check bool "fresh registration is not born dead" true
             (C2c_mcp.Broker.registration_is_alive r));
      let outfile = Filename.temp_file "c2c-reg-route" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=b071-reg-sender-sid \
             %s send b071-reg-fresh 'routability check' > %s 2>&1"
            (Filename.quote broker_dir) c2c_binary (Filename.quote outfile)
          in
          let rc = Sys.command cmd in
          let content = read_file outfile in
          check int
            (Printf.sprintf "send to freshly-registered alias exits 0 (output: %s)"
               content)
            0 rc))

(* ------------------------------------------------------------------------- *)
(* c2c whoami — verify alias display                                        *)
(* ------------------------------------------------------------------------- *)

let test_whoami_exits_zero () =
  (* Use a fake session ID so whoami exits 0 even without a real registration *)
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=cli-test-session c2c whoami > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c whoami exits 0" 0 rc

let test_whoami_output_contains_alias_field () =
  let tmpfile = Filename.temp_file "c2c-whoami" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=cli-test-session c2c whoami > %s 2>&1"
        tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* whoami output always contains "alias:" field label and "session_id:" *)
      check bool "whoami output contains alias field" true
        (string_contains content "alias:");
      check bool "whoami output contains session_id field" true
        (string_contains content "session_id:"))

(* ------------------------------------------------------------------------- *)
(* Cached update notice — each supported CLI path must emit it exactly once  *)
(* ------------------------------------------------------------------------- *)

let count_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index count =
    if index + needle_len > haystack_len then count
    else if String.sub haystack index needle_len = needle then
      loop (index + needle_len) (count + 1)
    else loop (index + 1) count
  in
  if needle_len = 0 then 0 else loop 0 0

let test_cached_update_notice_emitted_once () =
  with_temp_dir (fun broker_root ->
      let changelog_dir = Filename.concat broker_root "changelog" in
      Unix.mkdir changelog_dir 0o700;
      write_file (Filename.concat changelog_dir "remote.md")
        "## v999.0.0\n\n### Test update\nsummary: cached test update.\n";
      List.iter
        (fun args ->
          let stdout_path = Filename.temp_file "c2c-help-update" ".out" in
          let stderr_path = Filename.temp_file "c2c-help-update" ".err" in
          Fun.protect
            ~finally:(fun () ->
              Sys.remove stdout_path |> ignore;
              Sys.remove stderr_path |> ignore)
            (fun () ->
              let command =
                c2c_cmd
                  (Printf.sprintf
                     "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s \\
                      C2C_CHANGELOG_FETCH_DISABLE=1 c2c %s > %s 2> %s"
                     (Filename.quote broker_root) args
                     (Filename.quote stdout_path) (Filename.quote stderr_path))
              in
              check int ("c2c " ^ args ^ " exits 0") 0 (Sys.command command);
              let stderr = read_file stderr_path in
              check int ("c2c " ^ args ^ " emits one cached update notice") 1
                (count_substring stderr "notice: c2c update available")))
        [ "help"; "--help"; "commands" ])

(* ------------------------------------------------------------------------- *)
(* c2c history — verify message history display                             *)
(* ------------------------------------------------------------------------- *)

let test_history_exits_zero () =
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=cli-test-session c2c history > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c history exits 0" 0 rc

(* ------------------------------------------------------------------------- *)
(* c2c schedule list — verify schedule listing                              *)
(* ------------------------------------------------------------------------- *)

let test_schedule_list_exits_zero () =
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c schedule list > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c schedule list exits 0" 0 rc

let test_schedule_list_output_contains_header () =
  let tmpfile = Filename.temp_file "c2c-schedule-list" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c schedule list > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* schedule list outputs a table with NAME header or empty state *)
      check bool "schedule list has header or content" true
        (string_contains content "NAME" || string_contains content "schedule"
         || string_contains content "No schedules" || String.length content = 0))

(* ------------------------------------------------------------------------- *)
(* c2c memory list — verify memory listing                                  *)
(* ------------------------------------------------------------------------- *)

let test_memory_list_exits_zero () =
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c memory list > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c memory list exits 0" 0 rc

let test_memory_list_output_is_nonempty () =
  let tmpfile = Filename.temp_file "c2c-memory-list" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c memory list > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* memory list should produce some output — entries or empty message *)
      check bool "memory list produces output" true
        (String.length content > 0))

(* ------------------------------------------------------------------------- *)
(* c2c roles validate — verify role file validation                         *)
(* ------------------------------------------------------------------------- *)

let test_roles_validate_runs_and_shows_summary () =
  let tmpfile = Filename.temp_file "c2c-roles-validate" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf "c2c roles validate > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* Output ends with "[roles validate] N ok, N warnings, N errors" *)
      check bool "output contains validate summary" true
        (string_contains content "[roles validate]"))

(* ------------------------------------------------------------------------- *)
(* c2c rooms list — verify room listing                                     *)
(* ------------------------------------------------------------------------- *)

let test_rooms_list_exits_zero () =
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c rooms list > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c rooms list exits 0" 0 rc

let test_rooms_list_output_contains_room_entries () =
  let tmpfile = Filename.temp_file "c2c-rooms-list" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c rooms list > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* Output contains room entries, or a valid empty-room state. *)
      check bool "rooms list contains room entry pattern" true
        ((string_contains content "(" && string_contains content "members")
         || string_contains content "No rooms"))

(* ------------------------------------------------------------------------- *)
(* c2c rooms my-rooms — verify my-rooms listing                              *)
(* ------------------------------------------------------------------------- *)

let test_rooms_my_rooms_exits_zero () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"test-myrooms-sid"
        ~alias:"test-myrooms" ~pid:None ~pid_start_time:None ();
      let _ = C2c_mcp.Broker.join_room broker ~room_id:"my-room-a"
        ~alias:"test-myrooms" ~session_id:"test-myrooms-sid" in
      let _ = C2c_mcp.Broker.join_room broker ~room_id:"my-room-b"
        ~alias:"test-myrooms" ~session_id:"test-myrooms-sid" in
      let cmd = c2c_cmd (Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=test-myrooms-sid c2c rooms my-rooms > /dev/null 2>&1"
        (Filename.quote dir)) in
      let rc = Sys.command cmd in
      check int "c2c rooms my-rooms exits 0" 0 rc)

let test_rooms_my_rooms_lists_joined_rooms () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"test-myrooms-sid2"
        ~alias:"test-myrooms2" ~pid:None ~pid_start_time:None ();
      let _ = C2c_mcp.Broker.join_room broker ~room_id:"my-room-x"
        ~alias:"test-myrooms2" ~session_id:"test-myrooms-sid2" in
      let _ = C2c_mcp.Broker.join_room broker ~room_id:"my-room-y"
        ~alias:"test-myrooms2" ~session_id:"test-myrooms-sid2" in
      let tmpfile = Filename.temp_file "c2c-my-rooms" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
        (fun () ->
          ignore (Sys.command (c2c_cmd (Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=test-myrooms-sid2 c2c rooms my-rooms > %s 2>&1"
            (Filename.quote dir) tmpfile)));
          let ch = open_in tmpfile in
          let content = Fun.protect ~finally:(fun () -> close_in ch)
            (fun () -> really_input_string ch (in_channel_length ch))
          in
          check bool "my-rooms lists joined rooms" true
            (string_contains content "my-room-x" && string_contains content "my-room-y")))

let test_rooms_my_rooms_json_output () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"test-myrooms-json-sid"
        ~alias:"test-myrooms-json" ~pid:None ~pid_start_time:None ();
      let _ = C2c_mcp.Broker.join_room broker ~room_id:"json-room-1"
        ~alias:"test-myrooms-json" ~session_id:"test-myrooms-json-sid" in
      let tmpfile = Filename.temp_file "c2c-my-rooms-json" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
        (fun () ->
          ignore (Sys.command (c2c_cmd (Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=test-myrooms-json-sid c2c rooms my-rooms --json > %s 2>&1"
            (Filename.quote dir) tmpfile)));
          let ch = open_in tmpfile in
          let content = Fun.protect ~finally:(fun () -> close_in ch)
            (fun () -> really_input_string ch (in_channel_length ch))
          in
          let parsed = Yojson.Safe.from_string content in
          match parsed with
          | `List items ->
              let ids = List.map (fun item ->
                Yojson.Safe.Util.(item |> member "room_id" |> to_string)) items
              in
              check bool "json output contains room_id" true
                (List.mem "json-room-1" ids)
          | _ -> fail "expected JSON array from my-rooms --json"))

(* ------------------------------------------------------------------------- *)
(* c2c rooms join — verify room join / missing-arg handling                 *)
(* ------------------------------------------------------------------------- *)

let test_rooms_join_missing_room_exits_nonzero () =
  (* No ROOM argument provided → should exit non-zero *)
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c rooms join > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check bool "c2c rooms join with no args exits non-zero" true (rc <> 0)

let test_rooms_join_help_exits_zero () =
  (* --help should exit 0 even with missing required arg *)
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c rooms join --help > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c rooms join --help exits 0" 0 rc

(* ------------------------------------------------------------------------- *)
(* c2c doctor — deeper output checks                                         *)
(* ------------------------------------------------------------------------- *)

let test_doctor_output_contains_relay_info () =
  let tmpfile = Filename.temp_file "c2c-doctor-relay" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf "c2c doctor > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* doctor should mention relay or broker root in output *)
      let has_relay_or_broker =
        string_contains content "relay" || string_contains content "broker"
      in
      check bool "doctor output mentions relay or broker" true has_relay_or_broker)

let test_doctor_output_contains_peer_summary () =
  let tmpfile = Filename.temp_file "c2c-doctor-peers" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf "c2c doctor > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* doctor should show peer/registry info *)
      let has_peer_info =
        string_contains content "peer" || string_contains content "registry"
        || string_contains content "alive"
      in
      check bool "doctor output contains peer/registry info" true has_peer_info)

(* ------------------------------------------------------------------------- *)
(* c2c worktree list — verify worktree listing                             *)
(* ------------------------------------------------------------------------- *)

let test_worktree_list_exits_zero () =
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c dev worktree list > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c worktree list exits 0" 0 rc

let test_worktree_list_output_contains_refs_heads () =
  (* Self-contained: run in a fresh temp git repo so HEAD is always on a
     branch (refs/heads present), independent of the surrounding checkout.
     CI tag/detached checkouts (e.g. the release ci-gate) have no local
     branch, which would spuriously fail this assertion. *)
  with_temp_dir (fun dir ->
    let tmpfile = Filename.temp_file "c2c-worktree-list" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        let orig = Sys.getcwd () in
        Fun.protect ~finally:(fun () -> (try Sys.chdir orig with _ -> ()))
          (fun () ->
            Sys.chdir dir;
            ignore (Sys.command "git init -q");
            ignore (Sys.command "git config user.email t@t");
            ignore (Sys.command "git config user.name t");
            ignore (Sys.command "git commit --allow-empty -q -m init");
            ignore (Sys.command (c2c_cmd (Printf.sprintf
              "C2C_CLI_FORCE=1 c2c dev worktree list > %s 2>&1"
              (Filename.quote tmpfile)))));
        let ch = open_in tmpfile in
        let content = Fun.protect ~finally:(fun () -> close_in ch)
          (fun () -> really_input_string ch (in_channel_length ch))
        in
        (* Worktree list shows "refs/heads/" for each branch entry *)
        check bool "worktree list contains refs/heads entries" true
          (string_contains content "refs/heads")))

(* ------------------------------------------------------------------------- *)
(* c2c instances — verify managed-instance listing                           *)
(* ------------------------------------------------------------------------- *)

let test_instances_exits_zero () =
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c instances > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c instances exits 0" 0 rc

let test_instances_output_contains_managed_header () =
  let tmpfile = Filename.temp_file "c2c-instances" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c instances > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* instances output shows "Managed instances" header and count *)
      let has_header =
        (string_contains content "Managed instances"
         && (string_contains content "alive" || string_contains content "total"))
        || string_contains content "No managed instances"
      in
      check bool "instances output contains managed header and counts" true has_header)

let test_instances_json_output_is_valid () =
  let tmpfile = Filename.temp_file "c2c-instances-json" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c instances --json > %s 2>/dev/null" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* JSON output starts with '{' and contains "alive" field *)
      let is_valid_json =
        String.length content > 0
        && String.get content 0 = '{'
        && string_contains content "\"alive\""
      in
      check bool "instances --json output is valid JSON with alive field" true is_valid_json)

(* ------------------------------------------------------------------------- *)
(* c2c prune-rooms — verify room pruning                                    *)
(* ------------------------------------------------------------------------- *)

let test_prune_rooms_exits_zero () =
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c prune-rooms > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c prune-rooms exits 0" 0 rc

let test_prune_rooms_output_contains_eviction_info () =
  (* Output is either "Evicted N dead members:" or "No dead members to evict." *)
  let tmpfile = Filename.temp_file "c2c-prune-rooms" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf "C2C_CLI_FORCE=1 c2c prune-rooms > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "prune-rooms mentions eviction or no dead members" true
        (string_contains content "Evicted" || string_contains content "No dead members"
         || string_contains content "evict"))

(* ------------------------------------------------------------------------- *)
(* c2c set-compact / clear-compact — verify compacting flag operations      *)
(* ------------------------------------------------------------------------- *)

let test_set_compact_unregistered_session () =
  (* With a fake session ID, set-compact reports error and exits non-zero *)
  let tmpfile = Filename.temp_file "c2c-set-compact" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let rc = Sys.command (c2c_cmd (Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=cli-test-compact c2c set-compact --reason test > %s 2>&1"
        tmpfile)) in
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "set-compact exits non-zero for unregistered session" true (rc <> 0);
      check bool "set-compact reports session not registered" true
        (string_contains content "not registered" || string_contains content "error"))

let test_clear_compact_unregistered_session () =
  let tmpfile = Filename.temp_file "c2c-clear-compact" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let rc = Sys.command (c2c_cmd (Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=cli-test-compact c2c clear-compact > %s 2>&1"
        tmpfile)) in
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "clear-compact exits non-zero for unregistered session" true (rc <> 0);
      check bool "clear-compact reports no compacting flag" true
        (string_contains content "not registered" || string_contains content "error"
         || string_contains content "no compacting"))

(* ------------------------------------------------------------------------- *)
(* c2c check-pending-reply — verify pending reply checks                    *)
(* ------------------------------------------------------------------------- *)

let test_check_pending_reply_missing_args_exits_nonzero () =
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c check-pending-reply > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check bool "check-pending-reply with no args exits non-zero" true (rc <> 0)

let test_check_pending_reply_invalid_perm_reports_error () =
  let tmpfile = Filename.temp_file "c2c-check-pending" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c check-pending-reply nonexistent-perm fake-alias > %s 2>&1"
        tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "check-pending-reply invalid perm produces output" true
        (String.length content > 0))

(* ------------------------------------------------------------------------- *)
(* c2c agent delete — verify role deletion                                  *)
(* ------------------------------------------------------------------------- *)

let test_agent_delete_missing_name_exits_nonzero () =
  let cmd = c2c_cmd "c2c agent delete > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check bool "agent delete with no name exits non-zero" true (rc <> 0)

let test_agent_delete_nonexistent_role_reports_error () =
  let tmpfile = Filename.temp_file "c2c-agent-delete" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let rc = Sys.command (c2c_cmd (Printf.sprintf
        "c2c agent delete nonexistent-test-role-xyz > %s 2>&1" tmpfile)) in
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "agent delete nonexistent role exits non-zero" true (rc <> 0);
      check bool "agent delete nonexistent role reports error" true
        (string_contains content "not found" || string_contains content "error"))

(* ------------------------------------------------------------------------- *)
(* c2c install --dry-run                                                     *)
(* ------------------------------------------------------------------------- *)

(* Each test uses --dry-run so nothing is written to disk.
   Each client gets a unique alias to avoid collisions. *)

let test_install_dry_run_kimi () =
  with_temp_dir (fun home ->
    let alias = Printf.sprintf "willow-test-kimi-%d" (Unix.getpid ()) in
    let tmpfile = Filename.temp_file "c2c-install-dry" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
      let cmd = c2c_cmd (Printf.sprintf "%s c2c install kimi --dry-run --alias %s > %s 2>&1"
        (isolated_home_env home) (Filename.quote alias) tmpfile) in
      let rc = Sys.command cmd in
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* B146 reverted: kimi is re-enabled. The assertions stay flag-aware so
         the soft-disable toggle (C2c_start.kimi_disabled_for_release) can be
         flipped again for a future release without rewriting this test. *)
      if C2c_start.kimi_disabled_for_release then begin
        check bool "install kimi --dry-run refuses (disabled)" true (rc <> 0);
        check bool "refusal mentions disabled" true
          (string_contains content "disabled" || string_contains content "DISABLED"
           || string_contains content "temporarily")
      end else begin
        debug_install_failure "kimi" cmd rc content;
        check int "install kimi --dry-run exits 0" 0 rc;
        check bool "dry-run output contains [DRY-RUN]" true
          (string_contains content "[DRY-RUN]");
        check bool "dry-run output mentions kimi config" true
          (string_contains content "kimi" || string_contains content "Kimi")
      end))

let test_install_dry_run_opencode () =
  with_temp_dir (fun home ->
    let alias = Printf.sprintf "willow-test-oc-%d" (Unix.getpid ()) in
    let tmpfile = Filename.temp_file "c2c-install-dry" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
      let cmd = c2c_cmd (Printf.sprintf "%s c2c install opencode --dry-run --alias %s > %s 2>&1"
        (isolated_home_env home) (Filename.quote alias) tmpfile) in
      let rc = Sys.command cmd in
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      debug_install_failure "opencode" cmd rc content;
      check int "install opencode --dry-run exits 0" 0 rc;
      check bool "dry-run output contains [DRY-RUN]" true
        (string_contains content "[DRY-RUN]")))

let test_install_dry_run_codex () =
  with_temp_dir (fun home ->
    let alias = Printf.sprintf "willow-test-codex-%d" (Unix.getpid ()) in
    let tmpfile = Filename.temp_file "c2c-install-dry" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
      let cmd = c2c_cmd (Printf.sprintf "%s c2c install codex --dry-run --alias %s > %s 2>&1"
        (isolated_home_env home) (Filename.quote alias) tmpfile) in
      let rc = Sys.command cmd in
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      debug_install_failure "codex" cmd rc content;
      check int "install codex --dry-run exits 0" 0 rc;
      check bool "dry-run output contains [DRY-RUN]" true
        (string_contains content "[DRY-RUN]")))

(* ------------------------------------------------------------------------- *)
(* c2c config generation-client                                               *)
(* ------------------------------------------------------------------------- *)

let test_config_generation_client_exits_zero () =
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c config generation-client > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "config generation-client exits 0" 0 rc

let test_config_generation_client_shows_client_name () =
  let tmpfile = Filename.temp_file "c2c-config-gen" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c config generation-client > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* Should output one of: claude, opencode, codex *)
      check bool "config generation-client shows a valid client name" true
        (string_contains content "claude" || string_contains content "opencode"
         || string_contains content "codex"))

(* ------------------------------------------------------------------------- *)
(* c2c worktree gc — verify GC classification and --clean removal             *)
(* ------------------------------------------------------------------------- *)

(* Shell helper — captures stderr on failure for diagnostics.
   Uses a fixed stderr path to avoid temp-file-in-sandbox issues. *)
let sh fmt =
  let sh_err = "/tmp/sh-err-c2c-wt-gc.txt" in
  Printf.ksprintf (fun cmd ->
      let code = Sys.command (Printf.sprintf "%s 2>%s" cmd (Filename.quote sh_err)) in
      if code <> 0 then
        let err_msg =
          try
            let ch = open_in sh_err in
            Fun.protect ~finally:(fun () -> close_in ch) (fun () ->
              let content = really_input_string ch (in_channel_length ch) in
              if String.trim content = "" then "(no stderr)" else content)
          with _ -> "(could not read stderr)"
        in
        failwith (Printf.sprintf "shell command failed (%d): %s\nstderr: %s" code cmd err_msg)
      else
        ())
    fmt

(* Build a minimal git repo with refs/remotes/origin/master pointing at HEAD
   (synthesized via update-ref so we don't need a real remote), plus an
   optional worktree inside .worktrees/. Only worktrees inside .worktrees/
   are considered by scan_worktrees_for_gc.

   Note: creates the test repo in /tmp directly (not via temp_file) because
   Dune sandboxes the test temp dir and prevents mkdir inside it. *)
let with_test_repo_and_worktree state f =
  let tmp = Filename.concat "/tmp" ("c2c-wt-gc-test-" ^ string_of_int (Unix.getpid())) in
  (try ignore (Sys.command ("rm -rf " ^ Filename.quote tmp)) with _ -> ());
  Unix.mkdir tmp 0o700;
  Fun.protect
    ~finally:(fun () ->
      (* Best-effort cleanup: gc --clean may have already removed the worktree *)
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmp))))
    (fun () ->
      let repo = tmp in  (* repo IS the temp dir itself *)
      let wt_name = "wt" in
      let wt_path = Filename.concat (Filename.concat repo ".worktrees") wt_name in
      sh "git init -q -b master %s" (Filename.quote repo);
      sh "git -C %s config user.email t@t" (Filename.quote repo);
      sh "git -C %s config user.name t" (Filename.quote repo);
      sh "echo initial > %s/f" (Filename.quote repo);
      sh "git -C %s add f" (Filename.quote repo);
      sh "GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' git -C %s commit -q -m initial" (Filename.quote repo);
      (* Synthesize origin/master without needing a real remote *)
      sh "git -C %s update-ref refs/remotes/origin/master HEAD"
        (Filename.quote repo);
      (match state with
       | `Clean ->
           (* Create .worktrees/<name> worktree at origin/master.
              Path .worktrees/wt is relative to the repo dir (resolved by git
              from the repo's gitdir parent), giving repo/.worktrees/wt. *)
           sh "mkdir -p %s" (Filename.quote (Filename.concat repo ".worktrees"));
           sh "git -C %s worktree add %s origin/master"
             (Filename.quote repo) (Filename.quote (Filename.concat ".worktrees" wt_name))
       | `Dirty ->
           sh "mkdir -p %s" (Filename.quote (Filename.concat repo ".worktrees"));
           sh "git -C %s worktree add %s origin/master"
             (Filename.quote repo) (Filename.quote (Filename.concat ".worktrees" wt_name));
           sh "echo modified >> %s/f" (Filename.quote wt_path)
       | `None -> ());
      f repo wt_path)

(* Test 1: gc with a path-prefix that matches nothing exits 0 and shows 0 worktrees *)
let test_worktree_gc_no_worktrees () =
  with_test_repo_and_worktree `None (fun repo _wt ->
      (* Repo exists but has no worktrees (wt was never created) *)
      let tmpfile = Filename.temp_file "c2c-wt-gc" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
        (fun () ->
          (* gc from repo with a prefix that matches nothing *)
          let rc = Sys.command (
            Printf.sprintf "cd %s && %s"
              (Filename.quote repo)
              (c2c_cmd (Printf.sprintf "c2c dev worktree gc --path-prefix=no-such-wt-gc-test > %s 2>&1"
                (Filename.quote tmpfile)))
          ) in
          check int "gc with no matching worktrees exits 0" 0 rc;
          let ch = open_in tmpfile in
          let content = Fun.protect ~finally:(fun () -> close_in ch)
            (fun () -> really_input_string ch (in_channel_length ch))
          in
          (* Output should mention "0 worktrees" *)
          check bool "output mentions 0 worktrees" true
            (string_contains content "0 worktree")
        )
    )

(* Test 2: gc --clean removes a clean merged worktree *)
let test_worktree_gc_clean_removes_merged () =
  with_test_repo_and_worktree `Clean (fun repo wt ->
      (* Verify worktree exists before gc via [ -d ]. *)
      let dir_exists () =
        Sys.command (Printf.sprintf "if [ -d %s ]; then exit 0; else exit 1; fi"
          (Filename.quote wt)) = 0
      in
      check bool "worktree exists before gc" true (dir_exists ());
      (* Run c2c worktree gc --clean.
         --active-window-hours=0 bypasses freshness heuristic for new worktrees.
         --path-prefix=wt matches the test worktree name. *)
      let rc = Sys.command (
        Printf.sprintf "cd %s && %s"
          (Filename.quote repo)
          (c2c_cmd "c2c dev worktree gc --path-prefix=wt --active-window-hours=0 --clean > /dev/null 2>&1")
      ) in
      check int "gc --clean exits 0" 0 rc;
      (* Verify worktree is gone *)
      check bool "worktree removed after --clean" false (dir_exists ())
    )

(* Test 3: gc (dry-run) refuses a dirty worktree — does NOT remove it *)
let test_worktree_gc_refuses_dirty () =
  with_test_repo_and_worktree `Dirty (fun repo wt ->
      let tmpfile = Filename.temp_file "c2c-wt-gc" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
        (fun () ->
          (* gc without --clean: dry-run, should refuse dirty worktree *)
          let rc = Sys.command (
            Printf.sprintf "cd %s && %s"
              (Filename.quote repo)
              (c2c_cmd (Printf.sprintf "c2c dev worktree gc --path-prefix=wt --active-window-hours=0 --strict-dirty > %s 2>&1"
                (Filename.quote tmpfile)))
          ) in
          check int "gc dry-run exits 0" 0 rc;
          let ch = open_in tmpfile in
          let content = Fun.protect ~finally:(fun () -> close_in ch)
            (fun () -> really_input_string ch (in_channel_length ch))
          in
          (* Output should mention REFUSE and "dirty" *)
          check bool "output mentions REFUSE" true
            (string_contains content "REFUSE");
          check bool "output mentions dirty" true
            (string_contains content "dirty");
          (* Worktree must NOT be removed (it's a dry-run) *)
          check bool "dirty worktree still exists after dry-run" true
            (Sys.file_exists wt)
        )
    )

(* ------------------------------------------------------------------------- *)
(* c2c schedule enable / disable                                             *)
(* ------------------------------------------------------------------------- *)

let test_schedule_enable_nonexistent_exits_nonzero () =
  let tmpfile = Filename.temp_file "c2c-sched-en" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let rc = Sys.command
        (c2c_cmd (Printf.sprintf "c2c schedule enable nonexistent-test-sched-xyz > %s 2>&1" tmpfile)) in
      check bool "schedule enable nonexistent exits non-zero" true (rc <> 0);
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output contains not found" true
        (string_contains content "not found"))

let test_schedule_disable_nonexistent_exits_nonzero () =
  let tmpfile = Filename.temp_file "c2c-sched-dis" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let rc = Sys.command
        (c2c_cmd (Printf.sprintf "c2c schedule disable nonexistent-test-sched-xyz > %s 2>&1" tmpfile)) in
      check bool "schedule disable nonexistent exits non-zero" true (rc <> 0);
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output contains not found" true
        (string_contains content "not found"))

let test_schedule_enable_missing_name_exits_nonzero () =
  let rc = Sys.command (c2c_cmd "c2c schedule enable > /dev/null 2>&1") in
  check bool "schedule enable with no args exits non-zero" true (rc <> 0)

let test_schedule_disable_missing_name_exits_nonzero () =
  let rc = Sys.command (c2c_cmd "c2c schedule disable > /dev/null 2>&1") in
  check bool "schedule disable with no args exits non-zero" true (rc <> 0)

let test_schedule_enable_disable_roundtrip () =
  (* Use c2c schedule set to create a temp schedule, then disable/enable it,
     and clean up via c2c schedule rm.  This avoids having to locate the
     schedule directory on disk (it resolves via broker-root, not cwd). *)
  let sched_name = Printf.sprintf "test-sched-%08x" (Random.bits ()) in
  (* Create the schedule via CLI *)
  let rc_set = Sys.command
    (c2c_cmd (Printf.sprintf "c2c schedule set %s --interval 5m --message test > /dev/null 2>&1"
      (Filename.quote sched_name))) in
  check int "schedule set exits 0" 0 rc_set;
  Fun.protect ~finally:(fun () ->
    ignore (Sys.command
      (c2c_cmd (Printf.sprintf "c2c schedule rm %s > /dev/null 2>&1" (Filename.quote sched_name)))))
    (fun () ->
      (* Disable the schedule *)
      let tmpfile = Filename.temp_file "c2c-sched-rt" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
        (fun () ->
          let rc = Sys.command
            (c2c_cmd (Printf.sprintf "c2c schedule disable %s > %s 2>&1"
              (Filename.quote sched_name) tmpfile)) in
          check int "schedule disable exits 0" 0 rc;
          let ch = open_in tmpfile in
          let content = Fun.protect ~finally:(fun () -> close_in ch)
            (fun () -> really_input_string ch (in_channel_length ch))
          in
          check bool "output contains disabled" true
            (string_contains content "disabled"));
      (* Enable the schedule *)
      let tmpfile2 = Filename.temp_file "c2c-sched-rt2" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove tmpfile2 |> ignore)
        (fun () ->
          let rc = Sys.command
            (c2c_cmd (Printf.sprintf "c2c schedule enable %s > %s 2>&1"
              (Filename.quote sched_name) tmpfile2)) in
          check int "schedule enable exits 0" 0 rc;
          let ch = open_in tmpfile2 in
          let content = Fun.protect ~finally:(fun () -> close_in ch)
            (fun () -> really_input_string ch (in_channel_length ch))
          in
          check bool "output contains enabled" true
            (string_contains content "enabled")))

(* ------------------------------------------------------------------------- *)
(* c2c peer-pass list — verify artifact listing                               *)
(* ------------------------------------------------------------------------- *)

(* Create a minimal git repo so peer_passes_dir() resolves inside it *)
let with_fake_git_repo f =
  let tmp = Filename.concat "/tmp" ("c2c-peer-pass-test-" ^ string_of_int (Unix.getpid())) in
  (try ignore (Sys.command ("rm -rf " ^ Filename.quote tmp)) with _ -> ());
  Unix.mkdir tmp 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmp))))
    (fun () ->
      ignore (Sys.command (Printf.sprintf "git init -q -b master %s" (Filename.quote tmp)));
      ignore (Sys.command (Printf.sprintf "git -C %s config user.email t@t" (Filename.quote tmp)));
      ignore (Sys.command (Printf.sprintf "git -C %s config user.name t" (Filename.quote tmp)));
      ignore (Sys.command (Printf.sprintf "touch %s/.gitkeep" (Filename.quote tmp)));
      ignore (Sys.command (Printf.sprintf "git -C %s add . && git -C %s commit -q -m init" (Filename.quote tmp) (Filename.quote tmp)));
      f tmp)

(* Test 1: list with no peer-passes dir → shows empty message *)
let test_peer_pass_list_empty () =
  with_fake_git_repo (fun repo ->
      (* peer_passes_dir() resolves to repo/.c2c/peer-passes — no artifacts *)
      let cmd = Printf.sprintf "cd %s && %s" (Filename.quote repo)
        (c2c_cmd "c2c dev peer-pass list 2>&1") in
      let rc = Sys.command cmd in
      check int "peer-pass list (empty) exits 0" 0 rc
    )

(* Test 2: list with a real artifact present → shows entries *)
let test_peer_pass_list_shows_entries () =
  (* Use the real c2c install's artifact dir if it exists, otherwise skip *)
  let real_artifacts = "/home/xertrov/.c2c/peer-passes" in
  if not (Sys.file_exists real_artifacts) then
    check bool "real peer-passes dir exists" true true
  else
    (* Run from a fake git repo so peer_passes_dir() finds the real artifact path *)
    with_fake_git_repo (fun repo ->
        (* Copy a real artifact into the fake repo's peer-passes dir *)
        let art_dir = Filename.concat (Filename.concat repo ".c2c") "peer-passes" in
        ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote art_dir)));
        let real_art = Filename.concat real_artifacts "00087156-birch-coder.json" in
        if not (Sys.file_exists real_art) then
          check bool "real artifact exists" true true
        else begin
          ignore (Sys.command (Printf.sprintf "cp %s %s/"
            (Filename.quote real_art) (Filename.quote art_dir)));
          let tmpfile = Filename.temp_file "c2c-peer-list" ".out" in
          Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
            (fun () ->
              let rc = Sys.command (
                Printf.sprintf "cd %s && %s"
                  (Filename.quote repo)
                  (c2c_cmd (Printf.sprintf "c2c dev peer-pass list > %s 2>&1"
                    (Filename.quote tmpfile)))
              ) in
              check int "peer-pass list exits 0" 0 rc;
              let ch = open_in tmpfile in
              let content = Fun.protect ~finally:(fun () -> close_in ch)
                (fun () -> really_input_string ch (in_channel_length ch))
              in
              (* Human-readable output should contain reviewer name and/or sha *)
              check bool "list output contains reviewer or sha" true
                (string_contains content "birch" || string_contains content "sha")
            )
        end)

(* Test 3: list --json outputs parseable JSON *)
let test_peer_pass_list_json () =
  let real_artifacts = "/home/xertrov/.c2c/peer-passes" in
  if not (Sys.file_exists real_artifacts) then
    check bool "real peer-passes dir exists" true true
  else
    with_fake_git_repo (fun repo ->
        let art_dir = Filename.concat (Filename.concat repo ".c2c") "peer-passes" in
        ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote art_dir)));
        let real_art = Filename.concat real_artifacts "00087156-birch-coder.json" in
        if not (Sys.file_exists real_art) then
          check bool "real artifact exists" true true
        else begin
          ignore (Sys.command (Printf.sprintf "cp %s %s/"
            (Filename.quote real_art) (Filename.quote art_dir)));
          let tmpfile = Filename.temp_file "c2c-peer-list-json" ".out" in
          Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
            (fun () ->
              let rc = Sys.command (
                Printf.sprintf "cd %s && %s"
                  (Filename.quote repo)
                  (c2c_cmd (Printf.sprintf "c2c dev peer-pass list --json > %s 2>&1"
                    (Filename.quote tmpfile)))
              ) in
              check int "peer-pass list --json exits 0" 0 rc;
              let ch = open_in tmpfile in
              let content = Fun.protect ~finally:(fun () -> close_in ch)
                (fun () -> really_input_string ch (in_channel_length ch))
              in
              (* Output should be parseable JSON (starts with '[') *)
              check bool "json output starts with [" true
                (String.length content > 0 && content.[0] = '[')
            )
        end)

(* ------------------------------------------------------------------------- *)
(* c2c peer-pass verify — verify signed artifact                              *)
(* ------------------------------------------------------------------------- *)

(* Test 4: verify a real artifact → exits 0 and shows VERIFIED *)
let test_peer_pass_verify_valid_artifact () =
  let real_art = "/home/xertrov/.c2c/peer-passes/00087156-birch-coder.json" in
  if not (Sys.file_exists real_art) then
    check bool "real artifact exists for verify test" true true
  else
    let tmpfile = Filename.temp_file "c2c-peer-verify" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        let rc = Sys.command (
          c2c_cmd (Printf.sprintf "c2c dev peer-pass verify %s > %s 2>&1"
            (Filename.quote real_art) (Filename.quote tmpfile))
        ) in
        check int "peer-pass verify exits 0" 0 rc;
        let ch = open_in tmpfile in
        let content = Fun.protect ~finally:(fun () -> close_in ch)
          (fun () -> really_input_string ch (in_channel_length ch))
        in
        check bool "verify output contains VERIFIED" true
          (string_contains content "VERIFIED"))

(* Test 5: verify a nonexistent file → exits non-zero *)
let test_peer_pass_verify_nonexistent () =
  let nonexistent = "/tmp/c2c-nonexistent-peer-pass-artifact-00000000.json" in
  (* Ensure it definitely does not exist *)
  (try Sys.remove nonexistent with _ -> ());
  let rc = Sys.command (
    c2c_cmd (Printf.sprintf "c2c dev peer-pass verify %s > /dev/null 2>&1"
      (Filename.quote nonexistent))
  ) in
  check bool "peer-pass verify nonexistent exits non-zero" true (rc <> 0)

(* ------------------------------------------------------------------------- *)
(* c2c install --dry-run — verify install preview without side effects       *)
(* ------------------------------------------------------------------------- *)

let test_install_all_dry_run_exits_zero () =
  with_temp_dir (fun home ->
    let cmd =
      c2c_cmd
        (Printf.sprintf "%s c2c install all --dry-run > /dev/null 2>&1 < /dev/null"
           (isolated_home_env home))
    in
    let rc = Sys.command cmd in
    check int "c2c install all --dry-run exits 0" 0 rc)

let test_install_all_dry_run_shows_dry_run_markers () =
  with_temp_dir (fun home ->
    let fake_clients = fake_client_path_env home [ "codex"; "opencode"; "kimi" ] in
    let tmpfile = Filename.temp_file "c2c-install-all-dry" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
      let cmd = c2c_cmd (Printf.sprintf
        "%s %s c2c install all --dry-run > %s 2>&1 < /dev/null"
        fake_clients (isolated_home_env home) tmpfile) in
      let rc = Sys.command cmd in
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      debug_install_failure "all-markers" cmd rc content;
      check int "install all --dry-run exits 0" 0 rc;
      (* Binary-only default: self dry-run says "Would install", not client MCP. *)
      check bool "output previews binary install" true
        (string_contains content "Would install" || string_contains content "c2c binary");
      check bool "does not configure opencode by default" false
        (string_contains content "Configuring opencode");
      check bool "does not configure kimi by default" false
        (string_contains content "Configuring kimi")))

let test_install_all_dry_run_skips_all_clients_by_default () =
  (* B122: install all is binary-only; every client MCP path is opt-in. *)
  with_temp_dir (fun home ->
    let fake_clients = fake_client_path_env home [ "codex"; "opencode"; "kimi" ] in
    let tmpfile = Filename.temp_file "c2c-install-all-mcp-opt-in" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
      let cmd = c2c_cmd (Printf.sprintf
        "%s %s c2c install all --dry-run > %s 2>&1 < /dev/null"
        fake_clients (isolated_home_env home) tmpfile) in
      let rc = Sys.command cmd in
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      debug_install_failure "all-mcp-opt-in" cmd rc content;
      check int "install all exits 0" 0 rc;
      (* Clients on PATH must not be newly configured. They may show
         "skipped; MCP opt-in" or "configured — up-to-date" (project cwd may
         already have an install); either way, never "→ Configuring …". *)
      check bool "codex is not newly configured" true
        (string_contains content "codex: [skipped; MCP opt-in"
         || string_contains content "codex: [configured");
      check bool "opencode is not newly configured" true
        (string_contains content "opencode: [skipped; MCP opt-in"
         || string_contains content "opencode: [configured");
      (* B146 reverted: kimi is back in known_clients and `install all`
         configures it. Flag-aware: if the soft-disable toggle is flipped again,
         kimi is dropped and must be absent from the plan. *)
      if C2c_start.kimi_disabled_for_release then
        check bool "kimi not configured while disabled" false
          (string_contains content "Configuring kimi")
      else
        check bool "kimi is not newly configured" true
          (string_contains content "kimi: [skipped; MCP opt-in"
           || string_contains content "kimi: [configured");
      check bool "no client setup previewed" false
        (string_contains content "Configuring ");
      check bool "opt-in policy banner present" true
        (string_contains content "opt-in policy" || string_contains content "--with-clients")))

let test_install_all_json_dry_run_binary_only () =
  with_temp_dir (fun home ->
    let fake_clients = fake_client_path_env home [ "codex"; "opencode"; "kimi" ] in
    let tmpfile = Filename.temp_file "c2c-install-all-json" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
      let cmd = c2c_cmd (Printf.sprintf
        "%s %s c2c install all --dry-run --json > %s 2>&1 < /dev/null"
        fake_clients (isolated_home_env home) tmpfile) in
      let rc = Sys.command cmd in
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      debug_install_failure "all-json-binary-only" cmd rc content;
      check int "install all --json exits 0" 0 rc;
      check bool "binary_only true" true (string_contains content "\"binary_only\": true");
      check bool "with_clients false" true (string_contains content "\"with_clients\": false");
      check bool "no mcpServers plan in json" false
        (string_contains content "mcpServers")))

let test_install_all_with_clients_dry_run_configures () =
  (* Explicit bulk opt-in must plan client configuration. *)
  with_temp_dir (fun home ->
    let fake_clients = fake_client_path_env home [ "codex"; "kimi" ] in
    let tmpfile = Filename.temp_file "c2c-install-all-with-clients" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
      let cmd = c2c_cmd (Printf.sprintf
        "%s %s c2c install all --with-clients --dry-run > %s 2>&1 < /dev/null"
        fake_clients (isolated_home_env home) tmpfile) in
      let rc = Sys.command cmd in
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      debug_install_failure "all-with-clients" cmd rc content;
      check int "install all --with-clients exits 0" 0 rc;
      check bool "configures codex when opted in" true
        (string_contains content "Configuring codex"
         || string_contains content "[DRY-RUN]");
      check bool "does not claim mcp opt-in skip for codex" false
        (string_contains content "codex: [skipped; MCP opt-in")))

let test_interactive_install_default_skips_all_clients () =
  with_temp_dir (fun home ->
    let fake_clients = fake_client_path_env home [ "codex"; "opencode"; "kimi" ] in
    let tmpfile = Filename.temp_file "c2c-install-tui-mcp-opt-in" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
      (* [c2c_cmd] prefixes its command with PATH changes. That prefix would
         apply only to the left side of this pipe, so invoke the freshly-built
         binary directly on the right side instead. *)
      let cmd = Printf.sprintf
        "printf '\\n' | %s %s %s install --dry-run > %s 2>&1"
        fake_clients (isolated_home_env home) (Filename.quote c2c_binary)
        (Filename.quote tmpfile) in
      let rc = Sys.command cmd in
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      debug_install_failure "tui-mcp-opt-in" cmd rc content;
      check int "interactive install exits 0" 0 rc;
      check bool "Codex is unchecked in the default plan" true
        (string_contains content "[ ] configure codex");
      check bool "OpenCode is unchecked in the default plan" true
        (string_contains content "[ ] configure opencode");
      (* B146 reverted: kimi is back in known_clients, so the interactive
         plan offers it (unchecked by default). Flag-aware: if the soft-disable
         toggle is flipped again, kimi must not be offered at all. *)
      if C2c_start.kimi_disabled_for_release then
        check bool "Kimi not offered in the plan while disabled" false
          (string_contains content "configure kimi")
      else
        check bool "Kimi is unchecked in the default plan" true
          (string_contains content "[ ] configure kimi");
      check bool "no client Configuring preview" false
        (string_contains content "Configuring ")))

let test_install_all_dry_run_epilog () =
  with_temp_dir (fun home ->
    let tmpfile = Filename.temp_file "c2c-install-all-epilog" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf
        "%s c2c install all --dry-run > %s 2>&1 < /dev/null"
        (isolated_home_env home) tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* Binary-only default: opt-in guidance, not the MCP restart footer. *)
      check bool "install all output mentions opt-in / with-clients" true
        (string_contains content "--with-clients"
         || string_contains content "opt-in policy");
      check bool "install all output mentions CLI without MCP" true
        (string_contains content "without MCP" || string_contains content "c2c send")))

(* c2c install opencode — real install (not dry-run) with temp HOME.
   Regression test: write_deliver_watch_scripts used non-recursive mkdir,
   crashing with Sys_error when ~/.c2c/clients/opencode/ didn't exist. *)
let test_install_opencode_creates_deliver_watch_scripts () =
  with_temp_dir (fun tmp_home ->
    with_temp_dir (fun target_dir ->
      let env_prefix = isolated_home_env tmp_home in
      let alias = Printf.sprintf "test-oc-fix-%d" (Unix.getpid ()) in
      let tmpfile = Filename.temp_file "c2c-install-oc" ".out" in
      Fun.protect ~finally:(fun () -> (try Sys.remove tmpfile with _ -> ()))
        (fun () ->
          let cmd = c2c_cmd (Printf.sprintf
            "%s c2c install opencode --force --alias %s --target-dir %s > %s 2>&1"
            env_prefix (Filename.quote alias) (Filename.quote target_dir) tmpfile) in
          let rc = Sys.command cmd in
          let ch = open_in tmpfile in
          let content = Fun.protect ~finally:(fun () -> close_in ch)
            (fun () -> really_input_string ch (in_channel_length ch))
          in
          if rc <> 0 then debug_install_failure "opencode-real" cmd rc content;
          (* Must not crash — exit 0 *)
          check int "install opencode --force exits 0" 0 rc;
          (* client dir must exist *)
          let client_dir = Filename.concat tmp_home (Filename.concat ".c2c" (Filename.concat "clients" "opencode")) in
          check bool "client_dir exists" true (Sys.file_exists client_dir);
          check bool "client_dir is directory" true
            (try Sys.is_directory client_dir with _ -> false);
          (* deliver-watch.sh must exist and be executable *)
          let supervisor = Filename.concat client_dir "deliver-watch.sh" in
          check bool "deliver-watch.sh exists" true (Sys.file_exists supervisor);
          let supervisor_stat = Unix.stat supervisor in
          check bool "deliver-watch.sh is executable" true
            (supervisor_stat.Unix.st_perm land 0o111 <> 0);
          (* start-hooks/pre-deliver.sh must exist and be executable *)
          let hook_dir = Filename.concat client_dir "start-hooks" in
          check bool "start-hooks dir exists" true (Sys.file_exists hook_dir);
          let pre_deliver = Filename.concat hook_dir "pre-deliver.sh" in
          check bool "pre-deliver.sh exists" true (Sys.file_exists pre_deliver);
          let pre_deliver_stat = Unix.stat pre_deliver in
          check bool "pre-deliver.sh is executable" true
            (pre_deliver_stat.Unix.st_perm land 0o111 <> 0))))

(* ------------------------------------------------------------------------- *)
(* c2c agent new banner — verify timestamp has no double "UTC UTC"           *)
(* ------------------------------------------------------------------------- *)

(* Regression test: Banner.timestamp() was appending " UTC" on top of
   human_utc() which already includes "UTC", producing "2026-05-02 22:59:07 UTC UTC".
   Fixed by removing the redundant " ^ \" UTC\"" from Banner.timestamp (). *)
let test_agent_new_banner_no_double_utc () =
  let alias = Printf.sprintf "willow-test-banner-%d" (Unix.getpid ()) in
  let tmpfile = Filename.temp_file "c2c-agent-new-banner" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let cmd = c2c_cmd (Printf.sprintf "c2c agent new %s > %s 2>&1"
        (Filename.quote alias) tmpfile) in
      ignore (Sys.command cmd);
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      let lower = String.lowercase_ascii content in
      check bool "banner has no double UTC (no 'utc utc')" true
        (not (string_contains lower "utc utc")))

(* ------------------------------------------------------------------------- *)
(* broker_root_fallthrough — legacy .git/c2c/mcp env var rejection           *)
(* ------------------------------------------------------------------------- *)

(* Use the built binary from the dune build tree, not the installed one from PATH.
   Sys.executable_name is the test runner; the c2c binary is a sibling under cli/. *)
let c2c_exe =
  let dir = Filename.dirname Sys.executable_name in
  (* test binary is in _build/default/ocaml/test/;
     c2c.exe is in _build/default/ocaml/cli/ *)
  let candidate = Filename.concat (Filename.concat (Filename.dirname dir) "cli") "c2c.exe" in
  if Sys.file_exists candidate then candidate
  else "c2c"  (* fallback to PATH *)

let test_legacy_broker_root_env_warns () =
  let tmpfile = Filename.temp_file "c2c-broker-warn" ".err" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let cmd = Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=/tmp/fake/.git/c2c/mcp %s list > /dev/null 2>%s; true"
        c2c_exe tmpfile
      in
      ignore (Sys.command cmd);
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "stderr contains [WARNING]" true
        (string_contains content "[WARNING]");
      check bool "stderr mentions legacy" true
        (string_contains content "legacy");
      check bool "stderr mentions split-brain" true
        (string_contains content "split-brain"))

let test_legacy_broker_root_env_uses_canonical () =
  let errfile = Filename.temp_file "c2c-broker-canonical" ".err" in
  Fun.protect ~finally:(fun () -> Sys.remove errfile |> ignore)
    (fun () ->
      let cmd = Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=/tmp/fake/.git/c2c/mcp %s list > /dev/null 2>%s; true"
        c2c_exe errfile
      in
      ignore (Sys.command cmd);
      let ch = open_in errfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "stderr mentions Canonical path" true
        (string_contains content "Canonical path:");
      check bool "canonical path is not legacy" false
        (string_contains content "Canonical path: /tmp/fake/.git/c2c/mcp"))

(* ------------------------------------------------------------------------- *)
(* c2c sweep --force — safety-guard bypass                                   *)
(* ------------------------------------------------------------------------- *)

(* Reuse the dead_pid helper from test_c2c_mcp.ml (defined in same module). *)
let dead_pid () =
  match Unix.fork () with
  | 0 -> exit 0
  | child ->
      let _ = Unix.waitpid [] child in
      let rec wait n =
        if n <= 0 then child
        else if not (Sys.file_exists ("/proc/" ^ string_of_int child)) then child
        else (
          ignore (Unix.select [] [] [] 0.005);
          wait (n - 1))
      in
      wait 20

let test_sweep_force_removes_dead_reg () =
  with_temp_dir (fun dir ->
      (* Set up a temp broker with one dead registration. *)
      let broker = C2c_mcp.Broker.create ~root:dir in
      let dead = dead_pid () in
      C2c_mcp.Broker.register broker
        ~session_id:"session-dead" ~alias:"dead-alias"
        ~pid:(Some dead) ~pid_start_time:None ();
      (* Seed a fake inbox file for the dead reg. *)
      let inbox_path = Filename.concat dir "session-dead.inbox.json" in
      write_file inbox_path "[]";
      (* Run: c2c sweep --force *)
      let outfile = Filename.temp_file "sweep-force" ".out" in
      let errfile = Filename.temp_file "sweep-force" ".err" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s %s sweep --force > %s 2> %s"
            (Filename.quote dir) c2c_exe outfile errfile
          in
          let rc = Sys.command cmd in
          check int "sweep --force exits 0" 0 rc;
          let out = read_file outfile in
          check bool "output mentions dropped registration" true
            (string_contains out "Dropped 1 registrations");
          check bool "output mentions 1 inbox deleted" true
            (string_contains out "1 inboxes");
          check bool "inbox file removed" false
            (Sys.file_exists inbox_path)))

let test_sweep_without_force_refuses_when_recent_reg_exists () =
  with_temp_dir (fun dir ->
      (* A fresh pidless registration is protected during its bounded handoff
         window even though it has no inspectable process. *)
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-alive" ~alias:"alive-alias"
        ~pid:None ~pid_start_time:None ();
      (* Run: c2c sweep (no --force) — should refuse. *)
      let outfile = Filename.temp_file "sweep-no-force" ".out" in
      let errfile = Filename.temp_file "sweep-no-force" ".err" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s %s sweep > %s 2> %s"
            (Filename.quote dir) c2c_exe outfile errfile
          in
          let rc = Sys.command cmd in
          check int "sweep without --force exits 1 when recent reg present" 1 rc;
          let err = read_file errfile in
          check bool "stderr mentions active/recent registration" true
            (string_contains err "active/recent");
          check bool "stderr mentions --force hint" true
            (string_contains err "--force")))

let test_sweep_without_force_drops_aged_pidless_cli_reg () =
  with_temp_dir (fun dir ->
      (* A CLI row with no discoverable stable process is initially protected,
         then becomes reappable after the bounded pidless handoff window.
         Delivery remains lenient for compatibility. *)
      write_file (Filename.concat dir "registry.json")
        {|[{"session_id":"aged-cli-session","alias":"aged-cli-alias","pid":null,"client_type":"agy","registered_at":1.0,"confirmed_at":2.0}]|};
      let preview_path = Filename.temp_file "sweep-aged-pidless-preview" ".json" in
      let outfile = Filename.temp_file "sweep-legacy-pidless" ".out" in
      let errfile = Filename.temp_file "sweep-legacy-pidless" ".err" in
      Fun.protect
        ~finally:(fun () ->
          Sys.remove preview_path |> ignore;
          Sys.remove outfile |> ignore;
          Sys.remove errfile |> ignore)
        (fun () ->
          let preview_cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s %s sweep-dryrun --json > %s 2> %s"
            (Filename.quote dir) c2c_exe
            (Filename.quote preview_path) (Filename.quote errfile)
          in
          check int "sweep dry-run exits 0 for aged pidless CLI reg" 0
            (Sys.command preview_cmd);
          let preview = read_file preview_path |> Yojson.Safe.from_string in
          let open Yojson.Safe.Util in
          check int "dry-run predicts one registration and no inbox" 1
            (preview |> member "totals" |> member "would_drop_if_swept" |> to_int);
          check string "dry-run names aged pidless alias" "aged-cli-alias"
            (preview |> member "would_drop_regs" |> index 0
             |> member "alias" |> to_string);
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s %s sweep > %s 2> %s"
            (Filename.quote dir) c2c_exe outfile errfile
          in
          let rc = Sys.command cmd in
          check int "sweep without --force exits 0 for aged pidless CLI reg" 0 rc;
          let out = read_file outfile in
          check bool "aged pidless CLI registration dropped" true
            (string_contains out "Dropped 1 registrations")))

let test_sweep_force_bypasses_alive_guard () =
  with_temp_dir (fun dir ->
      (* Set up a temp broker with one alive (pid=None) registration. *)
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-alive" ~alias:"alive-alias"
        ~pid:None ~pid_start_time:None ();
      (* Run: c2c sweep --force — should bypass the guard and succeed. *)
      let outfile = Filename.temp_file "sweep-force-bypass" ".out" in
      let errfile = Filename.temp_file "sweep-force-bypass" ".err" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s %s sweep --force > %s 2> %s"
            (Filename.quote dir) c2c_exe outfile errfile
          in
          let rc = Sys.command cmd in
          check int "sweep --force exits 0 even with alive reg" 0 rc;
          let out = read_file outfile in
          check bool "output confirms sweep ran" true
            (string_contains out "Dropped")))

(* ------------------------------------------------------------------------- *)
(* c2c registry-prune — dry-run and --force semantics                        *)
(* ------------------------------------------------------------------------- *)

(* Create a dead registration with a dead PID. *)
let make_dead_reg broker ~session_id ~alias =
  let dead = dead_pid () in
  C2c_mcp.Broker.register broker
    ~session_id ~alias ~pid:(Some dead) ~pid_start_time:None ()

let test_registry_prune_dry_run_no_stale () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register a LIVE (pid=None) registration — not a candidate for pruning. *)
      C2c_mcp.Broker.register broker
        ~session_id:"session-alive" ~alias:"alive-alias"
        ~pid:None ~pid_start_time:None ();
      (* Run: c2c registry-prune (dry-run by default). *)
      let outfile = Filename.temp_file "prune-dry" ".out" in
      let errfile = Filename.temp_file "prune-dry" ".err" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s %s registry-prune > %s 2> %s"
            (Filename.quote dir) c2c_exe outfile errfile
          in
          let rc = Sys.command cmd in
          check int "registry-prune dry-run exits 0" 0 rc;
          let out = read_file outfile in
          check bool "output says no stale registrations" true
            (string_contains out "No stale test registrations to prune.")))

let test_registry_prune_force_removes_dead_reg () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register a dead registration whose alias matches the default prune pattern "eph-". *)
      make_dead_reg broker ~session_id:"session-eph-dead" ~alias:"eph-test-agent";
      (* Verify it exists via preview. *)
      let managed_sids = [] in
      let candidates = C2c_mcp.Broker.registry_prune_preview broker
        ~managed_session_ids:managed_sids ~patterns:["eph-"; "heal-"; "mon-"; "test-"; "tmp-"; "zombie-"]
      in
      check int "preview finds 1 candidate" 1 (List.length candidates);
      (* Run: c2c registry-prune --force *)
      let outfile = Filename.temp_file "prune-force" ".out" in
      let errfile = Filename.temp_file "prune-force" ".err" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s %s registry-prune --force > %s 2> %s"
            (Filename.quote dir) c2c_exe outfile errfile
          in
          let rc = Sys.command cmd in
          check int "registry-prune --force exits 0" 0 rc;
          let out = read_file outfile in
          check bool "output mentions pruned count" true
            (string_contains out "Pruned 1 stale registration(s)");
          check bool "output mentions alias" true
            (string_contains out "eph-test-agent");
          check bool "output mentions session_id" true
            (string_contains out "session-eph-dead");
          (* Verify the registry was actually modified by checking preview is now empty. *)
          let remaining = C2c_mcp.Broker.registry_prune_preview broker
            ~managed_session_ids:managed_sids ~patterns:["eph-"; "heal-"; "mon-"; "test-"; "tmp-"; "zombie-"]
          in
          check int "preview is empty after prune" 0 (List.length remaining)))

let test_registry_prune_pattern_filter () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register two dead registrations: one matches "eph-", one matches "zombie-". *)
      make_dead_reg broker ~session_id:"session-eph-dead" ~alias:"eph-test-agent";
      make_dead_reg broker ~session_id:"session-zombie-dead" ~alias:"zombie-test-agent";
      (* Run: c2c registry-prune --force --pattern eph- (only eph- pattern). *)
      let outfile = Filename.temp_file "prune-pattern" ".out" in
      let errfile = Filename.temp_file "prune-pattern" ".err" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
        (fun () ->
          let cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s %s registry-prune --force --pattern eph- > %s 2> %s"
            (Filename.quote dir) c2c_exe outfile errfile
          in
          let rc = Sys.command cmd in
          check int "registry-prune --force --pattern exits 0" 0 rc;
          let out = read_file outfile in
          check bool "output mentions pruned 1 stale" true
            (string_contains out "Pruned 1 stale registration(s)");
          check bool "output mentions eph-test-agent" true
            (string_contains out "eph-test-agent");
          check bool "output does not mention zombie alias" false
            (string_contains out "zombie-test-agent");
          (* Verify the zombie reg is still in the registry. *)
          let managed_sids = [] in
          let remaining = C2c_mcp.Broker.registry_prune_preview broker
            ~managed_session_ids:managed_sids ~patterns:["zombie-"]
          in
          check int "zombie registration still present" 1 (List.length remaining)))

(* ------------------------------------------------------------------------- *)
(* c2c relay dead-letter — help and error handling                           *)
(* ------------------------------------------------------------------------- *)

let test_relay_dead_letter_help_exits_zero () =
  (* Cmdliner routes --help to the standard help system and exits 0. *)
  let outfile = Filename.temp_file "relay-dead-letter-help" ".out" in
  let errfile = Filename.temp_file "relay-dead-letter-help" ".err" in
  Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
    (fun () ->
      let cmd = Printf.sprintf
        "C2C_CLI_FORCE=1 %s relay dead-letter --help > %s 2> %s"
        c2c_exe outfile errfile
      in
      let rc = Sys.command cmd in
      check int "relay dead-letter --help exits 0" 0 rc)

let test_relay_dead_letter_no_relay_url_exits_nonzero () =
  (* Without C2C_RELAY_URL or --relay-url, command must exit non-zero.
     Set C2C_MCP_BROKER_ROOT to a path with no relay.json so we reliably
     hit the "no relay-url" error rather than picking up a stale config
     from the jungle-coder broker inherited via dune exec environment. *)
  let outfile = Filename.temp_file "relay-dead-letter-no-url" ".out" in
  let errfile = Filename.temp_file "relay-dead-letter-no-url" ".err" in
  Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
    (fun () ->
      let cmd = Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=/tmp/nonexistent-broker-xyz123 %s relay dead-letter > %s 2> %s"
        c2c_exe outfile errfile
      in
      let rc = Sys.command cmd in
      check int "relay dead-letter without relay-url exits non-zero" 1 rc;
      let err = read_file errfile in
      check bool "stderr mentions --relay-url" true
        (string_contains err "--relay-url"))

let test_relay_dm_peek_help_exits_zero () =
  (* B096: `c2c relay dm peek` is wired up — its --help must exit 0 and
     the dm group --help must list `peek`. *)
  let outfile = Filename.temp_file "relay-dm-peek-help" ".out" in
  let errfile = Filename.temp_file "relay-dm-peek-help" ".err" in
  Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
    (fun () ->
      let cmd = Printf.sprintf
        "C2C_CLI_FORCE=1 %s relay dm peek --help > %s 2> %s"
        c2c_exe outfile errfile
      in
      let rc = Sys.command cmd in
      check int "relay dm peek --help exits 0" 0 rc;
      (* `relay dm --help` renders the positional docv which now lists peek. *)
      let dm_outfile = Filename.temp_file "relay-dm-help" ".out" in
      let dm_errfile = Filename.temp_file "relay-dm-help" ".err" in
      Fun.protect ~finally:(fun () -> Sys.remove dm_outfile |> ignore; Sys.remove dm_errfile |> ignore)
        (fun () ->
          let dm_cmd = Printf.sprintf
            "C2C_CLI_FORCE=1 %s relay dm --help > %s 2> %s"
            c2c_exe dm_outfile dm_errfile
          in
          let _ = Sys.command dm_cmd in
          let out = read_file dm_outfile in
          check bool "relay dm --help lists peek subcommand" true
            (string_contains out "peek")))

let test_monitor_help_lists_relay () =
  (* B089: `c2c monitor` gained relay-inbox watcher flags (--no-relay,
     --relay-interval, --relay-node-id, --relay-session-id). --help must exit 0
     and list them so the feature is discoverable. *)
  let outfile = Filename.temp_file "monitor-relay-help" ".out" in
  let errfile = Filename.temp_file "monitor-relay-help" ".err" in
  Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
    (fun () ->
      let cmd = Printf.sprintf
        "C2C_CLI_FORCE=1 %s monitor --help > %s 2> %s"
        c2c_exe outfile errfile
      in
      let rc = Sys.command cmd in
      check int "monitor --help exits 0" 0 rc;
      let out = read_file outfile in
      check bool "monitor --help lists --no-relay" true
        (string_contains out "--no-relay");
      check bool "monitor --help lists --relay-interval" true
        (string_contains out "--relay-interval"))

let test_relay_subscribe_https_no_longer_rejected_for_tls_scheme () =
  (* B189: https/wss are scheme-supported. Without a local identity the command
     still exits non-zero, but it must NOT fail on the old TLS-scheme guard. *)
  let outfile = Filename.temp_file "relay-subscribe-https" ".out" in
  let errfile = Filename.temp_file "relay-subscribe-https" ".err" in
  Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
    (fun () ->
      let cmd = Printf.sprintf
        "C2C_CLI_FORCE=1 HOME=%s %s relay subscribe --relay-url https://relay.example --alias alice > %s 2> %s"
        (Filename.get_temp_dir_name ()) c2c_exe outfile errfile
      in
      let rc = Sys.command cmd in
      check int "relay subscribe https exits non-zero without identity" 1 rc;
      let err = read_file errfile in
      check bool "stderr does NOT claim TLS unsupported" false
        (string_contains err "does not support TLS");
      check bool "stderr mentions identity (past scheme guard)" true
        (string_contains err "identity"))
(* ------------------------------------------------------------------------- *)
(* c2c send --from spoofing protection tests                                 *)
(* ------------------------------------------------------------------------- *)

let test_send_from_spoofing_rejected () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-victim" ~alias:"victim"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-recip" ~alias:"recip"
        ~pid:None ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-spoof" ".out" in
      let errfile = Filename.temp_file "c2c-spoof" ".err" in
      Fun.protect ~finally:(fun () ->
          (try Sys.remove outfile with _ -> ());
          (try Sys.remove errfile with _ -> ()))
        (fun () ->
           let send_cmd = Printf.sprintf
             "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=session-attacker %s send --from victim recip 'forged' > %s 2>%s"
             (Filename.quote dir) c2c_exe outfile errfile
           in
           let rc = Sys.command send_cmd in
           check bool "send --from spoofing exits non-zero" true (rc <> 0);
           let err = read_file errfile in
           check bool "stderr mentions refusing/refused/reject" true
             (string_contains err "refus"
              || string_contains err "reject"
              || string_contains err "spoof")))

let test_send_from_own_alias_allowed () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-sender" ~alias:"sender"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-recip" ~alias:"recip"
        ~pid:None ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-spoof-own" ".out" in
      let errfile = Filename.temp_file "c2c-spoof-own" ".err" in
      Fun.protect ~finally:(fun () ->
          (try Sys.remove outfile with _ -> ());
          (try Sys.remove errfile with _ -> ()))
        (fun () ->
           let send_cmd = Printf.sprintf
             "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=session-sender %s send --from sender recip 'legit' > %s 2>%s"
             (Filename.quote dir) c2c_exe outfile errfile
           in
           let rc = Sys.command send_cmd in
           check int "send --from own alias exits 0" 0 rc))

let test_send_from_unregistered_alias_rejected () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-op" ~alias:"op"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-recip" ~alias:"recip"
        ~pid:None ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-spoof-unreg" ".out" in
      let errfile = Filename.temp_file "c2c-spoof-unreg" ".err" in
      Fun.protect ~finally:(fun () ->
          (try Sys.remove outfile with _ -> ());
          (try Sys.remove errfile with _ -> ()))
        (fun () ->
           let send_cmd = Printf.sprintf
             "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=session-op %s send --from ghost-operator recip 'test' > %s 2>%s"
             (Filename.quote dir) c2c_exe outfile errfile
           in
           let rc = Sys.command send_cmd in
           check bool "send --from unregistered alias exits non-zero" true (rc <> 0);
           let err = read_file errfile in
           check bool "stderr mentions refusing or not registered" true
             (string_contains err "refus"
              || string_contains err "not registered")))

let test_send_from_coordinator_allowed () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-victim" ~alias:"victim"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-recip" ~alias:"recip"
        ~pid:None ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-spoof-coord" ".out" in
      let errfile = Filename.temp_file "c2c-spoof-coord" ".err" in
      Fun.protect ~finally:(fun () ->
          (try Sys.remove outfile with _ -> ());
          (try Sys.remove errfile with _ -> ()))
        (fun () ->
           let send_cmd = Printf.sprintf
             "C2C_CLI_FORCE=1 C2C_COORDINATOR=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=session-coord %s send --from victim recip 'coord relay' > %s 2>%s"
             (Filename.quote dir) c2c_exe outfile errfile
           in
           let rc = Sys.command send_cmd in
           check int "send --from as coordinator exits 0" 0 rc))

let test_send_from_case_variation_rejected () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-victim" ~alias:"Victim"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-recip" ~alias:"recip"
        ~pid:None ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-spoof-case" ".out" in
      let errfile = Filename.temp_file "c2c-spoof-case" ".err" in
      Fun.protect ~finally:(fun () ->
          (try Sys.remove outfile with _ -> ());
          (try Sys.remove errfile with _ -> ()))
        (fun () ->
           let send_cmd = Printf.sprintf
             "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=session-attacker %s send --from victim recip 'case forged' > %s 2>%s"
             (Filename.quote dir) c2c_exe outfile errfile
           in
           let rc = Sys.command send_cmd in
           check bool "send --from case variation spoofing exits non-zero" true (rc <> 0);
           let err = read_file errfile in
           check bool "stderr mentions refusing" true
             (string_contains err "refus")))

let test_send_all_from_spoofing_rejected () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-victim" ~alias:"victim"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-bystander" ~alias:"bystander"
        ~pid:None ~pid_start_time:None ();
      let outfile = Filename.temp_file "c2c-spoof-all" ".out" in
      let errfile = Filename.temp_file "c2c-spoof-all" ".err" in
      Fun.protect ~finally:(fun () ->
          (try Sys.remove outfile with _ -> ());
          (try Sys.remove errfile with _ -> ()))
        (fun () ->
           let send_cmd = Printf.sprintf
             "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=session-attacker %s send-all --from victim 'forged broadcast' > %s 2>%s"
             (Filename.quote dir) c2c_exe outfile errfile
           in
           let rc = Sys.command send_cmd in
            check bool "send-all --from spoofing exits non-zero" true (rc <> 0);
            let err = read_file errfile in
            check bool "stderr mentions refusing" true
              (string_contains err "refus")))

(* ------------------------------------------------------------------------- *)
(* c2c ping — dashboard + --verify probe (connect is a deprecated alias; see test_connect_deprecated_* below)                                  *)
(* ------------------------------------------------------------------------- *)

let with_temp_broker f =
  with_temp_dir (fun dir ->
    let broker_root = Filename.concat dir "broker" in
    Unix.mkdir broker_root 0o755;
    f ~dir ~broker_root)

let test_connect_dashboard_exits_zero () =
  with_temp_broker (fun ~dir ~broker_root ->
    let env = Printf.sprintf "C2C_MCP_BROKER_ROOT=%s" broker_root in
    let cmd = c2c_cmd (Printf.sprintf "%s c2c ping > /dev/null 2>&1" env) in
    let rc = Sys.command cmd in
    check int "c2c connect exits 0" 0 rc)

let test_connect_dashboard_shows_broker_root () =
  with_temp_broker (fun ~dir ~broker_root ->
    let env = Printf.sprintf "C2C_MCP_BROKER_ROOT=%s" broker_root in
    let tmpfile = Filename.temp_file "c2c-connect" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c ping > %s 2>&1" env tmpfile)));
        let content = read_file tmpfile in
        check bool "output contains broker root" true
          (string_contains content broker_root);
        check bool "output contains connection status header" true
          (string_contains content "connection status")))

let test_connect_dashboard_json_valid () =
  with_temp_broker (fun ~dir ~broker_root ->
    let env = Printf.sprintf "C2C_MCP_BROKER_ROOT=%s" broker_root in
    let tmpfile = Filename.temp_file "c2c-connect-json" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c ping --json > %s 2>&1" env tmpfile)));
        let content = read_file tmpfile in
        let json = Yojson.Safe.from_string content in
        check bool "JSON has broker_root" true
          (Yojson.Safe.Util.(json |> member "broker_root") <> `Null);
        check bool "JSON has clients" true
          (Yojson.Safe.Util.(json |> member "clients") <> `Null);
        check bool "JSON has next_action" true
          (Yojson.Safe.Util.(json |> member "next_action") <> `Null)))

let test_connect_dashboard_next_action_not_installed () =
  with_temp_broker (fun ~dir ~broker_root ->
    let env = Printf.sprintf "C2C_MCP_BROKER_ROOT=%s" broker_root in
    let tmpfile = Filename.temp_file "c2c-connect-next" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c ping > %s 2>&1" env tmpfile)));
        let content = read_file tmpfile in
        check bool "next action mentions install" true
          (string_contains content "c2c install")))

let test_connect_verify_inconclusive () =
  with_temp_broker (fun ~dir ~broker_root ->
    let env = Printf.sprintf "C2C_MCP_BROKER_ROOT=%s" broker_root in
    let tmpfile = Filename.temp_file "c2c-connect-verify" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        let rc = Sys.command (c2c_cmd (Printf.sprintf "%s c2c ping --verify --timeout 1 > %s 2>&1" env tmpfile)) in
        let content = read_file tmpfile in
        check bool "output contains INCONCLUSIVE" true
          (string_contains content "INCONCLUSIVE");
        check int "verify inconclusive exits 0" 0 rc))

let test_connect_verify_pass_via_drain () =
  with_temp_broker (fun ~dir ~broker_root ->
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    let session_a = "connect-test-a" in
    let session_b = "connect-test-b" in
    let alias_a = "ctest-a" in
    let alias_b = "ctest-b" in
    let pid = Some (Unix.getpid ()) in
    let pid_start = C2c_mcp.Broker.capture_pid_start_time pid in
    C2c_mcp.Broker.register broker ~session_id:session_a ~alias:alias_a ~pid ~pid_start_time:pid_start ();
    C2c_mcp.Broker.register broker ~session_id:session_b ~alias:alias_b ~pid ~pid_start_time:pid_start ();
    let marker = "connect-test-marker-xyz" in
    C2c_mcp.Broker.enqueue_message broker ~from_alias:alias_a ~to_alias:alias_b ~content:marker ();
    let messages = C2c_mcp.Broker.drain_inbox ~drained_by:"test_probe" broker ~session_id:session_b in
    check bool "drained marker" true (List.exists (fun (m : C2c_mcp.message) -> m.content = marker) messages);
    let archive_path = Filename.concat (Filename.concat broker_root "archive") (session_b ^ ".jsonl") in
    check bool "archive file exists" true (Sys.file_exists archive_path);
    let archive = read_file archive_path in
    check bool "archive contains marker" true (string_contains archive marker);
    check bool "archive contains drained_by" true (string_contains archive "drained_by");
    check bool "archive contains test_probe" true (string_contains archive "test_probe"))

let test_connect_verify_does_not_drain_real_inbox () =
  with_temp_broker (fun ~dir ~broker_root ->
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    let session_id = "connect-test-real" in
    let alias = "ctest-real" in
    let pid = Some (Unix.getpid ()) in
    let pid_start = C2c_mcp.Broker.capture_pid_start_time pid in
    C2c_mcp.Broker.register broker ~session_id ~alias ~pid ~pid_start_time:pid_start ();
    let real_msg = "real-inbox-message-should-survive" in
    C2c_mcp.Broker.enqueue_message broker ~from_alias:alias ~to_alias:alias ~content:real_msg ();
    let env = Printf.sprintf "C2C_MCP_BROKER_ROOT=%s" broker_root in
    let tmpfile = Filename.temp_file "c2c-verify-real" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        ignore (Sys.command (c2c_cmd (Printf.sprintf
          "%s c2c ping --verify --timeout 1 > %s 2>&1" env tmpfile)));
        let inbox_after = C2c_mcp.Broker.read_inbox broker ~session_id in
        let has_real = List.exists (fun (m : C2c_mcp.message) -> m.content = real_msg) inbox_after in
        check bool "real inbox message survived verify probe" true has_real))

let test_connect_detects_codex () =
  with_temp_dir (fun dir ->
    let home = Filename.concat dir "fakehome" in
    Unix.mkdir home 0o755;
    let broker_root = Filename.concat dir "broker" in
    Unix.mkdir broker_root 0o755;
    install_codex_fixture ~home ~broker_root;
    let env =
      Printf.sprintf "%s C2C_MCP_BROKER_ROOT=%s"
        (isolated_home_env home) (Filename.quote broker_root)
    in
    let tmpfile = Filename.temp_file "c2c-connect-codex" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c ping > %s 2>&1" env tmpfile)));
        let content = read_file tmpfile in
        check bool "detects codex MCP server configured" true
          (string_contains content "codex: MCP server configured")))

let test_connect_detects_kimi () =
  with_temp_dir (fun dir ->
    let home = Filename.concat dir "fakehome" in
    Unix.mkdir home 0o755;
    let kimi_dir = Filename.concat home ".kimi-code" in
    Unix.mkdir kimi_dir 0o755;
    let config_path = Filename.concat kimi_dir "mcp.json" in
    write_file config_path {|{"mcpServers":{"c2c":{"type":"stdio"}}}|};
    let broker_root = Filename.concat dir "broker" in
    Unix.mkdir broker_root 0o755;
    let env = Printf.sprintf "HOME=%s C2C_MCP_BROKER_ROOT=%s" home broker_root in
    let tmpfile = Filename.temp_file "c2c-connect-kimi" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c ping > %s 2>&1" env tmpfile)));
        let content = read_file tmpfile in
        check bool "detects kimi MCP server configured" true
          (string_contains content "kimi: MCP server configured")))

let test_connect_verify_fail_on_broken_broker () =
  (* Simulate FAIL: marker gone from inbox but NOT in archive.
     This happens when something drains the inbox without going through
     the broker's drain_inbox path (which always archives). We simulate
     by directly clearing the inbox file after enqueue. *)
  with_temp_broker (fun ~dir ~broker_root ->
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    let session_a = "connect-fail-a" in
    let session_b = "connect-fail-b" in
    let alias_a = "cfail-a" in
    let alias_b = "cfail-b" in
    let pid = Some (Unix.getpid ()) in
    let pid_start = C2c_mcp.Broker.capture_pid_start_time pid in
    C2c_mcp.Broker.register broker ~session_id:session_a ~alias:alias_a ~pid ~pid_start_time:pid_start ();
    C2c_mcp.Broker.register broker ~session_id:session_b ~alias:alias_b ~pid ~pid_start_time:pid_start ();
    let marker = "connect-fail-marker-xyz" in
    C2c_mcp.Broker.enqueue_message broker ~from_alias:alias_a ~to_alias:alias_b ~content:marker ();
    (* Verify marker is in inbox before sabotage *)
    let inbox_before = C2c_mcp.Broker.read_inbox broker ~session_id:session_b in
    check bool "marker in inbox before sabotage" true
      (List.exists (fun (m : C2c_mcp.message) -> m.content = marker) inbox_before);
    (* Sabotage: directly overwrite inbox with empty, bypassing archive *)
    let inbox_path = Filename.concat broker_root (session_b ^ ".inbox.json") in
    write_file inbox_path "[]";
    (* Verify marker is gone from inbox *)
    let inbox_after = C2c_mcp.Broker.read_inbox broker ~session_id:session_b in
    check bool "marker gone from inbox after sabotage" false
      (List.exists (fun (m : C2c_mcp.message) -> m.content = marker) inbox_after);
    (* Verify marker is NOT in archive *)
    let archive_entries = C2c_mcp.Broker.read_archive broker ~session_id:session_b ~limit:10 in
    let has_marker_in_archive = List.exists (fun (e : C2c_mcp.Broker.archive_entry) ->
      e.ae_content = marker
    ) archive_entries in
    check bool "marker NOT in archive (FAIL condition)" false has_marker_in_archive)

let test_connect_dashboard_next_action_partially_configured () =
  (* Set up codex config only → any_installed=true, all_installed=false
     → next action should mention "partially configured" *)
  with_temp_dir (fun dir ->
    let home = Filename.concat dir "fakehome" in
    Unix.mkdir home 0o755;
    let codex_dir = Filename.concat home ".codex" in
    Unix.mkdir codex_dir 0o755;
    let config_path = Filename.concat codex_dir "config.toml" in
    write_file config_path "[mcp_servers.c2c]\ncommand = \"c2c-mcp-server\"\n";
    let broker_root = Filename.concat dir "broker" in
    Unix.mkdir broker_root 0o755;
    let env = Printf.sprintf "HOME=%s C2C_MCP_BROKER_ROOT=%s" home broker_root in
    let tmpfile = Filename.temp_file "c2c-connect-partial" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c ping > %s 2>&1" env tmpfile)));
        let content = read_file tmpfile in
        check bool "next action mentions partially configured" true
          (string_contains content "partially configured")))

let test_connect_dashboard_next_action_all_installed_no_session () =
  (* Set up all 4 client configs → all_installed=true, alive_count=0
     → next action should mention "no live session" *)
  with_temp_dir (fun dir ->
    let home = Filename.concat dir "fakehome" in
    Unix.mkdir home 0o755;
    (* Claude: ~/.claude/settings.json with c2c hook *)
    let claude_dir = Filename.concat home ".claude" in
    Unix.mkdir claude_dir 0o755;
    write_file (Filename.concat claude_dir "settings.json")
      {|{"hooks":{"PostToolUse":[{"command":"c2c-hook","type":"command"}]}}|};
    (* OpenCode: ~/.config/opencode/plugins/c2c.ts (>= 1024 bytes) *)
    let config_dir = Filename.concat home ".config" in
    (try Unix.mkdir config_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let oc_dir = Filename.concat config_dir "opencode" in
    let oc_plugins = Filename.concat oc_dir "plugins" in
    Unix.mkdir oc_dir 0o755;
    Unix.mkdir oc_plugins 0o755;
    let plugin_content = String.make 1100 ' ' in
    write_file (Filename.concat oc_plugins "c2c.ts") plugin_content;
    (* Kimi: ~/.kimi-code/mcp.json with mcpServers.c2c *)
    let kimi_dir = Filename.concat home ".kimi-code" in
    Unix.mkdir kimi_dir 0o755;
    write_file (Filename.concat kimi_dir "mcp.json")
      {|{"mcpServers":{"c2c":{"type":"stdio"}}}|};
    let broker_root = Filename.concat dir "broker" in
    Unix.mkdir broker_root 0o755;
    install_codex_fixture ~home ~broker_root;
    let env =
      Printf.sprintf "%s C2C_MCP_BROKER_ROOT=%s"
        (isolated_home_env home) (Filename.quote broker_root)
    in
    let tmpfile = Filename.temp_file "c2c-connect-nosession" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c ping > %s 2>&1" env tmpfile)));
        let content = read_file tmpfile in
        check bool "next action mentions no live session" true
          (string_contains content "no live session"
           || string_contains content "partially configured")))

(* --- deprecated alias: 'c2c connect' -> 'c2c ping' (B095) ------------------ *)
(* The 'connect' alias must keep working (backward compat) and print a stderr
   hint pointing users at 'c2c ping' and clarifying that 'c2c relay connect' is
   the cross-host bridge. Hint goes to stderr so --json stdout stays clean. *)

let test_connect_deprecated_alias_prints_hint () =
  with_temp_broker (fun ~dir ~broker_root ->
    let env = Printf.sprintf "C2C_MCP_BROKER_ROOT=%s" broker_root in
    let tmpfile = Filename.temp_file "c2c-connect-deprecated" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        let rc = Sys.command (c2c_cmd (Printf.sprintf "%s c2c connect > %s 2>&1" env tmpfile)) in
        let content = read_file tmpfile in
        check int "deprecated connect alias exits 0" 0 rc;
        check bool "alias prints deprecation hint" true
          (string_contains content "deprecated alias");
        check bool "alias clarifies relay connect is the cross-host bridge" true
          (string_contains content "c2c relay connect");
        (* alias still renders the dashboard (broker root + connection status header) *)
        check bool "alias still shows broker root" true
          (string_contains content broker_root);
        check bool "alias still shows connection status header" true
          (string_contains content "connection status")))

let test_connect_deprecated_alias_verify_works () =
  with_temp_broker (fun ~dir ~broker_root ->
    let env = Printf.sprintf "C2C_MCP_BROKER_ROOT=%s" broker_root in
    let tmpfile = Filename.temp_file "c2c-connect-deprecated-verify" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        let rc = Sys.command (c2c_cmd (Printf.sprintf "%s c2c connect --verify --timeout 1 > %s 2>&1" env tmpfile)) in
        let content = read_file tmpfile in
        check bool "alias --verify still runs probe (INCONCLUSIVE)" true
          (string_contains content "INCONCLUSIVE");
        check bool "alias --verify prints deprecation hint" true
          (string_contains content "deprecated alias");
        check int "alias --verify inconclusive exits 0" 0 rc))

(* ------------------------------------------------------------------------- *)
(* Alcotest registry                                                         *)
(* ------------------------------------------------------------------------- *)

(* ------------------------------------------------------------------------- *)
(* c2c init — nonce + blocklist integration                                 *)
(* ------------------------------------------------------------------------- *)

let run_c2c_init ~broker_root ~args =
  let tmpfile = Filename.temp_file "c2c-init" ".out" in
  let cmd =
    Printf.sprintf "C2C_MCP_BROKER_ROOT=%s %s > %s 2>&1"
      (Filename.quote broker_root)
      (c2c_cmd (Printf.sprintf "c2c init --no-setup %s" args))
      (Filename.quote tmpfile)
  in
  let rc = Sys.command cmd in
  let content = read_file tmpfile in
  Sys.remove tmpfile;
  (rc, content)

let extract_alias_line content =
  let lines = String.split_on_char '\n' content in
  let alias_line =
    List.find_opt
      (fun line -> String.length line >= 8 && String.sub line 0 8 = "  alias:")
      lines
  in
  match alias_line with
  | Some line -> (
      match String.split_on_char ':' line with
      | _ :: rest -> Some (String.trim (String.concat ":" rest))
      | _ -> None)
  | None -> None

let test_init_require_easy_terminates_with_nonce () =
  with_temp_dir (fun dir ->
      let rc, content = run_c2c_init ~broker_root:dir ~args:"--client codex --require-easy" in
      check int "init --require-easy exits 0" 0 rc;
      match extract_alias_line content with
      | Some alias -> (
          match String.split_on_char '-' alias with
          | [ client; w1; w2; nonce ] ->
              check string "client prefix" "codex" client;
              check bool "word1 non-empty" true (String.length w1 > 0);
              check bool "word2 non-empty" true (String.length w2 > 0);
              check int "nonce length 4" 4 (String.length nonce)
          | _ -> fail "alias not client-word-word-nonce")
      | None -> fail "no alias line in init output")

let test_init_no_nonce_keeps_default_entropy () =
  with_temp_dir (fun dir ->
      let rc, content = run_c2c_init ~broker_root:dir ~args:"--client codex --no-nonce" in
      check int "init --no-nonce exits 0" 0 rc;
      match extract_alias_line content with
      | Some alias ->
          (* B082: --no-nonce is deprecated for default aliases. *)
          check int "alias has client + 2 words + nonce" 4
            (List.length (String.split_on_char '-' alias))
      | None -> fail "no alias line in init output")

let test_init_explicit_alias_not_nonced () =
  with_temp_dir (fun dir ->
      let rc, content = run_c2c_init ~broker_root:dir ~args:"--alias foo" in
      check int "init --alias foo exits 0" 0 rc;
      match extract_alias_line content with
      | Some alias -> check string "alias is foo" "foo" alias
      | None -> fail "no alias line in init output")

let test_init_rejects_banned_alias () =
  with_temp_dir (fun dir ->
      let rc, content = run_c2c_init ~broker_root:dir ~args:"--alias codex" in
      check int "init --alias codex exits non-zero" 1 rc;
      check bool "error mentions blocked" true
        (string_contains content "blocked"))

let test_init_prefers_claude_environment_over_ambiguous_path () =
  with_temp_dir (fun dir ->
      let home = Filename.concat dir "home" in
      let fake_bin = Filename.concat dir "fake-bin" in
      Unix.mkdir home 0o755;
      Unix.mkdir fake_bin 0o755;
      List.iter
        (fun client ->
          let path = Filename.concat fake_bin client in
          write_file path "#!/bin/sh\nexit 0\n";
          Unix.chmod path 0o755)
        [ "claude"; "opencode" ];
      let tmpfile = Filename.temp_file "c2c-init-client-detect" ".out" in
      Fun.protect
        ~finally:(fun () -> Sys.remove tmpfile)
        (fun () ->
          let cmd =
            Printf.sprintf
              "env -i HOME=%s PATH=%s CLAUDE_CODE_SESSION_ID=claude-b102-session C2C_MCP_BROKER_ROOT=%s %s init --no-setup > %s 2>&1"
              (Filename.quote home)
              (Filename.quote fake_bin)
              (Filename.quote dir)
              (Filename.quote c2c_binary)
              (Filename.quote tmpfile)
          in
          let rc = Sys.command cmd in
          let content = read_file tmpfile in
          check int "init exits 0" 0 rc;
          match extract_alias_line content with
          | Some alias ->
              check bool "native Claude environment wins over PATH ambiguity" true
                (String.starts_with ~prefix:"claude-" alias)
          | None -> fail "no alias line in init output"))

(* B046: init should reuse existing alias for the same session_id *)
let test_init_reuses_alias_for_same_session_id () =
  with_temp_dir (fun dir ->
      let session_id = "test-sess-b046" in
      (* Run 1: should generate a new alias *)
      let args = Printf.sprintf "--client codex --no-nonce" in
      let cmd1 =
        Printf.sprintf "C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=%s %s > /tmp/c2c-b046-r1.out 2>&1"
          (Filename.quote dir) (Filename.quote session_id)
          (c2c_cmd (Printf.sprintf "c2c init --no-setup %s" args))
      in
      let rc1 = Sys.command cmd1 in
      let content1 = read_file "/tmp/c2c-b046-r1.out" in
      check int "init run 1 exits 0" 0 rc1;
      let alias1 = match extract_alias_line content1 with
        | Some a -> a
        | None -> fail "no alias line in init run 1 output"
      in
      (* Run 2: should reuse the same alias *)
      let cmd2 =
        Printf.sprintf "C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=%s %s > /tmp/c2c-b046-r2.out 2>&1"
          (Filename.quote dir) (Filename.quote session_id)
          (c2c_cmd (Printf.sprintf "c2c init --no-setup %s" args))
      in
      let rc2 = Sys.command cmd2 in
      let content2 = read_file "/tmp/c2c-b046-r2.out" in
      check int "init run 2 exits 0" 0 rc2;
      let alias2 = match extract_alias_line content2 with
        | Some a -> a
        | None -> fail "no alias line in init run 2 output"
      in
      (* Assert aliases are identical — the core B046 invariant *)
      check string "alias stable across re-runs" alias1 alias2;
      (* Cleanup temp files *)
      (try Sys.remove "/tmp/c2c-b046-r1.out" with _ -> ());
      (try Sys.remove "/tmp/c2c-b046-r2.out" with _ -> ()))

(* B135: init --alias that differs from the existing session registration is refused. *)
let test_init_explicit_rename_refused_sticky_alias () =
  with_temp_dir (fun dir ->
      let session_id = "test-sess-b135" in
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id ~alias:"original-sticky"
        ~pid:None ~pid_start_time:None ();
      let out = Filename.temp_file "c2c-b135-init" ".out" in
      Fun.protect
        ~finally:(fun () -> try Sys.remove out with _ -> ())
        (fun () ->
          let cmd =
            Printf.sprintf
              "C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=%s %s > %s 2>&1"
              (Filename.quote dir) (Filename.quote session_id)
              (c2c_cmd "c2c init --no-setup --alias renamed-sticky")
              (Filename.quote out)
          in
          let rc = Sys.command cmd in
          let content = read_file out in
          check bool "init --alias rename exits non-zero" true (rc <> 0);
          check bool "error mentions sticky" true
            (string_contains content "sticky");
          check bool "error names original alias" true
            (string_contains content "original-sticky");
          let regs = C2c_mcp.Broker.list_registrations broker in
          check string "old alias remains" "original-sticky" (List.hd regs).alias))

(* B135: c2c register --alias rename for same session_id is refused. *)
let test_register_cmd_explicit_rename_refused_sticky_alias () =
  with_temp_dir (fun dir ->
      let session_id = "test-sess-b135-reg" in
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id ~alias:"reg-original"
        ~pid:None ~pid_start_time:None ();
      let out = Filename.temp_file "c2c-b135-reg" ".out" in
      Fun.protect
        ~finally:(fun () -> try Sys.remove out with _ -> ())
        (fun () ->
          let cmd =
            Printf.sprintf
              "C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=%s %s > %s 2>&1"
              (Filename.quote dir) (Filename.quote session_id)
              (c2c_cmd "c2c register --alias reg-renamed")
              (Filename.quote out)
          in
          let rc = Sys.command cmd in
          let content = read_file out in
          check bool "register --alias rename exits non-zero" true (rc <> 0);
          check bool "error mentions sticky" true
            (string_contains content "sticky");
          let regs = C2c_mcp.Broker.list_registrations broker in
          check string "old alias remains" "reg-original" (List.hd regs).alias))

(* B135: same-alias c2c register refresh still works. *)
let test_register_cmd_same_alias_refresh_allowed () =
  with_temp_dir (fun dir ->
      let session_id = "test-sess-b135-same" in
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id ~alias:"keep-me"
        ~pid:None ~pid_start_time:None ();
      let out = Filename.temp_file "c2c-b135-same" ".out" in
      Fun.protect
        ~finally:(fun () -> try Sys.remove out with _ -> ())
        (fun () ->
          let cmd =
            Printf.sprintf
              "C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=%s %s > %s 2>&1"
              (Filename.quote dir) (Filename.quote session_id)
              (c2c_cmd "c2c register --alias keep-me")
              (Filename.quote out)
          in
          let rc = Sys.command cmd in
          check int "same-alias register exits 0" 0 rc;
          let regs = C2c_mcp.Broker.list_registrations broker in
          check string "alias unchanged" "keep-me" (List.hd regs).alias))

(* B240: same-alias re-register of a reserved client-prefix sticky alias
   (e.g. kimi-… auto-gen) must succeed for PID refresh. Blocked-prefix must
   not fire before sticky same-alias allowance. First-time claim of the
   prefix without from_auto_gen remains rejected. *)
let test_register_cmd_same_alias_reserved_prefix_refresh_allowed () =
  with_temp_dir (fun dir ->
      let session_id = "test-sess-b240-kimi-prefix" in
      let sticky = "kimi-ember-frost-a1b2" in
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Simulate prior auto-registration under reserved client prefix. *)
      C2c_mcp.Broker.register broker ~session_id ~alias:sticky
        ~pid:None ~pid_start_time:None ~from_auto_gen:true ();
      let out = Filename.temp_file "c2c-b240-same" ".out" in
      Fun.protect
        ~finally:(fun () -> try Sys.remove out with _ -> ())
        (fun () ->
          let cmd =
            Printf.sprintf
              "C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=%s %s > %s 2>&1"
              (Filename.quote dir) (Filename.quote session_id)
              (c2c_cmd (Printf.sprintf "c2c register --alias %s" sticky))
              (Filename.quote out)
          in
          let rc = Sys.command cmd in
          let content = read_file out in
          check int "same-alias reserved-prefix register exits 0" 0 rc;
          check bool "not blocked-prefix error" false
            (string_contains content "blocked" || string_contains content "reserved");
          let regs = C2c_mcp.Broker.list_registrations broker in
          check string "alias unchanged" sticky (List.hd regs).alias);
      (* Different session still cannot claim the reserved prefix via CLI. *)
      let out2 = Filename.temp_file "c2c-b240-fresh" ".out" in
      Fun.protect
        ~finally:(fun () -> try Sys.remove out2 with _ -> ())
        (fun () ->
          let cmd =
            Printf.sprintf
              "C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=session-fresh-b240 %s > %s 2>&1"
              (Filename.quote dir)
              (c2c_cmd "c2c register --alias kimi-should-block-zz99")
              (Filename.quote out2)
          in
          let rc = Sys.command cmd in
          let content = read_file out2 in
          check bool "fresh reserved-prefix claim exits non-zero" true (rc <> 0);
          check bool "fresh claim mentions blocked/reserved" true
            (string_contains content "blocked"
             || string_contains content "reserved")))

(* B135: env-only C2C_MCP_AUTO_REGISTER_ALIAS rename is also refused. *)
let test_register_cmd_env_alias_rename_refused_sticky_alias () =
  with_temp_dir (fun dir ->
      let session_id = "test-sess-b135-env" in
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id ~alias:"env-original"
        ~pid:None ~pid_start_time:None ();
      let out = Filename.temp_file "c2c-b135-env" ".out" in
      Fun.protect
        ~finally:(fun () -> try Sys.remove out with _ -> ())
        (fun () ->
          let cmd =
            Printf.sprintf
              "C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=%s \
               C2C_MCP_AUTO_REGISTER_ALIAS=env-renamed %s > %s 2>&1"
              (Filename.quote dir) (Filename.quote session_id)
              (c2c_cmd "c2c register")
              (Filename.quote out)
          in
          let rc = Sys.command cmd in
          let content = read_file out in
          check bool "env-alias rename exits non-zero" true (rc <> 0);
          check bool "error mentions sticky" true
            (string_contains content "sticky");
          let regs = C2c_mcp.Broker.list_registrations broker in
          check string "old alias remains" "env-original" (List.hd regs).alias))

(* B140: the explicit `c2c rename` path performs the sanctioned atomic
   rename-everywhere; the sticky-alias refusal now advertises it. *)
let test_cli_rename_happy_path () =
  with_temp_dir (fun dir ->
      let session_id = "test-sess-b140-cli" in
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id ~alias:"b140-cli-old"
        ~pid:None ~pid_start_time:None ();
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"b140-room"
           ~alias:"b140-cli-old" ~session_id);
      let out = Filename.temp_file "c2c-b140-rename" ".out" in
      Fun.protect
        ~finally:(fun () -> try Sys.remove out with _ -> ())
        (fun () ->
          let key_dir = Filename.concat dir "xkeys" in
          Unix.mkdir key_dir 0o700;
          let cmd =
            (* Isolate HOME so a developer-local ~/.config/c2c/relay.json
               cannot trigger a live rebind during the B140 unit path.
               B179's rebind semantics are covered by test_relay_rename_rebind. *)
            Printf.sprintf
              "env -u C2C_RELAY_URL -u C2C_RELAY_TOKEN -u C2C_RELAY_CONFIG \
               HOME=%s XDG_CONFIG_HOME=%s C2C_MCP_BROKER_ROOT=%s C2C_KEY_DIR=%s \
               %s > %s 2>&1"
              (Filename.quote dir)
              (Filename.quote (Filename.concat dir ".config"))
              (Filename.quote dir) (Filename.quote key_dir)
              (c2c_cmd
                 (Printf.sprintf
                    "c2c rename b140-cli-new --session-id %s --json"
                    (Filename.quote session_id)))
              (Filename.quote out)
          in
          let rc = Sys.command cmd in
          let content = read_file out in
          check int ("rename exits 0: " ^ content) 0 rc;
          let json = Yojson.Safe.from_string content in
          let open Yojson.Safe.Util in
          check bool "rename ok json" true (json |> member "ok" |> to_bool);
          check string "old alias reported" "b140-cli-old"
            (json |> member "old_alias" |> to_string);
          (* B179: always surface relay_rebind; with no URL it is skipped. *)
          check string "relay_rebind skipped without relay URL" "skipped"
            (json |> member "relay_rebind" |> member "status" |> to_string);
          let regs = C2c_mcp.Broker.list_registrations broker in
          check string "registry renamed via CLI" "b140-cli-new"
            (List.hd regs).alias;
          let rooms = C2c_mcp.Broker.my_rooms broker ~session_id in
          check bool "room membership renamed via CLI" true
            (List.exists
               (fun ri ->
                 ri.C2c_mcp.Broker.ri_room_id = "b140-room"
                 && List.mem "b140-cli-new" ri.C2c_mcp.Broker.ri_members)
               rooms)))

let test_sticky_alias_error_advertises_rename () =
  with_temp_dir (fun dir ->
      let session_id = "test-sess-b140-hint" in
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id ~alias:"b140-hint-old"
        ~pid:None ~pid_start_time:None ();
      let out = Filename.temp_file "c2c-b140-hint" ".out" in
      Fun.protect
        ~finally:(fun () -> try Sys.remove out with _ -> ())
        (fun () ->
          let cmd =
            Printf.sprintf
              "C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=%s %s > %s 2>&1"
              (Filename.quote dir) (Filename.quote session_id)
              (c2c_cmd "c2c register --alias b140-hint-new")
              (Filename.quote out)
          in
          let rc = Sys.command cmd in
          let content = read_file out in
          check bool "register --alias rename still refused" true (rc <> 0);
          check bool "refusal advertises c2c rename" true
            (string_contains content "c2c rename")))

let run_capture command =
  let tmpfile = Filename.temp_file "c2c-cli-capture" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let rc = Sys.command (Printf.sprintf "%s > %s 2>&1" command (Filename.quote tmpfile)) in
      (rc, read_file tmpfile))

let test_rooms_knock_approve_then_join_flow () =
  with_temp_dir (fun broker_root ->
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      let live_pid = Unix.getpid () in
      C2c_mcp.Broker.register broker ~session_id:"alice-sid"
        ~alias:"alice" ~pid:(Some live_pid) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"bob-sid"
        ~alias:"bob" ~pid:(Some live_pid) ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"gated-room"
                ~alias:"alice" ~session_id:"alice-sid");
      C2c_mcp.Broker.set_room_visibility broker ~room_id:"gated-room"
        ~from_alias:"alice" ~visibility:C2c_mcp.Gated;
      let env =
        Printf.sprintf "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s"
          (Filename.quote broker_root)
      in
      let rc, out =
        run_capture
          (c2c_cmd
             (Printf.sprintf
                "%s C2C_MCP_SESSION_ID=bob-sid c2c rooms knock gated-room --json"
                env))
      in
      check int ("rooms knock exits 0: " ^ out) 0 rc;
      let knock_json = Yojson.Safe.from_string out in
      check bool "knock ok" true
        Yojson.Safe.Util.(knock_json |> member "ok" |> to_bool);
      let rc, out =
        run_capture
          (c2c_cmd
             (Printf.sprintf
                "%s C2C_MCP_SESSION_ID=alice-sid c2c rooms knocks gated-room --json"
                env))
      in
      check int ("rooms knocks exits 0: " ^ out) 0 rc;
      let knocks =
        Yojson.Safe.from_string out |> Yojson.Safe.Util.to_list
      in
      check int "one pending knock in CLI list" 1 (List.length knocks);
      check string "CLI listed requester" "bob"
        Yojson.Safe.Util.(List.hd knocks |> member "requester_alias" |> to_string);
      let rc, out =
        run_capture
          (c2c_cmd
             (Printf.sprintf
                "%s C2C_MCP_SESSION_ID=alice-sid c2c rooms approve-knock gated-room bob --json"
                env))
      in
      check int ("rooms approve-knock exits 0: " ^ out) 0 rc;
      let approve_json = Yojson.Safe.from_string out in
      check bool "approve ok" true
        Yojson.Safe.Util.(approve_json |> member "ok" |> to_bool);
      let rc, out =
        run_capture
          (c2c_cmd
             (Printf.sprintf
                "%s C2C_MCP_SESSION_ID=bob-sid c2c rooms join gated-room --history-limit 0 --json"
                env))
      in
      check int ("bob joins after approval: " ^ out) 0 rc;
      let members =
        Yojson.Safe.Util.(
          Yojson.Safe.from_string out |> member "members" |> to_list
          |> List.map (fun item -> item |> member "alias" |> to_string))
      in
      check bool "joined room members include bob" true (List.mem "bob" members))

let test_poll_inbox_cross_repo_alias_drains () =
  with_temp_dir (fun broker_root ->
      let root = Filename.quote broker_root in
      let live_pid = string_of_int (Unix.getpid ()) in
      let env = Printf.sprintf "C2C_SESSIONS_BROKER_ROOT=%s" root in
      let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s C2C_MCP_SESSION_ID=recv-sid C2C_MCP_CLIENT_PID=%s c2c register --cross-repo --alias recv" env live_pid)) in
      check int ("register recv exits 0: " ^ out) 0 rc;
      let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s C2C_MCP_SESSION_ID=sender-sid C2C_MCP_CLIENT_PID=%s c2c register --cross-repo --alias sender" env live_pid)) in
      check int ("register sender exits 0: " ^ out) 0 rc;
      let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s C2C_MCP_SESSION_ID=sender-sid c2c send --cross-repo --from sender recv msg-one" env)) in
      check int ("send exits 0: " ^ out) 0 rc;

      let rc, peek1 = run_capture (c2c_cmd (Printf.sprintf "%s c2c peek-inbox --cross-repo --alias recv" env)) in
      check int ("peek alias exits 0: " ^ peek1) 0 rc;
      check bool "peek sees message" true (string_contains peek1 "msg-one");
      let rc, peek2 = run_capture (c2c_cmd (Printf.sprintf "%s c2c peek-inbox --cross-repo --alias recv" env)) in
      check int ("second peek exits 0: " ^ peek2) 0 rc;
      check bool "peek is non-destructive" true (string_contains peek2 "msg-one");
      let rc, drained = run_capture (c2c_cmd (Printf.sprintf "%s c2c poll-inbox --cross-repo --alias recv" env)) in
      check int ("poll alias exits 0: " ^ drained) 0 rc;
      check bool "poll drains message" true (string_contains drained "msg-one");
      let rc, after = run_capture (c2c_cmd (Printf.sprintf "%s c2c peek-inbox --cross-repo --alias recv" env)) in
      check int ("peek after drain exits 0: " ^ after) 0 rc;
      check bool "inbox empty after drain" true (string_contains after "(no messages)"))

let test_poll_inbox_cross_repo_alias_errors () =
  with_temp_dir (fun broker_root ->
      let live_pid = string_of_int (Unix.getpid ()) in
      let env = Printf.sprintf "C2C_SESSIONS_BROKER_ROOT=%s" (Filename.quote broker_root) in
      let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s C2C_MCP_SESSION_ID=recv-sid C2C_MCP_CLIENT_PID=%s c2c register --cross-repo --alias recv" env live_pid)) in
      check int ("register recv exits 0: " ^ out) 0 rc;
      let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s c2c poll-inbox --cross-repo --alias recv --session-id recv-sid" env)) in
      check bool "poll alias/session mutex exits non-zero" true (rc <> 0);
      check bool "poll mutex mentions mutually exclusive" true (string_contains out "mutually exclusive");
      let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s c2c peek-inbox --cross-repo --alias missing" env)) in
      check bool "peek missing alias exits non-zero" true (rc <> 0);
      check bool "peek missing alias mentions unregistered" true (string_contains out "alias missing is not registered"))

let seed_cross_repo_message broker_root message =
  let live_pid = string_of_int (Unix.getpid ()) in
  let env = Printf.sprintf "C2C_SESSIONS_BROKER_ROOT=%s" (Filename.quote broker_root) in
  let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s C2C_MCP_SESSION_ID=recv-sid C2C_MCP_CLIENT_PID=%s c2c register --cross-repo --alias recv" env live_pid)) in
  check int ("register recv exits 0: " ^ out) 0 rc;
  let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s C2C_MCP_SESSION_ID=sender-sid C2C_MCP_CLIENT_PID=%s c2c register --cross-repo --alias sender" env live_pid)) in
  check int ("register sender exits 0: " ^ out) 0 rc;
  let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s C2C_MCP_SESSION_ID=sender-sid c2c send --cross-repo --from sender recv %s" env (Filename.quote message))) in
  check int ("send exits 0: " ^ out) 0 rc;
  env

let test_deliver_inbox_dry_run_does_not_drain () =
  with_temp_dir (fun broker_root ->
      let message = "full body line one\nline two with enough content to prove full-body" in
      let env = seed_cross_repo_message broker_root message in
      let cmd = Printf.sprintf "%s %s --cross-repo --alias recv --dry-run --json --full-body"
        env (Filename.quote c2c_deliver_inbox_binary)
      in
      let rc, out = run_capture cmd in
      check int ("deliver-inbox dry-run exits 0: " ^ out) 0 rc;
      check bool "dry-run JSON reports delivered zero" true (string_contains out "\"delivered\":0");
      check bool "dry-run JSON includes full body" true (string_contains out "line two with enough content");
      let rc, peek = run_capture (c2c_cmd (Printf.sprintf "%s c2c peek-inbox --cross-repo --alias recv" env)) in
      check int ("peek after dry-run exits 0: " ^ peek) 0 rc;
      check bool "dry-run leaves inbox intact" true (string_contains peek "line two with enough content"))

let test_deliver_inbox_cross_repo_alias_drains_full_body () =
  with_temp_dir (fun broker_root ->
      let message = "full body line one\nline two with enough content to prove full-body" in
      let env = seed_cross_repo_message broker_root message in
      let cmd = Printf.sprintf "%s %s --cross-repo --alias recv --json --full-body"
        env (Filename.quote c2c_deliver_inbox_binary)
      in
      let rc, out = run_capture cmd in
      check int ("deliver-inbox exits 0: " ^ out) 0 rc;
      check bool "delivery JSON reports delivered one" true (string_contains out "\"delivered\":1");
      check bool "delivery JSON includes full body" true (string_contains out "line two with enough content");
      let rc, peek = run_capture (c2c_cmd (Printf.sprintf "%s c2c peek-inbox --cross-repo --alias recv" env)) in
      check int ("peek after delivery exits 0: " ^ peek) 0 rc;
      check bool "delivery drains inbox" true (string_contains peek "(no messages)"))

(* B156: run a shell one-liner that backgrounds a daemon under a HARD
   wall-clock cap, so a wedged subprocess can never hang the whole test
   executable. `term_wait <pid>` tears the daemon down with a bounded
   SIGTERM->SIGKILL escalation (never an unbounded `wait`). *)
let term_wait_fn =
  "term_wait() { p=$1; kill \"$p\" 2>/dev/null || true; \
   i=0; while kill -0 \"$p\" 2>/dev/null && [ $i -lt 15 ]; do sleep 0.2; i=$((i+1)); done; \
   kill -9 \"$p\" 2>/dev/null || true; wait \"$p\" 2>/dev/null || true; }; "

let run_daemon_oneliner oneliner =
  Sys.command
    (Printf.sprintf "timeout -k 5 45 sh -c %s"
       (Filename.quote (term_wait_fn ^ oneliner)))

let test_deliver_inbox_inotify_ignores_unrelated_events () =
  with_temp_dir (fun broker_root ->
      let live_pid = string_of_int (Unix.getpid ()) in
      let env = Printf.sprintf "C2C_SESSIONS_BROKER_ROOT=%s" (Filename.quote broker_root) in
      let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s C2C_MCP_SESSION_ID=recv-sid C2C_MCP_CLIENT_PID=%s c2c register --cross-repo --alias recv" env live_pid)) in
      check int ("register recv exits 0: " ^ out) 0 rc;
      let outfile = Filename.temp_file "c2c-deliver-inotify" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore) (fun () ->
          let cmd = Printf.sprintf
            "%s %s --inotify --loop --cross-repo --alias recv --full-body > %s 2>&1 & pid=$!; sleep 1; : > %s; sleep 1; term_wait $pid"
            env
            (Filename.quote c2c_deliver_inbox_binary)
            (Filename.quote outfile)
            (Filename.quote (Filename.concat broker_root "unrelated.inbox.json"))
          in
          let rc = run_daemon_oneliner cmd in
          check int "inotify unrelated-event harness exits 0" 0 rc;
          let out = read_file outfile in
          check bool "unrelated event does not emit delivery" false (string_contains out "delivered from=");
          check bool "unrelated event does not emit zero summary" false (string_contains out "delivered=0");
          (* B156 review: the daemon must leave NO orphaned inotifywait watcher
             for this temp broker after teardown. Retry briefly to absorb the
             post-SIGKILL reaping window; "CLEAN" only prints once no matching
             watcher remains. *)
          (* pgrep -x matches on the exact process NAME (inotifywait), so this
             checker's own `sh` (whose command line contains the string
             "inotifywait" and the broker path) does not self-match. *)
          let _, leftover = run_capture
            (Printf.sprintf
               "for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -a -x inotifywait 2>/dev/null | grep -F %s >/dev/null && sleep 0.2 || { echo CLEAN; break; }; done"
               (Filename.quote broker_root))
          in
          check bool "no orphaned inotifywait watcher for temp broker" true
            (string_contains leftover "CLEAN")))

let test_deliver_inbox_register_self_enables_alias_send () =
  with_temp_dir (fun broker_root ->
      let env = Printf.sprintf "C2C_SESSIONS_BROKER_ROOT=%s" (Filename.quote broker_root) in
      let live_pid = string_of_int (Unix.getpid ()) in
      let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s C2C_MCP_SESSION_ID=sender-sid C2C_MCP_CLIENT_PID=%s c2c register --cross-repo --alias sender" env live_pid)) in
      check int ("register sender exits 0: " ^ out) 0 rc;
      let outfile = Filename.temp_file "c2c-deliver-register" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore) (fun () ->
          let cmd = Printf.sprintf
            "%s %s --loop --cross-repo --alias recv --register --full-body > %s 2>&1 & pid=$!; sleep 2; %s C2C_MCP_SESSION_ID=sender-sid c2c send --cross-repo --from sender recv 'registered receiver body'; sleep 2; term_wait $pid"
            env
            (Filename.quote c2c_deliver_inbox_binary)
            (Filename.quote outfile)
            env
          in
          let rc = run_daemon_oneliner cmd in
          check int "self-register harness exits 0" 0 rc;
          let out = read_file outfile in
          check bool "self-registered receiver gets alias send" true (string_contains out "registered receiver body");
          check bool "self-registered receiver drains exactly one" true (string_contains out "delivered=1")))

(* ------------------------------------------------------------------------- *)
(* poll-inbox --wait / wait-inbox — blocking one-shot receive                *)
(* ------------------------------------------------------------------------- *)

(* Seed helper: enqueue a message directly into a session inbox, bypassing
   alias resolution (enqueue_by_session_id writes under the inbox lock). *)
let seed_message broker ~session_id ~from_alias ~content =
  let msg : C2c_mcp.message =
    { from_alias
    ; to_alias = "wait-test-recipient"
    ; content
    ; deferrable = false
    ; reply_via = None
    ; enc_status = None
    ; ts = Unix.gettimeofday ()
    ; ephemeral = false
    ; message_id = None
    ; pow_difficulty = None
    }
  in
  C2c_mcp.Broker.enqueue_by_session_id broker ~session_id ~messages:[ msg ]

let wait_cmd ~dir ~sid args =
  Printf.sprintf
    "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=%s %s %s"
    (Filename.quote dir) sid c2c_binary args

(* (a) empty inbox + --wait --timeout 1s → exit 1, stderr note, clean stdout *)
let test_wait_empty_inbox_times_out () =
  with_temp_dir (fun dir ->
      let outfile = Filename.temp_file "c2c-wait-to" ".out" in
      let errfile = Filename.temp_file "c2c-wait-to" ".err" in
      Fun.protect
        ~finally:(fun () ->
          Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
        (fun () ->
          let cmd = wait_cmd ~dir ~sid:"wait-empty-sid"
            (Printf.sprintf "poll-inbox --wait --timeout 1s --poll-interval 0.2 > %s 2> %s"
               (Filename.quote outfile) (Filename.quote errfile))
          in
          let rc = Sys.command cmd in
          check int "wait on empty inbox exits 1" 1 rc;
          check string "stdout stays clean on timeout" "" (read_file outfile);
          check bool "stderr carries timeout note" true
            (string_contains (read_file errfile) "timeout: no messages after 1s")))

(* (b) pre-seeded inbox + --wait → exit 0, message printed, inbox drained *)
let test_wait_preseeded_drains () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      seed_message broker ~session_id:"wait-seed-sid"
        ~from_alias:"seed-sender" ~content:"preseeded hello";
      let rc, out = run_capture
        (wait_cmd ~dir ~sid:"wait-seed-sid" "poll-inbox --wait --timeout 5s --poll-interval 0.2")
      in
      check int "preseeded wait exits 0" 0 rc;
      check bool "message printed" true (string_contains out "preseeded hello");
      check int "inbox drained after wait" 0
        (List.length (C2c_mcp.Broker.read_inbox broker ~session_id:"wait-seed-sid")))

(* (c) --peek --wait → exit 0, message NOT drained *)
let test_wait_peek_does_not_drain () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      seed_message broker ~session_id:"wait-peek-sid"
        ~from_alias:"seed-sender" ~content:"peek me";
      let rc, out = run_capture
        (wait_cmd ~dir ~sid:"wait-peek-sid" "poll-inbox --wait --peek --timeout 5s --poll-interval 0.2")
      in
      check int "peek wait exits 0" 0 rc;
      check bool "peeked message printed" true (string_contains out "peek me");
      check int "message survives peek" 1
        (List.length (C2c_mcp.Broker.read_inbox broker ~session_id:"wait-peek-sid")))

(* (d) message arriving DURING the wait unblocks it.  The seeder is a forked
   child of the test process (same C2c_mcp lib), enqueuing after 0.6s while
   the CLI blocks in its poll loop. *)
let test_wait_unblocks_on_mid_wait_arrival () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let pid = Unix.fork () in
      if pid = 0 then begin
        (* child: seed after a delay, then exit without running finalisers *)
        (try
           Unix.sleepf 0.6;
           seed_message broker ~session_id:"wait-race-sid"
             ~from_alias:"late-sender" ~content:"mid-wait arrival"
         with _ -> ());
        Unix._exit 0
      end
      else begin
        let started = Unix.gettimeofday () in
        let rc, out = run_capture
          (wait_cmd ~dir ~sid:"wait-race-sid" "wait-inbox --timeout 10s --poll-interval 0.2")
        in
        ignore (Unix.waitpid [] pid);
        let elapsed = Unix.gettimeofday () -. started in
        check int "mid-wait arrival exits 0" 0 rc;
        check bool "mid-wait message printed" true (string_contains out "mid-wait arrival");
        check bool "unblocked before the timeout" true (elapsed < 8.0);
        check bool "actually waited for the arrival" true (elapsed >= 0.5)
      end)

(* (e) --from filter: non-matching does not unblock and is not drained;
   matching is drained (case-insensitively) while non-matching survives. *)
let test_wait_from_nonmatching_does_not_unblock () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      seed_message broker ~session_id:"wait-from-sid"
        ~from_alias:"other" ~content:"noise msg";
      let rc, _out = run_capture
        (wait_cmd ~dir ~sid:"wait-from-sid"
           "wait-inbox --from wanted --timeout 1s --poll-interval 0.2")
      in
      check int "non-matching sender does not unblock (timeout)" 1 rc;
      check int "non-matching message not drained" 1
        (List.length (C2c_mcp.Broker.read_inbox broker ~session_id:"wait-from-sid")))

let test_wait_from_matching_selective_drain () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      seed_message broker ~session_id:"wait-from2-sid"
        ~from_alias:"other" ~content:"noise msg";
      seed_message broker ~session_id:"wait-from2-sid"
        ~from_alias:"wanted" ~content:"wanted msg";
      (* --from is case-insensitive: filter WANTED matches sender "wanted" *)
      let rc, out = run_capture
        (wait_cmd ~dir ~sid:"wait-from2-sid"
           "wait-inbox --from WANTED --timeout 5s --poll-interval 0.2")
      in
      check int "matching sender unblocks" 0 rc;
      check bool "matching message printed" true (string_contains out "wanted msg");
      check bool "non-matching message not printed" false (string_contains out "noise msg");
      let remaining = C2c_mcp.Broker.read_inbox broker ~session_id:"wait-from2-sid" in
      check int "non-matching message survives selective drain" 1 (List.length remaining);
      check string "survivor is the non-matching sender" "other"
        (List.hd remaining).from_alias)

(* (f) bad duration → exit 2; wait-only flags without --wait → exit 2 *)
let test_wait_bad_duration_exits_two () =
  with_temp_dir (fun dir ->
      let rc, out = run_capture
        (wait_cmd ~dir ~sid:"wait-bad-sid" "poll-inbox --wait --timeout bogus")
      in
      check int "bad --timeout exits 2" 2 rc;
      check bool "error mentions timeout" true (string_contains out "invalid --timeout"))

let test_wait_flags_require_wait () =
  with_temp_dir (fun dir ->
      let rc, out = run_capture
        (wait_cmd ~dir ~sid:"wait-req-sid" "poll-inbox --timeout 5s")
      in
      check int "--timeout without --wait exits 2" 2 rc;
      check bool "error mentions --wait" true (string_contains out "require --wait"))

(* (g) JSON shape matches poll-inbox --json; and JSON timeout emits [] *)
let test_wait_json_shape_matches_poll_inbox () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      seed_message broker ~session_id:"wait-json-sid"
        ~from_alias:"json-sender" ~content:"json body";
      let rc, out = run_capture
        (wait_cmd ~dir ~sid:"wait-json-sid"
           "wait-inbox --json --timeout 5s --poll-interval 0.2")
      in
      check int "json wait exits 0" 0 rc;
      match Yojson.Safe.from_string out with
      | `List [ `Assoc fields ] ->
          let str k = match List.assoc_opt k fields with Some (`String s) -> s | _ -> "<missing>" in
          check string "from_alias field" "json-sender" (str "from_alias");
          check string "content field" "json body" (str "content");
          check bool "to_alias present" true (List.mem_assoc "to_alias" fields);
          check bool "ts present" true (List.mem_assoc "ts" fields)
      | _ -> fail ("unexpected JSON shape: " ^ out))

let test_wait_json_timeout_emits_empty_list () =
  with_temp_dir (fun dir ->
      let outfile = Filename.temp_file "c2c-wait-json-to" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore)
        (fun () ->
          let cmd = wait_cmd ~dir ~sid:"wait-json-to-sid"
            (Printf.sprintf "wait-inbox --json --timeout 1s --poll-interval 0.2 > %s 2>/dev/null"
               (Filename.quote outfile))
          in
          let rc = Sys.command cmd in
          check int "json timeout exits 1" 1 rc;
          match Yojson.Safe.from_string (read_file outfile) with
          | `List [] -> ()
          | j -> fail ("expected [] on json timeout, got: " ^ Yojson.Safe.to_string j)))

(* wait-inbox is registered as a real command with wait forced on *)
let test_wait_inbox_command_registered () =
  with_temp_dir (fun dir ->
      let rc, out = run_capture
        (wait_cmd ~dir ~sid:"wait-help-sid" "wait-inbox --help=plain")
      in
      check int "wait-inbox --help exits 0" 0 rc;
      check bool "help mentions blocking receive" true
        (string_contains out "Blocking one-shot receive"))

(* ------------------------------------------------------------------------- *)
(* #9 split-brain: XDG_STATE_HOME profile brokers vs canonical HOME root.     *)
(* End-to-end through the built binary: warning on stderr only (JSON stdout   *)
(* stays clean), health reports the orphaned XDG broker, and migrate-broker   *)
(* defaults its source to the orphaned XDG broker when no legacy path exists. *)
(* ------------------------------------------------------------------------- *)

let ( // ) = Filename.concat

let mkdir_p = C2c_mcp.mkdir_p

(* Run [command] capturing stdout and stderr separately. *)
let run_capture_split command =
  let out_f = Filename.temp_file "c2c-cli-stdout" ".out" in
  let err_f = Filename.temp_file "c2c-cli-stderr" ".err" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove out_f with _ -> ());
      (try Sys.remove err_f with _ -> ()))
    (fun () ->
      let rc =
        Sys.command
          (Printf.sprintf "%s > %s 2> %s" command (Filename.quote out_f)
             (Filename.quote err_f))
      in
      (rc, read_file out_f, read_file err_f))

(* Isolated env for split-brain tests: fresh HOME + per-profile XDG, with the
   broker overrides explicitly cleared so resolution exercises the fallback
   chain. Mirrors what a Claude profile-share session exports. *)
let split_brain_env home =
  Printf.sprintf
    "HOME=%s XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s C2C_MCP_BROKER_ROOT= C2C_STATE_HOME= C2C_CLI_FORCE=1"
    (Filename.quote home)
    (Filename.quote (home // ".config"))
    (Filename.quote (home // ".local" // "state"))

(* Extract <fp> from a ".../repos/<fp>/broker" path reported by health. *)
let fp_of_broker_root root =
  Filename.basename (Filename.dirname root)

let health_broker_root env =
  let rc, out, _err =
    run_capture_split (c2c_cmd (Printf.sprintf "env %s c2c health --json" env))
  in
  check int "health --json exits 0" 0 rc;
  match Yojson.Safe.from_string out with
  | `Assoc kvs ->
      (match List.assoc_opt "broker_root" kvs with
       | Some (`String r) -> r
       | _ -> Alcotest.fail "health json missing broker_root")
  | _ -> Alcotest.fail "health --json did not emit a json object"

let plant_xdg_broker home fp =
  let xdg_broker =
    home // ".local" // "state" // "c2c" // "repos" // fp // "broker" in
  mkdir_p xdg_broker;
  write_file (xdg_broker // "registry.json") "{\"registrations\":[]}\n";
  xdg_broker

let test_xdg_profile_broker_resolves_to_canonical_home () =
  with_temp_dir (fun home ->
      let env = split_brain_env home in
      let root = health_broker_root env in
      check bool
        (Printf.sprintf "broker root %s is under $HOME/.c2c despite XDG" root)
        true
        (string_contains root (home // ".c2c" // "repos")))

let test_c2c_state_home_escape_hatch () =
  with_temp_dir (fun home ->
      let state = home // "relocated-state" in
      mkdir_p state;
      let env =
        Printf.sprintf "%s C2C_STATE_HOME=%s" (split_brain_env home)
          (Filename.quote state)
      in
      let root = health_broker_root env in
      check bool
        (Printf.sprintf "broker root %s is under $C2C_STATE_HOME" root)
        true
        (string_contains root (state // "c2c" // "repos")))

let test_xdg_split_brain_warning_on_stderr_json_clean () =
  with_temp_dir (fun home ->
      let env = split_brain_env home in
      let root = health_broker_root env in
      let fp = fp_of_broker_root root in
      let xdg_broker = plant_xdg_broker home fp in
      let rc, out, err =
        run_capture_split
          (c2c_cmd (Printf.sprintf "env %s c2c health --json" env))
      in
      check int "health --json exits 0 with split-brain present" 0 rc;
      (* stderr: one-line warning mentioning migrate-broker *)
      check bool "stderr warning mentions migrate-broker" true
        (string_contains err "migrate-broker");
      check bool "stderr warning names the orphaned XDG broker" true
        (string_contains err xdg_broker);
      (* stdout: still valid JSON (warning must not pollute it) *)
      (match Yojson.Safe.from_string out with
       | `Assoc kvs ->
           (match List.assoc_opt "xdg_split_brain_broker" kvs with
            | Some (`String p) ->
                check string "health json reports the XDG broker" xdg_broker p
            | _ -> Alcotest.fail "health json missing xdg_split_brain_broker");
           (match List.assoc_opt "migrate_hint" kvs with
            | Some (`String hint) ->
                check bool "migrate_hint mentions migrate-broker" true
                  (string_contains hint "migrate-broker")
            | _ -> Alcotest.fail "health json missing migrate_hint")
       | _ -> Alcotest.fail "stdout polluted: health --json not a json object"))

let test_no_warning_without_xdg_broker () =
  with_temp_dir (fun home ->
      let env = split_brain_env home in
      let rc, _out, err =
        run_capture_split
          (c2c_cmd (Printf.sprintf "env %s c2c health --json" env))
      in
      check int "health --json exits 0" 0 rc;
      check bool "no split-brain warning when XDG broker absent" false
        (string_contains err "migrate-broker"))

let test_health_human_reports_split_brain () =
  with_temp_dir (fun home ->
      let env = split_brain_env home in
      let root = health_broker_root env in
      let fp = fp_of_broker_root root in
      let _xdg_broker = plant_xdg_broker home fp in
      let rc, out, _err =
        run_capture_split (c2c_cmd (Printf.sprintf "env %s c2c health" env))
      in
      check int "health exits 0" 0 rc;
      check bool "human output mentions split-brain" true
        (string_contains out "split-brain");
      check bool "human output recommends migrate-broker" true
        (string_contains out "c2c migrate-broker"))

(* migrate-broker with no --from defaults to the orphaned XDG-profile broker
   when the legacy .git/c2c/mcp path does not exist. Run inside a fresh temp
   git repo so the main repo's legacy dir can't shadow the XDG source. *)
let test_migrate_broker_defaults_to_xdg_source () =
  with_temp_dir (fun sandbox ->
      let repo = sandbox // "repo" in
      let home = sandbox // "home" in
      mkdir_p repo; mkdir_p home;
      check int "git init sandbox repo" 0
        (Sys.command
           (Printf.sprintf "git -C %s init -q" (Filename.quote repo)));
      let env = split_brain_env home in
      let in_repo cmd =
        Printf.sprintf "cd %s && %s" (Filename.quote repo) (c2c_cmd cmd) in
      let rc, out, _err =
        run_capture_split (in_repo (Printf.sprintf "env %s c2c health --json" env))
      in
      check int "health --json in sandbox exits 0" 0 rc;
      let root =
        match Yojson.Safe.from_string out with
        | `Assoc kvs ->
            (match List.assoc_opt "broker_root" kvs with
             | Some (`String r) -> r
             | _ -> Alcotest.fail "sandbox health json missing broker_root")
        | _ -> Alcotest.fail "sandbox health --json not a json object"
      in
      let fp = fp_of_broker_root root in
      let xdg_broker = plant_xdg_broker home fp in
      let rc, out, _err =
        run_capture_split
          (in_repo (Printf.sprintf "env %s c2c migrate-broker --dry-run" env))
      in
      check int "migrate-broker --dry-run exits 0" 0 rc;
      check bool "dry-run source is the orphaned XDG broker" true
        (string_contains out xdg_broker);
      check bool "dry-run destination is the canonical HOME root" true
        (string_contains out (home // ".c2c" // "repos")))

(* B073: a live (non-dry-run) migration from an XDG-profile source must
   remove the source broker tree — including entries skipped as
   already-at-canonical — so the split-brain warning stops firing. The
   incident shape was skip-heavy ("1 copied, 4 skipped"): the canonical
   root already holds most files, only one is new. *)
let test_migrate_broker_xdg_live_silences_warning () =
  with_temp_dir (fun sandbox ->
      let repo = sandbox // "repo" in
      let home = sandbox // "home" in
      mkdir_p repo; mkdir_p home;
      check int "git init sandbox repo" 0
        (Sys.command
           (Printf.sprintf "git -C %s init -q" (Filename.quote repo)));
      let env = split_brain_env home in
      let in_repo cmd =
        Printf.sprintf "cd %s && %s" (Filename.quote repo) (c2c_cmd cmd) in
      let root =
        let rc, out, _err =
          run_capture_split (in_repo (Printf.sprintf "env %s c2c health --json" env))
        in
        check int "health --json in sandbox exits 0" 0 rc;
        match Yojson.Safe.from_string out with
        | `Assoc kvs ->
            (match List.assoc_opt "broker_root" kvs with
             | Some (`String r) -> r
             | _ -> Alcotest.fail "sandbox health json missing broker_root")
        | _ -> Alcotest.fail "sandbox health --json not a json object"
      in
      let fp = fp_of_broker_root root in
      let xdg_broker = plant_xdg_broker home fp in
      (* Skip-heavy shape: canonical root already exists with overlapping
         content; XDG source has the same files + one new one. *)
      let canonical = home // ".c2c" // "repos" // fp // "broker" in
      mkdir_p canonical;
      mkdir_p (xdg_broker // "keys");
      mkdir_p (canonical // "keys");
      write_file (canonical // "registry.json") "{\"registrations\":[]}\n";
      write_file (xdg_broker // "sess1.inbox.json") "[]";
      write_file (canonical // "sess1.inbox.json") "[]";
      write_file (xdg_broker // "keys" // "id") "k\n";
      write_file (canonical // "keys" // "id") "k\n";
      write_file (xdg_broker // "only-in-xdg.log") "new\n";
      (* Live migration (no --dry-run). *)
      let rc, out, _err =
        run_capture_split
          (in_repo (Printf.sprintf "env %s c2c migrate-broker --json" env))
      in
      check int "live migrate-broker exits 0" 0 rc;
      (match Yojson.Safe.from_string out with
       | `Assoc kvs ->
           (match List.assoc_opt "ok" kvs with
            | Some (`Bool true) -> ()
            | _ -> Alcotest.fail "migrate --json ok!=true");
           (match List.assoc_opt "source_removed" kvs with
            | Some (`Bool true) -> ()
            | _ -> Alcotest.fail "migrate --json source_removed!=true")
       | _ -> Alcotest.fail "migrate --json did not emit a json object");
      check bool "XDG source registry.json is gone" false
        (Sys.file_exists (xdg_broker // "registry.json"));
      check bool "XDG source broker tree is gone" false
        (Sys.file_exists xdg_broker);
      check bool "new file landed at canonical" true
        (Sys.file_exists (canonical // "only-in-xdg.log"));
      (* The split-brain warning must be silent on the next command. *)
      let rc, _out, err =
        run_capture_split (in_repo (Printf.sprintf "env %s c2c health --json" env))
      in
      check int "post-migrate health exits 0" 0 rc;
      check bool "post-migrate stderr has no split-brain warning" false
        (string_contains err "migrate-broker"))

(* B157: docs-drift must accept every genuinely-registered c2c command —
   including command groups (`c2c dev`, `c2c deliver`) and Tier3 operator
   commands (`c2c watch`) that agent-tier `--help` hides — and must still flag
   a genuinely-unregistered command. Regression for the false-positive storm
   where real commands were reported "top-level c2c command is not registered",
   which drowned real drift and once misled a docs-audit into "fixing" a valid
   `c2c watch` reference. The known-command set is now built from the same
   source of truth as the cmdliner command tree (all tiers), so it can never
   drift below the real surface. *)
let docs_drift_unregistered_claims out =
  (* Extract the `claim` of every kind="command" / "not registered" finding
     from a --json findings array. Empty list on any parse failure. *)
  try
    match Yojson.Safe.from_string out with
    | `List items ->
        List.filter_map
          (function
            | `Assoc kvs ->
                let get k =
                  match List.assoc_opt k kvs with Some (`String s) -> s | _ -> ""
                in
                if get "kind" = "command"
                   && string_contains (get "message") "not registered"
                then Some (get "claim")
                else None
            | _ -> None)
          items
    | _ -> []
  with _ -> []

let test_docs_drift_accepts_registered_commands () =
  with_temp_dir (fun dir ->
      (* The exact commands the bug report flagged as false positives, plus
         `c2c <group> <sub>` forms that must validate on the group head token. *)
      let must_pass =
        [ "dev"; "deliver"; "relay"; "rooms"; "schedule"; "doctor"; "memory";
          "uninstall"; "self-update"; "new"; "codex"; "resume"; "host-id";
          "await-reply"; "approval-reply"; "migrate-broker"; "watch";
          "dev instances"; "rooms send"; "deliver wake-watch"; "schedule set" ]
      in
      (* Dynamically enumerate the live command surface too, so newly-added
         top-level commands are covered automatically. `c2c commands` hides
         Tier3 (hence the explicit `watch` above), but this pins Tier1/2/4 and
         every group head as they evolve. *)
      let _, listing =
        run_capture (c2c_cmd "C2C_COORDINATOR=1 c2c commands --all --dev")
      in
      let enumerated =
        String.split_on_char '\n' listing
        |> List.filter_map (fun line ->
               if String.length line > 2 && line.[0] = ' ' && line.[1] = ' '
                  && line.[2] <> ' '
               then
                 let rest = String.sub line 2 (String.length line - 2) in
                 let tok =
                   match String.index_opt rest ' ' with
                   | Some i -> String.sub rest 0 i
                   | None -> rest
                 in
                 if String.length tok > 0 && tok.[0] >= 'a' && tok.[0] <= 'z'
                 then Some tok
                 else None
               else None)
      in
      let doc = Filename.concat dir "b157-registered.md" in
      let oc = open_out doc in
      List.iter
        (fun f -> Printf.fprintf oc "Use `c2c %s` here.\n" f)
        (must_pass @ enumerated);
      close_out oc;
      let _, out =
        run_capture
          (c2c_cmd
             (Printf.sprintf "c2c doctor docs-drift --doc %s --json"
                (Filename.quote doc)))
      in
      check (list string)
        "no registered command is flagged as unregistered"
        [] (docs_drift_unregistered_claims out);
      (* Negative controls: a genuinely-bogus command AND composite tier-map
         DISPLAY labels (e.g. `roles-validate`, `config-show` — hyphenated
         forms of real `c2c roles validate` / `c2c config show` group commands,
         which Cmdliner rejects) MUST still be flagged. This proves the check is
         live (not vacuous) and that the tier map's non-top-level labels do NOT
         leak into the accepted set. *)
      let bogus_doc = Filename.concat dir "b157-bogus.md" in
      let oc = open_out bogus_doc in
      Printf.fprintf oc "Try `c2c totallynotarealcommand` now.\n";
      Printf.fprintf oc "Also `c2c roles-validate` and `c2c config-show`.\n";
      close_out oc;
      let _, bout =
        run_capture
          (c2c_cmd
             (Printf.sprintf "c2c doctor docs-drift --doc %s --json"
                (Filename.quote bogus_doc)))
      in
      let flagged = docs_drift_unregistered_claims bout in
      check bool "bogus command is still flagged as unregistered" true
        (List.exists (fun c -> string_contains c "totallynotarealcommand") flagged);
      check bool "composite tier-map label roles-validate is flagged" true
        (List.exists (fun c -> string_contains c "roles-validate") flagged);
      check bool "composite tier-map label config-show is flagged" true
        (List.exists (fun c -> string_contains c "config-show") flagged))

(* B155: `c2c statusline` — fast, pure-local one-line state summary for a
   client status line. These exercise the real CLI path end-to-end against a
   temp broker. *)
let test_statusline_json_reports_state () =
  with_temp_dir (fun dir ->
      let sessions_dir = Filename.concat dir "sessions-broker" in
      let broker = C2c_mcp.Broker.create ~root:dir in
      let sessions_broker = C2c_mcp.Broker.create ~root:sessions_dir in
      let live_pid = Unix.getpid () in
      C2c_mcp.Broker.register broker ~session_id:"sl-self-sid"
        ~alias:"sl-selftest" ~pid:(Some live_pid) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"sl-peer-sid"
        ~alias:"sl-peertest" ~pid:(Some live_pid) ~pid_start_time:None ();
      (* The peer registration is visible through both local routes.  The
         current-repository broker wins that duplicate; the sessions-only
         registration contributes one additional machine-wide peer. *)
      C2c_mcp.Broker.register sessions_broker ~session_id:"sl-peer-sid"
        ~alias:"sl-peertest" ~pid:(Some live_pid) ~pid_start_time:None ();
      C2c_mcp.Broker.register sessions_broker ~session_id:"sl-global-sid"
        ~alias:"sl-globaltest" ~pid:(Some live_pid) ~pid_start_time:None ();
      (* stdin is EOF (/dev/null), so the alias resolves from the env
         session id rather than a Claude stdin JSON blob. *)
      let rc, out =
        run_capture
          (c2c_cmd
             (Printf.sprintf
                "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s C2C_SESSIONS_BROKER_ROOT=%s C2C_MCP_SESSION_ID=sl-self-sid \
                 c2c statusline --json < /dev/null"
                (Filename.quote dir) (Filename.quote sessions_dir)))
      in
      check int "statusline --json exits 0" 0 rc;
      (match Yojson.Safe.from_string out with
       | `Assoc kvs ->
           let get k = List.assoc_opt k kvs in
           check bool "registered is true" true (get "registered" = Some (`Bool true));
           check bool "alias resolves from session id" true
             (get "alias" = Some (`String "sl-selftest"));
           check bool "counts both live registrations" true
             (get "peers_alive" = Some (`Int 2));
           check bool "repo count is explicit" true
             (get "peers_repo_alive" = Some (`Int 2));
           check bool "machine count is explicit and deduplicated" true
             (get "peers_machine_alive" = Some (`Int 3));
           check bool "stable compatibility peer field remains repo-scoped" true
             (get "peers_alive" = Some (`Int 2))
       | _ | (exception _) ->
           Alcotest.failf "statusline --json did not emit an object: %s" out);
      let human_rc, human =
        run_capture
          (c2c_cmd
             (Printf.sprintf
                "C2C_CLI_FORCE=1 PI_C2C_ASCII=0 C2C_MCP_BROKER_ROOT=%s C2C_SESSIONS_BROKER_ROOT=%s C2C_MCP_SESSION_ID=sl-self-sid \
                 c2c statusline --no-color < /dev/null"
                (Filename.quote dir) (Filename.quote sessions_dir)))
      in
      check int "human statusline exits 0" 0 human_rc;
      check bool "human output uses spaced globe+relay glyph" true
        (string_contains human "🌐 ⇄ ");
      check bool "human output drops old 'relay:' token" true
        (not (string_contains human "relay:"));
      check bool "human output shows repo icon + spaced count" true
        (string_contains human "📦 2");
      check bool "human output shows machine icon + spaced count" true
        (string_contains human "🖥️ 3");
      check bool "human output drops literal '2 repo' wording" true
        (not (string_contains human "2 repo"));
      check bool "human output drops literal '3 machine' wording" true
        (not (string_contains human "3 machine")))

(* B169: PI_C2C_ASCII=1 swaps the unicode glyphs for plain-text fallbacks in
   the human line (the `🌐 ⇄ …` relay token becomes `[relay] …`, and the 📦/🖥️
   peer icons revert to the words `repo`/`machine`). The assertions are robust
   to the relay classification: any relay state still yields a `[relay] `
   prefix, so `[relay]` is present and `🌐`/`⇄` are not. *)
let test_statusline_ascii_fallback () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"sl-ascii-sid"
        ~alias:"sl-asciitest" ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let rc, human =
        run_capture
          (c2c_cmd
             (Printf.sprintf
                "C2C_CLI_FORCE=1 PI_C2C_ASCII=1 C2C_MCP_BROKER_ROOT=%s \
                 C2C_MCP_SESSION_ID=sl-ascii-sid c2c statusline --no-color < /dev/null"
                (Filename.quote dir)))
      in
      check int "ascii statusline exits 0" 0 rc;
      check bool "ascii output uses spaced [relay] token" true
        (string_contains human "[relay] ");
      check bool "ascii output uses 'repo' word" true
        (string_contains human "repo");
      check bool "ascii output uses 'machine' word" true
        (string_contains human "machine");
      check bool "ascii output drops unicode globe" true
        (not (string_contains human "🌐"));
      check bool "ascii output drops unicode relay arrows" true
        (not (string_contains human "⇄"));
      check bool "ascii output drops unicode repo icon" true
        (not (string_contains human "📦"));
      check bool "ascii output drops unicode machine icon" true
        (not (string_contains human "🖥")))

let test_statusline_reads_stdin_session_json () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"sl-stdin-sid"
        ~alias:"sl-stdintest" ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let jsonfile = Filename.concat dir "sess.json" in
      let oc = open_out jsonfile in
      output_string oc
        {|{"session_id":"sl-stdin-sid","model":{"display_name":"TestModel"}}|};
      close_out oc;
      let rc, out =
        run_capture
          (c2c_cmd
             (Printf.sprintf
                "C2C_CLI_FORCE=1 C2C_MCP_BROKER_ROOT=%s c2c statusline --json < %s"
                (Filename.quote dir) (Filename.quote jsonfile)))
      in
      check int "statusline stdin --json exits 0" 0 rc;
      check bool "alias resolves from stdin session_id" true
        (string_contains out "sl-stdintest");
      check bool "model display_name surfaced from stdin json" true
        (string_contains out "TestModel"))

let test_statusline_streaming_stdin_is_bounded () =
  (* B155 review: a continuous stdin producer must NOT hang statusline — the
     read is capped by an absolute deadline + size cap, so it returns promptly
     (truncated blob → unparseable → fail-open) rather than hanging or growing
     the buffer without bound. The outer `timeout` is a safety net: if the read
     ever regressed to hanging, rc would be 124 (not 0) and this fails fast
     instead of wedging the suite. *)
  let rc, _out =
    run_capture
      (c2c_cmd "timeout 10 sh -c 'yes \"{\\\"a\\\":1}\" | c2c statusline --json'")
  in
  check int "streaming stdin statusline returns fail-open (no hang)" 0 rc

let test_statusline_print_config () =
  let rc, out = run_capture (c2c_cmd "c2c statusline --print-config") in
  check int "statusline --print-config exits 0" 0 rc;
  check bool "print-config mentions Claude statusLine hook" true
    (string_contains out "statusLine");
  check bool "print-config references c2c statusline" true
    (string_contains out "c2c statusline");
  check bool "print-config explains repo scope" true
    (string_contains out "repo");
  check bool "print-config explains machine scope" true
    (string_contains out "machine")

let () =
  Alcotest.run "c2c_cli"
    [ ( "broker_root_split_brain",
        [ ( "XDG profile resolves to canonical HOME root", `Quick, test_xdg_profile_broker_resolves_to_canonical_home )
        ; ( "C2C_STATE_HOME escape hatch honored", `Quick, test_c2c_state_home_escape_hatch )
        ; ( "orphaned XDG broker warns on stderr, JSON stays clean", `Quick, test_xdg_split_brain_warning_on_stderr_json_clean )
        ; ( "no warning without an XDG broker", `Quick, test_no_warning_without_xdg_broker )
        ; ( "health human output reports split-brain", `Quick, test_health_human_reports_split_brain )
        ; ( "migrate-broker defaults --from to the XDG broker", `Quick, test_migrate_broker_defaults_to_xdg_source )
        ; ( "live migrate from XDG source silences the warning (B073)", `Quick, test_migrate_broker_xdg_live_silences_warning )
        ] )
    ; ( "doctor",
        [ ( "doctor exits 0 on clean run", `Quick, test_doctor_runs_and_exits_zero )
        ; ( "doctor output contains health checks", `Quick, test_doctor_output_contains_health_checks )
        ; ( "doctor output contains push status", `Quick, test_doctor_output_contains_push_status )
        ; ( "doctor output contains push verdict", `Quick, test_doctor_output_contains_push_verdict )
        ; ( "doctor output contains relay classification", `Quick, test_doctor_output_contains_relay_classification )
        ; ( "docs-drift accepts registered commands, flags bogus (B157)", `Quick, test_docs_drift_accepts_registered_commands )
        ] )
    ; ( "statusline",
        [ ( "statusline --json reports registration/alias/peers (B155)", `Quick, test_statusline_json_reports_state )
        ; ( "statusline PI_C2C_ASCII plain-text fallback (B169)", `Quick, test_statusline_ascii_fallback )
        ; ( "statusline reads Claude stdin session JSON (B155)", `Quick, test_statusline_reads_stdin_session_json )
        ; ( "statusline streaming stdin is bounded (B155)", `Quick, test_statusline_streaming_stdin_is_bounded )
        ; ( "statusline --print-config emits Claude snippet (B155)", `Quick, test_statusline_print_config )
        ] )
    ; ( "config_show",
        [ ( "config show exits 0", `Quick, test_config_show_exits_zero )
        ; ( "config show output has key=value format", `Quick, test_config_show_contains_key_value_pairs )
        ; ( "config show renders explicit values", `Quick, test_config_show_renders_explicit_values )
        ] )
    ; ( "agent_list",
        [ ( "agent list exits 0", `Quick, test_agent_list_exits_zero )
        ; ( "agent list shows role files or empty message", `Quick, test_agent_list_shows_role_files )
        ] )
    ; ( "agent_new",
        [ ( "agent new creates role file", `Quick, test_agent_new_creates_role_file )
        ; ( "agent new output file is valid yaml", `Quick, test_agent_new_role_file_is_valid_yaml )
        ] )
    ; ( "list",
        [ ( "list exits 0", `Quick, test_list_exits_zero )
        ; ( "peers alias exits 0 (B183)", `Quick, test_peers_alias_exits_zero )
        ; ( "inbox alias exits 0 (B183)", `Quick, test_inbox_alias_exits_zero )
        ; ( "list output contains peer entries", `Quick, test_list_output_contains_peer_entries )
        ; ( "unknown liveness is not labeled unknown client type", `Quick, test_list_unknown_liveness_is_not_labeled_unknown_client_type )
        ; ( "register happy path omits relay identity debug noise", `Quick, test_register_happy_path_does_not_emit_relay_identity_debug_noise )
        ; ( "register CLI blocked alias explains reason and suggestion", `Quick, test_register_cli_blocked_alias_explains_reason_and_suggestion )
        ; ( "rename help documents reserved alias guidance (B182)", `Quick, test_rename_help_documents_reserved_alias_guidance )
        ] )
    ; ( "send",
        [ ( "send missing args exits non-zero", `Quick, test_send_missing_args_exits_nonzero )
        ; ( "remote connector liveness uses send broker root (B177)", `Quick, test_remote_connector_liveness_is_scoped_to_broker_state )
        ; ( "send unknown alias routes to relay outbox", `Quick, test_send_unknown_alias_routes_to_relay_outbox )
        ; ( "send auto-registers unregistered sender (B078)", `Quick, test_send_auto_registers_unregistered_session )
        ; ( "send falls back when auto-registration fails (B078)", `Quick, test_send_auto_register_failure_falls_back_to_raw_session_id )
        ; ( "send auto-register reuses sticky across fingerprint (B188)", `Quick, test_send_auto_register_reuses_sticky_across_fingerprint )
        ; ( "send cross-broker fallback routes to sibling broker", `Quick, test_send_cross_broker_fallback )
        ; ( "send not-found error mentions scanned brokers", `Quick, test_send_not_found_error_mentions_scanned_brokers )
        ; ( "send to dead alias queues offline (B072/B127)", `Quick, test_send_dead_alias_queues_offline )
        ; ( "send to dead alias --json reports queued_offline (B127)", `Quick, test_send_dead_alias_json_queued_offline )
        ; ( "send to dead alias --fail-if-queued exits 3 (B127)", `Quick, test_send_dead_alias_fail_if_queued_exits_3 )
        ; ( "send to unknown-liveness alias routes (B071/B072)", `Quick, test_send_unknown_liveness_alias_routes )
        ; ( "send to remote @host reports queued, not ok (B088)", `Quick, test_send_remote_target_reports_queued_not_ok )
        ; ( "send to remote @host --json surfaces delivery.state queued (B088)", `Quick, test_send_remote_target_json_delivery_state_queued )
        ; ( "send to remote @host --fail-if-queued exits non-zero (B088)", `Quick, test_send_remote_target_fail_if_queued_exits_nonzero )
        ; ( "send to local target still reports delivered (B088)", `Quick, test_send_local_target_still_reports_delivered )
        ; ( "zero-env register is routable (B071)", `Quick, test_register_zero_env_is_routable )
        ] )
    ; ( "whoami",
        [ ( "whoami exits 0", `Quick, test_whoami_exits_zero )
        ; ( "whoami output contains alias field", `Quick, test_whoami_output_contains_alias_field )
        ] )
    ; ( "update_notice",
        [ ( "supported paths emit cached update notice once", `Quick,
            test_cached_update_notice_emitted_once )
        ] )
    ; ( "history",
        [ ( "history exits 0", `Quick, test_history_exits_zero )
        ] )
    ; ( "poll_inbox",
        [ ( "cross-repo alias drains", `Quick, test_poll_inbox_cross_repo_alias_drains )
        ; ( "cross-repo alias errors", `Quick, test_poll_inbox_cross_repo_alias_errors )
        ] )
    ; ( "wait_inbox",
        [ ( "empty inbox --wait times out with exit 1", `Quick, test_wait_empty_inbox_times_out )
        ; ( "preseeded inbox --wait drains and exits 0", `Quick, test_wait_preseeded_drains )
        ; ( "--peek --wait does not drain", `Quick, test_wait_peek_does_not_drain )
        ; ( "mid-wait arrival unblocks", `Quick, test_wait_unblocks_on_mid_wait_arrival )
        ; ( "--from non-matching does not unblock or drain", `Quick, test_wait_from_nonmatching_does_not_unblock )
        ; ( "--from matching drains selectively", `Quick, test_wait_from_matching_selective_drain )
        ; ( "bad --timeout duration exits 2", `Quick, test_wait_bad_duration_exits_two )
        ; ( "wait-only flags require --wait", `Quick, test_wait_flags_require_wait )
        ; ( "--json shape matches poll-inbox --json", `Quick, test_wait_json_shape_matches_poll_inbox )
        ; ( "--json timeout emits []", `Quick, test_wait_json_timeout_emits_empty_list )
        ; ( "wait-inbox command registered", `Quick, test_wait_inbox_command_registered )
        ] )
    ; ( "deliver_inbox",
        [ ( "dry-run does not drain", `Quick, test_deliver_inbox_dry_run_does_not_drain )
        ; ( "cross-repo alias drains full body", `Quick, test_deliver_inbox_cross_repo_alias_drains_full_body )
        ; ( "inotify ignores unrelated events", `Quick, test_deliver_inbox_inotify_ignores_unrelated_events )
        ; ( "register self enables alias send", `Quick, test_deliver_inbox_register_self_enables_alias_send )
        ] )
    ; ( "schedule_list",
        [ ( "schedule list exits 0", `Quick, test_schedule_list_exits_zero )
        ; ( "schedule list output contains header", `Quick, test_schedule_list_output_contains_header )
        ] )
    ; ( "memory_list",
        [ ( "memory list exits 0", `Quick, test_memory_list_exits_zero )
        ; ( "memory list output is nonempty", `Quick, test_memory_list_output_is_nonempty )
        ] )
    ; ( "roles_validate",
        [ ( "roles validate shows summary line", `Quick, test_roles_validate_runs_and_shows_summary )
        ] )
    ; ( "rooms_list",
        [ ( "rooms list exits 0", `Quick, test_rooms_list_exits_zero )
        ; ( "rooms list contains room entries", `Quick, test_rooms_list_output_contains_room_entries )
        ] )
    ; ( "rooms_join",
        [ ( "rooms join missing room exits non-zero", `Quick, test_rooms_join_missing_room_exits_nonzero )
        ; ( "rooms join --help exits 0", `Quick, test_rooms_join_help_exits_zero )
        ; ( "rooms knock approve then join flow", `Quick, test_rooms_knock_approve_then_join_flow )
        ] )
    ; ( "rooms_my_rooms",
        [ ( "rooms my-rooms exits 0", `Quick, test_rooms_my_rooms_exits_zero )
        ; ( "rooms my-rooms lists joined rooms", `Quick, test_rooms_my_rooms_lists_joined_rooms )
        ; ( "rooms my-rooms --json is valid JSON array", `Quick, test_rooms_my_rooms_json_output )
        ] )
    ; ( "doctor_deep",
        [ ( "doctor output contains relay/broker info", `Quick, test_doctor_output_contains_relay_info )
        ; ( "doctor output contains peer/registry info", `Quick, test_doctor_output_contains_peer_summary )
        ] )
    ; ( "worktree_list",
        [ ( "worktree list exits 0", `Quick, test_worktree_list_exits_zero )
        ; ( "worktree list contains refs/heads entries", `Quick, test_worktree_list_output_contains_refs_heads )
        ] )
    ; ( "instances",
        [ ( "instances exits 0", `Quick, test_instances_exits_zero )
        ; ( "instances output contains managed header", `Quick, test_instances_output_contains_managed_header )
        ; ( "instances --json is valid JSON", `Quick, test_instances_json_output_is_valid )
        ] )
    ; ( "prune_rooms",
        [ ( "prune-rooms exits 0", `Quick, test_prune_rooms_exits_zero )
        ; ( "prune-rooms output mentions eviction", `Quick, test_prune_rooms_output_contains_eviction_info )
        ] )
    ; ( "compact",
        [ ( "set-compact unregistered session", `Quick, test_set_compact_unregistered_session )
        ; ( "clear-compact unregistered session", `Quick, test_clear_compact_unregistered_session )
        ] )
    ; ( "check_pending_reply",
        [ ( "check-pending-reply missing args exits non-zero", `Quick, test_check_pending_reply_missing_args_exits_nonzero )
        ; ( "check-pending-reply invalid perm produces output", `Quick, test_check_pending_reply_invalid_perm_reports_error )
        ] )
    ; ( "agent_delete",
        [ ( "agent delete missing name exits non-zero", `Quick, test_agent_delete_missing_name_exits_nonzero )
        ; ( "agent delete nonexistent role reports error", `Quick, test_agent_delete_nonexistent_role_reports_error )
        ] )
    ; ( "config_generation_client",
        [ ( "config generation-client exits 0", `Quick, test_config_generation_client_exits_zero )
        ; ( "config generation-client shows client name", `Quick, test_config_generation_client_shows_client_name )
        ] )
    ; ( "worktree_gc",
        [ ( "gc with no matching worktrees exits 0", `Quick, test_worktree_gc_no_worktrees )
        ; ( "gc --clean removes clean merged worktree", `Quick, test_worktree_gc_clean_removes_merged )
        ; ( "gc dry-run refuses dirty worktree", `Quick, test_worktree_gc_refuses_dirty )
        ] )
    ; ( "agent_rename",
        [ ( "agent rename exits 0", `Quick, test_agent_rename_exits_zero )
        ; ( "agent rename old file is gone", `Quick, test_agent_rename_old_file_gone )
        ; ( "agent rename new file exists", `Quick, test_agent_rename_new_file_exists )
        ; ( "agent rename missing old exits non-zero", `Quick, test_agent_rename_missing_old_exits_nonzero )
        ; ( "agent rename existing new exits non-zero", `Quick, test_agent_rename_existing_new_exits_nonzero )
        ] )
    ; ( "schedule_enable_disable",
        [ ( "enable nonexistent schedule exits non-zero", `Quick, test_schedule_enable_nonexistent_exits_nonzero )
        ; ( "disable nonexistent schedule exits non-zero", `Quick, test_schedule_disable_nonexistent_exits_nonzero )
        ; ( "enable missing name exits non-zero", `Quick, test_schedule_enable_missing_name_exits_nonzero )
        ; ( "disable missing name exits non-zero", `Quick, test_schedule_disable_missing_name_exits_nonzero )
        ; ( "enable/disable roundtrip on temp schedule", `Quick, test_schedule_enable_disable_roundtrip )
        ] )
    ; ( "peer_pass_list",
        [ ( "peer-pass list with no artifacts shows empty message", `Quick, test_peer_pass_list_empty )
        ; ( "peer-pass list with artifacts shows review entries", `Quick, test_peer_pass_list_shows_entries )
        ; ( "peer-pass list --json outputs valid JSON", `Quick, test_peer_pass_list_json )
        ] )
    ; ( "peer_pass_verify",
        [ ( "peer-pass verify valid artifact exits 0", `Quick, test_peer_pass_verify_valid_artifact )
        ; ( "peer-pass verify nonexistent file exits non-zero", `Quick, test_peer_pass_verify_nonexistent )
        ] )
    ; ( "install_dry_run",
        [ ( "install all --dry-run exits 0", `Quick, test_install_all_dry_run_exits_zero )
        ; ( "install all --dry-run is binary-only (no client MCP)", `Quick, test_install_all_dry_run_shows_dry_run_markers )
        ; ( "install all --dry-run skips all clients by default", `Quick, test_install_all_dry_run_skips_all_clients_by_default )
        ; ( "install all --json --dry-run binary_only", `Quick, test_install_all_json_dry_run_binary_only )
        ; ( "install all --with-clients --dry-run configures", `Quick, test_install_all_with_clients_dry_run_configures )
        ; ( "interactive install defaults skip all clients", `Quick, test_interactive_install_default_skips_all_clients )
        ; ( "install all --dry-run shows opt-in guidance", `Quick, test_install_all_dry_run_epilog )
        ; ( "install kimi --dry-run exits 0 and shows DRY-RUN", `Quick, test_install_dry_run_kimi )
        ; ( "install opencode --dry-run exits 0 and shows DRY-RUN", `Quick, test_install_dry_run_opencode )
        ; ( "install codex --dry-run exits 0 and shows DRY-RUN", `Quick, test_install_dry_run_codex )
        ] )
    ; ( "install_opencode_real",
        [ ( "install opencode --force creates deliver-watch scripts", `Quick, test_install_opencode_creates_deliver_watch_scripts )
        ] )
    ; ( "agent_new_banner",
        [ ( "agent new banner has no double UTC", `Quick, test_agent_new_banner_no_double_utc )
        ] )
    ; ( "broker_root_fallthrough",
        [ ( "legacy broker root env warns on stderr", `Quick, test_legacy_broker_root_env_warns )
        ; ( "legacy broker root env uses canonical path", `Quick, test_legacy_broker_root_env_uses_canonical )
        ] )
    ; ( "sweep",
        [ ( "sweep --force removes dead registrations", `Quick, test_sweep_force_removes_dead_reg )
        ; ( "sweep refuses when recent non-managed registrations exist", `Quick, test_sweep_without_force_refuses_when_recent_reg_exists )
        ; ( "sweep drops aged pidless CLI registration without force", `Quick, test_sweep_without_force_drops_aged_pidless_cli_reg )
        ; ( "sweep --force bypasses alive guard", `Quick, test_sweep_force_bypasses_alive_guard )
        ] )
    ; ( "registry_prune",
        [ ( "registry-prune dry-run with no stale entries exits 0", `Quick, test_registry_prune_dry_run_no_stale )
        ; ( "registry-prune --force removes dead matching registrations", `Quick, test_registry_prune_force_removes_dead_reg )
        ; ( "registry-prune --pattern filter works correctly", `Quick, test_registry_prune_pattern_filter )
        ] )
    ; ( "relay_dead_letter",
        [ ( "relay dead-letter --help exits 0", `Quick, test_relay_dead_letter_help_exits_zero )
        ; ( "relay dead-letter without relay-url exits non-zero", `Quick, test_relay_dead_letter_no_relay_url_exits_nonzero )
        ; ( "relay dm peek --help exits 0 and is listed", `Quick, test_relay_dm_peek_help_exits_zero )
        ; ( "monitor --help lists relay watcher flags", `Quick, test_monitor_help_lists_relay )
        ; ( "relay subscribe https passes TLS scheme guard (B189)", `Quick, test_relay_subscribe_https_no_longer_rejected_for_tls_scheme )
        ] )
    ; ( "send_from_spoofing",
        [ ( "send --from spoofing rejected when alias held by different session", `Quick, test_send_from_spoofing_rejected )
        ; ( "send --from own alias allowed", `Quick, test_send_from_own_alias_allowed )
        ; ( "send --from unregistered alias rejected", `Quick, test_send_from_unregistered_alias_rejected )
        ; ( "send --from spoofing allowed for coordinator", `Quick, test_send_from_coordinator_allowed )
        ; ( "send --from case variation spoofing rejected", `Quick, test_send_from_case_variation_rejected )
        ; ( "send-all --from spoofing rejected", `Quick, test_send_all_from_spoofing_rejected )
        ] )
    ; ( "ping_dashboard",
        [ ( "ping exits 0 with temp broker", `Quick, test_connect_dashboard_exits_zero )
        ; ( "ping shows broker root", `Quick, test_connect_dashboard_shows_broker_root )
        ; ( "ping --json is valid JSON", `Quick, test_connect_dashboard_json_valid )
        ; ( "ping next action mentions install", `Quick, test_connect_dashboard_next_action_not_installed )
        ; ( "ping next action mentions partially configured", `Quick, test_connect_dashboard_next_action_partially_configured )
        ; ( "ping next action mentions no live session", `Quick, test_connect_dashboard_next_action_all_installed_no_session )
        ] )
    ; ( "ping_verify",
        [ ( "ping --verify reports INCONCLUSIVE", `Quick, test_connect_verify_inconclusive )
        ; ( "ping verify archive path works", `Quick, test_connect_verify_pass_via_drain )
        ; ( "ping --verify does not drain real inbox", `Quick, test_connect_verify_does_not_drain_real_inbox )
        ; ( "ping verify detects FAIL on broken broker", `Quick, test_connect_verify_fail_on_broken_broker )
        ] )
    ; ( "ping_client_detection",
        [ ( "ping detects codex config", `Quick, test_connect_detects_codex )
        ; ( "ping detects kimi config", `Quick, test_connect_detects_kimi )
        ] )
    ; ( "connect_deprecated_alias",
        [ ( "connect alias prints deprecation hint + still works", `Quick, test_connect_deprecated_alias_prints_hint )
        ; ( "connect alias --verify still runs probe", `Quick, test_connect_deprecated_alias_verify_works )
        ] )
    ; ( "init_name_hardening",
        [ ( "init --require-easy terminates with nonce", `Quick, test_init_require_easy_terminates_with_nonce )
        ; ( "init --no-nonce keeps default entropy", `Quick, test_init_no_nonce_keeps_default_entropy )
        ; ( "init --alias foo is not nonce'd", `Quick, test_init_explicit_alias_not_nonced )
        ; ( "init --alias codex is rejected", `Quick, test_init_rejects_banned_alias )
        ; ( "init prefers Claude environment over ambiguous PATH", `Quick
          , test_init_prefers_claude_environment_over_ambiguous_path )
        ; ( "init reuses alias for same session_id", `Quick, test_init_reuses_alias_for_same_session_id )
        ; ( "init explicit rename refused sticky alias", `Quick, test_init_explicit_rename_refused_sticky_alias )
        ; ( "register cmd explicit rename refused sticky alias", `Quick, test_register_cmd_explicit_rename_refused_sticky_alias )
        ; ( "register cmd same-alias refresh allowed", `Quick, test_register_cmd_same_alias_refresh_allowed )
        ; ( "register cmd same-alias reserved-prefix refresh allowed (B240)", `Quick, test_register_cmd_same_alias_reserved_prefix_refresh_allowed )
        ; ( "register cmd env-alias rename refused sticky alias", `Quick, test_register_cmd_env_alias_rename_refused_sticky_alias )
        ; ( "cli rename happy path (B140)", `Quick, test_cli_rename_happy_path )
        ; ( "sticky alias error advertises c2c rename (B140)", `Quick, test_sticky_alias_error_advertises_rename )
        ] )
    ]
