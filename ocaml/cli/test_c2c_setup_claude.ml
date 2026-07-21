(* test_c2c_setup_claude — setup_claude wires the SessionStart/SessionEnd
   session hook (claude-session-hooks slice) idempotently into a temp
   CLAUDE_CONFIG_DIR, `c2c uninstall claude` strips it, and the claude /c2c
   skill auto-refresh works (create / rewrite / no-op). *)

open Alcotest

let ( // ) = Filename.concat

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec at i = i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1)) in
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
  let dir = base // Printf.sprintf "c2c-setup-claude-%08x" (Random.bits ()) in
  Unix.mkdir dir 0o700;
  let claude_dir = dir // "claude-config" in
  Unix.mkdir claude_dir 0o700;
  let prev_home = Sys.getenv_opt "HOME" in
  let prev_claude_dir = Sys.getenv_opt "CLAUDE_CONFIG_DIR" in
  Unix.putenv "HOME" dir;
  Unix.putenv "CLAUDE_CONFIG_DIR" claude_dir;
  Fun.protect
    ~finally:(fun () ->
      (match prev_home with Some h -> Unix.putenv "HOME" h | None -> ());
      (match prev_claude_dir with
       | Some d -> Unix.putenv "CLAUDE_CONFIG_DIR" d
       | None -> Unix.putenv "CLAUDE_CONFIG_DIR" "");
      try remove_tree dir with _ -> ())
    (fun () -> f ~home:dir ~claude_dir)

let run_setup ?(with_mcp=false) ~project_dir () =
  C2c_setup.setup_claude ~with_mcp ~output_mode:C2c_types.Human ~dry_run:false
    ~root:"/fake/broker/root" ~alias_val:"claude-fixture-zz" ~alias_opt:None
    ~server_path:"/fake/bin/c2c_mcp_server.exe" ~mcp_command:"c2c-mcp-server"
    ~force:false ~channel_delivery:false ~global:false
    ~project_dir:(Some project_dir) ~alias_from_auto_gen:false ~skip_hooks:false

(* Count settings.json entries under hooks.<event> whose hooks[] runs [command]. *)
let count_event_entries settings_json ~event ~command =
  match settings_json with
  | `Assoc fields ->
      (match List.assoc_opt "hooks" fields with
       | Some (`Assoc hooks) ->
           (match List.assoc_opt event hooks with
            | Some (`List entries) ->
                List.length
                  (List.filter
                     (fun entry ->
                        match entry with
                        | `Assoc e ->
                            (match List.assoc_opt "hooks" e with
                             | Some (`List hs) ->
                                 List.exists
                                   (fun h ->
                                      match h with
                                      | `Assoc hf ->
                                          List.assoc_opt "command" hf
                                          = Some (`String command)
                                      | _ -> false)
                                   hs
                             | _ -> false)
                        | _ -> false)
                     entries)
            | _ -> 0)
       | _ -> 0)
  | _ -> 0

let test_install_writes_session_hook () =
  with_temp_home (fun ~home ~claude_dir ->
    let project_dir = home // "proj" in
    Unix.mkdir project_dir 0o700;
    let result = run_setup ~project_dir () in
    let script = claude_dir // "hooks" // "c2c-session-hook.sh" in
    check bool "session hook script exists" true (Sys.file_exists script);
    check bool "script is executable" true
      ((Unix.stat script).Unix.st_perm land 0o100 <> 0);
    check bool "script runs c2c hook claude" true
      (contains ~haystack:(read_file script) ~needle:"c2c hook claude");
    let settings = Yojson.Safe.from_file (claude_dir // "settings.json") in
    check int "one SessionStart entry" 1
      (count_event_entries settings ~event:"SessionStart" ~command:script);
    check int "one SessionEnd entry" 1
      (count_event_entries settings ~event:"SessionEnd" ~command:script);
    (* No matcher key on the session-hook entries: SessionStart matchers
       filter by source and omitting the key fires on every source
       (compact included). *)
    let settings_raw = read_file (claude_dir // "settings.json") in
    check bool "settings mention SessionStart" true
      (contains ~haystack:settings_raw ~needle:"SessionStart");
    (* Manifest artifact so uninstall removes the script. *)
    check bool "session hook owned-file artifact present" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "owned-file" && a.path = script)
         result.C2c_setup.artifacts);
    check bool "session_hook_status reported" true
      (List.exists
         (fun (k, v) -> k = "session_hook_status" && v = `String "registered")
         result.C2c_setup.extra_json))

let test_reinstall_is_idempotent () =
  with_temp_home (fun ~home ~claude_dir ->
    let project_dir = home // "proj" in
    Unix.mkdir project_dir 0o700;
    ignore (run_setup ~project_dir ());
    let result2 = run_setup ~project_dir () in
    let script = claude_dir // "hooks" // "c2c-session-hook.sh" in
    let settings = Yojson.Safe.from_file (claude_dir // "settings.json") in
    check int "still one SessionStart entry" 1
      (count_event_entries settings ~event:"SessionStart" ~command:script);
    check int "still one SessionEnd entry" 1
      (count_event_entries settings ~event:"SessionEnd" ~command:script);
    check bool "second install reports already registered" true
      (List.exists
         (fun (k, v) ->
            k = "session_hook_status" && v = `String "already registered")
         result2.C2c_setup.extra_json))

let test_uninstall_strips_session_hooks () =
  with_temp_home (fun ~home ~claude_dir ->
    let project_dir = home // "proj" in
    Unix.mkdir project_dir 0o700;
    ignore (run_setup ~project_dir ());
    let settings_path = claude_dir // "settings.json" in
    let script = claude_dir // "hooks" // "c2c-session-hook.sh" in
    let hook_script = claude_dir // "hooks" // "c2c-inbox-check.sh" in
    let stop_script = claude_dir // "hooks" // "c2c-stop-deliver.sh" in
    (* Add a user-owned SessionStart hook that must survive the strip. *)
    let user_cmd = "/usr/bin/my-own-session-hook" in
    let settings = Yojson.Safe.from_file settings_path in
    let settings =
      match settings with
      | `Assoc fields ->
          let hooks =
            match List.assoc_opt "hooks" fields with
            | Some (`Assoc h) -> h
            | _ -> []
          in
          let entries =
            match List.assoc_opt "SessionStart" hooks with
            | Some (`List es) -> es
            | _ -> []
          in
          let user_entry =
            `Assoc
              [ ( "hooks"
                , `List
                    [ `Assoc
                        [ ("type", `String "command"); ("command", `String user_cmd) ]
                    ] )
              ]
          in
          let hooks =
            List.filter (fun (k, _) -> k <> "SessionStart") hooks
            @ [ ("SessionStart", `List (entries @ [ user_entry ])) ]
          in
          `Assoc
            (List.filter (fun (k, _) -> k <> "hooks") fields
             @ [ ("hooks", `Assoc hooks) ])
      | j -> j
    in
    write_file settings_path (Yojson.Safe.pretty_to_string settings);
    let removed =
      C2c_uninstall.remove_claude_settings_hooks ~dry_run:false settings_path
        [ hook_script; stop_script; script ]
    in
    check bool "settings reported changed" true (removed <> None);
    let after = Yojson.Safe.from_file settings_path in
    check int "SessionStart c2c entry stripped" 0
      (count_event_entries after ~event:"SessionStart" ~command:script);
    check int "SessionEnd c2c entry stripped" 0
      (count_event_entries after ~event:"SessionEnd" ~command:script);
    check int "user SessionStart hook survives" 1
      (count_event_entries after ~event:"SessionStart" ~command:user_cmd);
    (* recompute_claude_artifacts covers the session hook script so
       manifest-less uninstall still removes the owned file. *)
    let _, owned, _ =
      C2c_uninstall.recompute_claude_artifacts ~target_dir:project_dir
    in
    check bool "recompute includes session hook script" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "owned-file" && a.path = script)
         owned))

(* refresh_claude_skill_if_stale: creates when missing, rewrites when drifted,
   leaves an up-to-date file alone (mtime unchanged). *)
let test_refresh_claude_skill_if_stale () =
  with_temp_home (fun ~home:_ ~claude_dir ->
    let skill_path = claude_dir // "skills" // "c2c" // "SKILL.md" in
    (* missing -> created *)
    C2c_setup.refresh_claude_skill_if_stale ();
    check bool "created when missing" true (Sys.file_exists skill_path);
    check bool "created with embedded content" true
      (read_file skill_path = C2c_claude_skill_embedded.content);
    (* drifted -> rewritten *)
    write_file skill_path "stale old skill\n";
    C2c_setup.refresh_claude_skill_if_stale ();
    check bool "drifted content refreshed" true
      (read_file skill_path = C2c_claude_skill_embedded.content);
    (* fresh -> untouched (no rewrite when content already matches) *)
    let mtime_before = (Unix.stat skill_path).Unix.st_mtime in
    Unix.sleepf 0.05;
    C2c_setup.refresh_claude_skill_if_stale ();
    let mtime_after = (Unix.stat skill_path).Unix.st_mtime in
    check bool "up-to-date skill not rewritten" true
      (mtime_before = mtime_after))

(* B254: default install (with_mcp:false) writes NO .mcp.json, but still
   installs hooks + skill. --with-mcp writes .mcp.json. *)
let test_default_install_omits_mcp_json () =
  with_temp_home (fun ~home ~claude_dir ->
    let project_dir = home // "proj" in
    Unix.mkdir project_dir 0o700;
    let result = run_setup ~with_mcp:false ~project_dir () in
    let mcp_json = project_dir // ".mcp.json" in
    check bool ".mcp.json NOT written by default" false (Sys.file_exists mcp_json);
    (* hooks + skill still land *)
    let session_hook = claude_dir // "hooks" // "c2c-session-hook.sh" in
    check bool "session hook script still written" true (Sys.file_exists session_hook);
    let skill = claude_dir // "skills" // "c2c" // "SKILL.md" in
    check bool "skill still written" true (Sys.file_exists skill);
    (* No mcpServers shared-key artifact in the manifest. *)
    check bool "no mcpServers artifact" false
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "shared-key" && a.key = Some "mcpServers.c2c")
         result.C2c_setup.artifacts);
    check bool "extra_json reports mcp=false" true
      (List.exists (fun (k, v) -> k = "mcp" && v = `Bool false)
         result.C2c_setup.extra_json))

let test_with_mcp_writes_mcp_json () =
  with_temp_home (fun ~home ~claude_dir:_ ->
    let project_dir = home // "proj" in
    Unix.mkdir project_dir 0o700;
    let result = run_setup ~with_mcp:true ~project_dir () in
    let mcp_json = project_dir // ".mcp.json" in
    check bool ".mcp.json written with --with-mcp" true (Sys.file_exists mcp_json);
    check bool "mcp.json mentions c2c" true
      (contains ~haystack:(read_file mcp_json) ~needle:"c2c");
    check bool "mcpServers artifact present" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "shared-key" && a.key = Some "mcpServers.c2c")
         result.C2c_setup.artifacts);
    check bool "extra_json reports mcp=true" true
      (List.exists (fun (k, v) -> k = "mcp" && v = `Bool true)
         result.C2c_setup.extra_json))

let () =
  Random.self_init ();
  run "c2c_setup_claude"
    [ ( "setup-claude"
      , [ test_case "install writes session hook + settings entries" `Quick
            test_install_writes_session_hook
        ; test_case "reinstall idempotent" `Quick test_reinstall_is_idempotent
        ; test_case "uninstall strips session hooks" `Quick
            test_uninstall_strips_session_hooks
        ; test_case "refresh claude skill if stale" `Quick
            test_refresh_claude_skill_if_stale
        ; test_case "B254 default install omits .mcp.json" `Quick
            test_default_install_omits_mcp_json
        ; test_case "B254 --with-mcp writes .mcp.json" `Quick
            test_with_mcp_writes_mcp_json
        ] )
    ]
