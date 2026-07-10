(* test_c2c_schema_v1.ml — conformance vectors for the canonical lean v1
   c2c message/event JSON schema (C2c_schema_v1).

   Acceptance (reconciliation row J1): valid/invalid version, valid/invalid
   state, forward-compatibility, and optionality. Each vector below is
   labelled so the acceptance-criteria trace is legible. The vectors here are
   the authoritative conformance set; docs/reference/message-schema-v1.md
   mirrors representative ones for readers. *)

module S = C2c_schema_v1

let parse = Yojson.Safe.from_string

(* ---- helpers ---- *)

let is_ok = function Ok _ -> true | Error _ -> false
let is_err = function Ok _ -> false | Error _ -> true

let ok_of s = S.validate (parse s)

let check_ok label s =
  match ok_of s with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "%s: expected Ok, got Error %S" label e

let check_err label s =
  match ok_of s with
  | Error _ -> ()
  | Ok _ -> Alcotest.failf "%s: expected Error, got Ok" label

(* ---- canonical documents ---- *)

(* Full v1 document: every v1 field populated. *)
let full_doc =
  {|{
    "schema_version": 1,
    "type": "dm",
    "message_id": "m-123",
    "ts": 1700000000.0,
    "from": { "alias": "lyra-quill", "host_id": "h9", "address": "lyra-quill@h9" },
    "to": "storm-ember",
    "source": "relay",
    "content": "untrusted external text",
    "in_reply_to": "m-100",
    "delivery": { "state": "delivered" }
  }|}

(* Minimal v1 document: only the required fields. *)
let minimal_doc =
  {|{
    "schema_version": 1,
    "type": "room",
    "from": { "alias": "storm-ember" },
    "to": "swarm-lounge",
    "content": "hi"
  }|}

(* ---- VALID ---- *)

let test_valid_full () = check_ok "full_doc" full_doc

let test_valid_minimal () = check_ok "minimal_doc (optionality: only required)" minimal_doc

let test_valid_all_types () =
  List.iter
    (fun ty ->
      let s =
        Printf.sprintf
          {|{"schema_version":1,"type":"%s","from":{"alias":"a"},"to":"b","content":"c"}|}
          ty
      in
      check_ok (Printf.sprintf "type=%s" ty) s)
    [ "dm"; "room"; "system" ]

let test_valid_all_delivery_states () =
  List.iter
    (fun st ->
      let s =
        Printf.sprintf
          {|{"schema_version":1,"type":"dm","from":{"alias":"a"},"to":"b","content":"c","delivery":{"state":"%s"}}|}
          st
      in
      check_ok (Printf.sprintf "delivery.state=%s" st) s)
    [ "queued"; "accepted"; "delivered" ]

let test_valid_all_sources () =
  List.iter
    (fun src ->
      let s =
        Printf.sprintf
          {|{"schema_version":1,"type":"dm","from":{"alias":"a"},"to":"b","content":"c","source":"%s"}|}
          src
      in
      check_ok (Printf.sprintf "source=%s" src) s)
    [ "local"; "relay" ]

(* ---- INVALID VERSION ---- *)

let test_invalid_version_two () =
  check_err "schema_version=2 rejected"
    {|{"schema_version":2,"type":"dm","from":{"alias":"a"},"to":"b","content":"c"}|}

let test_invalid_version_missing () =
  check_err "missing schema_version rejected"
    {|{"type":"dm","from":{"alias":"a"},"to":"b","content":"c"}|}

let test_invalid_version_type () =
  check_err "schema_version as string rejected"
    {|{"schema_version":"1","type":"dm","from":{"alias":"a"},"to":"b","content":"c"}|}

(* ---- INVALID / UNKNOWN STATE (and other enums) ---- *)

let test_invalid_delivery_state_read () =
  (* `read` is deliberately DEFERRED (receipts / I004); not a v1 state. *)
  check_err "delivery.state=read rejected (deferred to v2)"
    {|{"schema_version":1,"type":"dm","from":{"alias":"a"},"to":"b","content":"c","delivery":{"state":"read"}}|}

let test_invalid_delivery_state_bogus () =
  check_err "delivery.state=bogus rejected"
    {|{"schema_version":1,"type":"dm","from":{"alias":"a"},"to":"b","content":"c","delivery":{"state":"bogus"}}|}

let test_invalid_type () =
  check_err "unknown type rejected"
    {|{"schema_version":1,"type":"broadcast","from":{"alias":"a"},"to":"b","content":"c"}|}

let test_invalid_source () =
  check_err "unknown source rejected"
    {|{"schema_version":1,"type":"dm","from":{"alias":"a"},"to":"b","content":"c","source":"carrier-pigeon"}|}

(* ---- MISSING REQUIRED ---- *)

let test_missing_from_alias () =
  check_err "missing from.alias rejected"
    {|{"schema_version":1,"type":"dm","from":{"host_id":"h"},"to":"b","content":"c"}|}

let test_empty_from_alias () =
  check_err "empty from.alias rejected"
    {|{"schema_version":1,"type":"dm","from":{"alias":"  "},"to":"b","content":"c"}|}

let test_missing_from () =
  check_err "missing from rejected"
    {|{"schema_version":1,"type":"dm","to":"b","content":"c"}|}

let test_missing_to () =
  check_err "missing to rejected"
    {|{"schema_version":1,"type":"dm","from":{"alias":"a"},"content":"c"}|}

let test_missing_content () =
  check_err "missing content rejected"
    {|{"schema_version":1,"type":"dm","from":{"alias":"a"},"to":"b"}|}

let test_not_object () = check_err "non-object document rejected" {|[1,2,3]|}

(* ---- COMPATIBILITY (forward-compat: reserved/unknown ignored) ---- *)

let test_forward_compat_reserved_from_keys () =
  (* v2 identity/trust fields must be tolerated and ignored, not rejected. *)
  let s =
    {|{
      "schema_version": 1, "type": "dm",
      "from": { "alias": "a", "identity_pk": "PK", "verified": true, "trust_tier": "trusted" },
      "to": "b", "content": "c"
    }|}
  in
  check_ok "reserved v2 from-keys ignored" s;
  (* and the reserved keys are NOT surfaced into from_addr *)
  match ok_of s with
  | Ok { from = { host_id = None; address = None; alias = "a" }; _ } -> ()
  | Ok _ -> Alcotest.fail "reserved keys leaked into from_addr"
  | Error e -> Alcotest.failf "unexpected Error %S" e

let test_forward_compat_reserved_top_key () =
  check_ok "reserved v2 top-level key (priority) ignored"
    {|{"schema_version":1,"type":"dm","from":{"alias":"a"},"to":"b","content":"c","priority":"interrupt"}|}

let test_forward_compat_unknown_top_key () =
  check_ok "unknown top-level key tolerated"
    {|{"schema_version":1,"type":"dm","from":{"alias":"a"},"to":"b","content":"c","future_field":42}|}

let test_forward_compat_unknown_delivery_key () =
  check_ok "unknown delivery sub-key tolerated"
    {|{"schema_version":1,"type":"dm","from":{"alias":"a"},"to":"b","content":"c","delivery":{"state":"queued","read_at":123}}|}

let test_reserved_key_lists_documented () =
  (* the contract advertises what it defers, so consumers can reason about it *)
  Alcotest.(check bool)
    "identity_pk reserved" true
    (List.mem "identity_pk" S.reserved_v2_from_keys);
  Alcotest.(check bool)
    "priority reserved" true
    (List.mem "priority" S.reserved_v2_keys)

(* ---- OPTIONALITY (serialization contract) ---- *)

let test_serialize_omits_none () =
  let m : S.t =
    { schema_version = S.schema_version
    ; msg_type = S.Dm
    ; message_id = None
    ; ts = None
    ; from = { alias = "a"; host_id = None; address = None }
    ; to_ = "b"
    ; source = None
    ; content = "c"
    ; in_reply_to = None
    ; delivery_state = None
    }
  in
  let j = S.serialize m in
  let keys = match j with `Assoc kvs -> List.map fst kvs | _ -> [] in
  (* only required keys present; no null-valued optionals *)
  Alcotest.(check (list string))
    "minimal serialization key set"
    [ "schema_version"; "type"; "from"; "to"; "content" ]
    keys;
  (* and it must validate *)
  Alcotest.(check bool) "minimal serialize round-trips" true (is_ok (S.validate j))

let test_serialize_full_roundtrip () =
  let m : S.t =
    { schema_version = S.schema_version
    ; msg_type = S.Room
    ; message_id = Some "m-1"
    ; ts = Some 1700000000.5
    ; from = { alias = "a"; host_id = Some "h"; address = Some "a@h" }
    ; to_ = "room"
    ; source = Some S.Relay
    ; content = "hello"
    ; in_reply_to = Some "m-0"
    ; delivery_state = Some S.Accepted
    }
  in
  match S.validate (S.serialize m) with
  | Ok m' ->
      Alcotest.(check bool) "roundtrip equal" true (m = m')
  | Error e -> Alcotest.failf "full roundtrip failed: %S" e

let test_of_string_parse_error () =
  Alcotest.(check bool) "of_string returns Error on bad JSON" true
    (is_err (S.of_string "{not json"))

(* ==== J3: monitor NDJSON message events (C2c_monitor_ndjson) ============

   `c2c monitor --json` message events converge on this v1 schema while
   preserving every pre-J3 legacy key additively. These vectors live here
   (not in the cli-side test_c2c_monitor_logic suite) because the shaping
   goes through C2c_schema_v1 in the c2c_mcp library, which that pure-logic
   test executable does not link. Acceptance (reconciliation row J3):
   local/relay source, one object per line, immediate flush, schema
   validation, legacy old-reader vector. *)

module N = C2c_monitor_ndjson

(* A raw broker message exactly as the monitor reads it from an inbox /
   archive line (legacy shape). *)
let raw_local_msg =
  `Assoc
    [ ("from_alias", `String "coder1")
    ; ("to_alias", `String "coordinator1")
    ; ("content", `String "build green, ready to merge")
    ; ("ts", `Float 1745241234.5)
    ; ("message_id", `String "m-778")
    ]

let assoc_of = function
  | `Assoc kvs -> kvs
  | _ -> Alcotest.fail "expected a JSON object"

let field kvs k =
  match List.assoc_opt k kvs with
  | Some v -> v
  | None -> Alcotest.failf "missing field %S" k

(* J3 AC: a local-source monitor message event validates against v1. *)
let test_monitor_local_event_validates () =
  let ev = N.message_event ~monitor_ts:"1745241234.567" ~source:"local" raw_local_msg in
  match S.validate ev with
  | Error e -> Alcotest.failf "local monitor event failed v1 validation: %S" e
  | Ok m ->
      Alcotest.(check bool) "source=Local" true (m.S.source = Some S.Local);
      Alcotest.(check bool) "type=Dm" true (m.S.msg_type = S.Dm);
      Alcotest.(check string) "from.alias" "coder1" m.S.from.S.alias;
      Alcotest.(check string) "to" "coordinator1" m.S.to_;
      Alcotest.(check string) "content" "build green, ready to merge" m.S.content;
      Alcotest.(check bool) "message_id" true (m.S.message_id = Some "m-778");
      Alcotest.(check bool) "ts" true (m.S.ts = Some 1745241234.5)

(* J3 AC: a relay-source monitor message event validates against v1 —
   both transport sources flow through the same shaping in one stream. *)
let test_monitor_relay_event_validates () =
  (* Relay-peeked messages arrive already tagged source:"relay" by
     C2c_monitor_logic.tag_source; the shaping must not duplicate the key. *)
  let raw =
    `Assoc
      [ ("source", `String "relay")
      ; ("from_alias", `String "remote-coder")
      ; ("to_alias", `String "coordinator1")
      ; ("content", `String "cross-host DM surfaced by relay peek")
      ; ("ts", `Float 1751961120.0)
      ; ("message_id", `String "r-42")
      ]
  in
  let ev = N.message_event ~monitor_ts:"1745241239.012" ~source:"relay" raw in
  (match S.validate ev with
   | Error e -> Alcotest.failf "relay monitor event failed v1 validation: %S" e
   | Ok m ->
       Alcotest.(check bool) "source=Relay" true (m.S.source = Some S.Relay);
       Alcotest.(check string) "from.alias" "remote-coder" m.S.from.S.alias);
  let kvs = assoc_of ev in
  Alcotest.(check int) "source key appears exactly once" 1
    (List.length (List.filter (fun (k, _) -> k = "source") kvs))

(* J3 AC (legacy old-reader vector): every pre-J3 field name is still
   present with its pre-J3 value — the exact keys gui/src/types.ts
   MessageEvent and tests/test_c2c_monitor.py consume. Unknown extra
   fields (e.g. "deferrable") survive verbatim. *)
let test_monitor_legacy_old_reader_vector () =
  let raw =
    `Assoc
      [ ("from_alias", `String "sender1")
      ; ("to_alias", `String "receiver1")
      ; ("content", `String "hello from monitor test")
      ; ("deferrable", `Bool false)
      ]
  in
  let ev = N.message_event ~monitor_ts:"1745241234.567" ~source:"local" raw in
  let kvs = assoc_of ev in
  Alcotest.(check bool) "event_type=message" true
    (field kvs "event_type" = `String "message");
  Alcotest.(check bool) "monitor_ts preserved" true
    (field kvs "monitor_ts" = `String "1745241234.567");
  Alcotest.(check bool) "from_alias preserved" true
    (field kvs "from_alias" = `String "sender1");
  Alcotest.(check bool) "to_alias preserved" true
    (field kvs "to_alias" = `String "receiver1");
  Alcotest.(check bool) "content preserved" true
    (field kvs "content" = `String "hello from monitor test");
  Alcotest.(check bool) "unknown extra field preserved" true
    (field kvs "deferrable" = `Bool false);
  (* and the v1 face is present too *)
  Alcotest.(check bool) "schema_version=1" true
    (field kvs "schema_version" = `Int 1);
  Alcotest.(check bool) "validates as v1" true (is_ok (S.validate ev))

(* Room fanout: per-peer inbox copies tag to_alias "<alias>#<room>"; the
   v1 face reports type=room / to=<room> while the raw to_alias survives
   for old readers. *)
let test_monitor_room_fanout_event () =
  let raw =
    `Assoc
      [ ("from_alias", `String "coder1")
      ; ("to_alias", `String "coordinator1#swarm-lounge")
      ; ("content", `String "joining the room")
      ; ("ts", `Float 1745241234.5)
      ]
  in
  let ev = N.message_event ~monitor_ts:"1745241234.567" ~source:"local" raw in
  (match S.validate ev with
   | Error e -> Alcotest.failf "room fanout event failed v1 validation: %S" e
   | Ok m ->
       Alcotest.(check bool) "type=Room" true (m.S.msg_type = S.Room);
       Alcotest.(check string) "to=room name" "swarm-lounge" m.S.to_);
  let kvs = assoc_of ev in
  Alcotest.(check bool) "raw to_alias preserved verbatim" true
    (field kvs "to_alias" = `String "coordinator1#swarm-lounge")

(* J3 fix (peer-review, J4 finding-6 family): a "<alias>#<12hexhash>"
   relay host-hash to_alias is a DM, never a room — classification is
   gated by the canonical [C2c_mcp_helpers.is_room_recipient]. *)
let test_monitor_host_hash_to_alias_is_dm () =
  let raw =
    `Assoc
      [ ("from_alias", `String "coder1")
      ; ("to_alias", `String "coordinator1#a1b2c3d4e5f6")
      ; ("content", `String "relay-addressed dm")
      ; ("ts", `Float 1745241234.5)
      ]
  in
  let ev = N.message_event ~monitor_ts:"1745241234.567" ~source:"relay" raw in
  (match S.validate ev with
   | Error e -> Alcotest.failf "host-hash event failed v1 validation: %S" e
   | Ok m ->
       Alcotest.(check bool) "type=Dm (host-hash suffix is not a room)" true
         (m.S.msg_type = S.Dm);
       Alcotest.(check string) "to keeps full tagged value" "coordinator1#a1b2c3d4e5f6" m.S.to_);
  let kvs = assoc_of ev in
  Alcotest.(check bool) "raw to_alias preserved verbatim" true
    (field kvs "to_alias" = `String "coordinator1#a1b2c3d4e5f6")

(* Explicit room_id field (archive/room-history shape) wins over the
   to_alias heuristic and is itself preserved as a legacy key. *)
let test_monitor_room_id_field_event () =
  let raw =
    `Assoc
      [ ("from_alias", `String "coder1")
      ; ("to_alias", `String "swarm-lounge")
      ; ("content", `String "hi room")
      ; ("room_id", `String "swarm-lounge")
      ; ("event", `String "room_message")
      ]
  in
  let ev = N.message_event ~monitor_ts:"1745241234.567" ~source:"local" raw in
  (match S.validate ev with
   | Error e -> Alcotest.failf "room_id event failed v1 validation: %S" e
   | Ok m ->
       Alcotest.(check bool) "type=Room" true (m.S.msg_type = S.Room);
       Alcotest.(check string) "to=room_id" "swarm-lounge" m.S.to_);
  let kvs = assoc_of ev in
  Alcotest.(check bool) "room_id preserved" true
    (field kvs "room_id" = `String "swarm-lounge");
  Alcotest.(check bool) "event preserved" true
    (field kvs "event" = `String "room_message")

(* Pre-J3 behaviour: a non-object inbox entry passes through unshaped. *)
let test_monitor_non_object_passthrough () =
  let raw = `String "not an object" in
  Alcotest.(check bool) "non-object unchanged" true
    (N.message_event ~monitor_ts:"1.000" ~source:"local" raw = raw)

(* J3 AC (one object per line): consecutive emit_line writes produce
   exactly one compact JSON object per '\n'-terminated line — no
   pretty-printing, no embedded newlines, no blank separator lines. *)
let test_monitor_ndjson_one_object_per_line () =
  let path = Filename.temp_file "j3-ndjson" ".out" in
  Fun.protect ~finally:(fun () -> try Sys.remove path with _ -> ()) (fun () ->
    let oc = open_out path in
    let ev1 = N.message_event ~monitor_ts:"1.000" ~source:"local" raw_local_msg in
    let ev2 = N.message_event ~monitor_ts:"2.000" ~source:"relay" raw_local_msg in
    N.emit_line oc ev1;
    N.emit_line oc ev2;
    close_out oc;
    let ic = open_in path in
    let contents =
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        really_input_string ic (in_channel_length ic))
    in
    Alcotest.(check bool) "stream ends with newline" true
      (String.length contents > 0 && contents.[String.length contents - 1] = '\n');
    let lines =
      String.split_on_char '\n' contents
      |> List.filter (fun l -> l <> "")
    in
    Alcotest.(check int) "two events -> two lines" 2 (List.length lines);
    (* every line is a complete JSON object that validates as v1 *)
    List.iter
      (fun line ->
        match S.of_string line with
        | Ok _ -> ()
        | Error e -> Alcotest.failf "line is not a valid v1 object: %S (%s)" line e)
      lines;
    (* no blank lines / pretty-printing: raw split yields exactly 3 parts
       (two lines + trailing ""), so there are no interior empty lines *)
    Alcotest.(check int) "no interior blank lines" 3
      (List.length (String.split_on_char '\n' contents)))

(* J3 AC (immediate flush): the line is readable from the file BEFORE the
   channel is closed — emit_line flushes after every event, so a
   line-by-line subprocess consumer never waits on a buffered line. *)
let test_monitor_ndjson_immediate_flush () =
  let path = Filename.temp_file "j3-flush" ".out" in
  Fun.protect ~finally:(fun () -> try Sys.remove path with _ -> ()) (fun () ->
    let oc = open_out path in
    Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      let ev = N.message_event ~monitor_ts:"1.000" ~source:"local" raw_local_msg in
      N.emit_line oc ev;
      (* read back while oc is STILL OPEN: only a flushed write is visible *)
      let ic = open_in path in
      let contents =
        Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
          really_input_string ic (in_channel_length ic))
      in
      Alcotest.(check bool) "flushed line visible before close" true
        (String.length contents > 0
         && contents.[String.length contents - 1] = '\n');
      match S.of_string (String.trim contents) with
      | Ok _ -> ()
      | Error e -> Alcotest.failf "flushed line not a valid v1 object: %s" e))

let () =
  Alcotest.run "c2c_schema_v1"
    [ ( "valid",
        [ Alcotest.test_case "full document" `Quick test_valid_full;
          Alcotest.test_case "minimal document (optionality)" `Quick test_valid_minimal;
          Alcotest.test_case "all types" `Quick test_valid_all_types;
          Alcotest.test_case "all delivery states" `Quick test_valid_all_delivery_states;
          Alcotest.test_case "all sources" `Quick test_valid_all_sources ] );
      ( "invalid-version",
        [ Alcotest.test_case "version 2 rejected" `Quick test_invalid_version_two;
          Alcotest.test_case "missing version rejected" `Quick test_invalid_version_missing;
          Alcotest.test_case "non-int version rejected" `Quick test_invalid_version_type ] );
      ( "invalid-state",
        [ Alcotest.test_case "delivery.state=read deferred" `Quick test_invalid_delivery_state_read;
          Alcotest.test_case "delivery.state bogus" `Quick test_invalid_delivery_state_bogus;
          Alcotest.test_case "unknown type" `Quick test_invalid_type;
          Alcotest.test_case "unknown source" `Quick test_invalid_source ] );
      ( "missing-required",
        [ Alcotest.test_case "missing from.alias" `Quick test_missing_from_alias;
          Alcotest.test_case "empty from.alias" `Quick test_empty_from_alias;
          Alcotest.test_case "missing from" `Quick test_missing_from;
          Alcotest.test_case "missing to" `Quick test_missing_to;
          Alcotest.test_case "missing content" `Quick test_missing_content;
          Alcotest.test_case "non-object" `Quick test_not_object ] );
      ( "compatibility",
        [ Alcotest.test_case "reserved v2 from-keys ignored" `Quick test_forward_compat_reserved_from_keys;
          Alcotest.test_case "reserved v2 top key ignored" `Quick test_forward_compat_reserved_top_key;
          Alcotest.test_case "unknown top key tolerated" `Quick test_forward_compat_unknown_top_key;
          Alcotest.test_case "unknown delivery sub-key tolerated" `Quick test_forward_compat_unknown_delivery_key;
          Alcotest.test_case "reserved key lists documented" `Quick test_reserved_key_lists_documented ] );
      ( "optionality",
        [ Alcotest.test_case "serialize omits None" `Quick test_serialize_omits_none;
          Alcotest.test_case "full roundtrip" `Quick test_serialize_full_roundtrip;
          Alcotest.test_case "of_string parse error" `Quick test_of_string_parse_error ] );
      ( "monitor-ndjson (J3)",
        [ Alcotest.test_case "local event validates as v1" `Quick test_monitor_local_event_validates;
          Alcotest.test_case "relay event validates as v1" `Quick test_monitor_relay_event_validates;
          Alcotest.test_case "legacy old-reader vector" `Quick test_monitor_legacy_old_reader_vector;
          Alcotest.test_case "room fanout to_alias" `Quick test_monitor_room_fanout_event;
          Alcotest.test_case "host-hash to_alias is DM" `Quick test_monitor_host_hash_to_alias_is_dm;
          Alcotest.test_case "explicit room_id field" `Quick test_monitor_room_id_field_event;
          Alcotest.test_case "non-object passthrough" `Quick test_monitor_non_object_passthrough;
          Alcotest.test_case "one object per line" `Quick test_monitor_ndjson_one_object_per_line;
          Alcotest.test_case "immediate flush" `Quick test_monitor_ndjson_immediate_flush ] );
    ]
