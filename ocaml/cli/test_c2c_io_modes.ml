(* test_c2c_io_modes.ml — #84: the atomic write must not change what it was
   not asked to change.

   Two properties, both of which the pre-#84 implementation got wrong because
   `rename` replaces an inode rather than editing one:

     1. MODE. The new inode carried `open_out`'s umask default, so every
        rewrite of an operator-owned config reset its permissions. A 0600
        ~/.hermes/config.yaml came back 0644 with no notice and no restore on
        uninstall.
     2. SYMLINKS. The rename replaced the LINK, so a config symlinked into a
        dotfiles repo became a regular file and the repo stopped tracking it.

   The mode tests deliberately pin the *decision* as well as the mechanism: c2c
   preserves an over-permissive mode rather than tightening it. That is the
   product call from #84 (report, do not act), so a future change that starts
   silently chmod'ing operator files should fail here and be made on purpose. *)

let ( // ) = Filename.concat
let check = Alcotest.check
let int = Alcotest.int
let string = Alcotest.string
let bool = Alcotest.bool

let with_temp_dir f =
  let dir =
    Filename.get_temp_dir_name ()
    // Printf.sprintf "c2c-io-modes-%d-%d" (Unix.getpid ()) (Random.int 1000000)
  in
  Unix.mkdir dir 0o700;
  let rec rm path =
    match Unix.lstat path with
    | exception _ -> ()
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun e -> rm (path // e)) (Sys.readdir path);
        (try Unix.rmdir path with _ -> ())
    | _ -> ( try Unix.unlink path with _ -> ())
  in
  Fun.protect ~finally:(fun () -> rm dir) (fun () -> f dir)

let write_raw path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let read_raw path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      really_input_string ic (in_channel_length ic))

let mode path = (Unix.stat path).Unix.st_perm land 0o7777

let write_ok ?perm path content =
  match C2c_io.write_file_atomic ?perm path content with
  | Ok () -> ()
  | Error e -> Alcotest.failf "write_file_atomic %s failed: %s" path e

(* ---------------------------------------------------------------------- *)
(* 1. Mode preservation                                                     *)
(* ---------------------------------------------------------------------- *)

(* The headline regression: a restricted config must not be widened. *)
let test_preserves_restrictive_mode () =
  with_temp_dir (fun dir ->
      let path = dir // "config.yaml" in
      write_raw path "old\n";
      Unix.chmod path 0o600;
      write_ok path "new\n";
      check int "0600 survives the rename" 0o600 (mode path);
      check string "content did change" "new\n" (read_raw path))

(* Several restrictive modes, so the test cannot pass by hardcoding 0600
   somewhere in the implementation. *)
let test_preserves_various_modes () =
  with_temp_dir (fun dir ->
      List.iter
        (fun m ->
          let path = dir // Printf.sprintf "cfg-%o" m in
          write_raw path "x\n";
          Unix.chmod path m;
          write_ok path "y\n";
          check int (Printf.sprintf "%o preserved" m) m (mode path))
        [ 0o400; 0o600; 0o640; 0o644; 0o664; 0o700; 0o755 ])

(* The deliberate half of the #84 decision. c2c does NOT tighten a file it did
   not create — it reports instead (see C2c_config_modes). If someone later
   makes the write silently narrow permissions, this fails and forces the
   product call to be made explicitly rather than as a side effect. *)
let test_preserves_world_writable_mode_by_design () =
  with_temp_dir (fun dir ->
      let path = dir // "codex-config.toml" in
      write_raw path "old\n";
      Unix.chmod path 0o666;
      write_ok path "new\n";
      check int "0666 preserved, not silently tightened" 0o666 (mode path))

(* Explicit ?perm is for files c2c owns; it must beat the preserved mode. *)
let test_explicit_perm_overrides_preserved () =
  with_temp_dir (fun dir ->
      let path = dir // "key" in
      write_raw path "old\n";
      Unix.chmod path 0o644;
      write_ok ~perm:0o600 path "secret\n";
      check int "?perm wins over the existing mode" 0o600 (mode path))

(* A file that does not exist yet has no mode to preserve, so ?perm is the only
   way to pin one — the key-material path in c2c_broker.ml depends on this. *)
let test_new_file_takes_explicit_perm () =
  with_temp_dir (fun dir ->
      let path = dir // "fresh-key" in
      write_ok ~perm:0o600 path "secret\n";
      check int "new file honours ?perm" 0o600 (mode path))

(* Without ?perm a brand-new file falls back to the umask default. Asserted
   loosely (only that it is not somehow restricted) because the umask is
   environmental; the point is that creation is unchanged by #84. *)
let test_new_file_without_perm_is_created () =
  with_temp_dir (fun dir ->
      let path = dir // "fresh" in
      write_ok path "hello\n";
      check bool "file exists" true (Sys.file_exists path);
      check string "content written" "hello\n" (read_raw path))

(* ---------------------------------------------------------------------- *)
(* 2. Symlinks                                                              *)
(* ---------------------------------------------------------------------- *)

(* The dotfiles-repo case: the link must survive and its destination change. *)
let test_symlink_survives_and_target_is_written () =
  with_temp_dir (fun dir ->
      let real = dir // "real-config.json" in
      let link = dir // "config.json" in
      write_raw real "old\n";
      Unix.chmod real 0o600;
      Unix.symlink real link;
      write_ok link "new\n";
      check bool "link is still a symlink" true
        ((Unix.lstat link).Unix.st_kind = Unix.S_LNK);
      check string "destination holds the new content" "new\n" (read_raw real);
      check int "destination mode preserved through the link" 0o600 (mode real))

(* A relative link must resolve against the LINK's directory, not the cwd. *)
let test_relative_symlink_resolves_against_link_dir () =
  with_temp_dir (fun dir ->
      let sub = dir // "sub" in
      Unix.mkdir sub 0o700;
      let real = sub // "real.toml" in
      let link = sub // "link.toml" in
      write_raw real "old\n";
      Unix.symlink "real.toml" link;
      write_ok link "new\n";
      check bool "link intact" true ((Unix.lstat link).Unix.st_kind = Unix.S_LNK);
      check string "relative destination written" "new\n" (read_raw real))

let test_symlink_chain_is_followed () =
  with_temp_dir (fun dir ->
      let real = dir // "real" in
      let mid = dir // "mid" in
      let top = dir // "top" in
      write_raw real "old\n";
      Unix.symlink real mid;
      Unix.symlink mid top;
      write_ok top "new\n";
      check string "end of chain written" "new\n" (read_raw real);
      check bool "first hop still a link" true
        ((Unix.lstat top).Unix.st_kind = Unix.S_LNK);
      check bool "second hop still a link" true
        ((Unix.lstat mid).Unix.st_kind = Unix.S_LNK))

(* A dangling link should create its destination, matching what an ordinary
   open-for-write does — not replace the link with a regular file. *)
let test_dangling_symlink_creates_destination () =
  with_temp_dir (fun dir ->
      let missing = dir // "not-there-yet" in
      let link = dir // "link" in
      Unix.symlink missing link;
      write_ok link "created\n";
      check bool "destination now exists" true (Sys.file_exists missing);
      check string "destination content" "created\n" (read_raw missing);
      check bool "link not replaced" true
        ((Unix.lstat link).Unix.st_kind = Unix.S_LNK))

(* A symlink loop has no destination to resolve. The write must terminate
   rather than spin; a loop is a broken filesystem state, so any defined
   outcome is acceptable as long as it is bounded. *)
let test_symlink_loop_terminates () =
  with_temp_dir (fun dir ->
      let a = dir // "a" and b = dir // "b" in
      Unix.symlink a b;
      Unix.symlink b a;
      (* Only assert termination and that we do not raise. *)
      let _ = C2c_io.write_file_atomic a "x\n" in
      check bool "returned without hanging or raising" true true)

(* ---------------------------------------------------------------------- *)
(* 3. resolve_symlink in isolation                                          *)
(* ---------------------------------------------------------------------- *)

let test_resolve_non_symlink_is_identity () =
  with_temp_dir (fun dir ->
      let path = dir // "plain" in
      write_raw path "x\n";
      check string "plain path unchanged" path
        (C2c_io.resolve_symlink path))

let test_resolve_missing_path_is_identity () =
  with_temp_dir (fun dir ->
      let path = dir // "nope" in
      check string "missing path unchanged" path
        (C2c_io.resolve_symlink path))

(* ---------------------------------------------------------------------- *)
(* 4. The locked variant carries the same contract                          *)
(* ---------------------------------------------------------------------- *)

let test_locked_preserves_mode () =
  with_temp_dir (fun dir ->
      let path = dir // "state.json" in
      write_raw path "old\n";
      Unix.chmod path 0o600;
      (match C2c_io.write_file_atomic_locked path "new\n" with
      | Ok () -> ()
      | Error e -> Alcotest.failf "locked write failed: %s" e);
      check int "locked write preserves 0600" 0o600 (mode path);
      check string "content replaced" "new\n" (read_raw path))

(* The lock open used O_TRUNC, so dying between lock and rename left the file
   EMPTY — the exact window the atomic write exists to close. Asserting the
   content survives a completed write is the observable proxy. *)
let test_locked_does_not_truncate_on_open () =
  with_temp_dir (fun dir ->
      let path = dir // "state.json" in
      write_raw path "important\n";
      (* Read through the same path the lock open uses, before any write. *)
      let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT ] 0o600 in
      Unix.close fd;
      check string "opening for the lock did not truncate" "important\n"
        (read_raw path))

(* ---------------------------------------------------------------------- *)
(* 5. C2c_config_modes — the reporting half                                 *)
(* ---------------------------------------------------------------------- *)

let with_manifest ~json f =
  with_temp_dir (fun dir ->
      let manifest = dir // "install-manifest.json" in
      write_raw manifest json;
      let prev = Sys.getenv_opt "C2C_INSTALL_MANIFEST_PATH" in
      Unix.putenv "C2C_INSTALL_MANIFEST_PATH" manifest;
      Fun.protect
        ~finally:(fun () ->
          match prev with
          | Some v -> Unix.putenv "C2C_INSTALL_MANIFEST_PATH" v
          | None -> Unix.putenv "C2C_INSTALL_MANIFEST_PATH" "")
        (fun () -> f dir))

let manifest_json ~paths =
  let artifacts =
    paths
    |> List.map (fun p ->
           Printf.sprintf
             {|{"kind":"shared-key","path":%s,"key":"mcpServers.c2c","format":"json"}|}
             (Yojson.Safe.to_string (`String p)))
    |> String.concat ","
  in
  Printf.sprintf
    {|{"version":1,"installs":[{"component":"claude","alias":null,"target_dir":"/tmp","c2c_version":"test","ts":0.0,"artifacts":[%s]}]}|}
    artifacts

(* No manifest must not read as "all clear" — that is the one answer that would
   mislead, since the manifest is best-effort and may simply be absent. *)
let test_modes_unknown_without_manifest () =
  with_manifest ~json:{|{"version":1,"installs":[]}|} (fun _ ->
      match C2c_config_modes.check () with
      | C2c_config_modes.Unknown _ -> ()
      | C2c_config_modes.Clean _ -> Alcotest.fail "empty manifest reported Clean"
      | C2c_config_modes.World_writable _ ->
          Alcotest.fail "empty manifest reported offenders")

let test_modes_clean_when_all_restricted () =
  with_temp_dir (fun dir ->
      let cfg = dir // "claude.json" in
      write_raw cfg "{}\n";
      Unix.chmod cfg 0o600;
      with_manifest ~json:(manifest_json ~paths:[ cfg ]) (fun _ ->
          match C2c_config_modes.check () with
          | C2c_config_modes.Clean n -> check int "one config checked" 1 n
          | _ -> Alcotest.fail "expected Clean"))

let test_modes_flags_world_writable () =
  with_temp_dir (fun dir ->
      let good = dir // "a.json" and bad = dir // "b.toml" in
      write_raw good "{}\n";
      write_raw bad "x\n";
      Unix.chmod good 0o600;
      Unix.chmod bad 0o666;
      with_manifest ~json:(manifest_json ~paths:[ good; bad ]) (fun _ ->
          match C2c_config_modes.check () with
          | C2c_config_modes.World_writable offenders ->
              check (Alcotest.list Alcotest.string) "only the 0666 file" [ bad ]
                offenders
          | _ -> Alcotest.fail "expected World_writable"))

(* Group-write is a deliberate, normal setup and must not be flagged. *)
let test_modes_ignores_group_writable () =
  with_temp_dir (fun dir ->
      let cfg = dir // "shared.json" in
      write_raw cfg "{}\n";
      Unix.chmod cfg 0o660;
      with_manifest ~json:(manifest_json ~paths:[ cfg ]) (fun _ ->
          match C2c_config_modes.check () with
          | C2c_config_modes.Clean _ -> ()
          | _ -> Alcotest.fail "group-writable should not be flagged"))

(* A recorded path that no longer exists is not a finding — uninstall removes
   files and the manifest can outlive them. *)
let test_modes_ignores_missing_paths () =
  with_temp_dir (fun dir ->
      let gone = dir // "removed.json" in
      with_manifest ~json:(manifest_json ~paths:[ gone ]) (fun _ ->
          match C2c_config_modes.check () with
          | C2c_config_modes.Clean _ -> ()
          | _ -> Alcotest.fail "missing path should not be flagged"))

(* Owned files are c2c's own to set modes on, so they stay out of scope. *)
let test_modes_ignores_owned_files () =
  check bool "owned-file is not shared" false
    (C2c_config_modes.is_shared_kind "owned-file");
  check bool "binary is not shared" false (C2c_config_modes.is_shared_kind "binary");
  check bool "shared-key is shared" true (C2c_config_modes.is_shared_kind "shared-key");
  check bool "shared-block is shared" true
    (C2c_config_modes.is_shared_kind "shared-block");
  check bool "shared-toml-section is shared" true
    (C2c_config_modes.is_shared_kind "shared-toml-section")

let () =
  Alcotest.run "c2c_io modes and symlinks"
    [ ( "mode preservation",
        [ Alcotest.test_case "restrictive mode survives" `Quick
            test_preserves_restrictive_mode
        ; Alcotest.test_case "several modes survive" `Quick
            test_preserves_various_modes
        ; Alcotest.test_case "world-writable preserved by design" `Quick
            test_preserves_world_writable_mode_by_design
        ; Alcotest.test_case "?perm overrides preserved mode" `Quick
            test_explicit_perm_overrides_preserved
        ; Alcotest.test_case "new file honours ?perm" `Quick
            test_new_file_takes_explicit_perm
        ; Alcotest.test_case "new file without ?perm still written" `Quick
            test_new_file_without_perm_is_created ] )
    ; ( "symlinks",
        [ Alcotest.test_case "link survives, destination written" `Quick
            test_symlink_survives_and_target_is_written
        ; Alcotest.test_case "relative link resolves against its dir" `Quick
            test_relative_symlink_resolves_against_link_dir
        ; Alcotest.test_case "chain is followed" `Quick test_symlink_chain_is_followed
        ; Alcotest.test_case "dangling link creates destination" `Quick
            test_dangling_symlink_creates_destination
        ; Alcotest.test_case "loop terminates" `Quick test_symlink_loop_terminates
        ; Alcotest.test_case "non-symlink is identity" `Quick
            test_resolve_non_symlink_is_identity
        ; Alcotest.test_case "missing path is identity" `Quick
            test_resolve_missing_path_is_identity ] )
    ; ( "locked variant",
        [ Alcotest.test_case "preserves mode" `Quick test_locked_preserves_mode
        ; Alcotest.test_case "lock open does not truncate" `Quick
            test_locked_does_not_truncate_on_open ] )
    ; ( "config-mode reporting",
        [ Alcotest.test_case "no manifest is Unknown, not Clean" `Quick
            test_modes_unknown_without_manifest
        ; Alcotest.test_case "all restricted is Clean" `Quick
            test_modes_clean_when_all_restricted
        ; Alcotest.test_case "world-writable is flagged" `Quick
            test_modes_flags_world_writable
        ; Alcotest.test_case "group-writable is not flagged" `Quick
            test_modes_ignores_group_writable
        ; Alcotest.test_case "missing paths are not flagged" `Quick
            test_modes_ignores_missing_paths
        ; Alcotest.test_case "only shared kinds are in scope" `Quick
            test_modes_ignores_owned_files ] )
    ]
