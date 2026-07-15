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

let with_server ?rate_limiter f =
  Lwt_main.run
    (loopback_socket () >>= fun (fd, port) ->
     let relay = Relay.InMemoryRelay.create () in
     let rate_limiter =
       match rate_limiter with
       | Some rl -> rl
       | None -> Relay.Rate_limiter_inst.create ~gc_interval:300.0 ()
     in
     let stop, wake_stop = Lwt.wait () in
     let callback (conn, _) req body =
       RS.make_callback relay None conn req body ?broker_root:None
         ~native_tls:false ~rate_limiter
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

let post_send ~base_url ~from_alias ~to_alias ~content =
  call_json ~base_url ~meth:`POST ~path:"/send"
    ~body:(`Assoc [
      "from_alias", `String from_alias;
      "to_alias", `String to_alias;
      "content", `String content;
    ]) ()


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

(* Warm the actor past the PoW grace window by registering other sessions
   under the same alias+identity. Each successful register records route cost
   (10); once accumulated cost crosses grace (20) the relay demands PoW, which
   we mint and retry — the whole point is to push the actor past grace, so the
   register that crosses the boundary legitimately demands a proof and must
   mint through it rather than fail. Callers that then assert the NEXT register
   is pow_required rely on the actor being genuinely warm. *)
let warm_actor_past_grace ~base_url ~(identity : Relay_identity.t) ~alias =
  let actor_id = b64url identity.public_key in
  let rec loop n =
    if n <= 0 then Lwt.return_unit
    else begin
      let session_id = Printf.sprintf "session-warm-%d" n in
      let post ?(pow_nonce=None) ?(epoch=None) ?(server_nonce=None) () =
        let body =
          register_body ?pow_nonce ?pow_epoch:epoch ?pow_server_nonce:server_nonce
            ~node_id:"node-warm" ~session_id ~alias ~identity ~relay_url:base_url ()
        in
        post_register ~base_url body
      in
      post () >>= fun result ->
      (match Cohttp.Code.code_of_status result.status with
       | 200 -> Lwt.return_unit
       | 429 when json_string "error_code" result.json = "pow_required" ->
         let difficulty, epoch, server_nonce = required_pow_fields result in
         let pow_nonce = mint_required_pow ~actor_id ~difficulty ~epoch ~server_nonce in
         post ~pow_nonce:(Some pow_nonce) ~epoch:(Some epoch) ~server_nonce:(Some server_nonce) () >>= fun retry ->
         Alcotest.(check int) "warm register (pow retry) status" 200
           (Cohttp.Code.code_of_status retry.status);
         Lwt.return_unit
       | _ ->
         Alcotest.(check int) "warm register status" 200
           (Cohttp.Code.code_of_status result.status);
         Lwt.return_unit) >>= fun () ->
      loop (n - 1)
    end
  in
  loop 3

(* Mint a nonce whose SHA-256 has leading-zero-bits in [min_difficulty,
   below_difficulty): valid at the lower bar, stale at the higher one. This
   yields a deterministic "proof minted at the OLD difficulty" — unlike
   `Pow.mint ~difficulty:min`, whose first hit might *coincidentally* also
   clear the higher bar (~1/16 of the time), which would flake the
   escalation-rejection assertion. *)
let mint_in_band ~challenge ~min_difficulty ~below_difficulty =
  let rec loop counter =
    if counter >= Pow.max_mint_iterations then
      Alcotest.fail "mint_in_band: no nonce found in difficulty band"
    else
      let pow_nonce = string_of_int counter in
      if Pow.verify ~challenge ~difficulty:min_difficulty ~pow_nonce
         && not (Pow.verify ~challenge ~difficulty:below_difficulty ~pow_nonce)
      then pow_nonce
      else loop (counter + 1)
  in
  loop 0

(* The /register endpoint also sits behind a per-IP token bucket (capacity 10,
   refill 0.5/s) that is ORTHOGONAL to the PoW policy. Every loopback request
   shares the 127.0.0.1 bucket, so a test that compresses many registrations
   into milliseconds would trip the IP throttle (`rate_limit_exceeded`) long
   before exercising the PoW curve. Resetting the bucket — exactly the relay's
   own periodic GC (`cleanup`) — isolates the PoW difficulty-escalation
   behaviour under test while leaving the process-global PoW cost accumulator
   (`relay_pow_policy`) untouched. (`older_than:0.0` evicts any bucket whose
   last request is >0s old, i.e. all of them.) *)
let reset_ip_rate_limit rate_limiter =
  ignore (Relay.Rate_limiter_inst.cleanup rate_limiter ~older_than:0.0 : int)

(* One full register handshake at the actor's CURRENT required difficulty,
   mirroring the real `Pow_client` retry behaviour: POST without PoW; if the
   live relay answers `pow_required`, mint at the demanded difficulty and
   resubmit, asserting the retry lands (200). Each successful register adds
   the register route-cost (10) to the actor's accumulated cost, so repeated
   calls walk the difficulty curve upward.

   Resets the IP token bucket first so the (<=2) POSTs it makes never collide
   with the orthogonal per-IP throttle (see `reset_ip_rate_limit`).

   Returns (required_difficulty_demanded, next_difficulty_advertised_on_success)
   where the second component is the `X-C2C-PoW-Next` header value on the
   accepted response — the difficulty the relay pre-announces for the *next*
   request from this actor. *)
let register_handshake ~rate_limiter ~base_url ~identity ~actor_id ~alias
    ~session_id =
  reset_ip_rate_limit rate_limiter;
  let body () =
    register_body ~node_id:"node-climb" ~session_id ~alias ~identity
      ~relay_url:base_url ()
  in
  post_register ~base_url (body ()) >>= fun first ->
  match Cohttp.Code.code_of_status first.status with
  | 200 ->
      (* Grace window / difficulty 0: accepted with no PoW. *)
      Lwt.return (0, header_difficulty (require_pow_header first))
  | 429 ->
      Alcotest.(check string) "handshake 429 is pow_required" "pow_required"
        (json_string "error_code" first.json);
      let difficulty, epoch, server_nonce = required_pow_fields first in
      let pow_nonce =
        mint_required_pow ~actor_id ~difficulty ~epoch ~server_nonce
      in
      let retry =
        register_body ~pow_nonce ~pow_epoch:epoch ~pow_server_nonce:server_nonce
          ~node_id:"node-climb" ~session_id ~alias ~identity ~relay_url:base_url ()
      in
      post_register ~base_url retry >|= fun accepted ->
      Alcotest.(check int) "minted PoW retry is accepted" 200
        (Cohttp.Code.code_of_status accepted.status);
      Alcotest.(check bool) "retry ok" true
        (json_member "ok" accepted.json = `Bool true);
      (difficulty, header_difficulty (require_pow_header accepted))
  | code -> failf "register_handshake: unexpected status %d" code

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

(* A re-register of a session that already holds a lease for the same alias is
   a routine refresh, not a new registration: it must succeed PoW-free and
   advertise D=0 even when the actor is warmed past grace (otherwise a `--once`
   connector re-registering its sessions every sync burns CPU minting needless
   proofs). Without the refresh discount this would 429 with pow_required. *)
let test_lease_refresh_is_pow_free () =
  with_pow_env "1" (fun () ->
    with_server (fun ~base_url ~relay:_ ->
      let alias = "pow-refresh" in
      let identity = Relay_identity.generate ~alias_hint:alias () in
      (* 1. First registration of the session — in grace, free. *)
      let first_body =
        register_body ~node_id:"node-refresh" ~session_id:"session-refresh"
          ~alias ~identity ~relay_url:base_url ()
      in
      post_register ~base_url first_body >>= fun first ->
      Alcotest.(check int) "first register ok" 200
        (Cohttp.Code.code_of_status first.status);
      (* 2. Warm the SAME actor (identity) past grace using a DIFFERENT alias.
         PoW cost accumulates per-actor (the Ed25519 identity), not per-alias,
         so warming under a throwaway alias pushes this actor past grace
         WITHOUT rebinding the original `alias` lease — which the relay does
         on a same-identity re-register (it replaces the alias's lease). Keeping
         the original (node,session) lease intact is what lets step 3 be
         recognized as a lease refresh. *)
      warm_actor_past_grace ~base_url ~identity ~alias:(alias ^ "-warmer") >>= fun () ->
      (* 3. Re-register the SAME (node, session, alias) = a lease refresh.
         Must succeed without a PoW challenge despite the warm actor, and
         advertise D=0 (refresh neither charges cost nor escalates). *)
      let refresh_body =
        register_body ~node_id:"node-refresh" ~session_id:"session-refresh"
          ~alias ~identity ~relay_url:base_url ()
      in
      post_register ~base_url refresh_body >|= fun refresh ->
      Alcotest.(check int) "refresh succeeds without pow" 200
        (Cohttp.Code.code_of_status refresh.status);
      Alcotest.(check bool) "refresh ok" true
        (json_member "ok" refresh.json = `Bool true);
      Alcotest.(check int) "refresh advertises D=0" 0
        (header_difficulty (require_pow_header refresh))))

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

(* ------------------------------------------------------------------ *)
(* B009: live-relayer PoW rate-limiting + difficulty-escalation tests. *)
(*                                                                      *)
(* The difficulty curve is set by `Pow_policy` (step=4, d_max=12), so   *)
(* the ONLY difficulties the relay ever emits are 0/4/8/12 = the        *)
(* 1x/16x/256x/4096x rungs. The B009 ticket asks about reaching "32x"   *)
(* (2^5); with step=4 the relay can never return difficulty 5, so 32x   *)
(* is unreachable BY CONSTRUCTION. These tests assert the REAL curve    *)
(* (0->4->8->12 and the d_max=12 cap) rather than chasing 32x. Each     *)
(* successful `register` adds route-cost 10 to the actor's accumulated  *)
(* cost; required_difficulty(C) = 0 for C<=grace(20), else              *)
(* min(d_max, step*ceil((C-grace)/bucket)). So a run of registers under *)
(* one identity drives required = [0;0;0;4;8;12;12;...].                *)
(* ------------------------------------------------------------------ *)

(* Q2: increasing PoW still works as difficulty climbs — walk the curve UP,
   asserting every escalated register is accepted once the higher proof is
   supplied, and that the relay's `X-C2C-PoW-Next` header pre-announces the
   next rung (so the escalation is visible to the agent before it bites). *)
let test_increasing_pow_walks_difficulty_curve_up () =
  with_pow_env "1" (fun () ->
    let rate_limiter = Relay.Rate_limiter_inst.create ~gc_interval:300.0 () in
    with_server ~rate_limiter (fun ~base_url ~relay:_ ->
      let alias = "pow-climb-curve" in
      let identity = Relay_identity.generate ~alias_hint:alias () in
      let actor_id = b64url identity.public_key in
      let steps = 8 in
      let rec climb k acc =
        if k > steps then Lwt.return (List.rev acc)
        else
          register_handshake ~rate_limiter ~base_url ~identity ~actor_id ~alias
            ~session_id:(Printf.sprintf "session-curve-%d" k)
          >>= fun pair ->
          climb (k + 1) (pair :: acc)
      in
      climb 1 [] >|= fun results ->
      let requireds = List.map fst results in
      let next_headers = List.map snd results in
      (* Required difficulty walks 0->0->0->4->8->12 then holds at the
         d_max=12 cap. Only emittable rungs (0/4/8/12) appear; never 32x. *)
      Alcotest.(check (list int)) "required difficulty walks the curve up"
        [ 0; 0; 0; 4; 8; 12; 12; 12 ] requireds;
      (* The success-path next-difficulty header pre-announces the rung the
         *next* register will demand: header[k] = required[k+1]. *)
      Alcotest.(check (list int))
        "X-C2C-PoW-Next pre-announces the next escalation"
        [ 0; 0; 4; 8; 12; 12; 12; 12 ] next_headers;
      (* Monotonic non-decreasing and never above the cap. *)
      ignore
        (List.fold_left
           (fun prev d ->
              Alcotest.(check bool) "difficulty non-decreasing" true (d >= prev);
              Alcotest.(check bool) "difficulty never exceeds d_max=12" true
                (d <= 12);
              d)
           0 requireds)))

(* Q3: flooding the relay drives difficulty UP toward — and pins it at — the
   d_max cap. Every successful register under one identity escalates cost, so
   after enough requests the required difficulty saturates at 12 and stays
   there no matter how much more we flood (it is never driven above the cap). *)
let test_flood_drives_difficulty_to_cap () =
  with_pow_env "1" (fun () ->
    let rate_limiter = Relay.Rate_limiter_inst.create ~gc_interval:300.0 () in
    with_server ~rate_limiter (fun ~base_url ~relay:_ ->
      let alias = "pow-flood-cap" in
      let identity = Relay_identity.generate ~alias_hint:alias () in
      let actor_id = b64url identity.public_key in
      let flood = 12 in
      let rec loop k last =
        if k > flood then Lwt.return last
        else
          register_handshake ~rate_limiter ~base_url ~identity ~actor_id ~alias
            ~session_id:(Printf.sprintf "session-flood-%d" k)
          >>= fun (required, _next) ->
          Alcotest.(check bool) "flood difficulty never exceeds d_max=12" true
            (required <= 12);
          loop (k + 1) required
      in
      loop 1 0 >>= fun final_required ->
      Alcotest.(check int) "flooding saturates difficulty at the d_max=12 cap"
        12 final_required;
      (* Continued flood: still pinned at the cap, never above it. *)
      register_handshake ~rate_limiter ~base_url ~identity ~actor_id ~alias
        ~session_id:"session-flood-extra"
      >|= fun (required, next_header) ->
      Alcotest.(check int) "cap holds under continued flood" 12 required;
      Alcotest.(check int) "next-difficulty header pinned at the cap" 12
        next_header))

(* Q1: after difficulty escalates (bucket N -> N+1), a proof minted at the OLD
   (lower) difficulty is REJECTED. We climb to the bucket-2 rung (difficulty
   8), mint a proof that clears the OLD bar (4) but not the new one (8), and
   confirm the relay rejects it. Then a correctly-escalated proof on the SAME
   challenge is accepted — isolating the rejection cause to the proof's
   difficulty (not a stale/spent challenge), because `verify` short-circuits
   before `consume_if_valid`, leaving the challenge intact on a failed verify. *)
let test_stale_low_difficulty_proof_rejected_after_escalation () =
  with_pow_env "1" (fun () ->
    let rate_limiter = Relay.Rate_limiter_inst.create ~gc_interval:300.0 () in
    with_server ~rate_limiter (fun ~base_url ~relay:_ ->
      let alias = "pow-stale-proof" in
      let identity = Relay_identity.generate ~alias_hint:alias () in
      let actor_id = b64url identity.public_key in
      (* Climb so the actor sits one bucket below the bucket-2 rung: registers
         1-3 are in grace (required 0), register 4 demands difficulty 4. After
         it lands, the *next* fresh register will demand difficulty 8. *)
      let rec climb k =
        if k > 4 then Lwt.return_unit
        else
          register_handshake ~rate_limiter ~base_url ~identity ~actor_id ~alias
            ~session_id:(Printf.sprintf "session-stale-climb-%d" k)
          >>= fun (required, _) ->
          let expected = if k <= 3 then 0 else 4 in
          Alcotest.(check int)
            (Printf.sprintf "stale-climb step %d demands old/grace rung" k)
            expected required;
          climb (k + 1)
      in
      climb 1 >>= fun () ->
      reset_ip_rate_limit rate_limiter;
      (* Escalate: a fresh register now demands the bucket-2 difficulty (8). *)
      let challenge_req =
        register_body ~node_id:"node-climb" ~session_id:"session-stale-escalated"
          ~alias ~identity ~relay_url:base_url ()
      in
      post_register ~base_url challenge_req >>= fun rejected ->
      Alcotest.(check int) "escalated register is pow_required (429)" 429
        (Cohttp.Code.code_of_status rejected.status);
      let new_difficulty, epoch, server_nonce = required_pow_fields rejected in
      Alcotest.(check int) "escalated to bucket-2 difficulty (8 = 256x)" 8
        new_difficulty;
      let challenge =
        Pow.challenge_string ~ctx:Pow.ctx ~route:"register" ~actor_id ~epoch
          ~server_nonce
      in
      let old_difficulty = 4 in
      let stale_nonce =
        mint_in_band ~challenge ~min_difficulty:old_difficulty
          ~below_difficulty:new_difficulty
      in
      (* The stale proof clears the OLD bar but not the escalated one. *)
      Alcotest.(check bool) "stale proof clears the old difficulty (4)" true
        (Pow.verify ~challenge ~difficulty:old_difficulty ~pow_nonce:stale_nonce);
      Alcotest.(check bool) "stale proof fails the escalated difficulty (8)"
        false
        (Pow.verify ~challenge ~difficulty:new_difficulty ~pow_nonce:stale_nonce);
      let stale_body =
        register_body ~pow_nonce:stale_nonce ~pow_epoch:epoch
          ~pow_server_nonce:server_nonce ~node_id:"node-climb"
          ~session_id:"session-stale-submit" ~alias ~identity
          ~relay_url:base_url ()
      in
      post_register ~base_url stale_body >>= fun stale_resp ->
      Alcotest.(check int) "old-difficulty proof REJECTED after escalation" 429
        (Cohttp.Code.code_of_status stale_resp.status);
      Alcotest.(check string) "rejection is pow_required" "pow_required"
        (json_string "error_code" stale_resp.json);
      let still_required, _, _ = required_pow_fields stale_resp in
      Alcotest.(check int) "relay still demands the escalated difficulty (8)" 8
        still_required;
      (* Re-mint against the SAME challenge at the escalated difficulty. The
         failed verify above did NOT consume the challenge, so a correctly
         escalated proof on it is accepted — proving the rejection was about
         difficulty, not a spent/stale challenge. *)
      let fresh_nonce =
        match Pow.mint ~challenge ~difficulty:new_difficulty with
        | Some n -> n
        | None -> Alcotest.fail "Pow.mint failed at escalated difficulty"
      in
      let fresh_body =
        register_body ~pow_nonce:fresh_nonce ~pow_epoch:epoch
          ~pow_server_nonce:server_nonce ~node_id:"node-climb"
          ~session_id:"session-stale-accepted" ~alias ~identity
          ~relay_url:base_url ()
      in
      post_register ~base_url fresh_body >|= fun fresh_resp ->
      Alcotest.(check int) "escalated proof on the SAME challenge accepted" 200
        (Cohttp.Code.code_of_status fresh_resp.status);
      Alcotest.(check bool) "accepted ok" true
        (json_member "ok" fresh_resp.json = `Bool true)))

(* ------------------------------------------------------------------ *)
(* B014: per-message PoW-difficulty metadata on delivered messages.    *)
(*                                                                      *)
(* When the relay accepts a DM it records the sender's current PoW      *)
(* difficulty (leading-zero bits, keyed on the sender's identity), and  *)
(* the recipient sees it on delivery as a self-describing [pow] object  *)
(* ({ difficulty_bits, expected_hashes = 2^bits, scheme }). Signed      *)
(* content is untouched. Verified end-to-end over real HTTP.            *)
(* ------------------------------------------------------------------ *)

let find_message_with_content msgs content =
  List.find_opt (fun m -> json_string "content" m = content)
    (match msgs with `List l -> l | _ -> [])

(* Enabled + warmed sender: the delivered message carries a [pow] object whose
   difficulty_bits > 0 and expected_hashes = 2^bits. *)
let test_b014_delivered_message_carries_pow_metadata () =
  with_pow_env "1" (fun () ->
    let rate_limiter = Relay.Rate_limiter_inst.create ~gc_interval:300.0 () in
    with_server ~rate_limiter (fun ~base_url ~relay ->
      let rcpt_alias = "b014-rcpt" in
      let rcpt_identity = Relay_identity.generate ~alias_hint:rcpt_alias () in
      (* Register recipient (in grace → free) so the DM has an inbox to land in. *)
      reset_ip_rate_limit rate_limiter;
      post_register ~base_url
        (register_body ~node_id:"node-b014-rcpt" ~session_id:"session-b014-rcpt"
           ~alias:rcpt_alias ~identity:rcpt_identity ~relay_url:base_url ())
      >>= fun rcpt_reg ->
      Alcotest.(check int) "recipient register ok" 200
        (Cohttp.Code.code_of_status rcpt_reg.status);
      (* Register + warm the sender past grace so its required difficulty > 0. *)
      let sender_alias = "b014-sender" in
      let sender_identity = Relay_identity.generate ~alias_hint:sender_alias () in
      warm_actor_past_grace ~base_url ~identity:sender_identity ~alias:sender_alias
      >>= fun () ->
      reset_ip_rate_limit rate_limiter;
      post_send ~base_url ~from_alias:sender_alias ~to_alias:rcpt_alias
        ~content:"b014-hello" >|= fun sent ->
      Alcotest.(check int) "send ok" 200 (Cohttp.Code.code_of_status sent.status);
      (* Read the recipient's inbox directly from the relay backend: the HTTP
         /poll_inbox path requires a signed owner (orthogonal to B014), whereas
         the stored row is exactly what poll would return. *)
      let msgs =
        Relay.InMemoryRelay.poll_inbox relay ~node_id:"node-b014-rcpt"
          ~session_id:"session-b014-rcpt"
      in
      match find_message_with_content (`List msgs) "b014-hello" with
      | None -> failf "delivered message not found in inbox"
      | Some m ->
        (* content (the signed payload surface) is unchanged. *)
        Alcotest.(check string) "content preserved" "b014-hello"
          (json_string "content" m);
        let pow = json_member "pow" m in
        Alcotest.(check bool) "pow object present" true (pow <> `Null);
        let bits = json_int "difficulty_bits" pow in
        Alcotest.(check bool) "difficulty_bits > 0 for warmed sender" true (bits > 0);
        Alcotest.(check int) "expected_hashes = 2^difficulty_bits" (1 lsl bits)
          (json_int "expected_hashes" pow);
        Alcotest.(check string) "scheme" Pow.scheme_id (json_string "scheme" pow)))

(* PoW disabled: no [pow] object is attached (difficulty is unrecorded). *)
let test_b014_no_pow_metadata_when_disabled () =
  with_pow_env "0" (fun () ->
    let rate_limiter = Relay.Rate_limiter_inst.create ~gc_interval:300.0 () in
    with_server ~rate_limiter (fun ~base_url ~relay ->
      reset_ip_rate_limit rate_limiter;
      post_register ~base_url (`Assoc [
        "node_id", `String "node-b014-off-rcpt";
        "session_id", `String "session-b014-off-rcpt";
        "alias", `String "b014-off-rcpt";
      ]) >>= fun rcpt_reg ->
      Alcotest.(check int) "recipient register ok" 200
        (Cohttp.Code.code_of_status rcpt_reg.status);
      reset_ip_rate_limit rate_limiter;
      post_register ~base_url (`Assoc [
        "node_id", `String "node-b014-off-sender";
        "session_id", `String "session-b014-off-sender";
        "alias", `String "b014-off-sender";
      ]) >>= fun _ ->
      reset_ip_rate_limit rate_limiter;
      post_send ~base_url ~from_alias:"b014-off-sender" ~to_alias:"b014-off-rcpt"
        ~content:"b014-off" >|= fun sent ->
      Alcotest.(check int) "send ok" 200 (Cohttp.Code.code_of_status sent.status);
      let msgs =
        Relay.InMemoryRelay.poll_inbox relay ~node_id:"node-b014-off-rcpt"
          ~session_id:"session-b014-off-rcpt"
      in
      match find_message_with_content (`List msgs) "b014-off" with
      | None -> failf "delivered message not found in inbox"
      | Some m ->
        Alcotest.(check bool) "no pow object when PoW disabled" true
          (json_member "pow" m = `Null)))

(* Broker render surface: inbox_row_json emits the pow object iff recorded. *)
let test_b014_inbox_row_json_render () =
  let mk pow_difficulty =
    { C2c_mcp_helpers.from_alias = "s"; to_alias = "r"; content = "c"; deferrable = false;
      reply_via = None; enc_status = None; ts = 1.0; ephemeral = false;
      message_id = Some "m1"; pow_difficulty }
  in
  let row m = C2c_inbox_handlers.inbox_row_json ~m ~content:"c"
      ~delivery_state:C2c_schema_v1.Delivered ~enc_status:None in
  let pow_of j = match j with `Assoc f -> List.assoc_opt "pow" f | _ -> None in
  (match pow_of (row (mk (Some 8))) with
   | Some pow ->
     let open Yojson.Safe.Util in
     Alcotest.(check int) "rendered difficulty_bits" 8 (pow |> member "difficulty_bits" |> to_int);
     Alcotest.(check int) "rendered expected_hashes" 256 (pow |> member "expected_hashes" |> to_int)
   | None -> Alcotest.fail "expected pow object for Some 8");
  Alcotest.(check bool) "no pow object for None" true
    (pow_of (row (mk None)) = None)

let () =
  Alcotest.run "pow_relay" [
    "b014-metadata", [
      Alcotest.test_case "delivered message carries pow metadata (warmed sender)"
        `Quick test_b014_delivered_message_carries_pow_metadata;
      Alcotest.test_case "no pow metadata when relay PoW disabled"
        `Quick test_b014_no_pow_metadata_when_disabled;
      Alcotest.test_case "inbox_row_json renders pow object iff recorded"
        `Quick test_b014_inbox_row_json_render;
    ];
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
      Alcotest.test_case "enabled: lease refresh is pow-free even when warm"
        `Quick test_lease_refresh_is_pow_free;
      Alcotest.test_case "enabled: verified PoW is spent on failed register"
        `Quick test_verified_pow_is_spent_even_if_register_body_fails;
      Alcotest.test_case "enabled: forged PoW challenge fields are rejected"
        `Quick test_forged_pow_challenge_fields_are_rejected;
      Alcotest.test_case "enabled: malformed PoW fields are rejected"
        `Quick test_malformed_pow_fields_are_rejected_without_exception;
      Alcotest.test_case
        "B009: increasing PoW walks the difficulty curve up (0->4->8->12)"
        `Quick test_increasing_pow_walks_difficulty_curve_up;
      Alcotest.test_case
        "B009: flooding drives difficulty up to the d_max=12 cap"
        `Quick test_flood_drives_difficulty_to_cap;
      Alcotest.test_case
        "B009: old-difficulty proof rejected after difficulty escalation"
        `Quick test_stale_low_difficulty_proof_rejected_after_escalation;
    ];
  ]
