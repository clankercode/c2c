(* Tests for Feature C: the OpenCode plugin is embedded in the c2c binary.

   - Sync gate: the committed embedded blob must equal the canonical TS source
     in data/opencode-plugin/c2c.ts byte-for-byte.
   - Binary-only install: `c2c install opencode` writes the embedded blob when
     the repo data/ file is not present. *)

open Alcotest

let ( // ) = Filename.concat

let contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    let n = in_channel_length ic in
    really_input_string ic n)

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc contents)

let rec find_repo_root cwd =
  let candidate = cwd // "data" // "opencode-plugin" // "c2c.ts" in
  if Sys.file_exists candidate then cwd
  else
    let parent = Filename.dirname cwd in
    if parent = cwd then failwith "cannot find repo root (data/opencode-plugin/c2c.ts missing)"
    else find_repo_root parent

let repo_root () = find_repo_root (Sys.getcwd ())

let c2c_exe_path () =
  let cwd = Sys.getcwd () in
  let local = cwd // "c2c.exe" in
  if Sys.file_exists local then local
  else (repo_root ()) // "_build" // "default" // "ocaml" // "cli" // "c2c.exe"

let with_tmp_dir f =
  let dir = Filename.temp_file "c2c-embed-test-" "" in
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

let mkdir_p path =
  let rec loop dir =
    if dir <> "" && not (Sys.file_exists dir) then begin
      loop (Filename.dirname dir);
      Unix.mkdir dir 0o700
    end
  in
  loop path

let current_path () =
  match Sys.getenv_opt "PATH" with
  | None -> ""
  | Some p -> p

let with_install_env ~home ~bin_dir f =
  let old_path = current_path () in
  let old_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  Unix.putenv "PATH" (bin_dir ^ ":" ^ old_path);
  Fun.protect ~finally:(fun () ->
    (match old_home with
     | Some home -> Unix.putenv "HOME" home
     | None -> Unix.putenv "HOME" "");
    Unix.putenv "PATH" old_path)
    f

let install_opencode_cmd ~with_mcp ~exe ~target ~broker_root ~alias =
  Printf.sprintf
    "%s install opencode%s --target-dir %s --broker-root %s --alias %s --no-deliver-watch --json"
    (Filename.quote exe)
    (if with_mcp then " --with-mcp" else "")
    (Filename.quote target)
    (Filename.quote broker_root)
    (Filename.quote alias)

let test_sync_gate_embedded_equals_data_file () =
  let data_path = (repo_root ()) // "data" // "opencode-plugin" // "c2c.ts" in
  let data_content = read_file data_path in
  check string "embedded content equals data/opencode-plugin/c2c.ts"
    data_content C2c_opencode_plugin_embedded.content

let embedded_matches_data_file embedded =
  let data_path = (repo_root ()) // "data" // "opencode-plugin" // "c2c.ts" in
  let data_content = read_file data_path in
  String.equal data_content embedded

let test_install_opencode_binary_only_writes_embedded () =
  with_tmp_dir (fun home ->
    with_tmp_dir (fun target ->
      with_tmp_dir (fun invocation_cwd ->
      let bin_dir = home // "bin" in
      Unix.mkdir bin_dir 0o700;
      (* B254/B255: the default plugin install must not need an MCP server on
         PATH, because it does not write an MCP config. *)
      let exe = c2c_exe_path () in
      with_install_env ~home ~bin_dir
        (fun () ->
          with_cwd invocation_cwd (fun () ->
          let broker_root = target // "broker" in
          let cmd =
            install_opencode_cmd ~with_mcp:false ~exe ~target ~broker_root
              ~alias:"test-embed"
          in
          let rc = Sys.command cmd in
          check int "c2c install opencode exits 0" 0 rc;
          let plugin_path = target // ".opencode" // "plugins" // "c2c.ts" in
          check bool "plugin file was written" true (Sys.file_exists plugin_path);
          let mcp_config = target // ".opencode" // "opencode.json" in
          check bool "default install does not write opencode MCP config" false
            (Sys.file_exists mcp_config);
          let installed = read_file plugin_path in
          check string "installed plugin equals embedded content"
            C2c_opencode_plugin_embedded.content installed;
          (* Sanity: it should NOT be a symlink in the binary-only path. *)
          let is_symlink =
            try (Unix.lstat plugin_path).Unix.st_kind = Unix.S_LNK
            with Unix.Unix_error _ -> false
          in
          check bool "binary-only install writes a regular file, not a symlink"
            false is_symlink)))))

let test_install_opencode_with_mcp_writes_config () =
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
            let cmd =
              install_opencode_cmd ~with_mcp:true ~exe ~target ~broker_root
                ~alias:"test-embed-mcp"
            in
            let rc = Sys.command cmd in
            check int "c2c install opencode --with-mcp exits 0" 0 rc;
            let mcp_config = target // ".opencode" // "opencode.json" in
            check bool "--with-mcp writes opencode MCP config" true
              (Sys.file_exists mcp_config);
            check bool "MCP config contains c2c entry" true
              (contains (read_file mcp_config) "\"c2c\""))))))

let test_install_opencode_dev_symlink_is_target_relative () =
  with_tmp_dir (fun home ->
    with_tmp_dir (fun target ->
      with_tmp_dir (fun invocation_cwd ->
        let bin_dir = home // "bin" in
        Unix.mkdir bin_dir 0o700;
        let dummy_server = bin_dir // "c2c-mcp-server" in
        write_file dummy_server "#!/bin/sh\nexit 0\n";
        Unix.chmod dummy_server 0o755;
        let data_dir = target // "data" // "opencode-plugin" in
        mkdir_p data_dir;
        let canonical_plugin = data_dir // "c2c.ts" in
        write_file canonical_plugin C2c_opencode_plugin_embedded.content;
        let exe = c2c_exe_path () in
        with_install_env ~home ~bin_dir (fun () ->
          with_cwd invocation_cwd (fun () ->
            let broker_root = target // "broker" in
            let cmd =
              install_opencode_cmd ~with_mcp:false ~exe ~target ~broker_root
                ~alias:"test-embed-dev"
            in
            let rc = Sys.command cmd in
            check int "c2c install opencode exits 0" 0 rc;
            let plugin_path = target // ".opencode" // "plugins" // "c2c.ts" in
            let is_symlink =
              try (Unix.lstat plugin_path).Unix.st_kind = Unix.S_LNK
              with Unix.Unix_error _ -> false
            in
            check bool "dev install writes a symlink" true is_symlink;
            check string "symlink points at target repo canonical plugin"
              canonical_plugin (Unix.readlink plugin_path))))))

let test_sync_gate_fails_when_embedded_is_stale () =
  (* Anti-false-green: temporarily corrupt the embedded blob and assert the
     sync gate would fail. We do not mutate the committed .ml; we shadow the
     value in-memory and compare against the real data file. *)
  let stale = C2c_opencode_plugin_embedded.content ^ "\n/* stale mutation */\n" in
  check bool "stale embedded fails the sync gate" false
    (embedded_matches_data_file stale)

let () =
  run "c2c_opencode_plugin_embedded"
    [ ( "sync_gate",
        [ test_case "embedded_equals_data_file" `Quick test_sync_gate_embedded_equals_data_file
        ; test_case "stale_embedded_would_fail" `Quick test_sync_gate_fails_when_embedded_is_stale
        ] )
    ; ( "binary_only_install",
        [ test_case "install_opencode_writes_embedded" `Quick test_install_opencode_binary_only_writes_embedded
        ; test_case "install_opencode_with_mcp_writes_config" `Quick
            test_install_opencode_with_mcp_writes_config
        ] )
    ; ( "dev_checkout",
        [ test_case "install_opencode_symlink_uses_target_not_cwd" `Quick
            test_install_opencode_dev_symlink_is_target_relative
        ] )
    ]
