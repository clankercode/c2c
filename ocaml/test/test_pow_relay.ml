module RS = Relay.Relay_server (Relay.InMemoryRelay)

open Lwt.Infix

type http_result = {
  status : Cohttp.Code.status_code;
  headers : Cohttp.Header.t;
  json : Yojson.Safe.t;
}

let failf fmt = Printf.ksprintf (fun msg -> Alcotest.fail msg) fmt

let pow_header = "X-C2C-PoW-Next"

let b64url s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let with_pow_env value f =
  let previous = Sys.getenv_opt "C2C_RELAY_POW" in
  let restore () =
    match previous with
    | Some v -> Unix.putenv "C2C_RELAY_POW" v
    | None -> Unix.putenv "C2C_RELAY_POW" ""
  in
  Unix.putenv "C2C_RELAY_POW" value;
  Fun.protect ~finally:restore f

let loopback_socket () =
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt fd Unix.SO_REUSEADDR true;
  Lwt_unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) >>= fun () ->
  Lwt_unix.listen fd 16;
  match Lwt_unix.getsockname fd with
  | Unix.ADDR_INET (_, port) -> Lwt.return (fd, port)
  | _ -> Lwt.fail_with "loopback_socket: expected INET socket"

let with_server f =
  Lwt_main.run
    (loopback_socket () >>= fun (fd, port) ->
     let relay = Relay.InMemoryRelay.create () in
     let rate_limiter = Relay.Rate_limiter_inst.create ~gc_interval:300.0 () in
     let stop, wake_stop = Lwt.wait () in
     let callback (conn, _) req body =
       RS.make_callback relay None conn req body ?broker_root:None ~rate_limiter
     in
     let spec = Cohttp_lwt_unix.Server.make ~callback () in
     let server =
       Cohttp_lwt_unix.Server.create ~stop ~mode:(`TCP (`Socket fd)) spec
     in
     Lwt.pause () >>= fun () ->
     let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
     Lwt.finalize
       (fun () -> f ~base_url ~relay)
       (fun () ->
          Lwt.wakeup_later wake_stop ();
          server))

let call_json ~base_url ~meth ~path ?(body = `Assoc []) () =
  let uri = Uri.of_string (base_url ^ path) in
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  let body = Cohttp_lwt.Body.of_string (Yojson.Safe.to_string body) in
  Cohttp_lwt_unix.Client.call ~headers ~body meth uri >>= fun (resp, resp_body) ->
  Cohttp_lwt.Body.to_string resp_body >|= fun text ->
  let json =
    try Yojson.Safe.from_string text
    with Yojson.Json_error msg ->
      failf "response was not JSON: %s\nbody=%s" msg text
  in
  { status = Cohttp.Response.status resp; headers = Cohttp.Response.headers resp; json }

let post_register ~base_url body =
  call_json ~base_url ~meth:`POST ~path:"/register" ~body ()

let get_health ~base_url =
  call_json ~base_url ~meth:`GET ~path:"/health" ()

let json_member name json =
  match json with
  | `Assoc fields -> List.assoc_opt name fields |> Option.value ~default:`Null
  | _ -> `Null

let json_string name json =
  match json_member name json with
  | `String s -> s
  | v -> failf "expected JSON string field %s, got %s" name (Yojson.Safe.to_string v)

let json_int name json =
  match json_member name json with
  | `Int i -> i
  | v -> failf "expected JSON int field %s, got %s" name (Yojson.Safe.to_string v)

let json_assoc_set name value = function
  | `Assoc fields -> `Assoc ((name, value) :: List.remove_assoc name fields)
  | json -> failf "expected JSON object, got %s" (Yojson.Safe.to_string json)

let require_pow_header result =
  match Cohttp.Header.get result.headers pow_header with
  | Some h -> h
  | None -> failf "missing %s response header" pow_header

let header_param key header =
  let parts = String.split_on_char ';' header in
  let rec find = function
    | [] -> failf "header %S missing param %s" header key
    | part :: rest ->
        let trimmed = String.trim part in
        match String.split_on_char '=' trimmed with
        | [ k; v ] when k = key -> v
        | _ -> find rest
  in
  find parts

let header_difficulty header =
  int_of_string (header_param "difficulty" header)

let register_body ?pow_nonce ?pow_epoch ?pow_server_nonce
    ~node_id ~session_id ~alias ~identity ~relay_url () =
  let proof = Relay_signed_ops.sign_register identity ~alias ~relay_url in
  let fields = [
    "node_id", `String node_id;
    "session_id", `String session_id;
    "alias", `String alias;
    "client_type", `String "pow-test";
    "ttl", `Int 3600;
    "identity_pk", `String proof.identity_pk_b64;
    "signature", `String proof.sig_b64;
    "nonce", `String proof.nonce;
    "timestamp", `String proof.ts;
  ] in
  let fields =
    match pow_nonce, pow_epoch, pow_server_nonce with
    | Some nonce, Some epoch, Some server_nonce ->
        fields @ [
          "pow_nonce", `String nonce;
          "pow_epoch", `Int epoch;
          "pow_server_nonce", `String server_nonce;
        ]
    | None, None, None -> fields
    | _ -> failf "register_body: PoW fields must be supplied together"
  in
  `Assoc fields

let check_legacy_register_succeeds_without_pow ~pow_env ~alias_suffix =
  with_pow_env pow_env (fun () ->
    with_server (fun ~base_url ~relay:_ ->
      let body = `Assoc [
        "node_id", `String ("node-disabled-" ^ alias_suffix);
        "session_id", `String ("session-disabled-" ^ alias_suffix);
        "alias", `String ("pow-disabled-" ^ alias_suffix);
      ] in
      post_register ~base_url body >|= fun result ->
      Alcotest.(check int) "status" 200 (Cohttp.Code.code_of_status result.status);
      Alcotest.(check bool) "ok" true (json_member "ok" result.json = `Bool true);
      Alcotest.(check int) "disabled advertises D=0" 0
        (header_difficulty (require_pow_header result))))

let test_disabled_by_default_register_succeeds_without_pow () =
  check_legacy_register_succeeds_without_pow ~pow_env:"" ~alias_suffix:"default"

let test_disabled_explicit_zero_register_succeeds_without_pow () =
  check_legacy_register_succeeds_without_pow ~pow_env:"0" ~alias_suffix:"zero"

let test_health_advertises_pow_capability () =
  with_pow_env "1" (fun () ->
    with_server (fun ~base_url ~relay:_ ->
      get_health ~base_url >|= fun result ->
      Alcotest.(check int) "status" 200 (Cohttp.Code.code_of_status result.status);
      let pow = json_member "pow" result.json in
      Alcotest.(check bool) "pow enabled" true (json_member "enabled" pow = `Bool true);
      Alcotest.(check string) "scheme" Pow.scheme_id (json_string "scheme" pow);
      Alcotest.(check int) "health advertises D=0" 0
        (header_difficulty (require_pow_header result))))

let test_enabled_rejects_legacy_register_without_identity () =
  with_pow_env "1" (fun () ->
    with_server (fun ~base_url ~relay:_ ->
      let body = `Assoc [
        "node_id", `String "node-legacy-enabled";
        "session_id", `String "session-legacy-enabled";
        "alias", `String "pow-legacy-enabled";
      ] in
      post_register ~base_url body >|= fun result ->
      Alcotest.(check int) "status" 400 (Cohttp.Code.code_of_status result.status);
      Alcotest.(check string) "error_code" "missing_proof_field"
        (json_string "error_code" result.json);
      Alcotest.(check int) "legacy reject still advertises D=0" 0
        (header_difficulty (require_pow_header result))))

let test_enabled_grace_register_succeeds_without_pow () =
  with_pow_env "1" (fun () ->
    with_server (fun ~base_url ~relay:_ ->
      let identity = Relay_identity.generate ~alias_hint:"pow-grace" () in
      let body =
        register_body ~node_id:"node-grace" ~session_id:"session-grace"
          ~alias:"pow-grace" ~identity ~relay_url:base_url ()
      in
      post_register ~base_url body >|= fun result ->
      Alcotest.(check int) "status" 200 (Cohttp.Code.code_of_status result.status);
      Alcotest.(check bool) "ok" true (json_member "ok" result.json = `Bool true);
      Alcotest.(check int) "still in grace" 0
        (header_difficulty (require_pow_header result))))

let warm_actor_past_grace ~base_url ~identity ~alias =
  let rec loop n =
    if n <= 0 then Lwt.return_unit
    else
      let body =
        register_body
          ~node_id:"node-warm"
          ~session_id:(Printf.sprintf "session-warm-%d" n)
          ~alias ~identity ~relay_url:base_url ()
      in
      post_register ~base_url body >>= fun result ->
      Alcotest.(check int) "warm register status" 200
        (Cohttp.Code.code_of_status result.status);
      loop (n - 1)
  in
  loop 3

let required_pow_fields result =
  let required = json_member "required" result.json in
  ( json_int "difficulty" required,
    json_int "epoch" required,
    json_string "server_nonce" required )

let mint_required_pow ~actor_id ~difficulty ~epoch ~server_nonce =
  let challenge =
    Pow.challenge_string ~ctx:Pow.ctx ~route:"register" ~actor_id ~epoch
      ~server_nonce
  in
  match Pow.mint ~challenge ~difficulty with
  | None -> Alcotest.fail "Pow.mint failed at relay-required difficulty"
  | Some pow_nonce -> pow_nonce

let test_enabled_pow_required_then_minted_nonce_succeeds () =
  with_pow_env "1" (fun () ->
    with_server (fun ~base_url ~relay:_ ->
      let alias = "pow-required" in
      let identity = Relay_identity.generate ~alias_hint:alias () in
      let actor_id = b64url identity.public_key in
      warm_actor_past_grace ~base_url ~identity ~alias >>= fun () ->
      let rejected_body =
        register_body ~node_id:"node-needs-pow" ~session_id:"session-needs-pow"
          ~alias ~identity ~relay_url:base_url ()
      in
      post_register ~base_url rejected_body >>= fun rejected ->
      Alcotest.(check int) "pow_required status" 429
        (Cohttp.Code.code_of_status rejected.status);
      Alcotest.(check string) "error_code" "pow_required"
        (json_string "error_code" rejected.json);
      let required = json_member "required" rejected.json in
      let difficulty = json_int "difficulty" required in
      Alcotest.(check bool) "difficulty is nonzero" true (difficulty > 0);
      Alcotest.(check string) "ctx" Pow.ctx (json_string "ctx" required);
      let epoch = json_int "epoch" required in
      let server_nonce = json_string "server_nonce" required in
      let challenge =
        Pow.challenge_string ~ctx:Pow.ctx ~route:"register" ~actor_id ~epoch
          ~server_nonce
      in
      match Pow.mint ~challenge ~difficulty with
      | None -> Alcotest.fail "Pow.mint failed at relay-required difficulty"
      | Some pow_nonce ->
          let accepted_body =
            register_body ~pow_nonce ~pow_epoch:epoch ~pow_server_nonce:server_nonce
              ~node_id:"node-warm" ~session_id:"session-with-pow"
              ~alias ~identity ~relay_url:base_url ()
          in
          post_register ~base_url accepted_body >|= fun accepted ->
          Alcotest.(check int) "accepted status" 200
            (Cohttp.Code.code_of_status accepted.status);
          Alcotest.(check bool) "accepted ok" true
            (json_member "ok" accepted.json = `Bool true);
          Alcotest.(check bool) "next difficulty advertised" true
            (header_difficulty (require_pow_header accepted) >= difficulty)))

let test_relay_client_register_signed_mints_and_retries () =
  with_pow_env "1" (fun () ->
    with_server (fun ~base_url ~relay:_ ->
      let alias = "pow-client-retry" in
      let identity = Relay_identity.generate ~alias_hint:alias () in
      warm_actor_past_grace ~base_url ~identity ~alias >>= fun () ->
      let proof = Relay_signed_ops.sign_register identity ~alias ~relay_url:base_url in
      let client = Relay.Relay_client.make base_url in
      Relay.Relay_client.register_signed client
        ~node_id:"node-warm"
        ~session_id:"session-client-retry"
        ~alias
        ~client_type:"pow-client-test"
        ~identity_pk_b64:proof.identity_pk_b64
        ~sig_b64:proof.sig_b64
        ~nonce:proof.nonce
        ~ts:proof.ts
        () >|= fun json ->
      if json_member "ok" json <> `Bool true then
        failf "client register expected ok, got %s" (Yojson.Safe.to_string json);
      Alcotest.(check string) "alias" alias
        (json_string "alias" (json_member "lease" json))))

let test_connector_client_register_mints_and_retries () =
  with_pow_env "1" (fun () ->
    with_server (fun ~base_url ~relay:_ ->
      let alias = "pow-connector-retry" in
      let identity = Relay_identity.generate ~alias_hint:alias () in
      warm_actor_past_grace ~base_url ~identity ~alias >>= fun () ->
      let client = C2c_relay_connector.Relay_client.make ~identity base_url in
      C2c_relay_connector.Relay_client.register client
        ~node_id:"node-warm"
        ~session_id:"session-connector-retry"
        ~alias
        ~client_type:"pow-connector-test"
        () >|= fun json ->
      if json_member "ok" json <> `Bool true then
        failf "connector register expected ok, got %s" (Yojson.Safe.to_string json);
      Alcotest.(check string) "alias" alias
        (json_string "alias" (json_member "lease" json))))

let test_verified_pow_is_spent_even_if_register_body_fails () =
  with_pow_env "1" (fun () ->
    with_server (fun ~base_url ~relay:_ ->
      let alias = "pow-spent-on-fail" in
      let identity = Relay_identity.generate ~alias_hint:alias () in
      let actor_id = b64url identity.public_key in
      warm_actor_past_grace ~base_url ~identity ~alias >>= fun () ->
      let challenge_request =
        register_body ~node_id:"node-spent" ~session_id:"session-spent"
          ~alias ~identity ~relay_url:base_url ()
      in
      post_register ~base_url challenge_request >>= fun rejected ->
      Alcotest.(check int) "pow_required status" 429
        (Cohttp.Code.code_of_status rejected.status);
      let required = json_member "required" rejected.json in
      let difficulty = json_int "difficulty" required in
      let epoch = json_int "epoch" required in
      let server_nonce = json_string "server_nonce" required in
      let challenge =
        Pow.challenge_string ~ctx:Pow.ctx ~route:"register" ~actor_id ~epoch
          ~server_nonce
      in
      match Pow.mint ~challenge ~difficulty with
      | None -> Alcotest.fail "Pow.mint failed at relay-required difficulty"
      | Some pow_nonce ->
          let bad_signed_body =
            register_body ~pow_nonce ~pow_epoch:epoch ~pow_server_nonce:server_nonce
              ~node_id:"node-warm" ~session_id:"session-bad-signature"
              ~alias ~identity ~relay_url:base_url ()
            |> json_assoc_set "signature" (`String "not-base64url")
          in
          post_register ~base_url bad_signed_body >>= fun bad ->
          Alcotest.(check int) "bad signed body rejected after PoW" 400
            (Cohttp.Code.code_of_status bad.status);
          let valid_reuse_body =
            register_body ~pow_nonce ~pow_epoch:epoch ~pow_server_nonce:server_nonce
              ~node_id:"node-warm" ~session_id:"session-reuse-spent"
              ~alias ~identity ~relay_url:base_url ()
          in
          post_register ~base_url valid_reuse_body >|= fun reuse ->
          Alcotest.(check int) "spent PoW cannot be reused" 429
            (Cohttp.Code.code_of_status reuse.status);
          Alcotest.(check string) "reuse error" "pow_required"
            (json_string "error_code" reuse.json)))

let test_forged_pow_challenge_fields_are_rejected () =
  with_pow_env "1" (fun () ->
    with_server (fun ~base_url ~relay:_ ->
      let alias = "pow-forged-fields" in
      let identity = Relay_identity.generate ~alias_hint:alias () in
      let actor_id = b64url identity.public_key in
      warm_actor_past_grace ~base_url ~identity ~alias >>= fun () ->
      let challenge_request =
        register_body ~node_id:"node-forged" ~session_id:"session-forged"
          ~alias ~identity ~relay_url:base_url ()
      in
      post_register ~base_url challenge_request >>= fun rejected ->
      Alcotest.(check int) "pow_required status" 429
        (Cohttp.Code.code_of_status rejected.status);
      let difficulty, epoch, server_nonce = required_pow_fields rejected in
      let pow_nonce =
        mint_required_pow ~actor_id ~difficulty ~epoch ~server_nonce
      in
      let forged_nonce_body =
        register_body ~pow_nonce ~pow_epoch:epoch
          ~pow_server_nonce:("forged-" ^ server_nonce)
          ~node_id:"node-warm" ~session_id:"session-forged-nonce"
          ~alias ~identity ~relay_url:base_url ()
      in
      post_register ~base_url forged_nonce_body >>= fun forged_nonce ->
      Alcotest.(check int) "forged server nonce rejected" 429
        (Cohttp.Code.code_of_status forged_nonce.status);
      Alcotest.(check string) "forged nonce error" "pow_required"
        (json_string "error_code" forged_nonce.json);
      let forged_epoch_body =
        register_body ~pow_nonce ~pow_epoch:(epoch + 1) ~pow_server_nonce:server_nonce
          ~node_id:"node-warm" ~session_id:"session-forged-epoch"
          ~alias ~identity ~relay_url:base_url ()
      in
      post_register ~base_url forged_epoch_body >|= fun forged_epoch ->
      Alcotest.(check int) "forged epoch rejected" 429
        (Cohttp.Code.code_of_status forged_epoch.status);
      Alcotest.(check string) "forged epoch error" "pow_required"
        (json_string "error_code" forged_epoch.json)))

let test_malformed_pow_fields_are_rejected_without_exception () =
  with_pow_env "1" (fun () ->
    with_server (fun ~base_url ~relay:_ ->
      let alias = "pow-malformed-fields" in
      let identity = Relay_identity.generate ~alias_hint:alias () in
      warm_actor_past_grace ~base_url ~identity ~alias >>= fun () ->
      let malformed_body =
        register_body ~node_id:"node-malformed" ~session_id:"session-malformed"
          ~alias ~identity ~relay_url:base_url ()
        |> json_assoc_set "pow_nonce" (`Int 123)
        |> json_assoc_set "pow_epoch" (`String "not-an-int")
        |> json_assoc_set "pow_server_nonce" (`Bool true)
      in
      post_register ~base_url malformed_body >|= fun result ->
      Alcotest.(check int) "malformed pow fields rejected" 429
        (Cohttp.Code.code_of_status result.status);
      Alcotest.(check string) "malformed pow error" "pow_required"
        (json_string "error_code" result.json)))

let () =
  Alcotest.run "pow_relay" [
    "relay", [
      Alcotest.test_case "disabled by default: legacy register succeeds" `Quick
        test_disabled_by_default_register_succeeds_without_pow;
      Alcotest.test_case "explicit 0 disables: legacy register succeeds" `Quick
        test_disabled_explicit_zero_register_succeeds_without_pow;
      Alcotest.test_case "/health advertises pow capability" `Quick
        test_health_advertises_pow_capability;
      Alcotest.test_case "enabled rejects legacy register without identity"
        `Quick test_enabled_rejects_legacy_register_without_identity;
      Alcotest.test_case "enabled grace: signed register succeeds without pow"
        `Quick test_enabled_grace_register_succeeds_without_pow;
      Alcotest.test_case "enabled: pow_required then minted nonce succeeds" `Quick
        test_enabled_pow_required_then_minted_nonce_succeeds;
      Alcotest.test_case "client: register_signed mints and retries on pow_required"
        `Quick test_relay_client_register_signed_mints_and_retries;
      Alcotest.test_case "connector: register mints and retries on pow_required"
        `Quick test_connector_client_register_mints_and_retries;
      Alcotest.test_case "enabled: verified PoW is spent on failed register"
        `Quick test_verified_pow_is_spent_even_if_register_body_fails;
      Alcotest.test_case "enabled: forged PoW challenge fields are rejected"
        `Quick test_forged_pow_challenge_fields_are_rejected;
      Alcotest.test_case "enabled: malformed PoW fields are rejected"
        `Quick test_malformed_pow_fields_are_rejected_without_exception;
    ];
  ]
