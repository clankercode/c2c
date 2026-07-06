(* Unit tests for c2c_monitor_logic — the pure pieces of `c2c monitor`:
   B069 alias-resolution order, and B070 inbox/archive message dedup. *)

module L = C2c_monitor_logic

(* ---------- B069: alias resolution order ---------- *)

let source_eq a b = L.source_label a = L.source_label b

let alias_result = Alcotest.(pair (option string) (testable
  (fun ppf s -> Format.pp_print_string ppf (L.source_label s)) source_eq))

(* The core B069 regression: this session's OWN registration must win over the
   machine-global default-alias file (which any agent's `c2c init` clobbers). *)
let test_session_reg_beats_default_file () =
  let res =
    L.resolve_alias
      ~flag:None
      ~auto_env:None
      ~session_reg:(Some ("fable-scribe", "sess-123"))
      ~default_alias_file:(Some "codex-aivi-sola")   (* another agent's alias *)
      ~session_id_env:(Some "sess-123")
      ~single_alive:(Some "someone-else")
      ()
  in
  Alcotest.(check alias_result) "session reg wins"
    (Some "fable-scribe", L.Session_reg "sess-123") res

let test_flag_wins_over_everything () =
  let res =
    L.resolve_alias
      ~flag:(Some "explicit")
      ~auto_env:(Some "auto")
      ~session_reg:(Some ("sess-alias", "s"))
      ~default_alias_file:(Some "file")
      ~session_id_env:(Some "sid")
      ~single_alive:(Some "alive")
      ()
  in
  Alcotest.(check alias_result) "flag wins" (Some "explicit", L.Flag) res

let test_auto_env_beats_session_reg () =
  let res =
    L.resolve_alias
      ~flag:None
      ~auto_env:(Some "auto")
      ~session_reg:(Some ("sess-alias", "s"))
      ~default_alias_file:(Some "file")
      ~session_id_env:None
      ~single_alive:None
      ()
  in
  Alcotest.(check alias_result) "auto_env wins" (Some "auto", L.Auto_env) res

(* Fallback chain when neither flag, auto_env, nor a session registration
   resolves: default file, then session_id env, then single alive. *)
let test_default_file_fallback () =
  let res =
    L.resolve_alias ~flag:None ~auto_env:None ~session_reg:None
      ~default_alias_file:(Some "file-alias")
      ~session_id_env:(Some "sid") ~single_alive:(Some "alive") ()
  in
  Alcotest.(check alias_result) "default file used when no session reg"
    (Some "file-alias", L.Default_alias_file) res

let test_session_id_env_fallback () =
  let res =
    L.resolve_alias ~flag:None ~auto_env:None ~session_reg:None
      ~default_alias_file:None ~session_id_env:(Some "sid") ~single_alive:(Some "alive") ()
  in
  Alcotest.(check alias_result) "session_id env fallback"
    (Some "sid", L.Session_id_env) res

let test_single_alive_fallback () =
  let res =
    L.resolve_alias ~flag:None ~auto_env:None ~session_reg:None
      ~default_alias_file:None ~session_id_env:None ~single_alive:(Some "only-one") ()
  in
  Alcotest.(check alias_result) "single alive fallback"
    (Some "only-one", L.Single_alive) res

let test_unresolved () =
  let res =
    L.resolve_alias ~flag:None ~auto_env:None ~session_reg:None
      ~default_alias_file:None ~session_id_env:None ~single_alive:None ()
  in
  Alcotest.(check alias_result) "unresolved" (None, L.Unresolved) res

let test_is_fallback_source () =
  Alcotest.(check bool) "session reg is not fallback" false
    (L.is_fallback_source (L.Session_reg "s"));
  Alcotest.(check bool) "flag is not fallback" false (L.is_fallback_source L.Flag);
  Alcotest.(check bool) "auto env is not fallback" false (L.is_fallback_source L.Auto_env);
  Alcotest.(check bool) "default file IS fallback" true
    (L.is_fallback_source L.Default_alias_file);
  Alcotest.(check bool) "session id env IS fallback" true
    (L.is_fallback_source L.Session_id_env);
  Alcotest.(check bool) "single alive IS fallback" true
    (L.is_fallback_source L.Single_alive)

(* ---------- B070: dedup ---------- *)

let msg ?mid ~from ~to_ ?(ts = 1.0) content : Yojson.Safe.t =
  let base =
    [ ("from_alias", `String from)
    ; ("to_alias", `String to_)
    ; ("content", `String content)
    ; ("ts", `Float ts) ]
  in
  match mid with
  | Some m -> `Assoc (base @ [("message_id", `String m)])
  | None -> `Assoc base

let contents msgs =
  List.filter_map (function
    | `Assoc f -> (match List.assoc_opt "content" f with Some (`String s) -> Some s | _ -> None)
    | _ -> None) msgs

let test_msg_key_prefers_message_id () =
  let a = msg ~mid:"uuid-1" ~from:"x" ~to_:"y" "hello" in
  (* Same message_id, different content → same key (id is authoritative). *)
  let b = msg ~mid:"uuid-1" ~from:"x" ~to_:"y" "world" in
  Alcotest.(check string) "same id → same key" (L.msg_key a) (L.msg_key b)

let test_msg_key_content_fallback_distinguishes () =
  let a = msg ~from:"x" ~to_:"y" ~ts:1.0 "hello" in
  let b = msg ~from:"x" ~to_:"y" ~ts:2.0 "hello" in
  Alcotest.(check bool) "different ts → different key" false
    (L.msg_key a = L.msg_key b)

(* Room fanout: one room message lands in N peer archives, each tagged with the
   peer's own alias prefix on to_alias. Normalized key must collapse them. *)
let test_msg_key_room_fanout_collapses () =
  let a = msg ~from:"sender" ~to_:"coder1#lounge" ~ts:5.0 "hi room" in
  let b = msg ~from:"sender" ~to_:"planner1#lounge" ~ts:5.0 "hi room" in
  Alcotest.(check string) "room fanout collapses" (L.msg_key a) (L.msg_key b)

(* The core B070 dedup: inbox-peek surfaces a message, the later archive echo of
   the same message is suppressed. *)
let test_filter_unseen_suppresses_echo () =
  let seen = L.create_seen () in
  let m = msg ~mid:"m1" ~from:"a" ~to_:"b" "yo" in
  let first = L.filter_unseen seen [m] in
  Alcotest.(check (list string)) "first pass emits" ["yo"] (contents first);
  let echo = L.filter_unseen seen [m] in
  Alcotest.(check (list string)) "echo suppressed" [] (contents echo)

let test_filter_unseen_distinct_kept () =
  let seen = L.create_seen () in
  let m1 = msg ~mid:"m1" ~from:"a" ~to_:"b" "one" in
  let m2 = msg ~mid:"m2" ~from:"a" ~to_:"b" "two" in
  let out = L.filter_unseen seen [m1; m2; m1] in
  Alcotest.(check (list string)) "distinct kept, dup dropped in same batch"
    ["one"; "two"] (contents out)

let test_filter_unseen_keeps_nonobjects () =
  let seen = L.create_seen () in
  let junk : Yojson.Safe.t = `String "not-an-object" in
  let out = L.filter_unseen seen [junk; junk] in
  Alcotest.(check int) "non-objects always kept (uncomparable)" 2 (List.length out)

(* FIFO eviction: once an evicted key reappears it is treated as unseen again. *)
let test_seen_bounded_eviction () =
  let seen = L.create_seen ~cap:2 () in
  let m1 = msg ~mid:"k1" ~from:"a" ~to_:"b" "1" in
  let m2 = msg ~mid:"k2" ~from:"a" ~to_:"b" "2" in
  let m3 = msg ~mid:"k3" ~from:"a" ~to_:"b" "3" in
  ignore (L.filter_unseen seen [m1]);      (* seen: k1 *)
  ignore (L.filter_unseen seen [m2]);      (* seen: k1,k2 *)
  ignore (L.filter_unseen seen [m3]);      (* pushes out k1 → seen: k2,k3 *)
  Alcotest.(check bool) "k1 evicted (now unseen)" false (L.is_seen seen (L.msg_key m1));
  Alcotest.(check bool) "k3 still seen" true (L.is_seen seen (L.msg_key m3));
  let re = L.filter_unseen seen [m1] in
  Alcotest.(check (list string)) "evicted key re-emitted" ["1"] (contents re)

(* B084: archive filenames are session ids, not aliases. JSON mode previously
   compared the archive id against my_alias and suppressed this session's own
   archive when the two strings differed. *)
let test_archive_owner_uses_session_id () =
  Alcotest.(check bool) "own session archive" true
    (L.archive_owner_is_mine ~archive_id:"sid-123"
       ~my_alias:(Some "codex-ember-quill-a1b2")
       ~my_session_id:(Some "sid-123") ());
  Alcotest.(check bool) "other session archive" false
    (L.archive_owner_is_mine ~archive_id:"sid-456"
       ~my_alias:(Some "sid-456")
       ~my_session_id:(Some "sid-123") ());
  Alcotest.(check bool) "legacy alias fallback" true
    (L.archive_owner_is_mine ~archive_id:"codex-local"
       ~my_alias:(Some "codex-local") ~my_session_id:None ())

let () =
  Alcotest.run "c2c_monitor_logic"
    [ ( "alias-resolution-order",
        [ Alcotest.test_case "session reg beats default file" `Quick test_session_reg_beats_default_file
        ; Alcotest.test_case "flag wins over all" `Quick test_flag_wins_over_everything
        ; Alcotest.test_case "auto_env beats session reg" `Quick test_auto_env_beats_session_reg
        ; Alcotest.test_case "default file fallback" `Quick test_default_file_fallback
        ; Alcotest.test_case "session_id env fallback" `Quick test_session_id_env_fallback
        ; Alcotest.test_case "single alive fallback" `Quick test_single_alive_fallback
        ; Alcotest.test_case "unresolved" `Quick test_unresolved
        ; Alcotest.test_case "is_fallback_source classification" `Quick test_is_fallback_source
        ] )
    ; ( "dedup",
        [ Alcotest.test_case "msg_key prefers message_id" `Quick test_msg_key_prefers_message_id
        ; Alcotest.test_case "content-key distinguishes by ts" `Quick test_msg_key_content_fallback_distinguishes
        ; Alcotest.test_case "room fanout collapses" `Quick test_msg_key_room_fanout_collapses
        ; Alcotest.test_case "filter_unseen suppresses echo" `Quick test_filter_unseen_suppresses_echo
        ; Alcotest.test_case "filter_unseen keeps distinct" `Quick test_filter_unseen_distinct_kept
        ; Alcotest.test_case "filter_unseen keeps non-objects" `Quick test_filter_unseen_keeps_nonobjects
        ; Alcotest.test_case "seen set bounded eviction" `Quick test_seen_bounded_eviction
        ; Alcotest.test_case "archive owner uses session id" `Quick test_archive_owner_uses_session_id
        ] )
    ]
