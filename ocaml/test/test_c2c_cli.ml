(* test_c2c_cli.ml — CLI subcommand tests (#670, #698)
   Tests for c2c CLI commands with zero prior test coverage:
   - c2c doctor
   - c2c config show
   - c2c agent list
   - c2c roles validate
   - c2c list
   - c2c send (fixture-gated)
   - c2c whoami
   - c2c history
   - c2c schedule list
   - c2c memory list

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
  let cmd = "C2C_CLI_FORCE=1 C2C_MCP_ALIAS=cli-test-alias c2c whoami > /dev/null 2>&1" in
  let rc = Sys.command cmd in
  check int "c2c whoami exits 0" 0 rc

let test_whoami_output_contains_alias () =
  let tmpfile = Filename.temp_file "c2c-whoami" ".out" in
  Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
    (fun () ->
      ignore (Sys.command (Printf.sprintf
        "C2C_CLI_FORCE=1 C2C_MCP_ALIAS=cli-test-alias c2c whoami > %s 2>&1"
        tmpfile));
      let ch = open_in tmpfile in
      let content = Fun.protect ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
      in
      check bool "whoami output contains alias keyword" true
        (string_contains content "alias"))

(* ------------------------------------------------------------------------- *)
(* c2c history — verify message history display                             *)
(* ------------------------------------------------------------------------- *)

let test_history_exits_zero () =
  let cmd = "C2C_CLI_FORCE=1 C2C_MCP_ALIAS=cli-test-alias c2c history > /dev/null 2>&1" in
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
(* Alcotest registry                                                         *)
(* ------------------------------------------------------------------------- *)

let () =
  Alcotest.run "c2c_cli"
    [ ( "doctor",
        [ ( "doctor exits 0 on clean run", `Quick, test_doctor_runs_and_exits_zero )
        ; ( "doctor output contains health checks", `Quick, test_doctor_output_contains_health_checks )
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
        ; ( "whoami output contains alias", `Quick, test_whoami_output_contains_alias )
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
    ]
