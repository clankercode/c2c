(* test_c2c_kimi_notifier.ml — pure-function tests for the kimi notifier.

   End-to-end smoke (spawn kimi, write notification, see toast) lives in the
   manual dogfood validation per the slice's PR notes — kimi-cli is a runtime
   dep we can't reasonably embed in unit tests. *)

let test_notification_id_deterministic () =
  let id1 =
    C2c_kimi_notifier.notification_id_for_msg
      ~from_alias:"stanza-coder" ~ts:1777458000.123456
      ~content:"hello world"
  in
  let id2 =
    C2c_kimi_notifier.notification_id_for_msg
      ~from_alias:"stanza-coder" ~ts:1777458000.123456
      ~content:"hello world"
  in
  Alcotest.(check string) "same inputs → same id" id1 id2;
  Alcotest.(check int) "12-char id" 12 (String.length id1);
  (* Validate kimi-cli's id regex: [a-z0-9]{2,20} *)
  let re = Str.regexp "^[a-z0-9]+$" in
  Alcotest.(check bool) "lowercase hex only" true (Str.string_match re id1 0)

let test_notification_id_distinguishes () =
  let base =
    C2c_kimi_notifier.notification_id_for_msg
      ~from_alias:"a" ~ts:1.0 ~content:"x"
  in
  let diff_alias =
    C2c_kimi_notifier.notification_id_for_msg
      ~from_alias:"b" ~ts:1.0 ~content:"x"
  in
  let diff_ts =
    C2c_kimi_notifier.notification_id_for_msg
      ~from_alias:"a" ~ts:2.0 ~content:"x"
  in
  let diff_content =
    C2c_kimi_notifier.notification_id_for_msg
      ~from_alias:"a" ~ts:1.0 ~content:"y"
  in
  Alcotest.(check (neg string)) "alias differs" base diff_alias;
  Alcotest.(check (neg string)) "ts differs" base diff_ts;
  Alcotest.(check (neg string)) "content differs" base diff_content

let test_workspace_hash_matches_kimi_md5 () =
  (* Sanity-check against a known md5 that matches Python:
       md5(b"/home/xertrov/src/c2c").hexdigest()
       = f331b46a50c55c2ba466a5fcfa980fc2  (from probe-validated kimi session
       directory layout 2026-04-29). *)
  let h = C2c_kimi_notifier.workspace_hash_for_path "/home/xertrov/src/c2c" in
  Alcotest.(check string)
    "matches kimi-cli WorkDirMeta.sessions_dir md5"
    "f331b46a50c55c2ba466a5fcfa980fc2"
    h

let test_resolve_session_id_missing_log () =
  (* When KIMI_SHARE_DIR points at an empty dir, no log file → None *)
  let tmp = Filename.temp_file "kimi-test-" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  let old = Sys.getenv_opt "KIMI_SHARE_DIR" in
  Unix.putenv "KIMI_SHARE_DIR" tmp;
  let result = C2c_kimi_notifier.resolve_active_session_id () in
  (match old with
   | Some v -> Unix.putenv "KIMI_SHARE_DIR" v
   | None -> Unix.putenv "KIMI_SHARE_DIR" "");
  (try Unix.rmdir tmp with _ -> ());
  Alcotest.(check (option string)) "no log → None" None result

let test_resolve_session_id_parses_log () =
  let tmp = Filename.temp_file "kimi-test-" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  let log_dir = Filename.concat tmp "logs" in
  Unix.mkdir log_dir 0o755;
  let log_path = Filename.concat log_dir "kimi.log" in
  let oc = open_out log_path in
  output_string oc
    "2026-04-29 20:23:49.321 | INFO     | kimi_cli.cli:_run:583 |  - Created new session: 93d38a89-6838-4d54-97ad-f960db0db782\n";
  output_string oc
    "some other line\n";
  output_string oc
    "2026-04-29 20:25:00.000 | INFO     | kimi_cli.cli:_run:583 |  - Created new session: aaaa1234-5678-90ab-cdef-1234567890ab\n";
  close_out oc;
  let old = Sys.getenv_opt "KIMI_SHARE_DIR" in
  Unix.putenv "KIMI_SHARE_DIR" tmp;
  let result = C2c_kimi_notifier.resolve_active_session_id () in
  (match old with
   | Some v -> Unix.putenv "KIMI_SHARE_DIR" v
   | None -> Unix.putenv "KIMI_SHARE_DIR" "");
  (try Sys.remove log_path with _ -> ());
  (try Unix.rmdir log_dir with _ -> ());
  (try Unix.rmdir tmp with _ -> ());
  Alcotest.(check (option string))
    "picks the most recent session-id"
    (Some "aaaa1234-5678-90ab-cdef-1234567890ab")
    result

let () =
  Alcotest.run "c2c_kimi_notifier"
    [ "notification_id",
      [ Alcotest.test_case "deterministic + 12-char" `Quick test_notification_id_deterministic
      ; Alcotest.test_case "distinguishes by inputs" `Quick test_notification_id_distinguishes
      ]
    ; "workspace_hash",
      [ Alcotest.test_case "matches kimi-cli md5" `Quick test_workspace_hash_matches_kimi_md5 ]
    ; "session_id_resolve",
      [ Alcotest.test_case "missing log → None" `Quick test_resolve_session_id_missing_log
      ; Alcotest.test_case "parses log + picks newest" `Quick test_resolve_session_id_parses_log
      ]
    ]
