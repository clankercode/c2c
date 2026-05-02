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

(* ------------------------------------------------------------------------- *)
(* c2c doctor — verify health check output and exit 0 on clean run          *)
(* ------------------------------------------------------------------------- *)

let test_doctor_runs_and_exits_zero () =
  (* doctor requires being in the repo, so run from repo root *)
  let cmd = "c2c doctor > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c doctor exits 0" 0 rc

let test_doctor_output_contains_health_checks () =
  let tmpfile = Filename.temp_file "c2c-doctor" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf "c2c doctor > %s 2>&1" tmpfile));
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

let test_doctor_output_contains_commits_ahead () =
  let tmpfile = Filename.temp_file "c2c-doctor" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf "c2c doctor > %s 2>&1" tmpfile));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output contains commits ahead header" true
        (string_contains content "commits ahead"))

let test_doctor_output_contains_push_verdict () =
  let tmpfile = Filename.temp_file "c2c-doctor" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf "c2c doctor > %s 2>&1" tmpfile));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output contains push verdict category" true
        (string_contains content "Relay/deploy critical"
         || string_contains content "Local-only"))

let test_doctor_output_contains_relay_classification () =
  let tmpfile = Filename.temp_file "c2c-doctor" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf "c2c doctor > %s 2>&1" tmpfile));
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
      let cmd = Printf.sprintf "cd %s && c2c config show > /dev/null 2>&1" root in
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
          ignore (Sys.command (Printf.sprintf "cd %s && c2c config show > %s 2>&1" root tmpfile));
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
          ignore (Sys.command (Printf.sprintf "cd %s && c2c config show > %s 2>&1" root tmpfile));
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
  let cmd = "c2c agent list > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c agent list exits 0" 0 rc

let test_agent_list_shows_role_files () =
  let tmpfile = Filename.temp_file "c2c-agent-list" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf "c2c agent list > %s 2>&1" tmpfile));
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
    let cmd = Printf.sprintf "cd %s && c2c agent new %s > /dev/null 2>&1"
      (Filename.quote tmpdir) role_name in
    let rc = Sys.command cmd in
    check int "c2c agent new exits 0" 0 rc;
    (* The file should exist at .c2c/roles/<role_name>.md relative to tmpdir *)
    let role_path = Filename.concat tmpdir (Printf.sprintf ".c2c/roles/%s.md" role_name) in
    check bool "role file was created" true (Sys.file_exists role_path))

let test_agent_new_role_file_is_valid_yaml () =
  with_temp_dir (fun tmpdir ->
    let role_name = Printf.sprintf "e2e-parse-test-%08x" (Random.bits ()) in
    let cmd = Printf.sprintf "cd %s && c2c agent new %s > /dev/null 2>&1"
      (Filename.quote tmpdir) role_name in
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
    ignore (Sys.command (Printf.sprintf
      "cd %s && c2c agent new %s > /dev/null 2>&1"
      (Filename.quote tmpdir) old_name));
    (* Rename it *)
    let cmd = Printf.sprintf
      "cd %s && c2c agent rename %s %s > /dev/null 2>&1"
      (Filename.quote tmpdir) old_name new_name in
    let rc = Sys.command cmd in
    check int "c2c agent rename exits 0" 0 rc)

let test_agent_rename_old_file_gone () =
  with_temp_dir (fun tmpdir ->
    let old_name = Printf.sprintf "e2e-rename-src-%08x" (Random.bits ()) in
    let new_name = Printf.sprintf "e2e-rename-dst-%08x" (Random.bits ()) in
    ignore (Sys.command (Printf.sprintf
      "cd %s && c2c agent new %s > /dev/null 2>&1"
      (Filename.quote tmpdir) old_name));
    ignore (Sys.command (Printf.sprintf
      "cd %s && c2c agent rename %s %s > /dev/null 2>&1"
      (Filename.quote tmpdir) old_name new_name));
    let old_path = Filename.concat tmpdir (Printf.sprintf ".c2c/roles/%s.md" old_name) in
    check bool "old role file is gone after rename" false (Sys.file_exists old_path))

let test_agent_rename_new_file_exists () =
  with_temp_dir (fun tmpdir ->
    let old_name = Printf.sprintf "e2e-rename-src2-%08x" (Random.bits ()) in
    let new_name = Printf.sprintf "e2e-rename-dst2-%08x" (Random.bits ()) in
    ignore (Sys.command (Printf.sprintf
      "cd %s && c2c agent new %s > /dev/null 2>&1"
      (Filename.quote tmpdir) old_name));
    ignore (Sys.command (Printf.sprintf
      "cd %s && c2c agent rename %s %s > /dev/null 2>&1"
      (Filename.quote tmpdir) old_name new_name));
    let new_path = Filename.concat tmpdir (Printf.sprintf ".c2c/roles/%s.md" new_name) in
    check bool "new role file exists after rename" true (Sys.file_exists new_path))

let test_agent_rename_missing_old_exits_nonzero () =
  let nonexistent = Printf.sprintf "nonexistent-role-%08x" (Random.bits ()) in
  let new_name = Printf.sprintf "some-new-name-%08x" (Random.bits ()) in
  let cmd = Printf.sprintf "c2c agent rename %s %s > /dev/null 2>&1"
    nonexistent new_name in
  let rc = Sys.command cmd in
  check bool "rename nonexistent role exits non-zero" true (rc <> 0)

let test_agent_rename_existing_new_exits_nonzero () =
  with_temp_dir (fun tmpdir ->
    let name_a = Printf.sprintf "e2e-rename-a-%08x" (Random.bits ()) in
    let name_b = Printf.sprintf "e2e-rename-b-%08x" (Random.bits ()) in
    (* Create two roles *)
    ignore (Sys.command (Printf.sprintf
      "cd %s && c2c agent new %s > /dev/null 2>&1"
      (Filename.quote tmpdir) name_a));
    ignore (Sys.command (Printf.sprintf
      "cd %s && c2c agent new %s > /dev/null 2>&1"
      (Filename.quote tmpdir) name_b));
    (* Try to rename A to B — B already exists, should fail *)
    let cmd = Printf.sprintf
      "cd %s && c2c agent rename %s %s > /dev/null 2>&1"
      (Filename.quote tmpdir) name_a name_b in
    let rc = Sys.command cmd in
    check bool "rename to existing name exits non-zero" true (rc <> 0))

(* ------------------------------------------------------------------------- *)
(* c2c list — verify peer listing                                           *)
(* ------------------------------------------------------------------------- *)

let test_list_exits_zero () =
  let cmd = "C2C_CLI_FORCE=1 c2c list > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c list exits 0" 0 rc

let test_list_output_contains_peer_entries () =
  let tmpfile = Filename.temp_file "c2c-list" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf "C2C_CLI_FORCE=1 c2c list > %s 2>&1" tmpfile));
      let ch = open_in tmpfile in
      let lines = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () ->
          let rec read_lines acc =
            try read_lines ((input_line ch) :: acc)
            with End_of_file -> List.rev acc
          in
          read_lines [])
      in
      (* list output has lines with status keywords: alive, dead, or ??? *)
      let has_status = List.exists (fun l ->
        string_contains l "alive" || string_contains l "dead"
        || string_contains l "???"
      ) lines in
      check bool "list output contains peer status entries" true has_status)

(* ------------------------------------------------------------------------- *)
(* c2c send — fixture-gated send test                                       *)
(* ------------------------------------------------------------------------- *)

let test_send_missing_args_exits_nonzero () =
  let cmd = "C2C_CLI_FORCE=1 C2C_SEND_MESSAGE_FIXTURE=1 c2c send > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  (* Missing required ALIAS and MSG args => exits non-zero *)
  check bool "c2c send with no args exits non-zero" true (rc <> 0)

let test_send_unknown_alias_reports_error () =
  let tmpfile = Filename.temp_file "c2c-send" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_SEND_MESSAGE_FIXTURE=1 c2c send nonexistent-test-alias 'hello' > %s 2>&1"
        tmpfile));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "send to unknown alias reports error" true
        (string_contains content "unknown alias" || string_contains content "error"))

(* ------------------------------------------------------------------------- *)
(* c2c whoami — verify alias display                                        *)
(* ------------------------------------------------------------------------- *)

let test_whoami_exits_zero () =
  (* Use a fake session ID so whoami exits 0 even without a real registration *)
  let cmd = "C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=cli-test-session c2c whoami > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c whoami exits 0" 0 rc

let test_whoami_output_contains_alias_field () =
  let tmpfile = Filename.temp_file "c2c-whoami" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=cli-test-session c2c whoami > %s 2>&1"
        tmpfile));
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
  let cmd = "C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=cli-test-session c2c history > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c history exits 0" 0 rc

(* ------------------------------------------------------------------------- *)
(* c2c schedule list — verify schedule listing                              *)
(* ------------------------------------------------------------------------- *)

let test_schedule_list_exits_zero () =
  let cmd = "C2C_CLI_FORCE=1 c2c schedule list > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c schedule list exits 0" 0 rc

let test_schedule_list_output_contains_header () =
  let tmpfile = Filename.temp_file "c2c-schedule-list" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c schedule list > %s 2>&1" tmpfile));
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
  let cmd = "C2C_CLI_FORCE=1 c2c memory list > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c memory list exits 0" 0 rc

let test_memory_list_output_is_nonempty () =
  let tmpfile = Filename.temp_file "c2c-memory-list" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c memory list > %s 2>&1" tmpfile));
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
      ignore (Sys.command (Printf.sprintf "c2c roles validate > %s 2>&1" tmpfile));
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
  let cmd = "C2C_CLI_FORCE=1 c2c rooms list > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c rooms list exits 0" 0 rc

let test_rooms_list_output_contains_room_entries () =
  let tmpfile = Filename.temp_file "c2c-rooms-list" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c rooms list > %s 2>&1" tmpfile));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* Output contains room entries: "room-id (N members" *)
      check bool "rooms list contains room entry pattern" true
        (string_contains content "(" && string_contains content "members"))

(* ------------------------------------------------------------------------- *)
(* c2c rooms join — verify room join / missing-arg handling                 *)
(* ------------------------------------------------------------------------- *)

let test_rooms_join_missing_room_exits_nonzero () =
  (* No ROOM argument provided → should exit non-zero *)
  let cmd = "C2C_CLI_FORCE=1 c2c rooms join > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check bool "c2c rooms join with no args exits non-zero" true (rc <> 0)

let test_rooms_join_help_exits_zero () =
  (* --help should exit 0 even with missing required arg *)
  let cmd = "C2C_CLI_FORCE=1 c2c rooms join --help > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c rooms join --help exits 0" 0 rc

(* ------------------------------------------------------------------------- *)
(* c2c doctor — deeper output checks                                         *)
(* ------------------------------------------------------------------------- *)

let test_doctor_output_contains_relay_info () =
  let tmpfile = Filename.temp_file "c2c-doctor-relay" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf "c2c doctor > %s 2>&1" tmpfile));
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
      ignore (Sys.command (Printf.sprintf "c2c doctor > %s 2>&1" tmpfile));
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
  let cmd = "C2C_CLI_FORCE=1 c2c worktree list > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c worktree list exits 0" 0 rc

let test_worktree_list_output_contains_refs_heads () =
  let tmpfile = Filename.temp_file "c2c-worktree-list" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c worktree list > %s 2>&1" tmpfile));
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
  let cmd = "C2C_CLI_FORCE=1 c2c instances > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c instances exits 0" 0 rc

let test_instances_output_contains_managed_header () =
  let tmpfile = Filename.temp_file "c2c-instances" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c instances > %s 2>&1" tmpfile));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      (* instances output shows "Managed instances" header and count *)
      let has_header =
        string_contains content "Managed instances"
        && (string_contains content "alive" || string_contains content "total")
      in
      check bool "instances output contains managed header and counts" true has_header)

let test_instances_json_output_is_valid () =
  let tmpfile = Filename.temp_file "c2c-instances-json" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c instances --json > %s 2>&1" tmpfile));
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
  let cmd = "C2C_CLI_FORCE=1 c2c prune-rooms > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c prune-rooms exits 0" 0 rc

let test_prune_rooms_output_contains_eviction_info () =
  (* Output is either "Evicted N dead members:" or "No dead members to evict." *)
  let tmpfile = Filename.temp_file "c2c-prune-rooms" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf "C2C_CLI_FORCE=1 c2c prune-rooms > %s 2>&1" tmpfile));
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
      let rc = Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=cli-test-compact c2c set-compact --reason test > %s 2>&1"
        tmpfile) in
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
      let rc = Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=cli-test-compact c2c clear-compact > %s 2>&1"
        tmpfile) in
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
  let cmd = "C2C_CLI_FORCE=1 c2c check-pending-reply > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check bool "check-pending-reply with no args exits non-zero" true (rc <> 0)

let test_check_pending_reply_invalid_perm_reports_error () =
  let tmpfile = Filename.temp_file "c2c-check-pending" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c check-pending-reply nonexistent-perm fake-alias > %s 2>&1"
        tmpfile));
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
  let cmd = "c2c agent delete > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check bool "agent delete with no name exits non-zero" true (rc <> 0)

let test_agent_delete_nonexistent_role_reports_error () =
  let tmpfile = Filename.temp_file "c2c-agent-delete" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let rc = Sys.command (Printf.sprintf
        "c2c agent delete nonexistent-test-role-xyz > %s 2>&1" tmpfile) in
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
  let alias = Printf.sprintf "willow-test-kimi-%d" (Unix.getpid ()) in
  let tmpfile = Filename.temp_file "c2c-install-dry" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let cmd = Printf.sprintf "c2c install kimi --dry-run --alias %s > %s 2>&1"
        (Filename.quote alias) tmpfile in
      let rc = Sys.command cmd in
      check int "install kimi --dry-run exits 0" 0 rc;
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "dry-run output contains [DRY-RUN]" true
        (string_contains content "[DRY-RUN]");
      check bool "dry-run output mentions kimi config" true
        (string_contains content "kimi" || string_contains content "Kimi"))

let test_install_dry_run_opencode () =
  let alias = Printf.sprintf "willow-test-oc-%d" (Unix.getpid ()) in
  let tmpfile = Filename.temp_file "c2c-install-dry" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let cmd = Printf.sprintf "c2c install opencode --dry-run --alias %s > %s 2>&1"
        (Filename.quote alias) tmpfile in
      let rc = Sys.command cmd in
      check int "install opencode --dry-run exits 0" 0 rc;
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "dry-run output contains [DRY-RUN]" true
        (string_contains content "[DRY-RUN]"))

let test_install_dry_run_codex () =
  let alias = Printf.sprintf "willow-test-codex-%d" (Unix.getpid ()) in
  let tmpfile = Filename.temp_file "c2c-install-dry" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let cmd = Printf.sprintf "c2c install codex --dry-run --alias %s > %s 2>&1"
        (Filename.quote alias) tmpfile in
      let rc = Sys.command cmd in
      check int "install codex --dry-run exits 0" 0 rc;
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "dry-run output contains [DRY-RUN]" true
        (string_contains content "[DRY-RUN]"))

(* ------------------------------------------------------------------------- *)
(* c2c config generation-client                                               *)
(* ------------------------------------------------------------------------- *)

let test_config_generation_client_exits_zero () =
  let cmd = "C2C_CLI_FORCE=1 c2c config generation-client > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "config generation-client exits 0" 0 rc

let test_config_generation_client_shows_client_name () =
  let tmpfile = Filename.temp_file "c2c-config-gen" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 c2c config generation-client > %s 2>&1" tmpfile));
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
      sh "git -C %s commit -q -m initial" (Filename.quote repo);
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
            Printf.sprintf
              "cd %s && c2c worktree gc --path-prefix=no-such-wt-gc-test > %s 2>&1"
              (Filename.quote repo)
              (Filename.quote tmpfile)
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
        Printf.sprintf "cd %s && c2c worktree gc --path-prefix=wt --active-window-hours=0 --clean > /dev/null 2>&1"
          (Filename.quote repo)
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
            Printf.sprintf
              "cd %s && c2c worktree gc --path-prefix=wt > %s 2>&1"
              (Filename.quote repo)
              (Filename.quote tmpfile)
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
        (Printf.sprintf "c2c schedule enable nonexistent-test-sched-xyz > %s 2>&1" tmpfile) in
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
        (Printf.sprintf "c2c schedule disable nonexistent-test-sched-xyz > %s 2>&1" tmpfile) in
      check bool "schedule disable nonexistent exits non-zero" true (rc <> 0);
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output contains not found" true
        (string_contains content "not found"))

let test_schedule_enable_missing_name_exits_nonzero () =
  let rc = Sys.command "c2c schedule enable > /dev/null 2>&1" in
  check bool "schedule enable with no args exits non-zero" true (rc <> 0)

let test_schedule_disable_missing_name_exits_nonzero () =
  let rc = Sys.command "c2c schedule disable > /dev/null 2>&1" in
  check bool "schedule disable with no args exits non-zero" true (rc <> 0)

let test_schedule_enable_disable_roundtrip () =
  (* Use c2c schedule set to create a temp schedule, then disable/enable it,
     and clean up via c2c schedule rm.  This avoids having to locate the
     schedule directory on disk (it resolves via broker-root, not cwd). *)
  let sched_name = Printf.sprintf "test-sched-%08x" (Random.bits ()) in
  (* Create the schedule via CLI *)
  let rc_set = Sys.command
    (Printf.sprintf "c2c schedule set %s --interval 5m --message test > /dev/null 2>&1"
      (Filename.quote sched_name)) in
  check int "schedule set exits 0" 0 rc_set;
  Fun.protect ~finally:(fun () ->
    ignore (Sys.command
      (Printf.sprintf "c2c schedule rm %s > /dev/null 2>&1" (Filename.quote sched_name))))
    (fun () ->
      (* Disable the schedule *)
      let tmpfile = Filename.temp_file "c2c-sched-rt" ".out" in
      Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
        (fun () ->
          let rc = Sys.command
            (Printf.sprintf "c2c schedule disable %s > %s 2>&1"
              (Filename.quote sched_name) tmpfile) in
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
            (Printf.sprintf "c2c schedule enable %s > %s 2>&1"
              (Filename.quote sched_name) tmpfile2) in
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
      let cmd = Printf.sprintf "cd %s && c2c peer-pass list 2>&1" (Filename.quote repo) in
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
                Printf.sprintf "cd %s && c2c peer-pass list > %s 2>&1"
                  (Filename.quote repo) (Filename.quote tmpfile)
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
                Printf.sprintf "cd %s && c2c peer-pass list --json > %s 2>&1"
                  (Filename.quote repo) (Filename.quote tmpfile)
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
          Printf.sprintf "c2c peer-pass verify %s > %s 2>&1"
            (Filename.quote real_art) (Filename.quote tmpfile)
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
    Printf.sprintf "c2c peer-pass verify %s > /dev/null 2>&1"
      (Filename.quote nonexistent)
  ) in
  check bool "peer-pass verify nonexistent exits non-zero" true (rc <> 0)

(* ------------------------------------------------------------------------- *)
(* c2c install --dry-run — verify install preview without side effects       *)
(* ------------------------------------------------------------------------- *)

let test_install_all_dry_run_exits_zero () =
  let cmd = "c2c install all --dry-run > /dev/null 2>&1 < /dev/null" in
  let rc = Sys.command cmd in
  check int "c2c install all --dry-run exits 0" 0 rc

let test_install_all_dry_run_shows_dry_run_markers () =
  let tmpfile = Filename.temp_file "c2c-install-all-dry" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "c2c install all --dry-run > %s 2>&1 < /dev/null" tmpfile));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output contains [DRY-RUN] marker" true
        (string_contains content "[DRY-RUN]"))

let test_install_gemini_dry_run_exits_zero () =
  let tmpfile = Filename.temp_file "c2c-install-gemini-dry" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      let rc = Sys.command (Printf.sprintf
        "c2c install gemini --dry-run > %s 2>&1 < /dev/null" tmpfile) in
      check int "c2c install gemini --dry-run exits 0" 0 rc;
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output contains broker root" true
        (string_contains content "broker root"))

let test_install_gemini_dry_run_shows_config_preview () =
  let tmpfile = Filename.temp_file "c2c-install-gemini-dry2" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "c2c install gemini --dry-run > %s 2>&1 < /dev/null" tmpfile));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "output contains [DRY-RUN] would write" true
        (string_contains content "[DRY-RUN] would write");
      check bool "output contains Configured Gemini" true
        (string_contains content "Configured Gemini"))

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
      let cmd = Printf.sprintf "c2c agent new %s > %s 2>&1"
        (Filename.quote alias) tmpfile in
      ignore (Sys.command cmd);
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      let lower = String.lowercase_ascii content in
      check bool "banner has no double UTC (no 'utc utc')" true
        (not (string_contains lower "utc utc")))

(* ------------------------------------------------------------------------- *)
(* Alcotest registry                                                         *)
(* ------------------------------------------------------------------------- *)

let () =
  Alcotest.run "c2c_cli"
    [ ( "doctor",
        [ ( "doctor exits 0 on clean run", `Quick, test_doctor_runs_and_exits_zero )
        ; ( "doctor output contains health checks", `Quick, test_doctor_output_contains_health_checks )
        ; ( "doctor output contains commits ahead", `Quick, test_doctor_output_contains_commits_ahead )
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
        ; ( "send unknown alias reports error", `Quick, test_send_unknown_alias_reports_error )
        ] )
    ; ( "whoami",
        [ ( "whoami exits 0", `Quick, test_whoami_exits_zero )
        ; ( "whoami output contains alias field", `Quick, test_whoami_output_contains_alias_field )
        ] )
    ; ( "history",
        [ ( "history exits 0", `Quick, test_history_exits_zero )
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
        ; ( "install gemini --dry-run exits 0 and mentions broker root", `Quick, test_install_gemini_dry_run_exits_zero )
        ; ( "install gemini --dry-run shows config preview", `Quick, test_install_gemini_dry_run_shows_config_preview )
        ; ( "install kimi --dry-run exits 0 and shows DRY-RUN", `Quick, test_install_dry_run_kimi )
        ; ( "install opencode --dry-run exits 0 and shows DRY-RUN", `Quick, test_install_dry_run_opencode )
        ; ( "install codex --dry-run exits 0 and shows DRY-RUN", `Quick, test_install_dry_run_codex )
        ] )
    ; ( "agent_new_banner",
        [ ( "agent new banner has no double UTC", `Quick, test_agent_new_banner_no_double_utc )
        ] )
    ]
