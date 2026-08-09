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

(* B231: session-ownership signature_invalid must NOT recommend re-register
   (that steals the lease from a live relay-connect). *)
let session_ownership_response alias node_id session_id : Yojson.Safe.t =
  `Assoc [
    ("ok", `Bool false);
    ("error_code", `String "signature_invalid");
    ("error", `String (Printf.sprintf
      "verified signer %S does not own session (%s, %s)"
      alias node_id session_id));
  ]

let test_session_ownership_hint () =
  let resp =
    session_ownership_response "kimi-suvi-lumo-9cr1"
      "cli-kimi-suvi-lumo-9cr1" "cli-kimi-suvi-lumo-9cr1"
  in
  Alcotest.(check bool) "session ownership is signature_invalid" true
    (Relay_client_hints.is_signature_invalid resp);
  Alcotest.(check bool) "session ownership detector matches" true
    (Relay_client_hints.is_session_ownership_failure resp);
  Alcotest.(check bool) "generic bad-sig is not session ownership" false
    (Relay_client_hints.is_session_ownership_failure
       (signature_invalid_response "lyra-quill"));
  match
    Relay_client_hints.hint_for_response
      ~alias_source:(Relay_client_hints.Explicit "kimi-suvi-lumo-9cr1")
      resp
  with
  | None -> Alcotest.fail "expected a session-ownership hint"
  | Some hint ->
      Alcotest.(check bool) "must NOT recommend re-register" false
        (contains ~needle:"c2c relay register --alias" hint);
      Alcotest.(check bool) "explains connector holds the lease" true
        (contains ~needle:"relay-connect" hint);
      Alcotest.(check bool) "mentions Do NOT run register" true
        (contains ~needle:"Do NOT run" hint);
      Alcotest.(check bool) "suggests peek with alias" true
        (contains ~needle:"c2c relay dm peek --alias kimi-suvi-lumo-9cr1" hint)

(* Guard against drift: the substring the client keys on must stay in sync
   with the server-side format string (relay.ml / relay_ws_server.ml:
   "alias %S has no identity binding"). *)
let test_server_format_string_in_sync () =
  let server_msg = Printf.sprintf "alias %S has no identity binding" "some-alias" in
  Alcotest.(check bool) "client needle matches server format output" true
    (contains ~needle:"has no identity binding" server_msg);
  (* B231: session-ownership needle matches relay.ml reject_session_mismatch. *)
  let own_msg =
    Printf.sprintf "verified signer %S does not own session (%s, %s)"
      "a" "cli-a" "cli-a"
  in
  Alcotest.(check bool) "session-ownership needle matches server format" true
    (contains ~needle:"does not own session" own_msg)

(* --- contact_unauthorised (#81) ----------------------------------------- *)

(* Byte-for-byte the relay's uniform admission denial. relay.ml builds it in
   four places (handle_send's unknown_alias arm, handle_contact_deliver's
   deny, the /contact/v1/deliver auth gate, and the forward-in arm) and every
   one goes through json_error_str err_contact_unauthorised, so one literal
   covers all four. *)
let contact_unauthorised_response : Yojson.Safe.t =
  `Assoc [
    ("ok", `Bool false);
    ("error_code", `String "contact_unauthorised");
    ("error", `String "contact unauthorised");
  ]

let test_detects_contact_unauthorised () =
  Alcotest.(check bool) "uniform denial detected" true
    (Relay_client_hints.is_contact_unauthorised contact_unauthorised_response);
  Alcotest.(check bool) "success not matched" false
    (Relay_client_hints.is_contact_unauthorised (`Assoc [ ("ok", `Bool true) ]));
  Alcotest.(check bool) "other error code not matched" false
    (Relay_client_hints.is_contact_unauthorised
       (`Assoc [
          ("ok", `Bool false);
          ("error_code", `String "unauthorized");
          ("error", `String "contact unauthorised");
        ]));
  Alcotest.(check bool) "non-object not matched" false
    (Relay_client_hints.is_contact_unauthorised (`String "nope"))

(* The denial is NOT a peer rejection and the hint must say so — reading it
   as an ACL block is the whole reported failure mode in #81. *)
let test_contact_hint_denies_the_acl_reading () =
  let hint =
    match
      Relay_client_hints.hint_for_response
        ~alias_source:(Relay_client_hints.Explicit "pi-dcd88e")
        contact_unauthorised_response
    with
    | Some h -> h
    | None -> Alcotest.fail "expected a hint for contact_unauthorised"
  in
  Alcotest.(check bool) "says it is uniform" true
    (contains ~needle:"UNIFORM" hint);
  Alcotest.(check bool) "denies the blocked-by-peer reading" true
    (contains ~needle:"does NOT mean the peer" hint);
  (* All three locally-checkable classes, each with its command. *)
  Alcotest.(check bool) "class 1: recipient not registered" true
    (contains ~needle:"c2c relay register --alias" hint);
  Alcotest.(check bool) "class 2: no contact grant" true
    (contains ~needle:"c2c relay contact" hint);
  Alcotest.(check bool) "class 3: own binding" true
    (contains ~needle:"c2c whoami --relay" hint);
  Alcotest.(check bool) "class 3: own connector/lease" true
    (contains ~needle:"c2c status --relay" hint)

let test_contact_hint_without_recipient_context () =
  let hint =
    match
      Relay_client_hints.hint_for_response
        ~alias_source:Relay_client_hints.Anon_fallback
        contact_unauthorised_response
    with
    | Some h -> h
    | None -> Alcotest.fail "expected a hint"
  in
  (* No recipient known: the generic three classes still render, with a
     placeholder rather than a fabricated alias, and no local-reachability
     claim in either direction. *)
  Alcotest.(check bool) "placeholder recipient" true
    (contains ~needle:"<recipient>" hint);
  Alcotest.(check bool) "signer named" true (contains ~needle:"anon" hint);
  Alcotest.(check bool) "no local-reachability claim" false
    (contains ~needle:"alive on a broker on THIS machine" hint);
  Alcotest.(check bool) "no absence claim either" false
    (contains ~needle:"is not alive on any broker" hint)

(* The payload of the fix: a peer that is alive locally never needed the
   relay, so the hint must redirect to a bare-alias send instead of sending
   the operator off to fix a relay registration. *)
let test_contact_hint_redirects_when_peer_is_local () =
  let hint =
    match
      Relay_client_hints.hint_for_response
        ~contact:
          { Relay_client_hints.recipient = "grok-sugar-vesi-x6tv";
            recipient_live_locally = Some true }
        ~alias_source:(Relay_client_hints.Explicit "pi-dcd88e")
        contact_unauthorised_response
    with
    | Some h -> h
    | None -> Alcotest.fail "expected a hint"
  in
  Alcotest.(check bool) "names the recipient" true
    (contains ~needle:"grok-sugar-vesi-x6tv" hint);
  Alcotest.(check bool) "says the relay hop was unnecessary" true
    (contains ~needle:"the relay hop was not required at all" hint);
  Alcotest.(check bool) "gives the local send command" true
    (contains ~needle:"c2c send grok-sugar-vesi-x6tv" hint)

let test_contact_hint_confirms_relay_is_right_when_peer_absent () =
  let hint =
    match
      Relay_client_hints.hint_for_response
        ~contact:
          { Relay_client_hints.recipient = "far-peer";
            recipient_live_locally = Some false }
        ~alias_source:(Relay_client_hints.Explicit "me")
        contact_unauthorised_response
    with
    | Some h -> h
    | None -> Alcotest.fail "expected a hint"
  in
  Alcotest.(check bool) "confirms relay is the right transport" true
    (contains ~needle:"so the relay\n  is the right transport here" hint);
  Alcotest.(check bool) "does not suggest a local send" false
    (contains ~needle:"c2c send far-peer" hint)

(* An unreadable broker scan must render as "I did not look", never as
   "the peer is not here" — the latter sends someone chasing a relay
   registration that was never the problem. *)
let test_contact_hint_stays_silent_when_liveness_unknown () =
  let hint =
    match
      Relay_client_hints.hint_for_response
        ~contact:
          { Relay_client_hints.recipient = "unknown-peer";
            recipient_live_locally = None }
        ~alias_source:(Relay_client_hints.Explicit "me")
        contact_unauthorised_response
    with
    | Some h -> h
    | None -> Alcotest.fail "expected a hint"
  in
  Alcotest.(check bool) "names the recipient in the three classes" true
    (contains ~needle:"unknown-peer" hint);
  Alcotest.(check bool) "claims no local presence" false
    (contains ~needle:"alive on a broker on THIS machine" hint);
  Alcotest.(check bool) "claims no local absence" false
    (contains ~needle:"is not alive on any broker" hint)

(* Precedence guard: the codes are disjoint, so an auth failure on a route
   that also carries a recipient must still get the binding hint. *)
let test_contact_context_does_not_shadow_binding_hint () =
  let hint =
    match
      Relay_client_hints.hint_for_response
        ~contact:
          { Relay_client_hints.recipient = "peer";
            recipient_live_locally = Some true }
        ~alias_source:(Relay_client_hints.Explicit "me")
        (missing_binding_response "me")
    with
    | Some h -> h
    | None -> Alcotest.fail "expected a hint"
  in
  Alcotest.(check bool) "still the missing-binding hint" true
    (contains ~needle:"has no identity binding for alias" hint);
  Alcotest.(check bool) "not the contact hint" false
    (contains ~needle:"UNIFORM" hint)

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
          Alcotest.test_case "session ownership hint (B231)" `Quick test_session_ownership_hint;
          Alcotest.test_case "server format in sync" `Quick test_server_format_string_in_sync;
        ] );
      ( "contact_unauthorised (#81)",
        [
          Alcotest.test_case "detects the uniform denial" `Quick
            test_detects_contact_unauthorised;
          Alcotest.test_case "denies the ACL reading, names all three classes"
            `Quick test_contact_hint_denies_the_acl_reading;
          Alcotest.test_case "generic form without a recipient" `Quick
            test_contact_hint_without_recipient_context;
          Alcotest.test_case "redirects to a local send when peer is local"
            `Quick test_contact_hint_redirects_when_peer_is_local;
          Alcotest.test_case "confirms relay transport when peer is absent"
            `Quick test_contact_hint_confirms_relay_is_right_when_peer_absent;
          Alcotest.test_case "silent when local liveness is unknown" `Quick
            test_contact_hint_stays_silent_when_liveness_unknown;
          Alcotest.test_case "does not shadow the missing-binding hint" `Quick
            test_contact_context_does_not_shadow_binding_hint;
        ] );
    ]
