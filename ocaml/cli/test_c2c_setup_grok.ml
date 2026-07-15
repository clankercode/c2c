(* test_c2c_setup_grok — CLI-first Grok install: skill + hooks, no MCP. *)

open Alcotest

let ( // ) = Filename.concat

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec at i =
      i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1))
    in
    at 0

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
  let dir = base // Printf.sprintf "c2c-setup-grok-%08x" (Random.bits ()) in
  Unix.mkdir dir 0o700;
  let prev_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" dir;
  Fun.protect
    ~finally:(fun () ->
      (match prev_home with Some h -> Unix.putenv "HOME" h | None -> ());
      try remove_tree dir with _ -> ())
    (fun () -> f dir)

let run_setup ~alias =
  C2c_setup.setup_grok ~output_mode:C2c_types.Json ~dry_run:false
    ~root:"/fake/broker/root" ~alias_val:alias ~alias_from_auto_gen:false

let test_install_writes_skill_and_hooks_no_mcp () =
  with_temp_home (fun home ->
    let result = run_setup ~alias:"grok-fixture-aa" in
    let skill = home // ".grok" // "skills" // "c2c" // "SKILL.md" in
    let hooks = home // ".grok" // "hooks" // "c2c-session.json" in
    check bool "skill exists" true (Sys.file_exists skill);
    check bool "hooks exist" true (Sys.file_exists hooks);
    check bool "skill is assembled grok blob" true
      (read_file skill = C2c_grok_skill_embedded.content);
    check bool "CLI-first skill explains explicit relay registration" true
      (contains ~haystack:(read_file skill) ~needle:"--register-relay-alias");
    let hooks_body = read_file hooks in
    check bool "SessionStart hook" true
      (contains ~haystack:hooks_body ~needle:"SessionStart");
    check bool "SessionEnd hook" true
      (contains ~haystack:hooks_body ~needle:"SessionEnd");
    check bool "hook command is c2c hook grok" true
      (contains ~haystack:hooks_body ~needle:"hook grok");
    (* No MCP config.toml / .mcp.json written under ~/.grok for install. *)
    check bool "no ~/.grok/config.toml from install" false
      (Sys.file_exists (home // ".grok" // "config.toml"));
    check bool "skill owned-file artifact" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "owned-file" && a.path = skill)
         result.C2c_setup.artifacts);
    check bool "hooks owned-file artifact" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "owned-file" && a.path = hooks)
         result.C2c_setup.artifacts);
    check bool "client_configured reports true" true
      (C2c_setup.client_configured "grok"))

let test_refresh_grok_skill_if_stale () =
  with_temp_home (fun home ->
    let skill = home // ".grok" // "skills" // "c2c" // "SKILL.md" in
    C2c_setup.refresh_grok_skill_if_stale ();
    check bool "created when missing" true (Sys.file_exists skill);
    check bool "embedded content" true
      (read_file skill = C2c_grok_skill_embedded.content);
    write_file skill "stale\n";
    C2c_setup.refresh_grok_skill_if_stale ();
    check bool "drifted refreshed" true
      (read_file skill = C2c_grok_skill_embedded.content))

let test_session_identity_skill_write_remove () =
  with_temp_home (fun home ->
    C2c_setup.write_grok_session_identity_skill ~alias:"grok-test-xx"
      ~session_id:"019f4fb9-3c7a-7720-96c2-5cacb719d951";
    let path = home // ".grok" // "skills" // "c2c-session" // "SKILL.md" in
    check bool "identity skill exists" true (Sys.file_exists path);
    let body = read_file path in
    check bool "alias in body" true
      (contains ~haystack:body ~needle:"grok-test-xx");
    check bool "session id in body" true
      (contains ~haystack:body ~needle:"019f4fb9-3c7a-7720-96c2-5cacb719d951");
    C2c_setup.remove_grok_session_identity_skill ();
    check bool "identity skill removed" false (Sys.file_exists path))

let () =
  Random.self_init ();
  run "c2c_setup_grok"
    [ ( "setup_grok"
      , [ test_case "writes skill+hooks, no mcp" `Quick
            test_install_writes_skill_and_hooks_no_mcp
        ; test_case "refresh_grok_skill_if_stale" `Quick
            test_refresh_grok_skill_if_stale
        ; test_case "session identity skill write/remove" `Quick
            test_session_identity_skill_write_remove
        ] )
    ]
