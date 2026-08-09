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

let test_session_identity_skill_write_only_on_drift () =
  with_temp_home (fun home ->
    (* #22: the identity skill is identity-agnostic — it must NOT embed any
       concrete alias/session_id, and must point the agent at `c2c whoami`. *)
    C2c_setup.write_grok_session_identity_skill ();
    let path = home // ".grok" // "skills" // "c2c-session" // "SKILL.md" in
    check bool "identity skill exists" true (Sys.file_exists path);
    let body = read_file path in
    check bool "points at c2c whoami" true
      (contains ~haystack:body ~needle:"c2c whoami");
    check bool "no concrete alias embedded" false
      (contains ~haystack:body ~needle:"grok-test-xx");
    check bool "no concrete session id embedded" false
      (contains ~haystack:body ~needle:"019f4fb9-3c7a-7720-96c2-5cacb719d951");
    (* Two writes produce byte-identical content (clobber is a no-op). *)
    let ino_after_first = (Unix.stat path).st_ino in
    C2c_setup.write_grok_session_identity_skill ();
    check string "byte-stable across writes" body (read_file path);
    (* #82: unchanged content must not rewrite the file at all. write_c2c_skill
       is tmp+rename, so a real write always lands a NEW inode — an unchanged
       inode is proof no write happened, at a resolution mtime cannot give us.
       This is the whole fix: Grok re-announces its ~59 KB skill catalogue to
       every live session whenever the skill set it discovers changes. *)
    check bool "unchanged content does not rewrite the file" true
      (ino_after_first = (Unix.stat path).st_ino);
    (* ...but genuine drift still self-heals (an old/corrupt body is replaced). *)
    write_file path "stale body from an older c2c\n";
    C2c_setup.write_grok_session_identity_skill ();
    check string "drifted content is rewritten" body (read_file path);
    check bool "rewrite landed a new inode" true
      (ino_after_first <> (Unix.stat path).st_ino))

let () =
  Random.self_init ();
  run "c2c_setup_grok"
    [ ( "setup_grok"
      , [ test_case "writes skill+hooks, no mcp" `Quick
            test_install_writes_skill_and_hooks_no_mcp
        ; test_case "refresh_grok_skill_if_stale" `Quick
            test_refresh_grok_skill_if_stale
        ; test_case "session identity skill writes only on drift (#82)" `Quick
            test_session_identity_skill_write_only_on_drift
        ] )
    ]
