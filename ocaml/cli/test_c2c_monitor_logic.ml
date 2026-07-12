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

(* ---------- B089: relay-inbox watcher source ---------- *)

(* A relay /peek_inbox response: { ok = true, messages = [...] }. Each message
   has the same field shape as a local broker message (the connector writes
   the relay JSON verbatim into the local inbox), which is what lets the relay
   source reuse the B070 seen set. *)
let relay_resp msgs = `Assoc [("ok", `Bool true); ("messages", `List msgs)]

let source_of = function
  | `Assoc f -> (match List.assoc_opt "source" f with Some (`String s) -> Some s | _ -> None)
  | _ -> None

let test_extract_relay_messages () =
  let m1 = msg ~mid:"r1" ~from:"remote" ~to_:"me" "hi" in
  let m2 = msg ~mid:"r2" ~from:"remote" ~to_:"me" "yo" in
  Alcotest.(check (list string)) "extracts both in order"
    ["hi"; "yo"] (contents (L.extract_relay_messages (relay_resp [m1; m2])));
  Alcotest.(check (list string)) "empty messages -> []"
    [] (contents (L.extract_relay_messages (relay_resp [])));
  Alcotest.(check (list string)) "missing messages field -> []"
    [] (contents (L.extract_relay_messages (`Assoc [("ok", `Bool true)])));
  Alcotest.(check (list string)) "non-assoc resp -> []"
    [] (contents (L.extract_relay_messages (`String "garbage")))

let test_tag_source () =
  let m = msg ~mid:"r1" ~from:"x" ~to_:"y" "hi" in
  Alcotest.(check (option string)) "tagged relay" (Some "relay")
    (source_of (L.tag_source "relay" m));
  (* idempotent: re-tagging overwrites rather than duplicating the field *)
  let double = L.tag_source "local" (L.tag_source "relay" m) in
  Alcotest.(check (option string)) "retagged to local" (Some "local")
    (source_of double);
  let count = match double with
    | `Assoc f -> List.length (List.filter (fun (k, _) -> k = "source") f)
    | _ -> 0 in
  Alcotest.(check int) "exactly one source field" 1 count;
  (* key stability: tagging does not change the dedup key *)
  Alcotest.(check string) "tag preserves msg_key"
    (L.msg_key m) (L.msg_key (L.tag_source "relay" m));
  Alcotest.(check bool) "non-assoc passes through unchanged" true
    (L.tag_source "relay" (`String "x") = `String "x")

(* Core B089 requirement: peek is NON-draining, so the same pending message
   appears in every peek response. The watcher must surface it ONCE, then stay
   quiet until a genuinely new message arrives. *)
let test_relay_surface_dedup_across_cycles () =
  let seen = L.create_seen () in
  let m = msg ~mid:"r1" ~from:"remote" ~to_:"me" "cross-host hello" in
  let resp = relay_resp [m] in
  let first = L.relay_msgs_to_surface seen (L.extract_relay_messages resp) in
  Alcotest.(check (list string)) "first peek surfaces the DM"
    ["cross-host hello"] (contents first);
  Alcotest.(check (option string)) "surfaced DM tagged relay"
    (Some "relay") (source_of (List.hd first));
  let second = L.relay_msgs_to_surface seen (L.extract_relay_messages resp) in
  Alcotest.(check (list string)) "second peek does NOT re-surface (non-draining dedup)"
    [] (contents second)

(* A relay-peeked DM and its later LOCAL archive echo share message_id (the
   connector preserves it on local delivery), so the SHARED seen set suppresses
   the local echo — no double-surface across sources. This is the integration
   with B070 the spec asked for. *)
let test_relay_surface_cross_source_dedup () =
  let seen = L.create_seen () in
  let m = msg ~mid:"relay-uuid-9" ~from:"remote" ~to_:"me" "via relay" in
  let relay_surfaced = L.relay_msgs_to_surface seen [m] in
  Alcotest.(check (list string)) "relay surfaces" ["via relay"] (contents relay_surfaced);
  (* The same message_id then arrives via the LOCAL path (inbox-watch/archive) *)
  let local_echo = L.filter_unseen seen [m] in
  Alcotest.(check (list string)) "local echo suppressed by shared seen set"
    [] (contents local_echo)

let test_relay_surface_order_preserving () =
  let seen = L.create_seen () in
  let msgs = [ msg ~mid:"a" ~from:"x" ~to_:"y" "1"
             ; msg ~mid:"b" ~from:"x" ~to_:"y" "2"
             ; msg ~mid:"c" ~from:"x" ~to_:"y" "3" ] in
  let out = L.relay_msgs_to_surface seen msgs in
  Alcotest.(check (list string)) "order preserved" ["1"; "2"; "3"] (contents out)

let dec_node_id = function
  | L.Relay_watch { node_id; _ } -> Some node_id
  | L.Relay_watch_off _ -> None

let dec_session_id = function
  | L.Relay_watch { session_id; _ } -> Some session_id
  | L.Relay_watch_off _ -> None

let test_decide_relay_watch_gating () =
  (* off: no relay URL configured *)
  Alcotest.(check bool) "no URL -> off" true
    (dec_node_id (L.decide_relay_watch ~my_alias:(Some "me")
       ~relay_url:None ~identity:None ~node_id_override:None ~session_id_override:None ())
     = None);
  (* off: no alias resolved (can't peek as anyone) *)
  Alcotest.(check bool) "no alias -> off" true
    (dec_node_id (L.decide_relay_watch ~my_alias:None
       ~relay_url:(Some "http://r") ~identity:None ~node_id_override:None ~session_id_override:None ())
     = None);
  (* on: default cli-<alias> convention (matches `relay register --alias`) *)
  Alcotest.(check string) "default node_id = cli-<alias>" "cli-me"
    (Option.get (dec_node_id (L.decide_relay_watch ~my_alias:(Some "me")
       ~relay_url:(Some "http://r") ~identity:None ~node_id_override:None ~session_id_override:None ())));
  (* on: explicit override for connector-managed aliases *)
  Alcotest.(check string) "override honoured" "machine-node-42"
    (Option.get (dec_node_id (L.decide_relay_watch ~my_alias:(Some "me")
       ~relay_url:(Some "http://r") ~identity:None
       ~node_id_override:(Some "machine-node-42") ~session_id_override:None ())));
  (* node_id override implies session_id = node_id (matches --help: "defaults
     to same as --relay-node-id"). *)
  Alcotest.(check string) "node_id override => session_id = node_id" "machine-node-42"
    (Option.get (dec_session_id (L.decide_relay_watch ~my_alias:(Some "me")
       ~relay_url:(Some "http://r") ~identity:None
       ~node_id_override:(Some "machine-node-42") ~session_id_override:None ())));
  (* explicit session_id still wins over the node_id-derived default *)
  Alcotest.(check string) "explicit session_id wins" "sess-7"
    (Option.get (dec_session_id (L.decide_relay_watch ~my_alias:(Some "me")
       ~relay_url:(Some "http://r") ~identity:None
       ~node_id_override:(Some "machine-node-42") ~session_id_override:(Some "sess-7") ())));
  (* neither overridden => both default to cli-<alias> (and are equal) *)
  Alcotest.(check string) "default node_id = session_id = cli-<alias>" "cli-me"
    (Option.get (dec_session_id (L.decide_relay_watch ~my_alias:(Some "me")
       ~relay_url:(Some "http://r") ~identity:None ~node_id_override:None ~session_id_override:None ())))

(* ---------- claude-full-delivery: full-body burst rendering ---------- *)

let long_body = String.concat " " (List.init 40 (fun i -> Printf.sprintf "w%d" i))

let test_burst_full_body_one_line_per_message () =
  (* Full-body mode must emit every body in a burst, whole — no collapse,
     no truncation (the old collapse truncated the first body to 60 chars
     and dropped bodies 2..N entirely). *)
  let bodies = [ long_body; "second full body"; "third full body" ] in
  Alcotest.(check (list string)) "one full subject per message"
    [ Printf.sprintf "\"%s\"" long_body
    ; "\"second full body\""
    ; "\"third full body\"" ]
    (L.burst_subjects ~full_body:true bodies)

let test_burst_full_body_single_untruncated () =
  Alcotest.(check (list string)) "single full body untruncated"
    [ Printf.sprintf "\"%s\"" long_body ]
    (L.burst_subjects ~full_body:true [ long_body ])

let test_burst_snippet_single_truncates_80 () =
  match L.burst_subjects ~full_body:false [ long_body ] with
  | [ s ] ->
      Alcotest.(check bool) "shorter than the full body" true
        (String.length s < String.length long_body);
      Alcotest.(check bool) "carries truncation marker" true
        (let n = String.length s in
         n > 4 && String.sub s (n - 4) 4 = "\xE2\x80\xA6\"")
  | other ->
      Alcotest.failf "expected one subject, got %d" (List.length other)

let test_burst_snippet_collapses_with_count () =
  match L.burst_subjects ~full_body:false [ long_body; "b2"; "b3" ] with
  | [ s ] ->
      Alcotest.(check bool) "has (3 msgs) count" true
        (String.length s >= 8 && String.sub s 0 8 = "(3 msgs)")
  | other ->
      Alcotest.failf "expected collapsed subject, got %d" (List.length other)

let test_burst_empty () =
  Alcotest.(check (list string)) "empty burst -> no subjects" []
    (L.burst_subjects ~full_body:true [])

(* ---------- H3: connector-managed relay peek key resolution ---------- *)

(* Core H3 identity fix: a connector-managed broker registers alias inboxes
   under (machine_node_id, local_session_id), NOT cli-<alias>. When the impure
   caller detects a connector manages this alias, that key must become the
   DEFAULT the bare monitor peeks — otherwise cross-host DMs pile up unseen. *)
let test_connector_key_becomes_default () =
  let ck = Some L.{ node_id = "host-abc123"; session_id = "sess-42" } in
  let k = L.resolve_relay_peek_key ~alias:"me"
            ~node_id_override:None ~session_id_override:None ~connector_key:ck () in
  Alcotest.(check string) "connector node_id used" "host-abc123" k.L.node_id;
  Alcotest.(check string) "connector session_id used" "sess-42" k.L.session_id

let test_no_connector_falls_back_to_cli_alias () =
  let k = L.resolve_relay_peek_key ~alias:"me"
            ~node_id_override:None ~session_id_override:None ~connector_key:None () in
  Alcotest.(check string) "node_id = cli-<alias>" "cli-me" k.L.node_id;
  Alcotest.(check string) "session_id = cli-<alias>" "cli-me" k.L.session_id

let test_explicit_override_beats_connector_key () =
  let ck = Some L.{ node_id = "host-abc123"; session_id = "sess-42" } in
  (* explicit --relay-node-id / --relay-session-id win over the connector default *)
  let k = L.resolve_relay_peek_key ~alias:"me"
            ~node_id_override:(Some "manual-node") ~session_id_override:(Some "manual-sess")
            ~connector_key:ck () in
  Alcotest.(check string) "override node_id wins" "manual-node" k.L.node_id;
  Alcotest.(check string) "override session_id wins" "manual-sess" k.L.session_id;
  (* --relay-node-id alone still implies node/node even with a connector key *)
  let k2 = L.resolve_relay_peek_key ~alias:"me"
             ~node_id_override:(Some "manual-node") ~session_id_override:None
             ~connector_key:ck () in
  Alcotest.(check string) "node-only override => session = node" "manual-node" k2.L.session_id

let test_decide_relay_watch_uses_connector_key () =
  let ck = Some L.{ node_id = "host-xyz"; session_id = "sess-9" } in
  match L.decide_relay_watch ~my_alias:(Some "me") ~relay_url:(Some "https://r")
          ~identity:None ~node_id_override:None ~session_id_override:None
          ~connector_key:ck () with
  | L.Relay_watch { node_id; session_id } ->
      Alcotest.(check string) "watch node_id = connector node" "host-xyz" node_id;
      Alcotest.(check string) "watch session_id = connector session" "sess-9" session_id
  | L.Relay_watch_off r -> Alcotest.failf "expected on, got off: %s" r

(* ---------- H3: relay /peek_inbox response classification ---------- *)

let outcome_msgs = function L.Peek_ok m -> contents m | _ -> [ "<not-ok>" ]

let str_contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else
    let found = ref false and i = ref 0 in
    while (not !found) && !i <= hl - nl do
      if String.sub haystack !i nl = needle then found := true;
      incr i
    done;
    !found

let test_classify_ok_true_yields_messages () =
  let m = msg ~mid:"r1" ~from:"remote" ~to_:"me" "hi" in
  (match L.classify_relay_response (relay_resp [ m ]) with
   | L.Peek_ok out -> Alcotest.(check (list string)) "ok:true -> messages" [ "hi" ] (contents out)
   | _ -> Alcotest.fail "expected Peek_ok")

let test_classify_legacy_no_ok_field_is_ok () =
  (* A relay that omits `ok` (legacy) is treated as success — messages are data. *)
  let m = msg ~mid:"r1" ~from:"remote" ~to_:"me" "hi" in
  let resp = `Assoc [ ("messages", `List [ m ]) ] in
  Alcotest.(check (list string)) "legacy no-ok -> messages" [ "hi" ]
    (outcome_msgs (L.classify_relay_response resp))

let test_classify_auth_error_is_terminal () =
  let resp = `Assoc [ ("ok", `Bool false)
                    ; ("error_code", `String "signature_invalid")
                    ; ("error", `String "Ed25519 request signature does not verify") ] in
  (match L.classify_relay_response resp with
   | L.Peek_terminal detail ->
       Alcotest.(check bool) "detail names the code" true
         (str_contains detail "signature_invalid")
   | _ -> Alcotest.fail "expected Peek_terminal for signature_invalid")

let test_classify_unauthorized_is_terminal () =
  let resp = `Assoc [ ("ok", `Bool false); ("error_code", `String "unauthorized")
                    ; ("error", `String "missing Authorization header") ] in
  (match L.classify_relay_response resp with
   | L.Peek_terminal _ -> ()
   | _ -> Alcotest.fail "expected Peek_terminal for unauthorized")

let test_classify_connection_error_is_transient () =
  (* relay_client.connection_error shape: network/timeout/invalid-json *)
  let resp = `Assoc [ ("ok", `Bool false); ("error_code", `String "connection_error")
                    ; ("error", `String "request_timeout") ] in
  (match L.classify_relay_response resp with
   | L.Peek_transient _ -> ()
   | _ -> Alcotest.fail "expected Peek_transient for connection_error")

let test_classify_unknown_code_defaults_transient () =
  (* An unrecognized error_code must NOT kill the monitor — default transient. *)
  let resp = `Assoc [ ("ok", `Bool false); ("error_code", `String "rate_limited")
                    ; ("error", `String "429") ] in
  (match L.classify_relay_response resp with
   | L.Peek_transient _ -> ()
   | _ -> Alcotest.fail "expected Peek_transient for unknown code")

let test_classify_malformed_is_transient () =
  (match L.classify_relay_response (`String "garbage") with
   | L.Peek_transient _ -> ()
   | _ -> Alcotest.fail "expected Peek_transient for non-object")

let test_is_terminal_error_code_taxonomy () =
  List.iter (fun c -> Alcotest.(check bool) (c ^ " terminal") true (L.is_terminal_error_code c))
    [ "unauthorized"; "signature_invalid"; "timestamp_out_of_window"
    ; "missing_proof_field"; "not_found"; "unknown_node"; "not_registered"; "bad_request" ];
  List.iter (fun c -> Alcotest.(check bool) (c ^ " transient") false (L.is_terminal_error_code c))
    [ "connection_error"; "pow_required"; "rate_limited"; ""; "peer_timeout" ]

(* Lock the classifier to the EXACT JSON the public HTTPS relay
   (https://relay.c2c.im) returns, captured live 2026-07-10 via a read-only
   /peek_inbox probe. Guards against the relay contract drifting away from the
   classifier's assumptions. *)
let test_classify_real_relay_json_strings () =
  let ok_empty = Yojson.Safe.from_string {|{"ok":true,"messages":[]}|} in
  Alcotest.(check (list string)) "real ok:true empty -> []" []
    (outcome_msgs (L.classify_relay_response ok_empty));
  let bad_req =
    Yojson.Safe.from_string
      {|{"ok":false,"error_code":"bad_request","error":"node_id and session_id are required"}|}
  in
  (match L.classify_relay_response bad_req with
   | L.Peek_terminal _ -> ()
   | _ -> Alcotest.fail "real bad_request should classify terminal")

let test_exit_code_distinct () =
  (* relay-terminal exit code must be distinct from generic usage/startup exit 1 *)
  Alcotest.(check bool) "relay terminal exit <> 1" true (L.exit_relay_terminal <> 1);
  Alcotest.(check bool) "relay terminal exit <> 0" true (L.exit_relay_terminal <> 0)

(* ---------- B142: relay-terminal teardown policy ---------- *)

(* Core B142 regression: a terminal relay-peek failure while a LOCAL inbox/
   archive watch is active must NOT tear down the process — the relay loop is
   disabled but local receive continues. Only a pure-relay monitor (no local
   watch) exits so a supervisor notices. *)
let test_terminal_with_local_watch_does_not_exit () =
  Alcotest.(check bool)
    "local watch active -> do NOT exit (log + stop relay loop only)"
    false
    (L.should_exit_on_relay_terminal ~local_watch_active:true)

let test_terminal_without_local_watch_exits () =
  Alcotest.(check bool)
    "no local watch (sole relay source) -> exit so supervisor notices"
    true
    (L.should_exit_on_relay_terminal ~local_watch_active:false)

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
    ; ( "relay-watcher-source",
        [ Alcotest.test_case "extract_relay_messages" `Quick test_extract_relay_messages
        ; Alcotest.test_case "tag_source adds source field" `Quick test_tag_source
        ; Alcotest.test_case "relay surface dedup across peek cycles" `Quick test_relay_surface_dedup_across_cycles
        ; Alcotest.test_case "relay surface cross-source dedup" `Quick test_relay_surface_cross_source_dedup
        ; Alcotest.test_case "relay surface order preserving" `Quick test_relay_surface_order_preserving
        ; Alcotest.test_case "decide_relay_watch gating" `Quick test_decide_relay_watch_gating
        ] )
    ; ( "full-body-burst",
        [ Alcotest.test_case "full body: one line per message" `Quick test_burst_full_body_one_line_per_message
        ; Alcotest.test_case "full body: single untruncated" `Quick test_burst_full_body_single_untruncated
        ; Alcotest.test_case "snippet: single truncates at 80" `Quick test_burst_snippet_single_truncates_80
        ; Alcotest.test_case "snippet: burst collapses with count" `Quick test_burst_snippet_collapses_with_count
        ; Alcotest.test_case "empty burst" `Quick test_burst_empty
        ] )
    ; ( "connector-managed-key",
        [ Alcotest.test_case "connector key becomes default" `Quick test_connector_key_becomes_default
        ; Alcotest.test_case "no connector falls back to cli-alias" `Quick test_no_connector_falls_back_to_cli_alias
        ; Alcotest.test_case "explicit override beats connector key" `Quick test_explicit_override_beats_connector_key
        ; Alcotest.test_case "decide_relay_watch uses connector key" `Quick test_decide_relay_watch_uses_connector_key
        ] )
    ; ( "relay-response-classification",
        [ Alcotest.test_case "ok:true yields messages" `Quick test_classify_ok_true_yields_messages
        ; Alcotest.test_case "legacy no-ok field is ok" `Quick test_classify_legacy_no_ok_field_is_ok
        ; Alcotest.test_case "auth error is terminal" `Quick test_classify_auth_error_is_terminal
        ; Alcotest.test_case "unauthorized is terminal" `Quick test_classify_unauthorized_is_terminal
        ; Alcotest.test_case "connection error is transient" `Quick test_classify_connection_error_is_transient
        ; Alcotest.test_case "unknown code defaults transient" `Quick test_classify_unknown_code_defaults_transient
        ; Alcotest.test_case "malformed is transient" `Quick test_classify_malformed_is_transient
        ; Alcotest.test_case "terminal error code taxonomy" `Quick test_is_terminal_error_code_taxonomy
        ; Alcotest.test_case "real public-relay json strings" `Quick test_classify_real_relay_json_strings
        ; Alcotest.test_case "relay terminal exit code distinct" `Quick test_exit_code_distinct
        ] )
    ; ( "relay-terminal-teardown",
        [ Alcotest.test_case "terminal + local watch active -> no exit" `Quick
            test_terminal_with_local_watch_does_not_exit
        ; Alcotest.test_case "terminal + no local watch -> exit" `Quick
            test_terminal_without_local_watch_exits
        ] )
    ]
