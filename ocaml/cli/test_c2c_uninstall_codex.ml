(* test_c2c_uninstall_codex — the manifest-less recompute fallback for
   `c2c uninstall codex` must cover everything setup_codex writes as shared
   state: the [mcp_servers.c2c] TOML section, the config.toml hooks block,
   and the AGENTS.md orientation block — plus the owned skill file and the
   legacy deliver-watch scripts (no longer written by install, but kept in
   the fallback so older installs still get cleaned; removal is a no-op on
   absent files). *)

open Alcotest

let ( // ) = Filename.concat

let with_temp_home f =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-uninstall-codex-%08x" (Random.bits ()) in
  Unix.mkdir dir 0o700;
  let prev_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" dir;
  Fun.protect
    ~finally:(fun () ->
      (match prev_home with Some h -> Unix.putenv "HOME" h | None -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () -> f dir)

let test_recompute_codex_covers_shared_blocks () =
  with_temp_home (fun home ->
    let shared, owned, settings = C2c_uninstall.recompute_codex_artifacts () in
    let config = home // ".codex" // "config.toml" in
    let agents_md = home // ".codex" // "AGENTS.md" in
    check bool "settings path is None" true (settings = None);
    (* Shared: TOML section + both marker blocks. *)
    check bool "mcp_servers.c2c toml section" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "shared-toml-section"
            && a.path = config
            && a.section_prefix = Some "mcp_servers.c2c")
         shared);
    check bool "config.toml hooks shared-block" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "shared-block"
            && a.path = config
            && a.begin_marker = Some C2c_codex_hooks.config_begin_marker
            && a.end_marker = Some C2c_codex_hooks.config_end_marker)
         shared);
    check bool "AGENTS.md shared-block" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "shared-block"
            && a.path = agents_md
            && a.begin_marker = Some C2c_codex_hooks.agents_md_begin_marker
            && a.end_marker = Some C2c_codex_hooks.agents_md_end_marker)
         shared);
    (* Owned: the embedded skill + legacy deliver-watch script paths. *)
    let owned_path p =
      List.exists
        (fun (a : C2c_install_manifest.artifact) ->
           a.kind = "owned-file" && a.path = p)
        owned
    in
    check bool "skill owned file" true
      (owned_path (home // ".codex" // "skills" // "c2c" // "SKILL.md"));
    let client_dir = home // ".c2c" // "clients" // "codex" in
    check bool "legacy deliver-watch.sh still in fallback" true
      (owned_path (client_dir // "deliver-watch.sh"));
    check bool "legacy pre-deliver.sh still in fallback" true
      (owned_path (client_dir // "start-hooks" // "pre-deliver.sh")))

let () =
  Random.self_init ();
  run "c2c_uninstall_codex"
    [ ( "recompute-codex"
      , [ test_case "recompute covers shared blocks + owned files" `Quick
            test_recompute_codex_covers_shared_blocks
        ] )
    ]
