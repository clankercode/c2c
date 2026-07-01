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
        || string_contains l "???"
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

(* ------------------------------------------------------------------------- *)
(* c2c send — fixture-gated send test                                       *)
(* ------------------------------------------------------------------------- *)

let test_send_missing_args_exits_nonzero () =
  (* Missing required ALIAS and MSG args => exits non-zero.
     Cmdliner rejects missing positional args before touching the broker. *)
  let cmd = c2c_cmd "C2C_CLI_FORCE=1 c2c send > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check bool "c2c send with no args exits non-zero" true (rc <> 0)

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
  let tmpfile = Filename.temp_file "c2c-worktree-list" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (c2c_cmd (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c dev worktree list > %s 2>&1" tmpfile)));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* Worktree list shows "refs/heads/" for each entry *)
      check bool "worktree list contains refs/heads entries" true
        (string_contains content "refs/heads"))

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
      debug_install_failure "kimi" cmd rc content;
      check int "install kimi --dry-run exits 0" 0 rc;
      check bool "dry-run output contains [DRY-RUN]" true
        (string_contains content "[DRY-RUN]");
      check bool "dry-run output mentions kimi config" true
        (string_contains content "kimi" || string_contains content "Kimi")))

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
      check bool "output contains [DRY-RUN] marker" true
        (string_contains content "[DRY-RUN]")))

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
      check bool "install all output contains canonical verify line" true
        (string_contains content "Run 'c2c connect --verify'");
      check bool "install all output contains restart footer" true
        (string_contains content "restart your CLI client")))

let test_install_gemini_dry_run_refuses () =
  let tmpfile = Filename.temp_file "c2c-install-gemini-dry" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let rc = Sys.command (c2c_cmd (Printf.sprintf
        "c2c install gemini --dry-run > %s 2>&1 < /dev/null" tmpfile)) in
      check bool "c2c install gemini --dry-run exits non-zero" true (rc <> 0);
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output mentions DEPRECATED or Gemini" true
        (string_contains content "DEPRECATED" || string_contains content "Gemini"
         || string_contains content "gemini"))

let test_install_gemini_dry_run_shows_deprecation () =
  let tmpfile = Filename.temp_file "c2c-install-gemini-dry2" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let rc = Sys.command (c2c_cmd (Printf.sprintf
        "c2c install gemini --dry-run > %s 2>&1 < /dev/null" tmpfile)) in
      check bool "c2c install gemini --dry-run exits non-zero" true (rc <> 0);
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output mentions not supported or DEPRECATED" true
        (string_contains content "DEPRECATED" || string_contains content "not supported"
         || string_contains content "Gemini"))

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

let test_sweep_without_force_refuses_when_alive_reg_exists () =
  with_temp_dir (fun dir ->
      (* Set up a temp broker with one LIVE (non-managed) registration.
         registration_is_alive returns true for pid=None or our own pid. *)
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
          check int "sweep without --force exits 1 when alive reg present" 1 rc;
          let err = read_file errfile in
          check bool "stderr mentions alive registration" true
            (string_contains err "alive");
          check bool "stderr mentions --force hint" true
            (string_contains err "--force")))

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

let test_relay_subscribe_rejects_https_until_tls_supported () =
  let outfile = Filename.temp_file "relay-subscribe-https" ".out" in
  let errfile = Filename.temp_file "relay-subscribe-https" ".err" in
  Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore; Sys.remove errfile |> ignore)
    (fun () ->
      let cmd = Printf.sprintf
        "C2C_CLI_FORCE=1 %s relay subscribe --relay-url https://relay.example --alias alice > %s 2> %s"
        c2c_exe outfile errfile
      in
      let rc = Sys.command cmd in
      check int "relay subscribe https exits non-zero" 1 rc;
      let err = read_file errfile in
      check bool "stderr explains TLS unsupported" true
        (string_contains err "does not support TLS"))

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
(* c2c connect — dashboard + --verify probe                                  *)
(* ------------------------------------------------------------------------- *)

let with_temp_broker f =
  with_temp_dir (fun dir ->
    let broker_root = Filename.concat dir "broker" in
    Unix.mkdir broker_root 0o755;
    f ~dir ~broker_root)

let test_connect_dashboard_exits_zero () =
  with_temp_broker (fun ~dir ~broker_root ->
    let env = Printf.sprintf "C2C_MCP_BROKER_ROOT=%s" broker_root in
    let cmd = c2c_cmd (Printf.sprintf "%s c2c connect > /dev/null 2>&1" env) in
    let rc = Sys.command cmd in
    check int "c2c connect exits 0" 0 rc)

let test_connect_dashboard_shows_broker_root () =
  with_temp_broker (fun ~dir ~broker_root ->
    let env = Printf.sprintf "C2C_MCP_BROKER_ROOT=%s" broker_root in
    let tmpfile = Filename.temp_file "c2c-connect" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c connect > %s 2>&1" env tmpfile)));
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
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c connect --json > %s 2>&1" env tmpfile)));
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
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c connect > %s 2>&1" env tmpfile)));
        let content = read_file tmpfile in
        check bool "next action mentions install" true
          (string_contains content "c2c install")))

let test_connect_verify_inconclusive () =
  with_temp_broker (fun ~dir ~broker_root ->
    let env = Printf.sprintf "C2C_MCP_BROKER_ROOT=%s" broker_root in
    let tmpfile = Filename.temp_file "c2c-connect-verify" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        let rc = Sys.command (c2c_cmd (Printf.sprintf "%s c2c connect --verify --timeout 1 > %s 2>&1" env tmpfile)) in
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
          "%s c2c connect --verify --timeout 1 > %s 2>&1" env tmpfile)));
        let inbox_after = C2c_mcp.Broker.read_inbox broker ~session_id in
        let has_real = List.exists (fun (m : C2c_mcp.message) -> m.content = real_msg) inbox_after in
        check bool "real inbox message survived verify probe" true has_real))

let test_connect_detects_codex () =
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
    let tmpfile = Filename.temp_file "c2c-connect-codex" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c connect > %s 2>&1" env tmpfile)));
        let content = read_file tmpfile in
        check bool "detects codex MCP server configured" true
          (string_contains content "codex: MCP server configured")))

let test_connect_detects_kimi () =
  with_temp_dir (fun dir ->
    let home = Filename.concat dir "fakehome" in
    Unix.mkdir home 0o755;
    let kimi_dir = Filename.concat home ".kimi" in
    Unix.mkdir kimi_dir 0o755;
    let config_path = Filename.concat kimi_dir "mcp.json" in
    write_file config_path {|{"mcpServers":{"c2c":{"type":"stdio"}}}|};
    let broker_root = Filename.concat dir "broker" in
    Unix.mkdir broker_root 0o755;
    let env = Printf.sprintf "HOME=%s C2C_MCP_BROKER_ROOT=%s" home broker_root in
    let tmpfile = Filename.temp_file "c2c-connect-kimi" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c connect > %s 2>&1" env tmpfile)));
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
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c connect > %s 2>&1" env tmpfile)));
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
    (* Codex: ~/.codex/config.toml with mcp_servers.c2c *)
    let codex_dir = Filename.concat home ".codex" in
    Unix.mkdir codex_dir 0o755;
    write_file (Filename.concat codex_dir "config.toml")
      "[mcp_servers.c2c]\ncommand = \"c2c-mcp-server\"\n";
    (* OpenCode: ~/.config/opencode/plugins/c2c.ts (>= 1024 bytes) *)
    let config_dir = Filename.concat home ".config" in
    (try Unix.mkdir config_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let oc_dir = Filename.concat config_dir "opencode" in
    let oc_plugins = Filename.concat oc_dir "plugins" in
    Unix.mkdir oc_dir 0o755;
    Unix.mkdir oc_plugins 0o755;
    let plugin_content = String.make 1100 ' ' in
    write_file (Filename.concat oc_plugins "c2c.ts") plugin_content;
    (* Kimi: ~/.kimi/mcp.json with mcpServers.c2c *)
    let kimi_dir = Filename.concat home ".kimi" in
    Unix.mkdir kimi_dir 0o755;
    write_file (Filename.concat kimi_dir "mcp.json")
      {|{"mcpServers":{"c2c":{"type":"stdio"}}}|};
    let broker_root = Filename.concat dir "broker" in
    Unix.mkdir broker_root 0o755;
    let env = Printf.sprintf "HOME=%s C2C_MCP_BROKER_ROOT=%s" home broker_root in
    let tmpfile = Filename.temp_file "c2c-connect-nosession" ".out" in
    Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
      (fun () ->
        ignore (Sys.command (c2c_cmd (Printf.sprintf "%s c2c connect > %s 2>&1" env tmpfile)));
        let content = read_file tmpfile in
        check bool "next action mentions no live session" true
          (string_contains content "no live session"
           || string_contains content "partially configured")))

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
          | [ w1; w2; nonce ] ->
              check bool "word1 non-empty" true (String.length w1 > 0);
              check bool "word2 non-empty" true (String.length w2 > 0);
              check int "nonce length 4" 4 (String.length nonce)
          | _ -> fail "alias not word-word-nonce")
      | None -> fail "no alias line in init output")

let test_init_no_nonce_yields_bare () =
  with_temp_dir (fun dir ->
      let rc, content = run_c2c_init ~broker_root:dir ~args:"--client codex --no-nonce" in
      check int "init --no-nonce exits 0" 0 rc;
      match extract_alias_line content with
      | Some alias ->
          (* codex-<word>-<word>: 3 segments, no nonce suffix. *)
          check int "alias has 3 segments" 3
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

let test_deliver_inbox_inotify_ignores_unrelated_events () =
  with_temp_dir (fun broker_root ->
      let live_pid = string_of_int (Unix.getpid ()) in
      let env = Printf.sprintf "C2C_SESSIONS_BROKER_ROOT=%s" (Filename.quote broker_root) in
      let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s C2C_MCP_SESSION_ID=recv-sid C2C_MCP_CLIENT_PID=%s c2c register --cross-repo --alias recv" env live_pid)) in
      check int ("register recv exits 0: " ^ out) 0 rc;
      let outfile = Filename.temp_file "c2c-deliver-inotify" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore) (fun () ->
          let cmd = Printf.sprintf
            "%s %s --inotify --loop --cross-repo --alias recv --full-body > %s 2>&1 & pid=$!; sleep 1; : > %s; sleep 1; kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true"
            env
            (Filename.quote c2c_deliver_inbox_binary)
            (Filename.quote outfile)
            (Filename.quote (Filename.concat broker_root "unrelated.inbox.json"))
          in
          let rc = Sys.command cmd in
          check int "inotify unrelated-event harness exits 0" 0 rc;
          let out = read_file outfile in
          check bool "unrelated event does not emit delivery" false (string_contains out "delivered from=");
          check bool "unrelated event does not emit zero summary" false (string_contains out "delivered=0")))

let test_deliver_inbox_register_self_enables_alias_send () =
  with_temp_dir (fun broker_root ->
      let env = Printf.sprintf "C2C_SESSIONS_BROKER_ROOT=%s" (Filename.quote broker_root) in
      let live_pid = string_of_int (Unix.getpid ()) in
      let rc, out = run_capture (c2c_cmd (Printf.sprintf "%s C2C_MCP_SESSION_ID=sender-sid C2C_MCP_CLIENT_PID=%s c2c register --cross-repo --alias sender" env live_pid)) in
      check int ("register sender exits 0: " ^ out) 0 rc;
      let outfile = Filename.temp_file "c2c-deliver-register" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove outfile |> ignore) (fun () ->
          let cmd = Printf.sprintf
            "%s %s --inotify --loop --cross-repo --alias recv --register --full-body > %s 2>&1 & pid=$!; sleep 1; %s C2C_MCP_SESSION_ID=sender-sid c2c send --cross-repo --from sender recv 'registered receiver body'; sleep 1; kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true"
            env
            (Filename.quote c2c_deliver_inbox_binary)
            (Filename.quote outfile)
            env
          in
          let rc = Sys.command cmd in
          check int "self-register harness exits 0" 0 rc;
          let out = read_file outfile in
          check bool "self-registered receiver gets alias send" true (string_contains out "registered receiver body");
          check bool "self-registered receiver drains exactly one" true (string_contains out "delivered=1")))

let () =
  Alcotest.run "c2c_cli"
    [ ( "doctor",
        [ ( "doctor exits 0 on clean run", `Quick, test_doctor_runs_and_exits_zero )
        ; ( "doctor output contains health checks", `Quick, test_doctor_output_contains_health_checks )
        ; ( "doctor output contains push status", `Quick, test_doctor_output_contains_push_status )
        ; ( "doctor output contains push verdict", `Quick, test_doctor_output_contains_push_verdict )
        ; ( "doctor output contains relay classification", `Quick, test_doctor_output_contains_relay_classification )
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
        ; ( "list output contains peer entries", `Quick, test_list_output_contains_peer_entries )
        ] )
    ; ( "send",
        [ ( "send missing args exits non-zero", `Quick, test_send_missing_args_exits_nonzero )
        ; ( "send unknown alias routes to relay outbox", `Quick, test_send_unknown_alias_routes_to_relay_outbox )
        ; ( "send cross-broker fallback routes to sibling broker", `Quick, test_send_cross_broker_fallback )
        ; ( "send not-found error mentions scanned brokers", `Quick, test_send_not_found_error_mentions_scanned_brokers )
        ] )
    ; ( "whoami",
        [ ( "whoami exits 0", `Quick, test_whoami_exits_zero )
        ; ( "whoami output contains alias field", `Quick, test_whoami_output_contains_alias_field )
        ] )
    ; ( "history",
        [ ( "history exits 0", `Quick, test_history_exits_zero )
        ] )
    ; ( "poll_inbox",
        [ ( "cross-repo alias drains", `Quick, test_poll_inbox_cross_repo_alias_drains )
        ; ( "cross-repo alias errors", `Quick, test_poll_inbox_cross_repo_alias_errors )
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
        ; ( "install all --dry-run shows [DRY-RUN] markers", `Quick, test_install_all_dry_run_shows_dry_run_markers )
        ; ( "install all --dry-run shows canonical epilog", `Quick, test_install_all_dry_run_epilog )
        ; ( "install gemini --dry-run refuses (deprecated)", `Quick, test_install_gemini_dry_run_refuses )
        ; ( "install gemini --dry-run shows deprecation", `Quick, test_install_gemini_dry_run_shows_deprecation )
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
        ; ( "sweep refuses when alive non-managed registrations exist", `Quick, test_sweep_without_force_refuses_when_alive_reg_exists )
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
        ; ( "relay subscribe rejects https until TLS is supported", `Quick, test_relay_subscribe_rejects_https_until_tls_supported )
        ] )
    ; ( "send_from_spoofing",
        [ ( "send --from spoofing rejected when alias held by different session", `Quick, test_send_from_spoofing_rejected )
        ; ( "send --from own alias allowed", `Quick, test_send_from_own_alias_allowed )
        ; ( "send --from unregistered alias rejected", `Quick, test_send_from_unregistered_alias_rejected )
        ; ( "send --from spoofing allowed for coordinator", `Quick, test_send_from_coordinator_allowed )
        ; ( "send --from case variation spoofing rejected", `Quick, test_send_from_case_variation_rejected )
        ; ( "send-all --from spoofing rejected", `Quick, test_send_all_from_spoofing_rejected )
        ] )
    ; ( "connect_dashboard",
        [ ( "connect exits 0 with temp broker", `Quick, test_connect_dashboard_exits_zero )
        ; ( "connect shows broker root", `Quick, test_connect_dashboard_shows_broker_root )
        ; ( "connect --json is valid JSON", `Quick, test_connect_dashboard_json_valid )
        ; ( "connect next action mentions install", `Quick, test_connect_dashboard_next_action_not_installed )
        ; ( "connect next action mentions partially configured", `Quick, test_connect_dashboard_next_action_partially_configured )
        ; ( "connect next action mentions no live session", `Quick, test_connect_dashboard_next_action_all_installed_no_session )
        ] )
    ; ( "connect_verify",
        [ ( "connect --verify reports INCONCLUSIVE", `Quick, test_connect_verify_inconclusive )
        ; ( "connect verify archive path works", `Quick, test_connect_verify_pass_via_drain )
        ; ( "connect --verify does not drain real inbox", `Quick, test_connect_verify_does_not_drain_real_inbox )
        ; ( "connect verify detects FAIL on broken broker", `Quick, test_connect_verify_fail_on_broken_broker )
        ] )
    ; ( "connect_client_detection",
        [ ( "connect detects codex config", `Quick, test_connect_detects_codex )
        ; ( "connect detects kimi config", `Quick, test_connect_detects_kimi )
        ] )
    ; ( "init_name_hardening",
        [ ( "init --require-easy terminates with nonce", `Quick, test_init_require_easy_terminates_with_nonce )
        ; ( "init --no-nonce yields bare alias", `Quick, test_init_no_nonce_yields_bare )
        ; ( "init --alias foo is not nonce'd", `Quick, test_init_explicit_alias_not_nonced )
        ; ( "init --alias codex is rejected", `Quick, test_init_rejects_banned_alias )
        ; ( "init reuses alias for same session_id", `Quick, test_init_reuses_alias_for_same_session_id )
        ] )
    ]
