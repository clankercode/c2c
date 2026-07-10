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

(* J4: serialize_with_legacy appends legacy keys after the v1 fields and
   the result still validates (unknown top-level keys are tolerated). *)
let test_serialize_with_legacy () =
  let m : S.t =
    { schema_version = S.schema_version
    ; msg_type = S.Dm
    ; message_id = None
    ; ts = Some 1700000000.0
    ; from = { alias = "lyra-quill"; host_id = None; address = None }
    ; to_ = "storm-ember"
    ; source = None
    ; content = "hi"
    ; in_reply_to = None
    ; delivery_state = Some S.Queued
    }
  in
  let json =
    S.serialize_with_legacy m
      ~legacy:[ ("queued", `Bool true); ("from_alias", `String "lyra-quill") ]
  in
  (match json with
   | `Assoc fields ->
       Alcotest.(check bool) "legacy queued appended" true
         (List.assoc_opt "queued" fields = Some (`Bool true));
       Alcotest.(check bool) "legacy from_alias appended" true
         (List.assoc_opt "from_alias" fields = Some (`String "lyra-quill"));
       Alcotest.(check bool) "v1 content still present" true
         (List.assoc_opt "content" fields = Some (`String "hi"))
   | _ -> Alcotest.fail "serialize_with_legacy did not return an object");
  Alcotest.(check bool) "document with legacy keys still validates" true
    (is_ok (S.validate json))

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
          Alcotest.test_case "of_string parse error" `Quick test_of_string_parse_error;
          Alcotest.test_case "serialize_with_legacy appends + validates" `Quick test_serialize_with_legacy ] );
    ]
