(* Tests for Relay_client_hints — the client-side actionable hint rendered
   when the relay rejects a signed request because the claimed alias has no
   identity binding (relay.ml try_verify_ed25519_request / handle_forward,
   relay_ws_server.ml). The server error shape under test is exactly what
   Relay_server_json.json_error_str produces:
     {"ok": false, "error_code": "unauthorized",
      "error": "alias \"<alias>\" has no identity binding"} *)

let missing_binding_response alias : Yojson.Safe.t =
  `Assoc [
    ("ok", `Bool false);
    ("error_code", `String "unauthorized");
    ("error", `String (Printf.sprintf "alias %S has no identity binding" alias));
  ]

let contains ~needle haystack =
  Relay_client_hints.contains_substring ~needle haystack

(* --- is_missing_identity_binding ---------------------------------------- *)

let test_detects_missing_binding () =
  Alcotest.(check bool) "anon missing-binding error detected" true
    (Relay_client_hints.is_missing_identity_binding
       (missing_binding_response "anon"));
  Alcotest.(check bool) "named-alias missing-binding error detected" true
    (Relay_client_hints.is_missing_identity_binding
       (missing_binding_response "lyra-quill"))

let test_ignores_other_unauthorized () =
  let other : Yojson.Safe.t =
    `Assoc [
      ("ok", `Bool false);
      ("error_code", `String "unauthorized");
      ("error", `String "request nonce replay");
    ]
  in
  Alcotest.(check bool) "other unauthorized error not matched" false
    (Relay_client_hints.is_missing_identity_binding other)

let test_ignores_other_error_codes () =
  let sig_invalid : Yojson.Safe.t =
    `Assoc [
      ("ok", `Bool false);
      ("error_code", `String "signature_invalid");
      ("error", `String "alias \"x\" has no identity binding");
    ]
  in
  Alcotest.(check bool) "non-unauthorized code not matched" false
    (Relay_client_hints.is_missing_identity_binding sig_invalid)

let test_ignores_success_and_non_objects () =
  Alcotest.(check bool) "ok:true not matched" false
    (Relay_client_hints.is_missing_identity_binding
       (`Assoc [ ("ok", `Bool true); ("peers", `List []) ]));
  Alcotest.(check bool) "non-object not matched" false
    (Relay_client_hints.is_missing_identity_binding (`String "nope"));
  let conn_err : Yojson.Safe.t =
    `Assoc [
      ("ok", `Bool false);
      ("error_code", `String "connection_error");
      ("error", `String "request_timeout");
    ]
  in
  Alcotest.(check bool) "connection_error not matched" false
    (Relay_client_hints.is_missing_identity_binding conn_err)

(* --- hint_for_response --------------------------------------------------- *)

let test_explicit_alias_hint_names_register_command () =
  match
    Relay_client_hints.hint_for_response
      ~alias_source:(Relay_client_hints.Explicit "lyra-quill")
      (missing_binding_response "lyra-quill")
  with
  | None -> Alcotest.fail "expected a hint for explicit alias"
  | Some hint ->
      Alcotest.(check bool) "hint names the exact register command" true
        (contains ~needle:"c2c relay register --alias lyra-quill" hint);
      Alcotest.(check bool) "hint mentions identity show" true
        (contains ~needle:"c2c relay identity show" hint)

let test_anon_fallback_hint_explains_missing_alias () =
  match
    Relay_client_hints.hint_for_response
      ~alias_source:Relay_client_hints.Anon_fallback
      (missing_binding_response "anon")
  with
  | None -> Alcotest.fail "expected a hint for anon fallback"
  | Some hint ->
      Alcotest.(check bool) "hint explains no session alias was found" true
        (contains ~needle:"no session alias was found" hint);
      Alcotest.(check bool) "hint suggests --alias" true
        (contains ~needle:"--alias <your-alias>" hint);
      Alcotest.(check bool) "hint suggests c2c init" true
        (contains ~needle:"c2c init" hint);
      Alcotest.(check bool) "hint names the register command" true
        (contains ~needle:"c2c relay register --alias" hint)

let test_no_hint_on_success_or_unrelated_error () =
  Alcotest.(check bool) "no hint on success" true
    (Relay_client_hints.hint_for_response
       ~alias_source:Relay_client_hints.Anon_fallback
       (`Assoc [ ("ok", `Bool true) ])
     = None);
  Alcotest.(check bool) "no hint on unrelated unauthorized" true
    (Relay_client_hints.hint_for_response
       ~alias_source:(Relay_client_hints.Explicit "x")
       (`Assoc [
          ("ok", `Bool false);
          ("error_code", `String "unauthorized");
          ("error", `String "request nonce replay");
        ])
     = None)

let signature_invalid_response alias : Yojson.Safe.t =
  `Assoc [
    ("ok", `Bool false);
    ("error_code", `String "signature_invalid");
    ("error", `String (Printf.sprintf
      "Ed25519 request signature does not verify (alias=%s, bound_pk=SHA256:x)"
      alias));
  ]

let test_signature_invalid_hint () =
  Alcotest.(check bool) "signature_invalid detected" true
    (Relay_client_hints.is_signature_invalid
       (signature_invalid_response "lyra-quill"));
  Alcotest.(check bool) "missing-binding is not signature_invalid" false
    (Relay_client_hints.is_signature_invalid
       (missing_binding_response "lyra-quill"));
  match
    Relay_client_hints.hint_for_response
      ~alias_source:(Relay_client_hints.Explicit "lyra-quill")
      (signature_invalid_response "lyra-quill")
  with
  | None -> Alcotest.fail "expected a hint for signature_invalid"
  | Some hint ->
      Alcotest.(check bool) "hint names re-register" true
        (contains ~needle:"c2c relay register --alias lyra-quill" hint);
      Alcotest.(check bool) "hint mentions whoami --relay" true
        (contains ~needle:"c2c whoami --relay" hint)

(* Guard against drift: the substring the client keys on must stay in sync
   with the server-side format string (relay.ml / relay_ws_server.ml:
   "alias %S has no identity binding"). *)
let test_server_format_string_in_sync () =
  let server_msg = Printf.sprintf "alias %S has no identity binding" "some-alias" in
  Alcotest.(check bool) "client needle matches server format output" true
    (contains ~needle:"has no identity binding" server_msg)

let () =
  Alcotest.run "relay_client_hints"
    [
      ( "is_missing_identity_binding",
        [
          Alcotest.test_case "detects missing binding" `Quick test_detects_missing_binding;
          Alcotest.test_case "ignores other unauthorized" `Quick test_ignores_other_unauthorized;
          Alcotest.test_case "ignores other error codes" `Quick test_ignores_other_error_codes;
          Alcotest.test_case "ignores success/non-objects" `Quick test_ignores_success_and_non_objects;
        ] );
      ( "hint_for_response",
        [
          Alcotest.test_case "explicit alias hint" `Quick test_explicit_alias_hint_names_register_command;
          Alcotest.test_case "anon fallback hint" `Quick test_anon_fallback_hint_explains_missing_alias;
          Alcotest.test_case "no hint otherwise" `Quick test_no_hint_on_success_or_unrelated_error;
          Alcotest.test_case "signature_invalid hint" `Quick test_signature_invalid_hint;
          Alcotest.test_case "server format in sync" `Quick test_server_format_string_in_sync;
        ] );
    ]
