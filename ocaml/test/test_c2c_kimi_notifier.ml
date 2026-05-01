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

let test_resolve_session_id_missing_config () =
  (* When instance config does not exist → None *)
  let tmp = Filename.temp_file "kimi-test-" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  let old_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" tmp;
  let result = C2c_kimi_notifier.read_session_id_from_config "nonexistent-alias" in
  (match old_home with
   | Some v -> Unix.putenv "HOME" v
   | None -> Unix.putenv "HOME" "");
  (try Unix.rmdir tmp with _ -> ());
  Alcotest.(check (option string)) "no config → None" None result

let test_resolve_session_id_reads_config () =
  let tmp = Filename.temp_file "kimi-test-" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  let local_dir = Filename.concat tmp ".local" in
  Unix.mkdir local_dir 0o755;
  let share_dir = Filename.concat local_dir "share" in
  Unix.mkdir share_dir 0o755;
  let c2c_dir = Filename.concat share_dir "c2c" in
  Unix.mkdir c2c_dir 0o755;
  let inst_dir = Filename.concat c2c_dir "instances" in
  Unix.mkdir inst_dir 0o755;
  let alias_dir = Filename.concat inst_dir "test-kimi" in
  Unix.mkdir alias_dir 0o755;
  let config_path = Filename.concat alias_dir "config.json" in
  let oc = open_out config_path in
  output_string oc "{\"resume_session_id\":\"aaaa1234-5678-90ab-cdef-1234567890ab\"}\n";
  close_out oc;
  let old_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" tmp;
  let result = C2c_kimi_notifier.read_session_id_from_config "test-kimi" in
  (match old_home with
   | Some v -> Unix.putenv "HOME" v
   | None -> Unix.putenv "HOME" "");
  (try Sys.remove config_path with _ -> ());
  (try Unix.rmdir alias_dir with _ -> ());
  (try Unix.rmdir inst_dir with _ -> ());
  (try Unix.rmdir c2c_dir with _ -> ());
  (try Unix.rmdir share_dir with _ -> ());
  (try Unix.rmdir local_dir with _ -> ());
  (try Unix.rmdir tmp with _ -> ());
  Alcotest.(check (option string))
    "reads resume_session_id from config"
    (Some "aaaa1234-5678-90ab-cdef-1234567890ab")
    result

(* #465: atomic_write_string should produce a stable file with the exact
   content. The fsync added in this slice is best-effort and not directly
   observable, but the contract — write atomically, content readable
   after — is what callers rely on. *)
let test_atomic_write_string_roundtrip () =
  let tmp = Filename.temp_file "c2c-aw-" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  let dest = Filename.concat tmp "out.json" in
  let content = "{\"version\":1,\"id\":\"abc123\"}" in
  C2c_kimi_notifier.atomic_write_string dest content;
  Alcotest.(check bool) "destination exists" true (Sys.file_exists dest);
  let ic = open_in dest in
  let got =
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () ->
        let buf = Buffer.create 64 in
        (try
           while true do
             Buffer.add_channel buf ic 1
           done
         with End_of_file -> ());
        Buffer.contents buf)
  in
  Alcotest.(check string) "content roundtrips" content got;
  (* Cleanup: dest, then any stray .tmp siblings, then the dir. *)
  (try Sys.remove dest with _ -> ());
  (try
     Array.iter
       (fun f -> try Sys.remove (Filename.concat tmp f) with _ -> ())
       (Sys.readdir tmp)
   with _ -> ());
  (try Unix.rmdir tmp with _ -> ())

(* #469 prctl smoke test deferred to dogfood validation; manual verification:
     c2c start kimi <name>
     ps -p <daemon-pid> -o comm   # → "c2c-kimi-notif"
   PR_SET_NAME truncates to 16 bytes incl. NUL, so 15-char name is safe. *)
(* #475: c2c-system events must NOT reach the kimi llm-sink — they cause
   identity-confusion when kimi reads "<alias> joined swarm-lounge" as a
   user-turn DM. *)
let test_is_system_event_predicate () =
  Alcotest.(check bool) "c2c-system → true" true
    (C2c_kimi_notifier.is_system_event ~from_alias:"c2c-system");
  Alcotest.(check bool) "regular alias → false" false
    (C2c_kimi_notifier.is_system_event ~from_alias:"stanza-coder");
  Alcotest.(check bool) "empty alias → false" false
    (C2c_kimi_notifier.is_system_event ~from_alias:"");
  Alcotest.(check bool) "case-sensitive (broker uses canonical lowercase)" false
    (C2c_kimi_notifier.is_system_event ~from_alias:"C2C-System")

let test_is_approval_verdict_body () =
  Alcotest.(check bool) "ka_x allow → true" true
    (C2c_kimi_notifier.is_approval_verdict_body "ka_abc123 allow");
  Alcotest.(check bool) "ka_x deny because rm → true" true
    (C2c_kimi_notifier.is_approval_verdict_body "ka_xyz deny because foo");
  Alcotest.(check bool) "ka_x ALLOW (uppercase) → true" true
    (C2c_kimi_notifier.is_approval_verdict_body "ka_call_id_42 ALLOW");
  Alcotest.(check bool) "leading whitespace ok → true" true
    (C2c_kimi_notifier.is_approval_verdict_body "   ka_t allow");
  Alcotest.(check bool) "tab separator → true" true
    (C2c_kimi_notifier.is_approval_verdict_body "ka_a\tdeny");
  Alcotest.(check bool) "regular DM → false" false
    (C2c_kimi_notifier.is_approval_verdict_body "hey, can you check the build?");
  Alcotest.(check bool) "ka_ alone → false" false
    (C2c_kimi_notifier.is_approval_verdict_body "ka_");
  Alcotest.(check bool) "ka_x without verdict → false" false
    (C2c_kimi_notifier.is_approval_verdict_body "ka_token nothing here");
  Alcotest.(check bool) "wrong prefix → false" false
    (C2c_kimi_notifier.is_approval_verdict_body "kb_token allow");
  Alcotest.(check bool) "empty → false" false
    (C2c_kimi_notifier.is_approval_verdict_body "")

let with_tmpdir f =
  let tmp = Filename.temp_file "kimi-notif-test-" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  Fun.protect ~finally:(fun () ->
      let rec rmrf p =
        if Sys.is_directory p then begin
          Array.iter (fun c -> rmrf (Filename.concat p c)) (Sys.readdir p);
          (try Unix.rmdir p with _ -> ())
        end else (try Sys.remove p with _ -> ())
      in
      rmrf tmp)
    (fun () -> f tmp)

let test_write_notification_skips_system_events () =
  with_tmpdir (fun sdir ->
      C2c_kimi_notifier.write_notification
        ~session_dir:sdir
        ~notification_id:"abc123def456"
        ~from_alias:"c2c-system"
        ~body:"lumi-ember registered";
      let ndir = Filename.concat (Filename.concat sdir "notifications") "abc123def456" in
      Alcotest.(check bool) "no notification dir created for system event"
        false (Sys.file_exists ndir))

let test_write_notification_writes_real_dm () =
  with_tmpdir (fun sdir ->
      C2c_kimi_notifier.write_notification
        ~session_dir:sdir
        ~notification_id:"realdm123456"
        ~from_alias:"stanza-coder"
        ~body:"hello kimi";
      let ndir = Filename.concat (Filename.concat sdir "notifications") "realdm123456" in
      let event_path = Filename.concat ndir "event.json" in
      let delivery_path = Filename.concat ndir "delivery.json" in
      Alcotest.(check bool) "event.json written" true (Sys.file_exists event_path);
      Alcotest.(check bool) "delivery.json written" true (Sys.file_exists delivery_path))

(* Helper: check whether substring [needle] occurs in [haystack]. *)
let contains haystack needle =
  let re = Str.regexp_string needle in
  try ignore (Str.search_forward re haystack 0); true
  with Not_found -> false

(* #141: sidecar chat log — operator-visible scrollback for ALL c2c messages. *)
let test_write_chat_log_creates_file_with_expected_line () =
  with_tmpdir (fun sdir ->
      C2c_kimi_notifier.write_chat_log
        ~session_dir:sdir
        ~from_alias:"stanza-coder"
        ~body:"hello kimi";
      let path = Filename.concat sdir "c2c-chat-log.md" in
      Alcotest.(check bool) "chat log created" true (Sys.file_exists path);
      let ic = open_in path in
      let content =
        Fun.protect ~finally:(fun () -> close_in ic)
          (fun () ->
             let buf = Buffer.create 256 in
             (try while true do Buffer.add_channel buf ic 1 done with End_of_file -> ());
             Buffer.contents buf)
      in
      Alcotest.(check bool) "contains FROM stanza-coder"
        true (contains content "FROM stanza-coder:");
      Alcotest.(check bool) "contains body"
        true (contains content "hello kimi"))

let test_write_chat_log_includes_system_events () =
  with_tmpdir (fun sdir ->
      C2c_kimi_notifier.write_chat_log
        ~session_dir:sdir
        ~from_alias:"c2c-system"
        ~body:"lumi-ember joined swarm-lounge";
      let path = Filename.concat sdir "c2c-chat-log.md" in
      let ic = open_in path in
      let content =
        Fun.protect ~finally:(fun () -> close_in ic)
          (fun () ->
             let buf = Buffer.create 256 in
             (try while true do Buffer.add_channel buf ic 1 done with End_of_file -> ());
             Buffer.contents buf)
      in
      Alcotest.(check bool) "system event logged in sidecar"
        true (contains content "FROM c2c-system:"))

let test_write_chat_log_multiline_body () =
  with_tmpdir (fun sdir ->
      let body = "line one\nline two\nline three" in
      C2c_kimi_notifier.write_chat_log
        ~session_dir:sdir
        ~from_alias:"coordinator1"
        ~body;
      let path = Filename.concat sdir "c2c-chat-log.md" in
      let ic = open_in path in
      let content =
        Fun.protect ~finally:(fun () -> close_in ic)
          (fun () ->
             let buf = Buffer.create 256 in
             (try while true do Buffer.add_channel buf ic 1 done with End_of_file -> ());
             Buffer.contents buf)
      in
      Alcotest.(check bool) "first line unindented"
        true (contains content "line one");
      Alcotest.(check bool) "continuation indented"
        true (contains content "    line two");
      Alcotest.(check bool) "third line indented"
        true (contains content "    line three"))

let test_write_chat_log_appends () =
  with_tmpdir (fun sdir ->
      C2c_kimi_notifier.write_chat_log ~session_dir:sdir ~from_alias:"a" ~body:"first";
      C2c_kimi_notifier.write_chat_log ~session_dir:sdir ~from_alias:"b" ~body:"second";
      let path = Filename.concat sdir "c2c-chat-log.md" in
      let ic = open_in path in
      let content =
        Fun.protect ~finally:(fun () -> close_in ic)
          (fun () ->
             let buf = Buffer.create 256 in
             (try while true do Buffer.add_channel buf ic 1 done with End_of_file -> ());
             Buffer.contents buf)
      in
      Alcotest.(check bool) "contains first entry"
        true (contains content "FROM a:");
      Alcotest.(check bool) "contains second entry"
        true (contains content "FROM b:"))

(* ─── #484 S1 fixture-gated tests ──────────────────────────────────────────────── *)

(* Guard: fixture-gated so tests are hermetic to CI.
   Set C2C_KIMI_NOTIFIER_FIXTURE=1 to enable.
   The three test functions below are only meaningful when the notifier has
   been patched to use read_inbox (the S1 fix).  They are harmless when
   C2C_KIMI_NOTIFIER_FIXTURE is unset — they just don't register. *)

let () =
  match Sys.getenv_opt "C2C_KIMI_NOTIFIER_FIXTURE" with
  | None -> ()
  | Some _ -> ()

(* Build a minimal broker root with a pre-seeded inbox. *)
let with_broker_root_and_inbox messages f =
  let tmp = Filename.temp_file "c2c-notifier-fixture-" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rmrf p =
        if Sys.is_directory p then begin
          Array.iter (fun c -> rmrf (Filename.concat p c)) (Sys.readdir p);
          try Unix.rmdir p with _ -> ()
        end else try Sys.remove p with _ -> ()
      in
      rmrf tmp)
    (fun () ->
       (* Broker needs a registry — create an empty one. *)
       let reg_path = Filename.concat tmp "registrations.yaml" in
       let reg = open_out reg_path in
       output_string reg "registrations: []\n";
       close_out reg;
       (* Write the inbox. *)
       let inbox_path = Filename.concat tmp "kimi-test-session.inbox.json" in
       let inbox = open_out inbox_path in
       let json_list =
         `List (List.map (fun (from_alias, content) ->
           `Assoc [
             ("from_alias", `String from_alias);
             ("to_alias", `String "kimi-test");
             ("content", `String content);
             ("ts", `Float (Unix.gettimeofday ()));
             ("deferrable", `Bool false);
             ("ephemeral", `Bool false);
             ("reply_via", `Null);
             ("enc_status", `Null);
             ("message_id", `Null);
           ])
           messages)
         |> Yojson.Safe.to_string
       in
       output_string inbox json_list;
       close_out inbox;
       f tmp)

(* Verify inbox contents after run_once. *)
let read_inbox_messages broker_root session_id =
  let path = Filename.concat broker_root (session_id ^ ".inbox.json") in
  if not (Sys.file_exists path) then []
  else
    try
      let json = Yojson.Safe.from_file path in
      match json with
      | `List items ->
          List.map (fun item ->
            let open Yojson.Safe.Util in
            ( item |> member "from_alias" |> to_string,
              item |> member "content" |> to_string ))
            items
      | _ -> []
    with _ -> []

(* [#484 S1] Core invariant: approval verdicts are NOT drained from the broker
   unless they were actually delivered to kimi. When session_dir is missing,
   delivery fails and the verdict stays in the broker inbox — await-reply can
   still find it on next poll (which is the whole point of the fix). *)
let test_approval_verdict_kept_in_inbox_after_run_once () =
  with_broker_root_and_inbox
    [ ("reviewer", "ka_call_42 allow — looks fine") ]
    (fun broker_root ->
       let broker = C2c_mcp.Broker.create ~root:broker_root in
       (* No kimi session dir → 0 deliveries, verdict stays in broker. *)
       let n = C2c_kimi_notifier.run_once
         ~broker_root
         ~alias:"kimi-test"
         ~session_id:"kimi-test-session"
         ~tmux_pane:None
       in
       Alcotest.(check int) "0 deliveries (no session dir)" 0 n;
       let remaining = read_inbox_messages broker_root "kimi-test-session" in
       Alcotest.(check int) "approval verdict kept in broker inbox" 1 (List.length remaining);
       match remaining with
       | [from_alias, content] ->
           Alcotest.(check string) "from_alias preserved" "reviewer" from_alias;
           Alcotest.(check bool) "ka_ verdict still present" true (contains content "ka_call_42")
       | _ -> Alcotest.fail "expected exactly 1 message")

(* System events: before the fix they were drained (removed). After the fix they
   stay in the inbox (written back as to_skip). This is a semantic change but not
   a regression — system events in the inbox are harmless and await-reply ignores them. *)
let test_system_event_remains_in_inbox_after_run_once () =
  with_broker_root_and_inbox
    [ ("c2c-system", "some-alias registered") ]
    (fun broker_root ->
       let broker = C2c_mcp.Broker.create ~root:broker_root in
       let n = C2c_kimi_notifier.run_once
         ~broker_root
         ~alias:"kimi-test"
         ~session_id:"kimi-test-session"
         ~tmux_pane:None
       in
        Alcotest.(check int) "0 deliveries (no session dir)" 0 n;
       let remaining = read_inbox_messages broker_root "kimi-test-session" in
       Alcotest.(check int) "system event still in inbox" 1 (List.length remaining);
       match remaining with
       | [from_alias, _] ->
           Alcotest.(check string) "system event preserved" "c2c-system" from_alias
       | _ -> Alcotest.fail "expected exactly 1 message")

(* Mixed inbox: system event + approval verdict + regular DM.
   After run_once: all 3 remain in broker inbox (nothing drained).
   await-reply will find the approval verdict on next poll. *)
let test_mixed_messages_approval_verdict_kept () =
  with_broker_root_and_inbox
    [ ("c2c-system", "some-alias registered")
    ; ("reviewer", "ka_call_99 deny — looks dangerous")
    ; ("another-peer", "hello kimi")
    ]
    (fun broker_root ->
       let broker = C2c_mcp.Broker.create ~root:broker_root in
       let n = C2c_kimi_notifier.run_once
         ~broker_root
         ~alias:"kimi-test"
         ~session_id:"kimi-test-session"
         ~tmux_pane:None
       in
        Alcotest.(check int) "0 deliveries (no session dir)" 0 n;
       let remaining = read_inbox_messages broker_root "kimi-test-session" in
       Alcotest.(check int) "all 3 messages remain in inbox" 3 (List.length remaining);
       let contents = List.map snd remaining in
       Alcotest.(check bool) "ka_ verdict still present" true
         (List.exists (fun c -> contains c "ka_call_99") contents))

(* ─── Idle-detection tests (#590) ─────────────────────────────────────────── *)

let with_tmpdir f =
  let tmp = Filename.temp_file "kimi-notifier-test-" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o700;
  Fun.protect
    ~finally:(fun () ->
      let rec rmrf p =
        match (Unix.lstat p).Unix.st_kind with
        | Unix.S_DIR ->
          Array.iter (fun e -> rmrf (Filename.concat p e)) (Sys.readdir p);
          Unix.rmdir p
        | _ -> Unix.unlink p
        | exception _ -> ()
      in
      rmrf tmp)
    (fun () -> f tmp)

let touch_file path =
  let oc = open_out path in
  close_out oc

let set_mtime path t =
  Unix.utimes path t t

let test_kimi_session_is_idle_no_wire () =
  with_tmpdir (fun dir ->
    let now = Unix.gettimeofday () in
    Alcotest.(check bool) "no wire.jsonl → idle" true
      (C2c_kimi_notifier.kimi_session_is_idle ~session_dir:dir ~now ~threshold_s:2.0))

let test_kimi_session_is_idle_fresh_mtime () =
  with_tmpdir (fun dir ->
    let wire = Filename.concat dir "wire.jsonl" in
    touch_file wire;
    let now = Unix.gettimeofday () in
    set_mtime wire now;  (* now → busy *)
    Alcotest.(check bool) "fresh mtime → busy" false
      (C2c_kimi_notifier.kimi_session_is_idle ~session_dir:dir ~now ~threshold_s:2.0))

let test_kimi_session_is_idle_stale_mtime () =
  with_tmpdir (fun dir ->
    let wire = Filename.concat dir "wire.jsonl" in
    touch_file wire;
    let now = Unix.gettimeofday () in
    set_mtime wire (now -. 10.0);  (* 10s ago → idle *)
    Alcotest.(check bool) "stale mtime → idle" true
      (C2c_kimi_notifier.kimi_session_is_idle ~session_dir:dir ~now ~threshold_s:2.0))

let test_kimi_session_is_idle_threshold_boundary () =
  with_tmpdir (fun dir ->
    let wire = Filename.concat dir "wire.jsonl" in
    touch_file wire;
    let now = Unix.gettimeofday () in
    (* Strictly greater than threshold ⇒ idle. Equal-or-less ⇒ busy. *)
    set_mtime wire (now -. 1.5);
    Alcotest.(check bool) "1.5s ago < 2s threshold → busy" false
      (C2c_kimi_notifier.kimi_session_is_idle ~session_dir:dir ~now ~threshold_s:2.0);
    set_mtime wire (now -. 3.0);
    Alcotest.(check bool) "3s ago > 2s threshold → idle" true
      (C2c_kimi_notifier.kimi_session_is_idle ~session_dir:dir ~now ~threshold_s:2.0))

let () =
  Alcotest.run "c2c_kimi_notifier"
    [ "notification_id",
      [ Alcotest.test_case "deterministic + 12-char" `Quick test_notification_id_deterministic
      ; Alcotest.test_case "distinguishes by inputs" `Quick test_notification_id_distinguishes
      ]
    ; "workspace_hash",
      [ Alcotest.test_case "matches kimi-cli md5" `Quick test_workspace_hash_matches_kimi_md5 ]
    ; "session_id_resolve",
      [ Alcotest.test_case "missing config → None" `Quick test_resolve_session_id_missing_config
      ; Alcotest.test_case "reads config + returns uuid" `Quick test_resolve_session_id_reads_config
      ]
    ; "atomic_write",
      [ Alcotest.test_case "roundtrip content" `Quick test_atomic_write_string_roundtrip ]
    ; "system_event_filter_475",
      [ Alcotest.test_case "is_system_event predicate" `Quick test_is_system_event_predicate
      ; Alcotest.test_case "write_notification skips c2c-system" `Quick test_write_notification_skips_system_events
      ; Alcotest.test_case "write_notification writes real DM" `Quick test_write_notification_writes_real_dm
      ]
    ; "approval_verdict_filter_490",
      [ Alcotest.test_case "is_approval_verdict_body predicate" `Quick test_is_approval_verdict_body
      ]
    ; "chat_log_141",
      [ Alcotest.test_case "creates file with expected line" `Quick test_write_chat_log_creates_file_with_expected_line
      ; Alcotest.test_case "includes system events" `Quick test_write_chat_log_includes_system_events
      ; Alcotest.test_case "multiline body indented" `Quick test_write_chat_log_multiline_body
      ; Alcotest.test_case "appends multiple entries" `Quick test_write_chat_log_appends
      ]
    ; "idle_detection_590",
      [ Alcotest.test_case "no wire.jsonl → idle" `Quick test_kimi_session_is_idle_no_wire
      ; Alcotest.test_case "fresh mtime → busy" `Quick test_kimi_session_is_idle_fresh_mtime
      ; Alcotest.test_case "stale mtime → idle" `Quick test_kimi_session_is_idle_stale_mtime
      ; Alcotest.test_case "threshold boundary" `Quick test_kimi_session_is_idle_threshold_boundary
      ]
    ; "await_reply_race_484",
      [ Alcotest.test_case "approval verdict kept in inbox" `Quick test_approval_verdict_kept_in_inbox_after_run_once
      ; Alcotest.test_case "system event kept in inbox" `Quick test_system_event_remains_in_inbox_after_run_once
      ; Alcotest.test_case "mixed messages verdict preserved" `Quick test_mixed_messages_approval_verdict_kept
      ]
    ]
