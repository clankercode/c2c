(* test_c2c_migrate.ml — #360 hotfix tests for broker dir migration.

   Asserts that the new migrate-broker:
     1. Lists every legacy artifact in dry-run output (incl. previously
        omitted classes: keys, allowed_signers, broker.log,
        room_history.d, top-level inbox.json files, .monitor-locks,
        pending-orphan-replay JSONs).
     2. Actually copies keys/ and allowed_signers (full migration).
     3. Preserves broker.log content byte-for-byte.
     4. Denies process-local artifacts (.pid, top-level .lock).
     5. Has no Unknown classifications for the realistic legacy fixture
        (all real artifacts are either COPY or DENY — never silently
        skipped). *)

open Alcotest

let ( // ) = Filename.concat

let mkdir_p path =
  let rec loop p =
    if p = "/" || p = "." || p = "" then ()
    else if Sys.file_exists p then ()
    else begin
      loop (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  loop path

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc contents

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

let rec remove_tree p =
  if not (Sys.file_exists p) then ()
  else
    match (Unix.lstat p).Unix.st_kind with
    | Unix.S_DIR ->
        Array.iter (fun n -> if n <> "." && n <> ".." then remove_tree (p // n))
          (Sys.readdir p);
        (try Unix.rmdir p with _ -> ())
    | _ -> (try Unix.unlink p with _ -> ())

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let name = Printf.sprintf "c2c-migrate-test-%d-%d" (Unix.getpid ()) (Random.bits ()) in
  let dir = base // name in
  mkdir_p dir;
  Fun.protect ~finally:(fun () -> remove_tree dir) @@ fun () ->
  f dir

(** Build a fixture legacy broker that mirrors the real-world artifact
    set described in the #360 finding. Every class the previous
    migrator silently dropped is represented here. *)
let make_realistic_legacy_dir src =
  mkdir_p src;
  (* Files: previously-copied classes *)
  write_file (src // "registry.json") "{}";
  write_file (src // "registry.json.lock") "";
  write_file (src // "deaths.jsonl") "{}\n";
  (* Files: previously-OMITTED classes (#360 silent loss) *)
  write_file (src // "broker.log") "broker-log-sentinel-content\n";
  write_file (src // "allowed_signers") "alice ssh-ed25519 AAA\n";
  write_file (src // "relay.json") "{\"url\":\"https://example\"}";
  write_file (src // "pending_permissions.json") "[]";
  write_file (src // "dead-letter.jsonl") "[]";
  write_file (src // "pending-orphan-replay.session-abc.json") "{}";
  (* Top-level inbox files (note: NOT under inbox.json.d/ — bug #360) *)
  write_file (src // "alice.inbox.json") "{\"messages\":[]}";
  write_file (src // "bob.inbox.json") "{\"messages\":[]}";
  (* Process-local artifacts that should be DENIED *)
  write_file (src // "alice.inbox.lock") "";
  write_file (src // "bob.inbox.lock") "";
  write_file (src // "registry.json.lock") "";
  write_file (src // "broker.pid") "12345\n";
  (* Subdirs: previously-copied *)
  write_file (src // "inbox.json.d" // "carol.json") "{}";
  write_file (src // "memory" // "alice" // "note.md") "remember\n";
  write_file (src // "archive" // "alice" // "log.jsonl") "{}\n";
  (* Subdirs: previously-OMITTED *)
  write_file (src // "keys" // "alice.ed25519") "PRIVKEY\n";
  write_file (src // "keys" // "alice.ed25519.pub") "PUBKEY\n";
  write_file (src // "rooms" // "swarm-lounge" // "history.jsonl") "{}\n";
  write_file (src // "room_history.d" // "swarm-lounge.jsonl") "{}\n";
  write_file (src // ".monitor-locks" // "alice.lock") "";
  write_file (src // ".sitreps" // "2026" // "04" // "28" // "10.md") "sitrep\n";
  write_file (src // ".leases" // "alice.json") "{}";
  write_file (src // ".cold_boot_done" // "alice") "";
  write_file (src // "nudge" // "state.json") "{}"

let collect_lines () =
  let lines = ref [] in
  let push s = lines := s :: !lines in
  (push, fun () -> List.rev !lines)

let line_contains lines needle =
  List.exists (fun l ->
    let hl = String.length l in
    let nl = String.length needle in
    let rec scan i =
      i + nl <= hl &&
      (String.sub l i nl = needle || scan (i + 1))
    in
    nl = 0 || scan 0
  ) lines

let assert_lists_artifact lines artifact =
  check bool
    (Printf.sprintf "dry-run output enumerates %s" artifact)
    true
    (line_contains lines artifact)

(* ------------------------------------------------------------------ *)
(* Tests                                                              *)
(* ------------------------------------------------------------------ *)

let test_dry_run_lists_all_legacy_artifacts () =
  with_temp_dir @@ fun root ->
  let src = root // "legacy" in
  let dst = root // "canonical" in
  make_realistic_legacy_dir src;
  let push, get = collect_lines () in
  let outcome =
    C2c_migrate.run ~src_root:src ~dest_root:dst ~dry_run:true ~print_line:push
  in
  let lines = get () in
  check bool "dry-run succeeds (no Unknown entries)" true outcome.ok;
  check (list (pair string string)) "no unknown entries" [] outcome.unknown;
  (* Every artifact class enumerated in the dry-run output. *)
  List.iter (assert_lists_artifact lines)
    [ "keys"
    ; "allowed_signers"
    ; "broker.log"
    ; "room_history.d"
    ; "alice.inbox.json"
    ; ".monitor-locks"
    ; "pending-orphan-replay.session-abc.json"
    ; "registry.json"
    ; "memory"
    ; "archive"
    ];
  (* Process-local entries marked WILL DENY, not silently dropped. *)
  check bool "alice.inbox.lock marked WILL DENY" true
    (List.exists (fun l ->
      line_contains [l] "WILL DENY" && line_contains [l] "alice.inbox.lock")
      lines);
  check bool "broker.pid marked WILL DENY" true
    (List.exists (fun l ->
      line_contains [l] "WILL DENY" && line_contains [l] "broker.pid")
      lines);
  (* Dry run does not write anything. *)
  check bool "destination still does not exist after dry-run"
    false (Sys.file_exists (dst // "broker.log"))

let test_migrate_copies_keys_and_allowed_signers () =
  with_temp_dir @@ fun root ->
  let src = root // "legacy" in
  let dst = root // "canonical" in
  make_realistic_legacy_dir src;
  let push, _get = collect_lines () in
  let outcome =
    C2c_migrate.run ~src_root:src ~dest_root:dst ~dry_run:false ~print_line:push
  in
  check bool "migration succeeds" true outcome.ok;
  check bool "keys/alice.ed25519 present at canonical" true
    (Sys.file_exists (dst // "keys" // "alice.ed25519"));
  check bool "keys/alice.ed25519.pub present at canonical" true
    (Sys.file_exists (dst // "keys" // "alice.ed25519.pub"));
  check bool "allowed_signers present at canonical" true
    (Sys.file_exists (dst // "allowed_signers"));
  check string "allowed_signers content preserved"
    "alice ssh-ed25519 AAA\n"
    (read_file (dst // "allowed_signers"));
  (* Legacy tree removed after successful copy + verify. *)
  check bool "legacy keys/ removed" false
    (Sys.file_exists (src // "keys" // "alice.ed25519"))

let test_migrate_preserves_broker_log () =
  with_temp_dir @@ fun root ->
  let src = root // "legacy" in
  let dst = root // "canonical" in
  make_realistic_legacy_dir src;
  let original = read_file (src // "broker.log") in
  let push, _ = collect_lines () in
  let outcome =
    C2c_migrate.run ~src_root:src ~dest_root:dst ~dry_run:false ~print_line:push
  in
  check bool "migration succeeds" true outcome.ok;
  check string "broker.log byte-equal at canonical"
    original
    (read_file (dst // "broker.log"))

let test_migrate_denies_process_local_artifacts () =
  with_temp_dir @@ fun root ->
  let src = root // "legacy" in
  let dst = root // "canonical" in
  make_realistic_legacy_dir src;
  let push, _ = collect_lines () in
  let outcome =
    C2c_migrate.run ~src_root:src ~dest_root:dst ~dry_run:false ~print_line:push
  in
  check bool "migration succeeds" true outcome.ok;
  (* Top-level *.lock and *.pid files are NOT copied. *)
  check bool "alice.inbox.lock not at canonical" false
    (Sys.file_exists (dst // "alice.inbox.lock"));
  check bool "broker.pid not at canonical" false
    (Sys.file_exists (dst // "broker.pid"));
  check bool "registry.json.lock not at canonical" false
    (Sys.file_exists (dst // "registry.json.lock"));
  (* Outcome's denied list lists them explicitly. *)
  let denied_names = List.map fst outcome.denied in
  check bool "alice.inbox.lock in denied list" true
    (List.mem "alice.inbox.lock" denied_names);
  check bool "broker.pid in denied list" true
    (List.mem "broker.pid" denied_names)

let test_migrate_top_level_inbox_json_copied () =
  (* Regression test: the previous migrator only copied inbox.json.d/ but
     the real broker dir has top-level *.inbox.json. They MUST move. *)
  with_temp_dir @@ fun root ->
  let src = root // "legacy" in
  let dst = root // "canonical" in
  make_realistic_legacy_dir src;
  let push, _ = collect_lines () in
  let outcome =
    C2c_migrate.run ~src_root:src ~dest_root:dst ~dry_run:false ~print_line:push
  in
  check bool "migration succeeds" true outcome.ok;
  check bool "alice.inbox.json present at canonical" true
    (Sys.file_exists (dst // "alice.inbox.json"));
  check bool "bob.inbox.json present at canonical" true
    (Sys.file_exists (dst // "bob.inbox.json"))

(* For the fail-loud-on-unknown test we need the classifier to report
   Unknown for *something*. The current classifier defaults non-deny
   files to Copy (intentionally — silent skip is the bug). To exercise
   the Unknown branch we synthesize an Unknown directly via the
   underlying type and re-run the relevant code path through a
   targeted helper.

   Since `run` does not expose a hook to inject classifications, this
   test instead asserts the contract via the [render_entry] / outcome
   shape: an Unknown entry must show "ABORT" and produce a non-ok
   outcome with the entry recorded. We exercise this by constructing
   a fake legacy dir with one entry whose name is empty (impossible
   in practice) and checking the path. Skipped — see comment. *)

let test_migrate_fails_loud_on_unclassified_file () =
  (* Drop a FIFO into the legacy dir — it is neither a regular file nor a
     dir nor a symlink, so the classifier cannot place it in COPY or
     DENY. The migrator must ABORT (non-zero exit, clear error) rather
     than silently skip. *)
  with_temp_dir @@ fun root ->
  let src = root // "legacy" in
  let dst = root // "canonical" in
  mkdir_p src;
  write_file (src // "registry.json") "{}";
  let fifo = src // "weird.fifo" in
  (try Unix.mkfifo fifo 0o600
   with Unix.Unix_error _ ->
     skip () (* mkfifo unsupported on this filesystem — skip *));
  let push, get = collect_lines () in
  let outcome =
    C2c_migrate.run ~src_root:src ~dest_root:dst ~dry_run:false ~print_line:push
  in
  let lines = get () in
  check bool "migration ABORTS on unclassified entry" false outcome.ok;
  check bool "outcome.unknown lists the FIFO" true
    (List.exists (fun (p, _) -> p = "weird.fifo") outcome.unknown);
  check bool "output contains ABORT marker" true
    (line_contains lines "ABORT");
  (* And critically: the legacy tree is untouched (no copy attempted). *)
  check bool "legacy registry.json still present (no destructive action)"
    true (Sys.file_exists (src // "registry.json"));
  check bool "destination not created" false
    (Sys.file_exists (dst // "registry.json"))

let suite =
  [ "dry-run lists all legacy artifacts", `Quick, test_dry_run_lists_all_legacy_artifacts
  ; "copies keys and allowed_signers", `Quick, test_migrate_copies_keys_and_allowed_signers
  ; "preserves broker.log byte-equal", `Quick, test_migrate_preserves_broker_log
  ; "denies *.pid and top-level *.lock", `Quick, test_migrate_denies_process_local_artifacts
  ; "copies top-level *.inbox.json", `Quick, test_migrate_top_level_inbox_json_copied
  ; "fails loud on unclassified file (FIFO)", `Quick, test_migrate_fails_loud_on_unclassified_file
  ]

let () = run "c2c-migrate-360" [ "migrate", suite ]
