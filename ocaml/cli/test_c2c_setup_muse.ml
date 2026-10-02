(* test_c2c_setup_muse — `c2c install/uninstall muse` (B354).

   Muse is CLI-first (no MCP by default, B254): install writes an owned skill
   + an owned plugin bundle, installs + approves the plugin non-interactively
   when the plugins gate is open, and otherwise merges a settings.json hooks
   map (live-proven fallback). Schema provenance: B352 spike verdicts
   (.collab/research/2026-10-02T18-55-00Z-muse-b352-spike-verdicts.md, all
   verified live on muse 1.4.2-R4684.1 against scratch HOME + scratch plugin
   scope) and muse's own capability-examples contract.

   muse CLI interaction goes through C2C_MUSE_BIN (test seam); tests point it
   at a stub script, so no real muse binary is needed and the gate-open vs
   gate-absent paths are both hermetic. The binary is never shelled to, so
   this stanza needs no (deps c2c.exe). *)

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
  if (try Sys.is_directory path with _ -> false) then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else (try Sys.remove path with _ -> ())

let rec mkdir_p d =
  if not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    (try Unix.mkdir d 0o755 with Unix.Unix_error _ -> ())
  end

(* Stub muse: gate output is env-controlled (C2C_MUSE_STUB_LIST), every other
   plugins verb succeeds and appends its argv to C2C_MUSE_STUB_LOG. *)
let stub_script = {|#!/bin/sh
if [ "$1" = "plugins" ] && [ "$2" = "list" ]; then
  printf '%s\n' "$C2C_MUSE_STUB_LIST"
  exit 0
fi
printf '%s\n' "$*" >> "$C2C_MUSE_STUB_LOG"
if [ "$1" = "plugins" ] && [ "$2" = "install" ]; then
  echo "installed c2c 0.0.0 enabled=true trust=user-local"
  exit 0
fi
if [ "$1" = "plugins" ] && [ "$2" = "approve" ]; then
  if [ "$C2C_MUSE_STUB_APPROVE_FAIL" = "1" ]; then
    echo "approve failed: trust store unavailable" >&2
    exit 1
  fi
  # Order marker: snapshot the settings file (if pointed at) so tests can
  # prove approve ran strictly after the final settings write.
  if [ -n "$C2C_MUSE_STUB_APPROVE_MARKER" ]; then
    if [ -n "$C2C_MUSE_STUB_SETTINGS" ] && [ -f "$C2C_MUSE_STUB_SETTINGS" ]; then
      cat "$C2C_MUSE_STUB_SETTINGS" > "$C2C_MUSE_STUB_APPROVE_MARKER"
    else
      echo "no-settings" > "$C2C_MUSE_STUB_APPROVE_MARKER"
    fi
  fi
  echo "approve plugin:c2c:hook:session-start"
  echo "approve plugin:c2c:hook:stop"
  echo "approve plugin:c2c:hook:session-end"
  exit 0
fi
if [ "$1" = "plugins" ] && [ "$2" = "remove" ]; then
  if [ "$C2C_MUSE_STUB_REMOVE_ABSENT" = "1" ]; then
    echo "plugin \`c2c\` is not installed"
    exit 1
  fi
  echo "removed c2c"
  exit 0
fi
if [ "$1" = "sleep-hold" ]; then
  echo "holding stdout open"
  exec sleep 30
fi
echo "stub: unknown argv: $*" >&2
exit 1
|}

type scratch = {
  home : string;
  config : string;
  data : string;
  settings : string;
  skill : string;
  bundle_manifest : string;
  stub : string;
  stub_log : string;
}

let with_scratch_env ~stub_list f =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-setup-muse-%08x" (Random.bits ()) in
  Unix.mkdir dir 0o700;
  let home = dir // "home" in
  Unix.mkdir home 0o700;
  let stub = dir // "muse-stub.sh" in
  write_file stub stub_script;
  Unix.chmod stub 0o755;
  let stub_log = dir // "stub.log" in
  let vars =
    [ ("HOME", home)
    ; ("XDG_CONFIG_HOME", home // ".config")
    ; ("XDG_DATA_HOME", home // ".local" // "share")
    ; ("C2C_MUSE_BIN", stub)
    ; ("C2C_MUSE_STUB_LIST", stub_list)
    ; ("C2C_MUSE_STUB_LOG", stub_log)
    ; ("C2C_INSTALL_MANIFEST_PATH", dir // "manifest.json")
    ]
  in
  let prev = List.map (fun (k, _) -> (k, Sys.getenv_opt k)) vars in
  List.iter (fun (k, v) -> Unix.putenv k v) vars;
  let sc =
    { home
    ; config = home // ".config" // "muse"
    ; data = home // ".local" // "share" // "muse"
    ; settings = home // ".config" // "muse" // "settings.json"
    ; skill = home // ".config" // "muse" // "skills" // "c2c" // "SKILL.md"
    ; bundle_manifest =
        home // ".c2c" // "clients" // "muse" // "plugin" // ".muse-plugin" // "plugin.json"
    ; stub
    ; stub_log
    }
  in
  Fun.protect
    ~finally:(fun () ->
      (* Repo convention (test_c2c_relay_systemd.ml): restore originally-unset
         vars to "" rather than leaking the scratch value (which points at a
         deleted dir after remove_tree). All 7 vars treat "" as unset. *)
      List.iter
        (fun (k, v) ->
           match v with Some x -> Unix.putenv k x | None -> Unix.putenv k "")
        prev;
      try remove_tree dir with _ -> ())
    (fun () -> f sc)

let with_gate_open f = with_scratch_env ~stub_list:"no plugins" f
let with_gate_absent f =
  with_scratch_env ~stub_list:"plugins are not available in this build" f

let run_setup ?(with_mcp = false) ~alias () =
  C2c_setup.setup_muse ~with_mcp ~output_mode:C2c_types.Json ~dry_run:false
    ~root:"/fake/broker/root" ~alias_val:alias ~server_path:"/fake/c2c-mcp-server"
    ~mcp_command:"c2c-mcp-server" ~alias_from_auto_gen:false

let run_setup_dry ?(with_mcp = false) ~alias () =
  C2c_setup.setup_muse ~with_mcp ~output_mode:C2c_types.Json ~dry_run:true
    ~root:"/fake/broker/root" ~alias_val:alias ~server_path:"" ~mcp_command:""
    ~alias_from_auto_gen:false

(* Seed a fake plugin cache + installed.json the way `plugins install`
   would, so the no-CLI fallback has something to clean. *)
let seed_plugin_cache sc =
  let cache =
    sc.data // "plugins" // "cache" // "local" // "c2c" // "deadbeef" // "package"
      // ".muse-plugin"
  in
  mkdir_p cache;
  write_file (cache // "plugin.json") "{}\n";
  let installed = sc.data // "plugins" // "installed.json" in
  write_file installed
    {|{"version":1,"plugins":{"c2c":{"id":"c2c"},"other":{"id":"other"}}}|}

let seed_foreign_settings_hooks sc =
  mkdir_p (Filename.dirname sc.settings);
  write_file sc.settings
    {|{"schema_version":1,"operator":true,"hooks":{"SessionStart":[{"matcher":".*","hooks":[{"type":"command","command":"other-tool","timeout":5}]}]}}|}

let extra_string result key =
  match List.assoc_opt key result.C2c_setup.extra_json with
  | Some (`String s) -> Some s
  | _ -> None

let has_artifact result ~kind ~path =
  List.exists
    (fun (a : C2c_install_manifest.artifact) -> a.kind = kind && a.path = path)
    result.C2c_setup.artifacts

(* --- install: plugin path -------------------------------------------- *)

let test_plugin_path_writes_skill_and_bundle_no_settings () =
  with_gate_open (fun sc ->
    let result = run_setup ~alias:"muse-fixture-aa" () in
    check bool "skill exists" true (Sys.file_exists sc.skill);
    check bool "bundle manifest exists" true (Sys.file_exists sc.bundle_manifest);
    check bool "skill is embedded muse blob" true
      (read_file sc.skill = C2c_muse_skill_embedded.content);
    check bool "skill is identity-agnostic" false
      (contains ~haystack:(read_file sc.skill) ~needle:"muse-fixture-aa");
    check bool "skill points at whoami" true
      (contains ~haystack:(read_file sc.skill) ~needle:"c2c whoami");
    check bool "bundle is pinned manifest bytes" true
      (read_file sc.bundle_manifest
      = Yojson.Safe.pretty_to_string (C2c_setup.muse_plugin_manifest_json ()) ^ "\n");
    (* No MCP by default (B254): settings.json is untouched on the plugin path. *)
    check bool "no settings.json without --with-mcp" false (Sys.file_exists sc.settings);
    check bool "hooks mode is plugin" true
      (extra_string result "hooks" = Some "plugin");
    check bool "skill owned-file artifact" true
      (has_artifact result ~kind:"owned-file" ~path:sc.skill);
    check bool "bundle owned-file artifact" true
      (has_artifact result ~kind:"owned-file" ~path:sc.bundle_manifest);
    check bool "no shared-key artifact by default" false
      (List.exists
         (fun (a : C2c_install_manifest.artifact) -> a.kind = "shared-key")
         result.C2c_setup.artifacts);
    (* The stub saw install + approve, non-interactively (stdin /dev/null is
       on the setup side; the stub records argv). *)
    let log = if Sys.file_exists sc.stub_log then read_file sc.stub_log else "" in
    check bool "plugins install ran" true (contains ~haystack:log ~needle:"plugins install");
    check bool "plugins approve ran" true (contains ~haystack:log ~needle:"plugins approve c2c");
    check bool "client_configured reports true" true (C2c_setup.client_configured "muse");
    check bool "client_mcp_configured reports false" false
      (C2c_setup.client_mcp_configured "muse"))

(* --- install: gate-absent fallback ----------------------------------- *)

let test_gate_absent_falls_back_to_settings_hooks () =
  with_gate_absent (fun sc ->
    let result = run_setup ~alias:"muse-fixture-bb" () in
    check bool "hooks mode is settings-fallback" true
      (extra_string result "hooks" = Some "settings-fallback");
    check bool "settings.json written" true (Sys.file_exists sc.settings);
    let json = Yojson.Safe.from_file sc.settings in
    (match json with
     | `Assoc fields ->
         check bool "schema_version ensured" true
           (List.assoc_opt "schema_version" fields = Some (`Int 1));
         (match List.assoc_opt "hooks" fields with
          | Some (`Assoc hooks) ->
              List.iter
                (fun ev ->
                   check bool (ev ^ " present") true (List.mem_assoc ev hooks))
                [ "SessionStart"; "Stop"; "SessionEnd" ];
              (* Stop takes NO matcher (D11); the others take catch-all. *)
              (match List.assoc_opt "Stop" hooks with
               | Some (`List [ `Assoc g ]) ->
                   check bool "Stop group has no matcher" false (List.mem_assoc "matcher" g)
               | _ -> fail ("Stop group shape wrong: " ^ Yojson.Safe.to_string json));
              (match List.assoc_opt "SessionStart" hooks with
               | Some (`List [ `Assoc g ]) ->
                   check bool "SessionStart matcher is catch-all" true
                     (List.assoc_opt "matcher" g = Some (`String ".*"))
               | _ -> fail ("SessionStart group shape wrong: " ^ Yojson.Safe.to_string json))
          | _ -> fail "hooks map missing")
     | _ -> fail "settings.json is not an object");
    (* Idempotent re-run: byte-identical settings (fixed point, never append). *)
    let before = read_file sc.settings in
    let _ = run_setup ~alias:"muse-fixture-bb" () in
    check string "re-run is byte-identical" before (read_file sc.settings))

let test_dry_run_checks_gate_and_writes_nothing () =
  (* Gate open: dry-run previews plugin mode but shells install/approve never. *)
  with_gate_open (fun sc ->
    let result = run_setup_dry ~alias:"muse-fixture-dry" () in
    check bool "dry-run previews plugin mode" true
      (extra_string result "hooks" = Some "plugin");
    check bool "skill not written" false (Sys.file_exists sc.skill);
    check bool "bundle not written" false (Sys.file_exists sc.bundle_manifest);
    check bool "settings not written" false (Sys.file_exists sc.settings);
    let log = if Sys.file_exists sc.stub_log then read_file sc.stub_log else "" in
    check bool "install never shelled" false (contains ~haystack:log ~needle:"install");
    check bool "approve never shelled" false (contains ~haystack:log ~needle:"approve"));
  (* Gate absent: dry-run honestly previews the fallback (and its merge). *)
  with_gate_absent (fun sc ->
    let result = run_setup_dry ~alias:"muse-fixture-dry" () in
    check bool "dry-run previews fallback mode" true
      (extra_string result "hooks" = Some "settings-fallback");
    check bool "settings not written" false (Sys.file_exists sc.settings))

(* --- pure merges: foreign preservation + schema pins ------------------ *)

let test_hooks_merge_preserves_foreign () =
  let foreign_handler =
    `Assoc [ ("type", `String "command"); ("command", `String "other-tool"); ("timeout", `Int 5) ]
  in
  let existing =
    `Assoc
      [ ("schema_version", `Int 1)
      ; ("operator_key", `String "keep-me")
      ; ( "hooks"
        , `Assoc
            [ ("SessionStart",
               `List [ `Assoc [ ("matcher", `String ".*"); ("hooks", `List [ foreign_handler ]) ] ])
            ; ("PreToolUse",
               `List [ `Assoc [ ("matcher", `String ".*"); ("hooks", `List [ foreign_handler ]) ] ])
            ])
      ]
  in
  let merged = C2c_setup.merge_muse_settings_hooks existing in
  (* Fixed point: merging twice yields identical output. *)
  check bool "merge is a fixed point" true
    (C2c_setup.merge_muse_settings_hooks merged = merged);
  (match merged with
   | `Assoc fields ->
       check bool "operator key preserved" true
         (List.assoc_opt "operator_key" fields = Some (`String "keep-me"));
       (match List.assoc_opt "hooks" fields with
        | Some (`Assoc hooks) ->
            (* Foreign event untouched (same value, still present). *)
            check bool "foreign PreToolUse event kept" true
              (List.assoc_opt "PreToolUse" hooks
              = Some (`List
                  [ `Assoc [ ("matcher", `String ".*"); ("hooks", `List [ foreign_handler ]) ] ]));
            (* Foreign group inside a c2c event kept alongside ours. *)
            (match List.assoc_opt "SessionStart" hooks with
             | Some (`List gs) ->
                 check int "SessionStart has foreign + c2c groups" 2 (List.length gs);
                 check bool "foreign group first (append order)" true
                   (List.nth gs 0
                   = `Assoc [ ("matcher", `String ".*"); ("hooks", `List [ foreign_handler ]) ])
             | _ -> fail "SessionStart missing")
        | _ -> fail "hooks map missing")
   | _ -> fail "merged value is not an object")

let test_mcp_merge_shape_pinned () =
  let existing =
    `Assoc
      [ ("schema_version", `Int 1)
      ; ("operator_key", `String "keep")
      ; ("mcpServers", `Assoc [ ("other", `Assoc [ ("command", `String "other") ]) ])
      ]
  in
  let merged =
    C2c_setup.build_muse_mcp_config ~root:"/fake/root" ~alias_val:"muse-fixture-cc"
      ~server_path:"/fake/server" ~mcp_command:"c2c-mcp-server" ~alias_from_auto_gen:false
      existing
  in
  let s = Yojson.Safe.to_string merged in
  (* LOAD-BEARING pins (binding B352 verdicts). *)
  check bool "no legacy mcp_servers key" false (contains ~haystack:s ~needle:"mcp_servers");
  check bool "mode optional" true (contains ~haystack:s ~needle:{|"mode":"optional"|});
  check bool "no static session id" false (contains ~haystack:s ~needle:"MUSE_SESSION_ID");
  check bool "C2C_MCP_SESSION_ID never static" false
    (contains ~haystack:s ~needle:"C2C_MCP_SESSION_ID");
  check bool "literal env only" false (contains ~haystack:s ~needle:"${");
  check bool "foreign server kept" true (contains ~haystack:s ~needle:{|"other"|});
  check bool "operator key kept" true (contains ~haystack:s ~needle:"keep");
  check bool "broker root literal" true (contains ~haystack:s ~needle:"/fake/root");
  check bool "client type pinned" true
    (contains ~haystack:s ~needle:{|"C2C_MCP_CLIENT_TYPE":"muse"|});
  check bool "auto drain 0" true
    (contains ~haystack:s ~needle:{|"C2C_MCP_AUTO_DRAIN_CHANNEL":"0"|});
  (* Idempotent replacement, never append. *)
  let twice =
    C2c_setup.build_muse_mcp_config ~root:"/fake/root" ~alias_val:"muse-fixture-cc"
      ~server_path:"/fake/server" ~mcp_command:"c2c-mcp-server" ~alias_from_auto_gen:false
      merged
  in
  check bool "mcp merge is a fixed point" true (twice = merged)

let test_plugin_manifest_schema_pinned () =
  let m = C2c_setup.muse_plugin_manifest_json () in
  let s = Yojson.Safe.to_string m in
  (* agy-#65 discipline: the loader validates strictly — pin the full shape. *)
  (match m with
   | `Assoc top ->
       check bool "schemaVersion 1" true
         (List.assoc_opt "schemaVersion" top = Some (`Int 1));
       check bool "name c2c" true
         (List.assoc_opt "name" top = Some (`String "c2c"));
       check bool "description present" true
         (match List.assoc_opt "description" top with Some (`String d) -> d <> "" | _ -> false);
       (match List.assoc_opt "compat" top with
        | Some (`Assoc c) ->
            check bool "compat.manifestDir" true
              (List.assoc_opt "manifestDir" c = Some (`String ".muse-plugin"))
        | _ -> fail "compat missing");
       (match List.assoc_opt "capabilities" top with
        | Some (`Assoc caps) ->
            (match List.assoc_opt "hooks" caps with
             | Some (`List hs) ->
                 check int "three hooks" 3 (List.length hs);
                 let ids =
                   List.filter_map
                     (function
                       | `Assoc h -> (match List.assoc_opt "id" h with Some (`String i) -> Some i | _ -> None)
                       | _ -> None)
                     hs
                 in
                 check bool "hook ids" true (ids = [ "session-start"; "stop"; "session-end" ]);
                 List.iter
                   (function
                     | `Assoc h ->
                         (match List.assoc_opt "command" h with
                          | Some (`List [ `String "c2c"; `String "hook"; `String "muse" ]) -> ()
                          | _ -> fail ("hook command is not the c2c argv array: " ^ s));
                         check bool "timeoutMs present" true
                           (List.mem_assoc "timeoutMs" h)
                     | _ -> fail "hook is not an object")
                   hs
             | _ -> fail "capabilities.hooks missing")
        | _ -> fail "capabilities missing")
   | _ -> fail "manifest is not an object")

let test_settings_read_fails_closed_on_invalid_json () =
  with_gate_open (fun sc ->
    mkdir_p (Filename.dirname sc.settings);
    write_file sc.settings "{ this is not json";
    (match C2c_setup.read_muse_settings_file sc.settings with
     | Ok _ -> fail "invalid JSON must not parse as empty config"
     | Error msg ->
         check bool "error names the file" true (contains ~haystack:msg ~needle:sc.settings));
    (* Missing file is empty config (fresh host), not an error. *)
    (match C2c_setup.read_muse_settings_file (sc.settings ^ ".absent") with
     | Ok (`Assoc []) -> ()
     | _ -> fail "missing settings must read as empty config");
    (* Valid JSON with a non-object root must also fail closed (never be
       silently replaced by a fresh object). *)
    write_file sc.settings "[1,2,3]";
    (match C2c_setup.read_muse_settings_file sc.settings with
     | Ok _ -> fail "non-object root must not read as config"
     | Error msg ->
         check bool "error names the file" true (contains ~haystack:msg ~needle:sc.settings)))

let test_capture_timeout_bounds_the_read () =
  with_gate_open (fun sc ->
    (* The stub holds stdout open for 30s; the 0.5s deadline must kill it —
       regression test for the pre-review hang (blocking read before the
       clock started). Allow generous slack for loaded CI (kill grace is
       1.0s by design). *)
    let t0 = Unix.gettimeofday () in
    let r = C2c_setup.run_muse_capture ~timeout_s:0.5 [| sc.stub; "sleep-hold" |] in
    let elapsed = Unix.gettimeofday () -. t0 in
    check bool "wedged child reports failure" false r.C2c_setup.ok;
    check bool "partial output captured" true
      (contains ~haystack:r.C2c_setup.output ~needle:"holding stdout open");
    check bool "bounded well under the hold" true (elapsed < 10.0))

let test_plugin_success_strips_stale_fallback_hooks () =
  (* Transport flip gated->open: stale fallback hooks from the gated install
     are stripped on plugin success, so the two transports never stack. *)
  with_gate_absent (fun sc ->
    seed_foreign_settings_hooks sc;
    let _ = run_setup ~alias:"muse-fixture-flip" () in
    check bool "fallback hooks present" true
      (contains ~haystack:(read_file sc.settings) ~needle:"c2c hook muse");
    Unix.putenv "C2C_MUSE_STUB_LIST" "no plugins";
    let result = run_setup ~alias:"muse-fixture-flip" () in
    check bool "flipped to plugin mode" true
      (extra_string result "hooks" = Some "plugin");
    let s = read_file sc.settings in
    check bool "stale c2c hooks stripped" false (contains ~haystack:s ~needle:"c2c hook muse");
    check bool "foreign hook survives the flip" true (contains ~haystack:s ~needle:"other-tool"))

(* with_scratch_env does not manage the C2C_MUSE_STUB_* control vars — scope
   them with Fun.protect so a mid-test check failure cannot leak "=1" into
   later tests in this Alcotest process and cascade. *)
let with_stub_var k v f =
  let prev = Sys.getenv_opt k in
  Unix.putenv k v;
  Fun.protect
    ~finally:(fun () ->
      match prev with Some x -> Unix.putenv k x | None -> Unix.putenv k "")
    f

let test_approve_failure_converges_to_fallback () =
  with_gate_open (fun sc ->
    with_stub_var "C2C_MUSE_STUB_APPROVE_FAIL" "1" (fun () ->
      let result = run_setup ~alias:"muse-fixture-appr" () in
      check bool "approve failure falls back" true
        (extra_string result "hooks" = Some "settings-fallback");
      check bool "fallback hooks merged" true
        (contains ~haystack:(read_file sc.settings) ~needle:"c2c hook muse")))

let test_approve_failure_with_mcp_merges_both () =
  with_gate_open (fun sc ->
    with_stub_var "C2C_MUSE_STUB_APPROVE_FAIL" "1" (fun () ->
      let result = run_setup ~with_mcp:true ~alias:"muse-fixture-apprmcp" () in
      check bool "approve failure falls back" true
        (extra_string result "hooks" = Some "settings-fallback");
      let json = Yojson.Safe.from_file sc.settings in
      (match json with
       | `Assoc fields ->
           check bool "hooks merged" true (List.mem_assoc "hooks" fields);
           check bool "mcpServers merged" true (List.mem_assoc "mcpServers" fields)
       | _ -> fail "settings.json is not an object")))

let test_approve_runs_after_final_settings_write () =
  (* Load-bearing order (findings §6: a settings write after approve resets
     trust). The stub snapshots settings.json at approve time; on paths
     that force a settings write the snapshot must equal the final file. *)
  with_gate_open (fun sc ->
    seed_foreign_settings_hooks sc;
    (* Flip path: fallback hooks present, gate open -> strip-write, then
       approve. The snapshot must show the strip already applied. *)
    let _ = run_setup ~alias:"muse-fixture-order" () in
    check bool "gate-open run keeps foreign hooks" true
      (contains ~haystack:(read_file sc.settings) ~needle:"other-tool");
    (* Re-run with the marker armed on a state that forces a write: seed
       c2c hooks, flip again, snapshot must equal final bytes. *)
    let marker = sc.home // "approve-marker.txt" in
    with_stub_var "C2C_MUSE_STUB_APPROVE_MARKER" marker (fun () ->
      with_stub_var "C2C_MUSE_STUB_SETTINGS" sc.settings (fun () ->
        write_file sc.settings
          {|{"schema_version":1,"hooks":{"SessionStart":[{"matcher":".*","hooks":[{"type":"command","command":"c2c hook muse","timeout":10}]}]}}|};
        let result = run_setup ~alias:"muse-fixture-order" () in
        check bool "plugin mode" true
          (extra_string result "hooks" = Some "plugin");
        check bool "approve ran (marker written)" true (Sys.file_exists marker);
        check string "approve saw final settings bytes" (read_file sc.settings)
          (read_file marker);
        check bool "strip applied before approve" false
          (contains ~haystack:(read_file marker) ~needle:"c2c hook muse"))))

let test_remove_absent_is_clean () =
  with_gate_open (fun sc ->
    with_stub_var "C2C_MUSE_STUB_REMOVE_ABSENT" "1" (fun () ->
      let ok, detail = C2c_setup.muse_plugin_remove ~dry_run:false in
      check bool "absent remove is ok" true ok;
      check string "absent detail" "not installed" detail);
    ignore sc)

(* --- install --with-mcp ------------------------------------------------ *)

let test_with_mcp_merges_entry () =
  with_gate_open (fun sc ->
    let result = run_setup ~with_mcp:true ~alias:"muse-fixture-dd" () in
    check bool "settings.json written" true (Sys.file_exists sc.settings);
    let s = read_file sc.settings in
    check bool "mcpServers.c2c present" true (contains ~haystack:s ~needle:{|"c2c"|});
    check bool "no legacy mcp_servers" false (contains ~haystack:s ~needle:"mcp_servers");
    (* Structural check (the file is pretty-printed, so no compact needles). *)
    (match Yojson.Safe.from_string s with
     | `Assoc fields ->
         (match List.assoc_opt "mcpServers" fields with
          | Some (`Assoc m) ->
              (match List.assoc_opt "c2c" m with
               | Some (`Assoc e) ->
                   check bool "mode optional" true
                     (List.assoc_opt "mode" e = Some (`String "optional"))
               | _ -> fail "mcpServers.c2c missing")
          | _ -> fail "mcpServers missing")
     | _ -> fail "settings.json is not an object");
    check bool "shared-key artifact recorded" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "shared-key" && a.path = sc.settings && a.key = Some "mcpServers.c2c")
         result.C2c_setup.artifacts);
    check bool "client_mcp_configured reports true" true
      (C2c_setup.client_mcp_configured "muse"))

let test_with_mcp_on_fallback_path_merges_both () =
  with_gate_absent (fun sc ->
    let _ = run_setup ~with_mcp:true ~alias:"muse-fixture-ee" () in
    let json = Yojson.Safe.from_file sc.settings in
    (match json with
     | `Assoc fields ->
         check bool "hooks merged" true (List.mem_assoc "hooks" fields);
         check bool "mcpServers merged" true (List.mem_assoc "mcpServers" fields);
         check bool "schema_version present" true (List.mem_assoc "schema_version" fields)
     | _ -> fail "settings.json is not an object"))

(* --- drift-only refresh (#82) ------------------------------------------ *)

let test_refresh_skill_only_on_drift () =
  with_gate_open (fun sc ->
    C2c_setup.refresh_muse_skill_if_stale ();
    check bool "created when missing" true (Sys.file_exists sc.skill);
    check bool "embedded content" true
      (read_file sc.skill = C2c_muse_skill_embedded.content);
    let ino = (Unix.stat sc.skill).st_ino in
    C2c_setup.refresh_muse_skill_if_stale ();
    check bool "unchanged content does not rewrite" true (ino = (Unix.stat sc.skill).st_ino);
    write_file sc.skill "stale body\n";
    C2c_setup.refresh_muse_skill_if_stale ();
    check bool "drifted content is rewritten" true
      (read_file sc.skill = C2c_muse_skill_embedded.content))

(* --- uninstall --------------------------------------------------------- *)

let upsert_manifest ~component ~target_dir artifacts =
  C2c_install_manifest.upsert_record
    ~record:
      { C2c_install_manifest.component
      ; alias = Some "muse-fixture-ff"
      ; target_dir
      ; c2c_version = "test"
      ; ts = 0.0
      ; artifacts
      }

let test_uninstall_round_trip_with_manifest () =
  with_gate_absent (fun sc ->
    seed_foreign_settings_hooks sc;
    seed_plugin_cache sc;
    let target_dir = sc.home in
    let setup_result = run_setup ~with_mcp:true ~alias:"muse-fixture-ff" () in
    upsert_manifest ~component:"muse" ~target_dir setup_result.C2c_setup.artifacts;
    check bool "manifest record present" true
      ((C2c_install_manifest.read_manifest ()).installs <> []);
    let any_removed, removed =
      C2c_uninstall.uninstall_component ~output_mode:C2c_types.Json ~dry_run:false
        ~component:"muse" ~target_dir ~alias:None
    in
    check bool "something removed" true any_removed;
    check bool "skill gone" false (Sys.file_exists sc.skill);
    check bool "bundle gone" false (Sys.file_exists sc.bundle_manifest);
    check bool "cache gone" false
      (Sys.file_exists (sc.data // "plugins" // "cache" // "local" // "c2c"));
    (* Stub remove ran (CLI-first verb) AND the file fallback is clean. *)
    let log = if Sys.file_exists sc.stub_log then read_file sc.stub_log else "" in
    check bool "plugins remove ran" true (contains ~haystack:log ~needle:"plugins remove c2c");
    (* installed.json keeps the foreign record, drops c2c. *)
    let installed = read_file (sc.data // "plugins" // "installed.json") in
    check bool "foreign plugin record kept" true (contains ~haystack:installed ~needle:"other");
    check bool "c2c plugin record dropped" false
      (contains ~haystack:installed ~needle:{|"c2c"|});
    (* settings.json: foreign hook + operator key survive; c2c gone. *)
    let s = read_file sc.settings in
    check bool "operator key survives" true (contains ~haystack:s ~needle:"operator");
    check bool "foreign hook survives" true (contains ~haystack:s ~needle:"other-tool");
    check bool "c2c hook stripped" false (contains ~haystack:s ~needle:"c2c hook muse");
    check bool "mcpServers.c2c stripped" false (contains ~haystack:s ~needle:{|"c2c"|});
    check bool "manifest record removed" true
      ((C2c_install_manifest.read_manifest ()).installs = []);
    check bool "removed paths non-empty" true (removed <> []))

let test_uninstall_recompute_without_manifest () =
  with_gate_absent (fun sc ->
    seed_foreign_settings_hooks sc;
    seed_plugin_cache sc;
    let _ = run_setup ~with_mcp:true ~alias:"muse-fixture-gg" () in
    (* No manifest upsert: pure recompute fallback. *)
    let any_removed, _ =
      C2c_uninstall.uninstall_component ~output_mode:C2c_types.Json ~dry_run:false
        ~component:"muse" ~target_dir:sc.home ~alias:None
    in
    check bool "something removed" true any_removed;
    check bool "skill gone" false (Sys.file_exists sc.skill);
    check bool "bundle gone" false (Sys.file_exists sc.bundle_manifest);
    check bool "cache gone" false
      (Sys.file_exists (sc.data // "plugins" // "cache" // "local" // "c2c"));
    let s = read_file sc.settings in
    check bool "foreign hook survives" true (contains ~haystack:s ~needle:"other-tool");
    check bool "c2c hook stripped" false (contains ~haystack:s ~needle:"c2c hook muse");
    check bool "mcpServers.c2c stripped" false (contains ~haystack:s ~needle:{|"c2c"|});
    check bool "client_configured reports false" false (C2c_setup.client_configured "muse"))

let test_uninstall_no_cli_falls_back_to_files () =
  with_gate_absent (fun sc ->
    seed_plugin_cache sc;
    (* Point at a missing binary: gate fails, remove fails, files must still go. *)
    Unix.putenv "C2C_MUSE_BIN" (sc.home // "no-such-muse");
    let _ = run_setup ~alias:"muse-fixture-hh" () in
    let _, removed =
      C2c_uninstall.uninstall_component ~output_mode:C2c_types.Json ~dry_run:false
        ~component:"muse" ~target_dir:sc.home ~alias:None
    in
    check bool "cache gone without CLI" false
      (Sys.file_exists (sc.data // "plugins" // "cache" // "local" // "c2c"));
    let installed = read_file (sc.data // "plugins" // "installed.json") in
    check bool "c2c record dropped without CLI" false
      (contains ~haystack:installed ~needle:{|"c2c"|});
    check bool "cache path reported" true
      (List.exists
         (fun p -> contains ~haystack:p ~needle:("cache" // "local" // "c2c"))
         removed))

let test_recompute_covers_every_setup_path () =
  with_gate_open (fun sc ->
    let shared, owned, settings = C2c_uninstall.recompute_muse_artifacts () in
    check bool "settings path is Some" true (settings = Some sc.settings);
    check bool "mcp shared-key covered" true
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "shared-key" && a.path = sc.settings && a.key = Some "mcpServers.c2c")
         shared);
    (* No hooks shared-key: hooks are cleaned surgically (a generic "hooks"
       removal would nuke foreign hooks). *)
    check bool "no hooks shared-key" false
      (List.exists
         (fun (a : C2c_install_manifest.artifact) ->
            a.kind = "shared-key" && a.key = Some "hooks")
         shared);
    let owned_path p =
      List.exists
        (fun (a : C2c_install_manifest.artifact) -> a.kind = "owned-file" && a.path = p)
        owned
    in
    check bool "skill covered" true (owned_path sc.skill);
    check bool "skill dir covered" true (owned_path (Filename.dirname sc.skill));
    check bool "bundle manifest covered" true (owned_path sc.bundle_manifest);
    check bool "bundle dirs covered" true
      (owned_path (Filename.dirname sc.bundle_manifest)
      && owned_path (Filename.dirname (Filename.dirname sc.bundle_manifest))))

let () =
  Random.self_init ();
  run "c2c_setup_muse"
    [ ( "install_plugin_path"
      , [ test_case "skill+bundle, no settings, install+approve" `Quick
            test_plugin_path_writes_skill_and_bundle_no_settings
        ] )
    ; ( "install_fallback"
      , [ test_case "gate-absent merges settings hooks, idempotent" `Quick
            test_gate_absent_falls_back_to_settings_hooks
        ; test_case "dry-run checks gate, writes nothing" `Quick
            test_dry_run_checks_gate_and_writes_nothing
        ; test_case "capture timeout bounds the read" `Quick
            test_capture_timeout_bounds_the_read
        ; test_case "plugin success strips stale fallback hooks" `Quick
            test_plugin_success_strips_stale_fallback_hooks
        ; test_case "remove-absent is clean" `Quick test_remove_absent_is_clean
        ; test_case "approve failure converges to fallback" `Quick
            test_approve_failure_converges_to_fallback
        ; test_case "approve failure with-mcp merges both" `Quick
            test_approve_failure_with_mcp_merges_both
        ; test_case "approve runs after final settings write" `Quick
            test_approve_runs_after_final_settings_write
        ] )
    ; ( "pure_merges"
      , [ test_case "hooks merge preserves foreign + fixed point" `Quick
            test_hooks_merge_preserves_foreign
        ; test_case "mcp merge shape pinned" `Quick test_mcp_merge_shape_pinned
        ; test_case "plugin manifest schema pinned" `Quick test_plugin_manifest_schema_pinned
        ; test_case "settings read fails closed on invalid JSON" `Quick
            test_settings_read_fails_closed_on_invalid_json
        ] )
    ; ( "install_with_mcp"
      , [ test_case "with-mcp merges entry" `Quick test_with_mcp_merges_entry
        ; test_case "with-mcp on fallback merges both" `Quick
            test_with_mcp_on_fallback_path_merges_both
        ] )
    ; ( "refresh"
      , [ test_case "refresh only on drift (#82)" `Quick test_refresh_skill_only_on_drift ] )
    ; ( "uninstall"
      , [ test_case "round-trip with manifest" `Quick test_uninstall_round_trip_with_manifest
        ; test_case "recompute without manifest" `Quick test_uninstall_recompute_without_manifest
        ; test_case "no-CLI file fallback" `Quick test_uninstall_no_cli_falls_back_to_files
        ; test_case "recompute covers every setup path" `Quick
            test_recompute_covers_every_setup_path
        ] )
    ]
