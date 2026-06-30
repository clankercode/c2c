(* Tests for B033: the Claude skill is embedded in the c2c binary.

   - Sync gate: the committed embedded blob must equal the canonical markdown
     source in data/claude-skill/SKILL.md byte-for-byte.
   - Binary-only install: `c2c install claude` writes the embedded skill when
     the repo data/ file is not present. *)

open Alcotest

let ( // ) = Filename.concat

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    let n = in_channel_length ic in
    really_input_string ic n)

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc contents)

let rec find_repo_root cwd =
  let candidate = cwd // "data" // "claude-skill" // "SKILL.md" in
  if Sys.file_exists candidate then cwd
  else
    let parent = Filename.dirname cwd in
    if parent = cwd then failwith "cannot find repo root (data/claude-skill/SKILL.md missing)"
    else find_repo_root parent

let repo_root () = find_repo_root (Sys.getcwd ())

let c2c_exe_path () =
  let cwd = Sys.getcwd () in
  let local = cwd // "c2c.exe" in
  if Sys.file_exists local then local
  else (repo_root ()) // "_build" // "default" // "ocaml" // "cli" // "c2c.exe"

let with_tmp_dir f =
  let dir = Filename.temp_file "c2c-skill-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () ->
    let rec rm p =
      try
        let st = Unix.lstat p in
        match st.Unix.st_kind with
        | Unix.S_DIR ->
            Array.iter (fun e -> rm (p // e)) (Sys.readdir p);
            Unix.rmdir p
        | _ -> Unix.unlink p
      with Unix.Unix_error _ -> ()
    in
    rm dir)
    (fun () -> f dir)

let with_cwd dir f =
  let old_cwd = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir old_cwd) f

let current_path () =
  match Sys.getenv_opt "PATH" with
  | None -> ""
  | Some p -> p

let with_install_env ~home ~bin_dir f =
  let old_path = current_path () in
  let old_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  Unix.putenv "PATH" (bin_dir ^ ":" ^ old_path);
  (* Clear CLAUDE_CONFIG_DIR so resolve_claude_dir uses HOME *)
  let old_claude_dir = Sys.getenv_opt "CLAUDE_CONFIG_DIR" in
  Unix.putenv "CLAUDE_CONFIG_DIR" "";
  Fun.protect ~finally:(fun () ->
    (match old_home with
     | Some home -> Unix.putenv "HOME" home
     | None -> Unix.putenv "HOME" "");
    Unix.putenv "PATH" old_path;
    (match old_claude_dir with
     | Some d -> Unix.putenv "CLAUDE_CONFIG_DIR" d
     | None -> Unix.putenv "CLAUDE_CONFIG_DIR" ""))
    f

let install_claude_cmd ~exe ~broker_root ~alias =
  Printf.sprintf
    "%s install claude --global --broker-root %s --alias %s --json"
    (Filename.quote exe)
    (Filename.quote broker_root)
    (Filename.quote alias)

(* B033 follow-up: `c2c init --client claude` on the DEFAULT CLI-only path
   (--with-mcp/--hooks off) must still write the /c2c skill. *)
let init_claude_cli_only_cmd ~exe ~broker_root ~session_id =
  Printf.sprintf
    "C2C_MCP_BROKER_ROOT=%s C2C_MCP_SESSION_ID=%s %s init --client claude --no-nonce --json"
    (Filename.quote broker_root)
    (Filename.quote session_id)
    (Filename.quote exe)

let test_sync_gate_embedded_equals_data_file () =
  let data_path = (repo_root ()) // "data" // "claude-skill" // "SKILL.md" in
  let data_content = read_file data_path in
  check string "embedded content equals data/claude-skill/SKILL.md"
    data_content C2c_claude_skill_embedded.content

let test_sync_gate_fails_when_embedded_is_stale () =
  let stale = C2c_claude_skill_embedded.content ^ "\n/* stale mutation */\n" in
  let data_path = (repo_root ()) // "data" // "claude-skill" // "SKILL.md" in
  let data_content = read_file data_path in
  check bool "stale embedded fails the sync gate" false
    (String.equal data_content stale)

let test_install_claude_writes_skill () =
  with_tmp_dir (fun home ->
    with_tmp_dir (fun target ->
      with_tmp_dir (fun invocation_cwd ->
        let bin_dir = home // "bin" in
        Unix.mkdir bin_dir 0o700;
        (* Provide a dummy c2c-mcp-server so resolve_mcp_server_paths succeeds *)
        let dummy_server = bin_dir // "c2c-mcp-server" in
        write_file dummy_server "#!/bin/sh\nexit 0\n";
        Unix.chmod dummy_server 0o755;
        let exe = c2c_exe_path () in
        with_install_env ~home ~bin_dir (fun () ->
          with_cwd invocation_cwd (fun () ->
            let broker_root = target // "broker" in
            let cmd = install_claude_cmd ~exe ~broker_root ~alias:"test-skill" in
            let rc = Sys.command cmd in
            check int "c2c install claude exits 0" 0 rc;
            let skill_path = home // ".claude" // "skills" // "c2c" // "SKILL.md" in
            check bool "skill file was written" true (Sys.file_exists skill_path);
            let installed = read_file skill_path in
            check string "installed skill equals embedded content"
              C2c_claude_skill_embedded.content installed)))))

let test_install_claude_skill_is_idempotent () =
  with_tmp_dir (fun home ->
    with_tmp_dir (fun target ->
      with_tmp_dir (fun invocation_cwd ->
        let bin_dir = home // "bin" in
        Unix.mkdir bin_dir 0o700;
        let dummy_server = bin_dir // "c2c-mcp-server" in
        write_file dummy_server "#!/bin/sh\nexit 0\n";
        Unix.chmod dummy_server 0o755;
        let exe = c2c_exe_path () in
        with_install_env ~home ~bin_dir (fun () ->
          with_cwd invocation_cwd (fun () ->
            let broker_root = target // "broker" in
            let cmd = install_claude_cmd ~exe ~broker_root ~alias:"test-idem" in
            (* First install *)
            let rc1 = Sys.command cmd in
            check int "first install exits 0" 0 rc1;
            let skill_path = home // ".claude" // "skills" // "c2c" // "SKILL.md" in
            let first_content = read_file skill_path in
            (* Second install (idempotent) *)
            let rc2 = Sys.command cmd in
            check int "second install exits 0" 0 rc2;
            let second_content = read_file skill_path in
            check string "skill content unchanged after re-install"
              first_content second_content)))))

let test_init_claude_cli_only_writes_skill () =
  with_tmp_dir (fun home ->
    with_tmp_dir (fun target ->
      with_tmp_dir (fun invocation_cwd ->
        let bin_dir = home // "bin" in
        Unix.mkdir bin_dir 0o700;
        (* dummy c2c-mcp-server so resolve_mcp_server_paths would succeed if reached *)
        let dummy_server = bin_dir // "c2c-mcp-server" in
        write_file dummy_server "#!/bin/sh\nexit 0\n";
        Unix.chmod dummy_server 0o755;
        let exe = c2c_exe_path () in
        with_install_env ~home ~bin_dir (fun () ->
          with_cwd invocation_cwd (fun () ->
            let broker_root = target // "broker" in
            let cmd = init_claude_cli_only_cmd ~exe ~broker_root ~session_id:"skill-cli-only-test" in
            let rc = Sys.command cmd in
            check int "c2c init --client claude (CLI-only) exits 0" 0 rc;
            let skill_path = home // ".claude" // "skills" // "c2c" // "SKILL.md" in
            check bool "skill file was written on CLI-only init" true (Sys.file_exists skill_path);
            let installed = read_file skill_path in
            check string "installed skill equals embedded content"
              C2c_claude_skill_embedded.content installed)))))

let test_skill_leads_with_cli_not_mcp () =
  (* Verify the skill content starts with CLI commands, not MCP tools *)
  let content = C2c_claude_skill_embedded.content in
  let has_cli_send =
    let needle = "c2c send" in
    let hay_len = String.length content in
    let needle_len = String.length needle in
    let rec loop i =
      i + needle_len <= hay_len
      && (String.sub content i needle_len = needle || loop (i + 1))
    in
    loop 0
  in
  let has_monitor =
    let needle = "c2c monitor" in
    let hay_len = String.length content in
    let needle_len = String.length needle in
    let rec loop i =
      i + needle_len <= hay_len
      && (String.sub content i needle_len = needle || loop (i + 1))
    in
    loop 0
  in
  check bool "skill mentions c2c send (CLI)" true has_cli_send;
  check bool "skill mentions c2c monitor" true has_monitor;
  (* Verify no mcp__ prefix appears in the first 500 chars (CLI-first) *)
  let first_500 = String.sub content 0 (min 500 (String.length content)) in
  let has_mcp_prefix =
    let needle = "mcp__" in
    let hay_len = String.length first_500 in
    let needle_len = String.length needle in
    let rec loop i =
      i + needle_len <= hay_len
      && (String.sub first_500 i needle_len = needle || loop (i + 1))
    in
    loop 0
  in
  check bool "skill does NOT lead with mcp__ prefix" false has_mcp_prefix

let () =
  run "c2c_claude_skill_embedded"
    [ ( "sync_gate",
        [ test_case "embedded_equals_data_file" `Quick test_sync_gate_embedded_equals_data_file
        ; test_case "stale_embedded_would_fail" `Quick test_sync_gate_fails_when_embedded_is_stale
        ] )
    ; ( "install_writes_skill",
        [ test_case "install_claude_writes_skill" `Quick test_install_claude_writes_skill
        ; test_case "install_claude_skill_is_idempotent" `Quick test_install_claude_skill_is_idempotent
        ; test_case "init_claude_cli_only_writes_skill" `Quick test_init_claude_cli_only_writes_skill
        ] )
    ; ( "content_quality",
        [ test_case "skill_leads_with_cli_not_mcp" `Quick test_skill_leads_with_cli_not_mcp
        ] )
    ]
