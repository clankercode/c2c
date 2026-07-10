(* test_c2c_setup_codex — setup_codex writes the hooks block + AGENTS.md
   idempotently into a temp HOME (#5 vanilla-codex slice). *)

open Alcotest

let ( // ) = Filename.concat

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec at i = i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1)) in
    at 0

let count_occurrences ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then 0
  else begin
    let count = ref 0 in
    let i = ref 0 in
    while !i + nl <= hl do
      if String.sub haystack !i nl = needle then begin incr count; i := !i + nl end
      else incr i
    done;
    !count
  end

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic))

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let with_temp_home f =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-setup-codex-%08x" (Random.bits ()) in
  Unix.mkdir dir 0o700;
  let prev_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" dir;
  Fun.protect
    ~finally:(fun () ->
      (match prev_home with Some h -> Unix.putenv "HOME" h | None -> ());
      try remove_tree dir with _ -> ())
    (fun () -> f dir)

let run_setup () =
  C2c_setup.setup_codex ~output_mode:C2c_types.Human ~dry_run:false
    ~root:"/fake/broker/root" ~alias_val:"codex-fixture-zz"
    ~server_path:"/fake/bin/c2c_mcp_server.exe" ~mcp_command:"c2c-mcp-server"
    ~client:"codex" ~alias_from_auto_gen:false

let test_fresh_install_writes_hooks_and_agents_md () =
  with_temp_home (fun home ->
    let result = run_setup () in
    let config = read_file (home // ".codex" // "config.toml") in
    check int "one hooks block" 1
      (count_occurrences ~haystack:config
         ~needle:C2c_codex_hooks.config_begin_marker);
    List.iter
      (fun needle ->
        check bool needle true (contains ~haystack:config ~needle))
      [ "[[hooks.UserPromptSubmit]]"
      ; "[[hooks.PostToolUse]]"
      ; "[[hooks.SessionStart]]"
      ; "[[hooks.SessionEnd]]"
      ; "command = \"c2c hook codex\""
      ; Printf.sprintf "[hooks.state.\"%s:user_prompt_submit:0:0\"]"
          (home // ".codex" // "config.toml")
      ; "trusted_hash = \"sha256:"
      ; "[mcp_servers.c2c]"
      ; "C2C_MCP_AUTO_REGISTER_ALIAS = \"codex-fixture-zz\""
      ];
    let agents_md = read_file (home // ".codex" // "AGENTS.md") in
    check int "one AGENTS.md block" 1
      (count_occurrences ~haystack:agents_md
         ~needle:C2c_codex_hooks.agents_md_begin_marker);
    check bool "AGENTS.md mentions wait-inbox" true
      (contains ~haystack:agents_md ~needle:"c2c wait-inbox");
    (* Manifest artifacts must cover both shared blocks so uninstall strips
       them. *)
    let block_artifacts =
      List.filter
        (fun (a : C2c_install_manifest.artifact) -> a.kind = "shared-block")
        result.C2c_setup.artifacts
    in
    check int "two shared-block artifacts" 2 (List.length block_artifacts);
    check bool "config.toml block artifact" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.path = home // ".codex" // "config.toml"
            && a.begin_marker = Some C2c_codex_hooks.config_begin_marker)
         block_artifacts);
    check bool "AGENTS.md block artifact" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.path = home // ".codex" // "AGENTS.md"
            && a.begin_marker = Some C2c_codex_hooks.agents_md_begin_marker)
         block_artifacts))

let test_reinstall_is_idempotent () =
  with_temp_home (fun home ->
    ignore (run_setup ());
    let first = read_file (home // ".codex" // "config.toml") in
    ignore (run_setup ());
    let second = read_file (home // ".codex" // "config.toml") in
    check int "one hooks block after reinstall" 1
      (count_occurrences ~haystack:second
         ~needle:C2c_codex_hooks.config_begin_marker);
    check int "one c2c hook command per event (4 total)" 4
      (count_occurrences ~haystack:second ~needle:"command = \"c2c hook codex\"");
    check int "hooks block count stable"
      (count_occurrences ~haystack:first ~needle:"trusted_hash")
      (count_occurrences ~haystack:second ~needle:"trusted_hash");
    let agents_md = read_file (home // ".codex" // "AGENTS.md") in
    check int "one AGENTS.md block after reinstall" 1
      (count_occurrences ~haystack:agents_md
         ~needle:C2c_codex_hooks.agents_md_begin_marker))

let test_preserves_user_hooks_and_offsets_indices () =
  with_temp_home (fun home ->
    let codex_dir = home // ".codex" in
    Unix.mkdir codex_dir 0o700;
    let config_path = codex_dir // "config.toml" in
    write_file config_path
      "model = \"gpt-5.5\"\n\n[[hooks.PostToolUse]]\n[[hooks.PostToolUse.hooks]]\n\
       type = \"command\"\ncommand = \"/usr/bin/my-own-hook\"\ntimeout = 5\n\n\
       [hooks.state.\"/x:post_tool_use:0:0\"]\ntrusted_hash = \"sha256:abc\"\n";
    ignore (run_setup ());
    let config = read_file config_path in
    check bool "user hook preserved" true
      (contains ~haystack:config ~needle:"/usr/bin/my-own-hook");
    check bool "user state preserved" true
      (contains ~haystack:config ~needle:"sha256:abc");
    check bool "user top-level key preserved" true
      (contains ~haystack:config ~needle:"model = \"gpt-5.5\"");
    (* c2c PostToolUse group comes after the user's -> trust key index 1. *)
    check bool "c2c post_tool_use trust key offset to 1" true
      (contains ~haystack:config
         ~needle:(Printf.sprintf "[hooks.state.\"%s:post_tool_use:1:0\"]" config_path));
    ignore (run_setup ());
    let again = read_file config_path in
    check bool "offset stable across reinstall" true
      (contains ~haystack:again
         ~needle:(Printf.sprintf "[hooks.state.\"%s:post_tool_use:1:0\"]" config_path));
    check int "still one managed block" 1
      (count_occurrences ~haystack:again
         ~needle:C2c_codex_hooks.config_begin_marker))

(* c2c install codex writes the embedded /c2c skill to
   ~/.codex/skills/c2c/SKILL.md and reports it as an owned manifest artifact
   so `c2c uninstall codex` removes it. *)
let test_install_writes_codex_skill () =
  with_temp_home (fun home ->
    let result = run_setup () in
    let skill_path = home // ".codex" // "skills" // "c2c" // "SKILL.md" in
    check bool "skill file exists" true (Sys.file_exists skill_path);
    check bool "skill content is the embedded blob" true
      (read_file skill_path = C2c_claude_skill_embedded.content);
    check bool "skill owned-file artifact present" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "owned-file" && a.path = skill_path)
         result.C2c_setup.artifacts))

(* refresh_codex_skill_if_stale: creates when missing, rewrites when drifted,
   leaves an up-to-date file alone (mtime unchanged). *)
let test_refresh_codex_skill_if_stale () =
  with_temp_home (fun home ->
    let skill_path = home // ".codex" // "skills" // "c2c" // "SKILL.md" in
    (* missing -> created *)
    C2c_setup.refresh_codex_skill_if_stale ();
    check bool "created when missing" true (Sys.file_exists skill_path);
    check bool "created with embedded content" true
      (read_file skill_path = C2c_claude_skill_embedded.content);
    (* drifted -> rewritten *)
    write_file skill_path "stale old skill\n";
    C2c_setup.refresh_codex_skill_if_stale ();
    check bool "drifted content refreshed" true
      (read_file skill_path = C2c_claude_skill_embedded.content);
    (* fresh -> untouched (no rewrite when content already matches) *)
    let mtime_before = (Unix.stat skill_path).Unix.st_mtime in
    Unix.sleepf 0.05;
    C2c_setup.refresh_codex_skill_if_stale ();
    let mtime_after = (Unix.stat skill_path).Unix.st_mtime in
    check bool "up-to-date skill not rewritten" true
      (mtime_before = mtime_after))

(* The core library duplicates the hooks-block BEGIN marker (for
   C2c_start.codex_hooks_installed / delivery_mode) because it cannot depend
   on the cli library. Guard the two constants against drift. *)
let test_hooks_marker_in_sync_with_core_lib () =
  check string "config begin marker in sync"
    C2c_codex_hooks.config_begin_marker
    C2c_start.codex_hooks_config_begin_marker

(* Codex delivery is via config.toml hooks — install must NOT write the
   deliver-watch supervisor scripts anymore, and must remove stale ones left
   by an older install (the uninstall recompute fallback still covers them
   for manifest-less uninstalls). *)
let test_install_removes_stale_deliver_watch_scripts () =
  with_temp_home (fun home ->
    let client_dir = home // ".c2c" // "clients" // "codex" in
    let hook_dir = client_dir // "start-hooks" in
    let rec mkdir_p d =
      if not (Sys.file_exists d) then begin
        mkdir_p (Filename.dirname d);
        Unix.mkdir d 0o700
      end
    in
    mkdir_p hook_dir;
    let supervisor = client_dir // "deliver-watch.sh" in
    let pre_deliver = hook_dir // "pre-deliver.sh" in
    write_file supervisor "#!/bin/bash\n# stale supervisor\n";
    write_file pre_deliver "#!/bin/bash\n# stale hook\n";
    let result = run_setup () in
    check bool "stale deliver-watch.sh removed" false (Sys.file_exists supervisor);
    check bool "stale pre-deliver.sh removed" false (Sys.file_exists pre_deliver);
    check bool "no deliver-watch owned-file artifacts" false
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "owned-file"
            && (Filename.basename a.path = "deliver-watch.sh"
                || Filename.basename a.path = "pre-deliver.sh"))
         result.C2c_setup.artifacts))

let test_preserves_user_agents_md () =
  with_temp_home (fun home ->
    let codex_dir = home // ".codex" in
    Unix.mkdir codex_dir 0o700;
    write_file (codex_dir // "AGENTS.md") "# Operator notes\n\nBe terse.\n";
    ignore (run_setup ());
    let agents_md = read_file (codex_dir // "AGENTS.md") in
    check bool "user AGENTS.md content preserved" true
      (contains ~haystack:agents_md ~needle:"# Operator notes");
    check int "one c2c block" 1
      (count_occurrences ~haystack:agents_md
         ~needle:C2c_codex_hooks.agents_md_begin_marker))

let () =
  Random.self_init ();
  run "c2c_setup_codex"
    [ ( "setup-codex"
      , [ test_case "fresh install" `Quick test_fresh_install_writes_hooks_and_agents_md
        ; test_case "reinstall idempotent" `Quick test_reinstall_is_idempotent
        ; test_case "user hooks preserved + indices offset" `Quick
            test_preserves_user_hooks_and_offsets_indices
        ; test_case "user AGENTS.md preserved" `Quick test_preserves_user_agents_md
        ; test_case "hooks marker in sync with core lib" `Quick
            test_hooks_marker_in_sync_with_core_lib
        ; test_case "install removes stale deliver-watch scripts" `Quick
            test_install_removes_stale_deliver_watch_scripts
        ; test_case "install writes codex skill" `Quick test_install_writes_codex_skill
        ; test_case "refresh codex skill if stale" `Quick test_refresh_codex_skill_if_stale
        ] )
    ]
