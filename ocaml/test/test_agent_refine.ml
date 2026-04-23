(* End-to-end test for `c2c agent refine --dry-run` *)
open Alcotest

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "c2c-agent-refine-test-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let with_cwd dir f =
  let prev = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Unix.chdir prev)
    (fun () ->
      Unix.chdir dir;
      f ())

let c2c_path =
  match Sys.getenv_opt "HOME" with
  | Some home -> Filename.concat home ".local/bin/c2c"
  | None -> "/home/xertrov/.local/bin/c2c"

(* Capture stdout from a child process running `c2c agent refine ... --dry-run` *)
let capture_refine_dryrun ?(client="claude") ?(extra_args=[]) role_name =
  let stdout_read, stdout_write = Unix.pipe () in
  (* Build env: inherit current env + override C2C_KEY_DIR *)
  let base_env = Unix.environment () in
  let extra_env = [| "C2C_KEY_DIR=/tmp/c2c-agent-refine-test-keys" |] in
  let env = Array.append base_env extra_env in
  match Unix.fork () with
  | 0 ->
      (* child *)
      Unix.close stdout_read;
      Unix.dup2 stdout_write Unix.stdout;
      Unix.close stdout_write;
      Unix.execve c2c_path
        (Array.append
           [| c2c_path; "agent"; "refine"; role_name; "--client"; client |]
           (Array.of_list (extra_args @ [ "--dry-run" ])))
        env
  | child ->
      Unix.close stdout_write;
      let buf = Buffer.create 512 in
      let rec read_loop ch =
        match input_char ch with
        | exception End_of_file -> ()
        | c -> Buffer.add_char buf c; read_loop ch
      in
      let ch = Unix.in_channel_of_descr stdout_read in
      read_loop ch;
      close_in ch;
      let rec wait_eintr () =
        try Unix.waitpid [] child
        with Unix.Unix_error (Unix.EINTR, _, _) -> wait_eintr ()
      in
      let (_, status) = wait_eintr () in
      (Buffer.contents buf, status)

let contains ~sub s =
  if sub = "" then true
  else (
    let re = Str.regexp_string sub in
      try ignore (Str.search_forward re s 0); true
      with Not_found -> false)

let test_refine_dry_run_composes_correct_prompt () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  (* create .c2c/roles/ directory and a test role file *)
  let roles_dir = Filename.concat dir ".c2c" in
  Unix.mkdir roles_dir 0o755;
  let roles_subdir = Filename.concat roles_dir "roles" in
  Unix.mkdir roles_subdir 0o755;
  (* also copy role-designer.md into the temp roles dir for refine to use *)
  let src_role_designer = "/home/xertrov/src/c2c/.c2c/roles/role-designer.md" in
  let dst_role_designer = Filename.concat roles_subdir "role-designer.md" in
  ignore (Sys.command (Printf.sprintf "cp %s %s"
    (Filename.quote src_role_designer) (Filename.quote dst_role_designer)));
  (* write a test role *)
  let test_role_path = Filename.concat roles_subdir "test-ephemeral.md" in
  let oc = open_out test_role_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "---\n\
      description: A test ephemeral role for unit testing.\n\
      role: ephemeral\n\
      model: anthropic:claude-sonnet-4-6\n\
      ---\n\
      \n\
      You are a test agent.\n");
  (* run dry-run and capture output *)
  let (out, _) = capture_refine_dryrun "test-ephemeral" in
  (* verify dry-run banner *)
  check bool "contains dry-run banner" true
    (contains ~sub:"c2c agent run [dry-run]:" out);
  (* verify role-designer is the spawned role *)
  check bool "contains role=role-designer" true
    (contains ~sub:"role=role-designer" out);
  (* verify kickoff prompt section *)
  check bool "contains kickoff prompt header" true
    (contains ~sub:"--- kickoff prompt ---" out);
  check bool "contains end prompt marker" true
    (contains ~sub:"--- end prompt ---" out);
  (* verify the role file path appears in the prompt *)
  check bool "contains role file path" true
    (contains ~sub:"test-ephemeral.md" out);
  (* verify the role body appears in the prompt *)
  check bool "contains role body" true
    (contains ~sub:"You are a test agent" out);
  (* verify client=claude appears in output *)
  check bool "contains client=claude" true
    (contains ~sub:"client=claude" out)

let test_refine_dry_run_role_not_found () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  (* create .c2c dir but no roles subdir — role file should not exist *)
  let roles_dir = Filename.concat dir ".c2c" in
  Unix.mkdir roles_dir 0o755;
  let stdout_read, stdout_write = Unix.pipe () in
  let stderr_read, stderr_write = Unix.pipe () in
  let base_env = Unix.environment () in
  let extra_env = [| "C2C_KEY_DIR=/tmp/c2c-agent-refine-test-keys" |] in
  let env = Array.append base_env extra_env in
  match Unix.fork () with
  | 0 ->
      Unix.close stdout_read; Unix.close stderr_read;
      Unix.dup2 stdout_write Unix.stdout;
      Unix.dup2 stderr_write Unix.stderr;
      Unix.close stdout_write; Unix.close stderr_write;
      Unix.execve c2c_path
        [| c2c_path; "agent"; "refine"; "nonexistent-role"; "--dry-run" |]
        env
  | child ->
      Unix.close stdout_write; Unix.close stderr_write;
      let buf = Buffer.create 256 in
      let ch = Unix.in_channel_of_descr stdout_read in
      let rec read_loop () =
        match input_char ch with
        | exception End_of_file -> ()
        | c -> Buffer.add_char buf c; read_loop ()
      in
      read_loop ();
      close_in ch;
      let err_buf = Buffer.create 256 in
      let err_ch = Unix.in_channel_of_descr stderr_read in
      let rec read_err () =
        match input_char err_ch with
        | exception End_of_file -> ()
        | c -> Buffer.add_char err_buf c; read_err ()
      in
      read_err ();
      close_in err_ch;
      let rec wait_eintr () =
        try Unix.waitpid [] child
        with Unix.Unix_error (Unix.EINTR, _, _) -> wait_eintr ()
      in
      let (_, status) = wait_eintr () in
      let stderr_out = Buffer.contents err_buf in
      check bool "fails with role not found" true
        (contains ~sub:"role file not found" stderr_out);
      match status with
      | Unix.WEXITED n -> check int "exits 1" 1 n
      | _ -> check bool "exits 1" false true

let test_refine_dry_run_bin_flag () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  (* create .c2c/roles/ directory and a test role file *)
  let roles_dir = Filename.concat dir ".c2c" in
  Unix.mkdir roles_dir 0o755;
  let roles_subdir = Filename.concat roles_dir "roles" in
  Unix.mkdir roles_subdir 0o755;
  let src_role_designer = "/home/xertrov/src/c2c/.c2c/roles/role-designer.md" in
  let dst_role_designer = Filename.concat roles_subdir "role-designer.md" in
  ignore (Sys.command (Printf.sprintf "cp %s %s"
    (Filename.quote src_role_designer) (Filename.quote dst_role_designer)));
  let test_role_path = Filename.concat roles_subdir "test-ephemeral.md" in
  let oc = open_out test_role_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "---\n\
      description: A test ephemeral role for unit testing.\n\
      role: ephemeral\n\
      model: anthropic:claude-sonnet-4-6\n\
      ---\n\
      \n\
      You are a test agent.\n");
  let (out, _) = capture_refine_dryrun ~extra_args:["--bin"; "cc-test"] "test-ephemeral" in
  check bool "contains bin=cc-test" true
    (contains ~sub:"bin=cc-test" out)

let test_refine_dry_run_timeout_flag () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  (* create .c2c/roles/ directory and a test role file *)
  let roles_dir = Filename.concat dir ".c2c" in
  Unix.mkdir roles_dir 0o755;
  let roles_subdir = Filename.concat roles_dir "roles" in
  Unix.mkdir roles_subdir 0o755;
  let src_role_designer = "/home/xertrov/src/c2c/.c2c/roles/role-designer.md" in
  let dst_role_designer = Filename.concat roles_subdir "role-designer.md" in
  ignore (Sys.command (Printf.sprintf "cp %s %s"
    (Filename.quote src_role_designer) (Filename.quote dst_role_designer)));
  let test_role_path = Filename.concat roles_subdir "test-ephemeral.md" in
  let oc = open_out test_role_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "---\n\
      description: A test ephemeral role for unit testing.\n\
      role: ephemeral\n\
      model: anthropic:claude-sonnet-4-6\n\
      ---\n\
      \n\
      You are a test agent.\n");
  let (out, _) = capture_refine_dryrun ~extra_args:["--timeout"; "600"] "test-ephemeral" in
  check bool "contains timeout=600s" true
    (contains ~sub:"timeout=600s" out)

let test_refine_dry_run_pane_flag () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  (* create .c2c/roles/ directory and a test role file *)
  let roles_dir = Filename.concat dir ".c2c" in
  Unix.mkdir roles_dir 0o755;
  let roles_subdir = Filename.concat roles_dir "roles" in
  Unix.mkdir roles_subdir 0o755;
  let src_role_designer = "/home/xertrov/src/c2c/.c2c/roles/role-designer.md" in
  let dst_role_designer = Filename.concat roles_subdir "role-designer.md" in
  ignore (Sys.command (Printf.sprintf "cp %s %s"
    (Filename.quote src_role_designer) (Filename.quote dst_role_designer)));
  let test_role_path = Filename.concat roles_subdir "test-ephemeral.md" in
  let oc = open_out test_role_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "---\n\
      description: A test ephemeral role for unit testing.\n\
      role: ephemeral\n\
      model: anthropic:claude-sonnet-4-6\n\
      ---\n\
      \n\
      You are a test agent.\n");
  let (out, _) = capture_refine_dryrun ~extra_args:["--pane"] "test-ephemeral" in
  check bool "contains pane=true" true
    (contains ~sub:"pane=true" out)

let () =
  Random.self_init ();
  Alcotest.run "agent_refine"
    [ ( "dry_run",
        [ ( "composes_correct_kickoff_prompt",
            `Quick, test_refine_dry_run_composes_correct_prompt )
        ; ( "role_not_found_error",
            `Quick, test_refine_dry_run_role_not_found )
        ; ( "bin_flag",
            `Quick, test_refine_dry_run_bin_flag )
        ; ( "timeout_flag",
            `Quick, test_refine_dry_run_timeout_flag )
        ; ( "pane_flag",
            `Quick, test_refine_dry_run_pane_flag )
        ] )
    ]
