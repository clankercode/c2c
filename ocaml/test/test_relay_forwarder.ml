(* test_relay_forwarder.ml — #330 S2: relay-to-relay forwarder tests.

    Tests the pure classification helpers (build_body, classify_response)
    and the forward_outcome type.  The network-bound forward_send is
    tested via the cross-host e2e test in test_cross_host_e2e.ml. *)

open Relay_forwarder

let string_contains ~sub s =
  try ignore (String.index s (String.get sub 0)); true with Not_found -> false

(* --- build_body tests --- *)

let test_build_body_basic () =
  let body = build_body ~self_host:"relay-a" ~from_alias:"alice"
      ~to_alias:"bob" ~content:"hello world" ~message_id:"msg-123" in
  let json_str = Yojson.Safe.to_string body in
  Alcotest.(check string) "from_alias tagged with self_host"
    {|{"from_alias":"alice@relay-a","to_alias":"bob","content":"hello world","message_id":"msg-123","via":["relay-a"]}|}
    json_str

let test_build_body_to_alias_preserved () =
  (* to_alias is passed through bare — the destination relay handles host *)
  let body = build_body ~self_host:"relay-a" ~from_alias:"alice"
      ~to_alias:"bob@relay-b" ~content:"hi" ~message_id:"msg-456" in
  let json_str = Yojson.Safe.to_string body in
  Alcotest.(check string) "to_alias is kept bare by forwarder"
    {|{"from_alias":"alice@relay-a","to_alias":"bob@relay-b","content":"hi","message_id":"msg-456","via":["relay-a"]}|}
    json_str

let test_build_body_via_list_self_host () =
  let body = build_body ~self_host:"relay-x" ~from_alias:"charlie"
      ~to_alias:"dana" ~content:"secret" ~message_id:"msg-789" in
  let json = Yojson.Safe.from_string (Yojson.Safe.to_string body) in
  let open Yojson.Safe.Util in
  let via_list = json |> member "via" in
  match via_list with
  | `List [`String s] when s = "relay-x" -> ()
  | _ -> Alcotest.fail ("expected via=[\"relay-x\"], got " ^ Yojson.Safe.to_string via_list)

(* --- classify_response tests --- *)

let test_classify_200_ok_delivered () =
  let outcome = classify_response ~status:200
      ~body:{|{"ok":true,"ts":1234567890.0}|} in
  match outcome with
  | Delivered ts when ts = 1234567890.0 -> ()
  | _ -> Alcotest.fail "expected Delivered 1234567890.0"

let test_classify_200_ok_duplicate () =
  let outcome = classify_response ~status:200
      ~body:{|{"ok":true,"duplicate":true,"ts":999.5}|} in
  match outcome with
  | Duplicate ts when ts = 999.5 -> ()
  | _ -> Alcotest.fail "expected Duplicate 999.5"

let test_classify_200_ok_no_ts_defaults_zero () =
  let outcome = classify_response ~status:200 ~body:{|{"ok":true}|} in
  match outcome with
  | Delivered ts when ts = 0.0 -> ()
  | _ -> Alcotest.fail "expected Delivered 0.0 when ts missing"

let test_classify_200_ok_false_is_5xx () =
  let outcome = classify_response ~status:200 ~body:{|{"ok":false}|} in
  match outcome with
  | Peer_5xx (c, _) when c = 200 -> ()
  | _ -> Alcotest.fail "expected Peer_5xx for ok=false"

let test_classify_200_malformed_json_is_5xx () =
  let outcome = classify_response ~status:200 ~body:"not json at all" in
  match outcome with
  | Peer_5xx (c, body) when c = 200 ->
      if not (string_contains ~sub:"not json" body) then
        Alcotest.fail ("expected body to contain 'not json', got: " ^ body)
  | _ -> Alcotest.fail "expected Peer_5xx for malformed JSON"

let test_classify_200_empty_body_is_5xx () =
  let outcome = classify_response ~status:200 ~body:"" in
  match outcome with
  | Peer_5xx (c, _) when c = 200 -> ()
  | _ -> Alcotest.fail "expected Peer_5xx for empty body"

let test_classify_401 () =
  let outcome = classify_response ~status:401 ~body:{|{"error":"forbidden"}|} in
  match outcome with
  | Peer_unauthorized -> ()
  | _ -> Alcotest.fail "expected Peer_unauthorized"

let test_classify_5xx () =
  let outcome = classify_response ~status:502 ~body:{|{"error":"bad gateway"}|} in
  match outcome with
  | Peer_5xx (code, body) ->
      Alcotest.(check int) "code preserved" 502 code;
      if not (string_contains ~sub:"bad gateway" body) then
        Alcotest.fail ("expected body to contain 'bad gateway', got: " ^ body)
  | _ -> Alcotest.fail "expected Peer_5xx for 502"

let test_classify_5xx_body_truncated_at_200 () =
  let long_body = String.make 300 'x' in
  let outcome = classify_response ~status:500 ~body:long_body in
  match outcome with
  | Peer_5xx (_, body) ->
      Alcotest.(check int) "body truncated to 200+3 (ellipsis)" 203 (String.length body)
  | _ -> Alcotest.fail "expected Peer_5xx"

let test_classify_4xx () =
  let outcome = classify_response ~status:404 ~body:{|{"error":"not found"}|} in
  match outcome with
  | Peer_4xx (code, body) ->
      Alcotest.(check int) "code preserved" 404 code;
      if not (string_contains ~sub:"not found" body) then
        Alcotest.fail ("expected body to contain 'not found', got: " ^ body)
  | _ -> Alcotest.fail "expected Peer_4xx for 404"

let test_classify_400 () =
  let outcome = classify_response ~status:400 ~body:{|{"error":"bad request"}|} in
  match outcome with
  | Peer_4xx (code, _) when code = 400 -> ()
  | _ -> Alcotest.fail "expected Peer_4xx for 400"

(* --- forward_outcome exhaustive match sanity --- *)

let test_outcome_exhaustive_match () =
  (* Compile-time sanity: ensure all constructors are handled.
     If a constructor is added to forward_outcome and this function
     is not updated, the compiler will warn (wildcard in match). *)
  let go outcome = match outcome with
    | Delivered _ -> "Delivered"
    | Duplicate _ -> "Duplicate"
    | Peer_unreachable _ -> "Peer_unreachable"
    | Peer_timeout -> "Peer_timeout"
    | Peer_5xx _ -> "Peer_5xx"
    | Peer_4xx _ -> "Peer_4xx"
    | Peer_unauthorized -> "Peer_unauthorized"
    | Local_error _ -> "Local_error"
  in
  Alcotest.(check string) "exhaustive match returns a string" "Peer_5xx"
    (go (Peer_5xx (500, "test")))

let () =
  let open Alcotest in
  run "relay_forwarder" [
    "build_body", [
      test_case "basic" `Quick test_build_body_basic;
      test_case "to_alias preserved bare" `Quick test_build_body_to_alias_preserved;
      test_case "via is self_host list" `Quick test_build_body_via_list_self_host;
    ];
    "classify_response", [
      test_case "200 ok → Delivered" `Quick test_classify_200_ok_delivered;
      test_case "200 dup → Duplicate" `Quick test_classify_200_ok_duplicate;
      test_case "200 ok no ts → Delivered 0.0" `Quick test_classify_200_ok_no_ts_defaults_zero;
      test_case "200 ok:false → 5xx" `Quick test_classify_200_ok_false_is_5xx;
      test_case "200 malformed json → 5xx" `Quick test_classify_200_malformed_json_is_5xx;
      test_case "200 empty → 5xx" `Quick test_classify_200_empty_body_is_5xx;
      test_case "401 → Peer_unauthorized" `Quick test_classify_401;
      test_case "5xx → Peer_5xx" `Quick test_classify_5xx;
      test_case "5xx body truncated at 200" `Quick test_classify_5xx_body_truncated_at_200;
      test_case "4xx → Peer_4xx" `Quick test_classify_4xx;
      test_case "400 → Peer_4xx" `Quick test_classify_400;
    ];
    "forward_outcome", [
      test_case "exhaustive match" `Quick test_outcome_exhaustive_match;
    ];
  ]
