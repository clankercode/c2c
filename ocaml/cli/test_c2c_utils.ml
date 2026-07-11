(* test_c2c_utils.ml — tests for C2c_utils helpers *)

(* Replicates the with_env pattern from test_c2c_stats.ml:
   Unix.putenv key "" to unset, Fun.protect for cleanup. *)
let with_env key value f =
  let old = Sys.getenv_opt key in
  (match value with
   | "" -> Unix.putenv key ""
   | v -> Unix.putenv key v);
  Fun.protect ~finally:(fun () ->
    match old with
    | Some v -> Unix.putenv key v
    | None -> ())
    f

let test_some_trimmed () =
  (* Whitespace-only values are treated as absent (matches C2c_utils behavior) *)
  Alcotest.(check (option string)) "whitespace-only → None"
    None
    (with_env "C2C_MCP_AUTO_REGISTER_ALIAS" "   " (fun () -> C2c_utils.alias_from_env_only ()))

let test_some_with_whitespace () =
  Alcotest.(check (option string)) "spaces around value trimmed"
    (Some "peer-alias")
    (with_env "C2C_MCP_AUTO_REGISTER_ALIAS" "  peer-alias  " (fun () -> C2c_utils.alias_from_env_only ()))

let test_none_on_empty () =
  Alcotest.(check (option string)) "empty string → None"
    None
    (with_env "C2C_MCP_AUTO_REGISTER_ALIAS" "" (fun () -> C2c_utils.alias_from_env_only ()))

let test_some_plain () =
  Alcotest.(check (option string)) "plain value → Some"
    (Some "test-alias")
    (with_env "C2C_MCP_AUTO_REGISTER_ALIAS" "test-alias" (fun () -> C2c_utils.alias_from_env_only ()))

(* Tests for trimmed_env_value (#518): treats empty-string env values as unset. *)
let test_trimmed_env_empty_string () =
  Alcotest.(check (option string)) "empty string → None"
    None
    (with_env "C2C_TEST_TRIMMED_518" "" (fun () -> C2c_utils.trimmed_env_value "C2C_TEST_TRIMMED_518"))

let test_trimmed_env_whitespace_only () =
  Alcotest.(check (option string)) "whitespace-only → None"
    None
    (with_env "C2C_TEST_TRIMMED_518" "   " (fun () -> C2c_utils.trimmed_env_value "C2C_TEST_TRIMMED_518"))

let test_trimmed_env_value_trimmed () =
  Alcotest.(check (option string)) "value with surrounding whitespace → trimmed"
    (Some "/my/broker/root")
    (with_env "C2C_TEST_TRIMMED_518" "  /my/broker/root  " (fun () -> C2c_utils.trimmed_env_value "C2C_TEST_TRIMMED_518"))

let test_trimmed_env_plain () =
  Alcotest.(check (option string)) "plain value → Some"
    (Some "/canonical/broker/root")
    (with_env "C2C_TEST_TRIMMED_518" "/canonical/broker/root" (fun () -> C2c_utils.trimmed_env_value "C2C_TEST_TRIMMED_518"))

(* ------------------------------------------------------------------ *)
(* J2: schema-v1 adaptation of CLI --json results (send / poll-inbox /
   peek-inbox / relay dm send|poll|peek). Every adapted row must:
   (a) validate as canonical v1 via C2c_schema_v1.validate,
   (b) preserve all legacy keys at unchanged values (old-reader vector),
   (c) contain no duplicate JSON keys. *)

let mk_msg ?message_id ?(to_alias = "zz-j2recv") () : C2c_mcp.message =
  { C2c_mcp.from_alias = "zz-j2send"
  ; to_alias
  ; content = "hello j2"
  ; deferrable = false
  ; reply_via = None
  ; enc_status = None
  ; ts = 1700000000.5
  ; ephemeral = false
  ; message_id
  ; pow_difficulty = None
  }

let assoc_keys = function
  | `Assoc kv -> List.map fst kv
  | _ -> Alcotest.fail "expected JSON object"

let check_no_dup_keys json =
  let keys = assoc_keys json in
  Alcotest.(check int) "no duplicate JSON keys"
    (List.length (List.sort_uniq compare keys))
    (List.length keys)

let get json key =
  match json with
  | `Assoc kv -> (
      match List.assoc_opt key kv with
      | Some v -> v
      | None -> Alcotest.fail (Printf.sprintf "missing key %S" key))
  | _ -> Alcotest.fail "expected JSON object"

let get_str json key =
  match get json key with
  | `String s -> s
  | _ -> Alcotest.fail (Printf.sprintf "key %S not a string" key)

let check_valid_v1 json =
  match C2c_schema_v1.validate json with
  | Ok _ -> ()
  | Error e -> Alcotest.fail ("v1 validate failed: " ^ e)

let delivery_state_of json =
  get_str (get json "delivery") "state"

let test_inbox_row_drain_delivered () =
  let row =
    C2c_utils.inbox_message_row_json
      ~delivery_state:C2c_schema_v1.Delivered (mk_msg ())
  in
  check_valid_v1 row;
  check_no_dup_keys row;
  Alcotest.(check string) "type dm" "dm" (get_str row "type");
  Alcotest.(check string) "delivered" "delivered" (delivery_state_of row);
  (match get row "source" with
   | exception _ -> ()
   | _ -> Alcotest.fail "source must be omitted on local inbox rows")

let test_inbox_row_peek_queued () =
  let row =
    C2c_utils.inbox_message_row_json
      ~delivery_state:C2c_schema_v1.Queued (mk_msg ())
  in
  check_valid_v1 row;
  Alcotest.(check string) "queued" "queued" (delivery_state_of row)

(* Old-reader vector: an existing consumer reading the legacy keys sees
   the exact same values as before the J2 adaptation. *)
let test_inbox_row_old_reader_vector () =
  let row =
    C2c_utils.inbox_message_row_json
      ~delivery_state:C2c_schema_v1.Delivered
      (mk_msg ~message_id:"m-42" ())
  in
  Alcotest.(check string) "legacy from_alias" "zz-j2send" (get_str row "from_alias");
  Alcotest.(check string) "legacy to_alias" "zz-j2recv" (get_str row "to_alias");
  Alcotest.(check string) "legacy content" "hello j2" (get_str row "content");
  (match get row "ts" with
   | `Float f -> Alcotest.(check (float 0.0)) "legacy ts" 1700000000.5 f
   | _ -> Alcotest.fail "ts not a float");
  Alcotest.(check string) "message_id via v1" "m-42" (get_str row "message_id");
  check_no_dup_keys row

let test_inbox_row_room_classified () =
  let row =
    C2c_utils.inbox_message_row_json ~delivery_state:C2c_schema_v1.Delivered
      (mk_msg ~to_alias:"zz-j2recv#zz-lounge" ())
  in
  check_valid_v1 row;
  Alcotest.(check string) "room row" "room" (get_str row "type")

(* Pin: a `<alias>#<12-lowercase-hex>` host-hash suffix is a cross-host
   DM, NOT a room (canonical classifier C2c_mcp_helpers.is_room_recipient). *)
let test_inbox_row_host_hash_is_dm () =
  let row =
    C2c_utils.inbox_message_row_json ~delivery_state:C2c_schema_v1.Delivered
      (mk_msg ~to_alias:"zz-j2recv#0123456789ab" ())
  in
  check_valid_v1 row;
  Alcotest.(check string) "host-hash suffix is dm" "dm" (get_str row "type")

let test_send_receipt_local_delivered () =
  let receipt =
    C2c_utils.cli_send_receipt_json ~ts:1700000001.0 ~from_alias:"zz-j2send"
      ~to_:"zz-j2recv" ~content:"hello j2"
      ~delivery_state:C2c_schema_v1.Delivered
      ~legacy_target_fields:[ ("to_alias", `String "zz-j2recv") ]
      ()
  in
  check_valid_v1 receipt;
  check_no_dup_keys receipt;
  Alcotest.(check string) "delivered" "delivered" (delivery_state_of receipt);
  (match get receipt "queued" with
   | `Bool true -> ()
   | _ -> Alcotest.fail "legacy queued:true missing");
  Alcotest.(check string) "legacy from_alias" "zz-j2send"
    (get_str receipt "from_alias");
  Alcotest.(check string) "legacy to_alias" "zz-j2recv"
    (get_str receipt "to_alias")

let test_send_receipt_remote_queued_with_warning () =
  let receipt =
    C2c_utils.cli_send_receipt_json ~ts:1700000001.0 ~from_alias:"zz-j2send"
      ~to_:"zz-j2recv@deadbeef1234" ~content:"hello j2"
      ~delivery_state:C2c_schema_v1.Queued
      ~delivery_warning:"queued locally; no relay connector detected"
      ~legacy_target_fields:[ ("to_alias", `String "zz-j2recv@deadbeef1234") ]
      ~compacting_warning:"recipient compacting for 12s"
      ()
  in
  check_valid_v1 receipt;
  check_no_dup_keys receipt;
  Alcotest.(check string) "queued" "queued" (delivery_state_of receipt);
  Alcotest.(check string) "delivery.warning preserved"
    "queued locally; no relay connector detected"
    (get_str (get receipt "delivery") "warning");
  Alcotest.(check string) "compacting_warning preserved"
    "recipient compacting for 12s" (get_str receipt "compacting_warning");
  (* remote target embeds @host — must not be misread as a room *)
  Alcotest.(check string) "send receipt is dm" "dm" (get_str receipt "type")

let test_relay_dm_send_accepted () =
  let raw =
    `Assoc [ ("ok", `Bool true); ("ts", `Float 1700000002.0)
           ; ("duplicate", `Bool true) ]
  in
  let adapted =
    C2c_utils.adapt_relay_dm_send_result ~from_alias:"zz-j2send"
      ~to_alias:"zz-j2recv" ~content:"hi relay" raw
  in
  check_valid_v1 adapted;
  check_no_dup_keys adapted;
  Alcotest.(check string) "relay ack is accepted" "accepted"
    (delivery_state_of adapted);
  Alcotest.(check string) "source relay" "relay" (get_str adapted "source");
  (match get adapted "ok" with
   | `Bool true -> ()
   | _ -> Alcotest.fail "legacy ok:true missing");
  (match get adapted "duplicate" with
   | `Bool true -> ()
   | _ -> Alcotest.fail "legacy duplicate:true missing");
  (match get adapted "ts" with
   | `Float f -> Alcotest.(check (float 0.0)) "legacy ts value" 1700000002.0 f
   | _ -> Alcotest.fail "ts not a float")

let test_relay_dm_send_error_passthrough () =
  let raw = `Assoc [ ("ok", `Bool false); ("error", `String "unknown_alias") ] in
  let adapted =
    C2c_utils.adapt_relay_dm_send_result ~from_alias:"zz-j2send"
      ~to_alias:"zz-j2recv" ~content:"hi" raw
  in
  Alcotest.(check bool) "error response unchanged" true (raw = adapted)

let relay_row ?(to_alias = "zz-j2recv#0123456789ab") () =
  `Assoc
    [ ("message_id", `String "r-77"); ("from_alias", `String "zz-j2send")
    ; ("to_alias", `String to_alias); ("content", `String "over the wire")
    ; ("ts", `Float 1700000003.0) ]

let relay_inbox_result rows = `Assoc [ ("ok", `Bool true); ("messages", `List rows) ]

let messages_of json =
  match get json "messages" with
  | `List l -> l
  | _ -> Alcotest.fail "messages not a list"

let test_relay_dm_poll_delivered () =
  let adapted =
    C2c_utils.adapt_relay_dm_inbox_result
      ~delivery_state:C2c_schema_v1.Delivered
      (relay_inbox_result [ relay_row () ])
  in
  (match get adapted "ok" with
   | `Bool true -> ()
   | _ -> Alcotest.fail "legacy ok:true missing");
  match messages_of adapted with
  | [ row ] ->
      check_valid_v1 row;
      check_no_dup_keys row;
      Alcotest.(check string) "poll rows delivered" "delivered"
        (delivery_state_of row);
      Alcotest.(check string) "source relay" "relay" (get_str row "source");
      (* host-hash relay address pin: DM, not room *)
      Alcotest.(check string) "host-hash relay row is dm" "dm"
        (get_str row "type");
      (* old-reader vector on the relay row *)
      Alcotest.(check string) "legacy message_id" "r-77" (get_str row "message_id");
      Alcotest.(check string) "legacy from_alias" "zz-j2send" (get_str row "from_alias");
      Alcotest.(check string) "legacy to_alias" "zz-j2recv#0123456789ab" (get_str row "to_alias");
      Alcotest.(check string) "legacy content" "over the wire" (get_str row "content")
  | _ -> Alcotest.fail "expected exactly one adapted row"

let test_relay_dm_peek_queued () =
  let adapted =
    C2c_utils.adapt_relay_dm_inbox_result ~delivery_state:C2c_schema_v1.Queued
      (relay_inbox_result [ relay_row ~to_alias:"zz-j2recv" () ])
  in
  match messages_of adapted with
  | [ row ] ->
      check_valid_v1 row;
      Alcotest.(check string) "peek rows queued" "queued" (delivery_state_of row)
  | _ -> Alcotest.fail "expected exactly one adapted row"

let test_relay_dm_poll_empty_batch_shape () =
  let raw = relay_inbox_result [] in
  let adapted =
    C2c_utils.adapt_relay_dm_inbox_result
      ~delivery_state:C2c_schema_v1.Delivered raw
  in
  Alcotest.(check bool) "empty batch keeps exact legacy shape" true
    (raw = adapted)

let test_relay_dm_malformed_row_passthrough () =
  (* row missing v1-required content: passed through untouched *)
  let bad = `Assoc [ ("from_alias", `String "x"); ("to_alias", `String "y") ] in
  let adapted =
    C2c_utils.adapt_relay_dm_inbox_result
      ~delivery_state:C2c_schema_v1.Delivered
      (relay_inbox_result [ bad ])
  in
  match messages_of adapted with
  | [ row ] -> Alcotest.(check bool) "malformed row unchanged" true (row = bad)
  | _ -> Alcotest.fail "expected exactly one row"

(* ==== J5: aggregate I002 closure gate (CLI half) =========================

   One sweep over every v1-adapted CLI surface in one place, each row
   constructed via its REAL production builder and gate-checked:
   validates as v1, round-trips (validate -> serialize -> validate to
   the same record), and carries no duplicate JSON keys.

   Surfaces swept here:
     - CLI send --json receipt          (C2c_utils.cli_send_receipt_json)
     - CLI poll-inbox / peek-inbox rows (C2c_utils.inbox_message_row_json)
     - CLI relay dm send ack            (C2c_utils.adapt_relay_dm_send_result)
     - CLI relay dm poll/peek rows      (C2c_utils.adapt_relay_dm_inbox_result)

   The library-half of the same gate (MCP poll/peek/send receipt rows and
   monitor NDJSON events) is the "aggregate-gate (J5/I002)" group in
   ocaml/test/test_c2c_schema_v1.ml — the CLI builders are modules of the
   c2c executable, not linkable from ocaml/test/, hence this split.
   Together the two tests close I002: if any adapted surface drifts off
   v1, one of them fails. *)

let gate_roundtrip ~what json =
  match C2c_schema_v1.validate json with
  | Error e -> Alcotest.failf "%s: failed v1 validation: %s" what e
  | Ok m ->
      (match C2c_schema_v1.validate (C2c_schema_v1.serialize m) with
       | Ok m' ->
           if m <> m' then
             Alcotest.failf "%s: validate/serialize round-trip not stable" what
       | Error e ->
           Alcotest.failf "%s: round-trip re-validation failed: %s" what e)

let gate_check ~what json =
  check_no_dup_keys json;
  (match get json "delivery" with
   | exception _ -> ()
   | d -> check_no_dup_keys d);
  gate_roundtrip ~what json

let test_aggregate_gate_cli_surfaces () =
  (* CLI poll-inbox (drained) + peek-inbox (queued) rows *)
  gate_check ~what:"cli poll-inbox row"
    (C2c_utils.inbox_message_row_json
       ~delivery_state:C2c_schema_v1.Delivered (mk_msg ~message_id:"m-g1" ()));
  gate_check ~what:"cli peek-inbox row"
    (C2c_utils.inbox_message_row_json
       ~delivery_state:C2c_schema_v1.Queued (mk_msg ()));
  gate_check ~what:"cli inbox row (room fanout)"
    (C2c_utils.inbox_message_row_json
       ~delivery_state:C2c_schema_v1.Delivered
       (mk_msg ~to_alias:"zz-j2recv#zz-lounge" ()));
  gate_check ~what:"cli inbox row (host-hash dm)"
    (C2c_utils.inbox_message_row_json
       ~delivery_state:C2c_schema_v1.Queued
       (mk_msg ~to_alias:"zz-j2recv#0123456789ab" ()));
  (* CLI send --json receipt: local-delivered and remote-queued+warnings *)
  gate_check ~what:"cli send receipt (local delivered)"
    (C2c_utils.cli_send_receipt_json ~ts:1700000001.0 ~from_alias:"zz-j2send"
       ~to_:"zz-j2recv" ~content:"hello j2"
       ~delivery_state:C2c_schema_v1.Delivered
       ~legacy_target_fields:[ ("to_alias", `String "zz-j2recv") ]
       ());
  gate_check ~what:"cli send receipt (remote queued + warnings)"
    (C2c_utils.cli_send_receipt_json ~ts:1700000001.0 ~from_alias:"zz-j2send"
       ~to_:"zz-j2recv@deadbeef1234" ~content:"hello j2"
       ~delivery_state:C2c_schema_v1.Queued
       ~delivery_warning:"queued locally; no relay connector detected"
       ~legacy_target_fields:
         [ ("to_alias", `String "zz-j2recv@deadbeef1234") ]
       ~compacting_warning:"recipient compacting for 12s"
       ());
  (* CLI relay dm send ack *)
  gate_check ~what:"cli relay dm send ack"
    (C2c_utils.adapt_relay_dm_send_result ~from_alias:"zz-j2send"
       ~to_alias:"zz-j2recv" ~content:"hi relay"
       (`Assoc
          [ ("ok", `Bool true); ("ts", `Float 1700000002.0)
          ; ("duplicate", `Bool true) ]));
  (* CLI relay dm poll (delivered) + peek (queued) rows *)
  let gate_relay_rows ~what ~delivery_state =
    let adapted =
      C2c_utils.adapt_relay_dm_inbox_result ~delivery_state
        (relay_inbox_result [ relay_row () ])
    in
    match messages_of adapted with
    | [ row ] -> gate_check ~what row
    | _ -> Alcotest.failf "%s: expected exactly one adapted row" what
  in
  gate_relay_rows ~what:"cli relay dm poll row"
    ~delivery_state:C2c_schema_v1.Delivered;
  gate_relay_rows ~what:"cli relay dm peek row"
    ~delivery_state:C2c_schema_v1.Queued

let () =
  Alcotest.run "c2c_utils" [
    "alias_from_env_only", [
      Alcotest.test_case "whitespace-only → None"   `Quick test_some_trimmed;
      Alcotest.test_case "spaces trimmed"           `Quick test_some_with_whitespace;
      Alcotest.test_case "empty string → None"     `Quick test_none_on_empty;
      Alcotest.test_case "Some plain"              `Quick test_some_plain;
    ];
    "trimmed_env_value", [
      Alcotest.test_case "empty string → None"        `Quick test_trimmed_env_empty_string;
      Alcotest.test_case "whitespace-only → None"     `Quick test_trimmed_env_whitespace_only;
      Alcotest.test_case "value trimmed"               `Quick test_trimmed_env_value_trimmed;
      Alcotest.test_case "plain value → Some"         `Quick test_trimmed_env_plain;
    ];
    "schema_v1_cli (J2)", [
      Alcotest.test_case "inbox drain row delivered + valid v1" `Quick test_inbox_row_drain_delivered;
      Alcotest.test_case "inbox peek row queued"                `Quick test_inbox_row_peek_queued;
      Alcotest.test_case "inbox row old-reader vector"          `Quick test_inbox_row_old_reader_vector;
      Alcotest.test_case "room suffix classified room"          `Quick test_inbox_row_room_classified;
      Alcotest.test_case "host-hash suffix is a DM (pin)"       `Quick test_inbox_row_host_hash_is_dm;
      Alcotest.test_case "send receipt local delivered"         `Quick test_send_receipt_local_delivered;
      Alcotest.test_case "send receipt remote queued + warning" `Quick test_send_receipt_remote_queued_with_warning;
      Alcotest.test_case "relay dm send ack accepted"           `Quick test_relay_dm_send_accepted;
      Alcotest.test_case "relay dm send error passthrough"      `Quick test_relay_dm_send_error_passthrough;
      Alcotest.test_case "relay dm poll rows delivered"         `Quick test_relay_dm_poll_delivered;
      Alcotest.test_case "relay dm peek rows queued"            `Quick test_relay_dm_peek_queued;
      Alcotest.test_case "relay dm empty batch shape kept"      `Quick test_relay_dm_poll_empty_batch_shape;
      Alcotest.test_case "relay dm malformed row passthrough"   `Quick test_relay_dm_malformed_row_passthrough;
    ];
    "aggregate-gate (J5/I002)", [
      Alcotest.test_case "cli surfaces sweep" `Quick test_aggregate_gate_cli_surfaces;
    ]
  ]
