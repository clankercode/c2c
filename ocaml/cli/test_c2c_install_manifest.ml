(* test_c2c_install_manifest.ml — unit tests for C2c_install_manifest. *)

open Alcotest
open C2c_install_manifest

let ( // ) = Filename.concat

let with_temp_home f =
  let base = Filename.get_temp_dir_name () in
  let home = base // Printf.sprintf "c2c-manifest-test-%08x" (Random.bits ()) in
  (try Unix.mkdir home 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) ->
     ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote home)));
     Unix.mkdir home 0o755);
  let old_home = try Some (Sys.getenv "HOME") with Not_found -> None in
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" (home // ".local" // "state");
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote home)));
      match old_home with
      | Some h -> Unix.putenv "HOME" h
      | None -> ())
    (fun () -> f home)

let expected_manifest_path home =
  home // ".local" // "state" // "c2c" // "install-manifest.json"

let test_manifest_path_uses_xdg_state_home () =
  with_temp_home (fun home ->
    let p = C2c_install_manifest.manifest_path () in
    check string "manifest path under XDG state" (expected_manifest_path home) p)

let test_round_trip () =
  with_temp_home (fun _home ->
    let artifact =
      C2c_install_manifest.shared_key
        ~path:"/tmp/.mcp.json" ~key:"mcpServers.c2c" ~format:"json"
    in
    let record =
      { C2c_install_manifest.component = "claude"
      ; alias = Some "test-alias"
      ; target_dir = "/tmp/project"
      ; c2c_version = "test-1"
      ; ts = 1781280000.0
      ; artifacts = [ artifact ]
      }
    in
    C2c_install_manifest.upsert_record ~record;
    let m = C2c_install_manifest.read_manifest () in
    check int "version is 1" 1 m.version;
    check int "one install record" 1 (List.length m.installs);
    let r = List.hd m.installs in
    check string "component" "claude" r.component;
    check (option string) "alias" (Some "test-alias") r.alias;
    check int "one artifact" 1 (List.length r.artifacts);
    let a = List.hd r.artifacts in
    check string "kind" "shared-key" a.kind;
    check (option string) "key" (Some "mcpServers.c2c") a.key)

let test_reinstall_replaces_record () =
  with_temp_home (fun _home ->
    let base_record component =
      { C2c_install_manifest.component
      ; alias = Some "alias-a"
      ; target_dir = "/tmp/project"
      ; c2c_version = "v1"
      ; ts = 1.0
      ; artifacts = [ C2c_install_manifest.owned_file "/tmp/a" ]
      }
    in
    C2c_install_manifest.upsert_record ~record:(base_record "claude");
    C2c_install_manifest.upsert_record
      ~record:{ (base_record "claude") with
                alias = Some "alias-b"
              ; c2c_version = "v2"
              ; artifacts = [ C2c_install_manifest.owned_file "/tmp/b" ] };
    let m = C2c_install_manifest.read_manifest () in
    check int "still one claude record" 1
      (List.filter (fun r -> r.component = "claude") m.installs |> List.length);
    let r = List.find (fun r -> r.component = "claude") m.installs in
    check string "version updated" "v2" r.c2c_version;
    check int "artifact replaced" 1 (List.length r.artifacts);
    check string "new artifact path" "/tmp/b" (List.hd r.artifacts).path)

let test_remove_record () =
  with_temp_home (fun _home ->
    let record component target =
      { C2c_install_manifest.component
      ; alias = None
      ; target_dir = target
      ; c2c_version = "v1"
      ; ts = 1.0
      ; artifacts = []
      }
    in
    C2c_install_manifest.upsert_record ~record:(record "claude" "/a");
    C2c_install_manifest.upsert_record ~record:(record "codex" "/b");
    C2c_install_manifest.remove_record ~component:"claude" ~target_dir:"/a";
    let m = C2c_install_manifest.read_manifest () in
    check int "one record remains" 1 (List.length m.installs);
    check string "remaining is codex" "codex" (List.hd m.installs).component)

let test_schema_preserved () =
  with_temp_home (fun _home ->
    let block =
      C2c_install_manifest.shared_block
        ~path:"/tmp/k.toml"
        ~begin_marker:"# BEGIN"
        ~end_marker:"# END"
        ~legacy_marker:"# LEGACY" ()
    in
    let section =
      C2c_install_manifest.shared_toml_section
        ~path:"/tmp/c.toml" ~section_prefix:"mcp_servers.c2c"
    in
    let record =
      { C2c_install_manifest.component = "kimi"
      ; alias = None
      ; target_dir = "/tmp"
      ; c2c_version = "v1"
      ; ts = 2.0
      ; artifacts = [ block; section ]
      }
    in
    C2c_install_manifest.upsert_record ~record;
    let m = C2c_install_manifest.read_manifest () in
    let r = List.hd m.installs in
    check int "two artifacts" 2 (List.length r.artifacts);
    let b = List.hd r.artifacts in
    check (option string) "begin marker" (Some "# BEGIN") b.begin_marker;
    check (option string) "legacy marker" (Some "# LEGACY") b.legacy_marker;
    let s = List.nth r.artifacts 1 in
    check (option string) "section prefix" (Some "mcp_servers.c2c") s.section_prefix)

let () =
  run "c2c_install_manifest"
    [ ( "manifest"
      , [ test_case "path resolves under XDG state" `Quick test_manifest_path_uses_xdg_state_home
        ; test_case "round-trip write/read" `Quick test_round_trip
        ; test_case "reinstall replaces same component/target" `Quick test_reinstall_replaces_record
        ; test_case "remove_record filters record" `Quick test_remove_record
        ; test_case "schema preserves optional fields" `Quick test_schema_preserved
        ]
      )
    ]
