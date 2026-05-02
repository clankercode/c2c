(* test_c2c_cli.ml — CLI subcommand tests (#670)
   Tests for c2c CLI commands with zero prior test coverage:
   - c2c doctor
   - c2c config show
   - c2c agent list
   - c2c roles validate

   Each test invokes the c2c binary via Sys.command and verifies
   exit code + output shape. *)

open Alcotest

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
    ; ( "roles_validate",
        [ ( "roles validate shows summary line", `Quick, test_roles_validate_runs_and_shows_summary )
        ] )
    ]
