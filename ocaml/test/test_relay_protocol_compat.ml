(* B121: client surfaces a clear incompatible-relay-protocol upgrade message
   instead of opaque signature_invalid / bad_request / http_error_* errors
   when /health advertises a wire protocol the client cannot speak. *)

open Alcotest

module S = Relay_test_support

let json_member name = function
  | `Assoc fields -> List.assoc_opt name fields |> Option.value ~default:`Null
  | _ -> `Null

let contains ~needle haystack =
  let nlen = String.length needle and hlen = String.length haystack in
  if nlen = 0 then true
  else begin
    let found = ref false in
    let i = ref 0 in
    while (not !found) && !i <= hlen - nlen do
      if String.sub haystack !i nlen = needle then found := true;
      incr i
    done;
    !found
  end

let health_body ~protocol_version ?(min_client = protocol_version)
    ?(version = "0.11.0") ?(git_hash = "deadbeef") () =
  Yojson.Safe.to_string
    (`Assoc
       [ ("ok", `Bool true);
         ("version", `String version);
         ("git_hash", `String git_hash);
         ("protocol_version", `Int protocol_version);
         ("min_client_protocol_version", `Int min_client);
         ("auth_mode", `String "prod");
         ("pow",
          `Assoc
            [ ("enabled", `Bool false); ("scheme", `String Pow.scheme_id) ])
       ])

let opaque_fail_body =
  Yojson.Safe.to_string
    (`Assoc
       [ ("ok", `Bool false);
         ("error_code", `String "signature_invalid");
         ("error", `String "signature verification failed") ])

(* --- pure protocol_compat_of_health ------------------------------------ *)

let test_compat_matching_versions () =
  let j =
    `Assoc
      [ ("ok", `Bool true);
        ("protocol_version", `Int Version.relay_protocol_version);
        ("min_client_protocol_version",
         `Int Version.relay_min_client_protocol_version);
        ("version", `String Version.version) ]
  in
  match Relay.Relay_client.protocol_compat_of_health j with
  | Relay.Relay_client.Compatible -> ()
  | _ -> fail "matching protocol_version should be Compatible"

let test_compat_missing_field_is_unknown () =
  let j = `Assoc [ ("ok", `Bool true); ("version", `String "0.9.0") ] in
  match Relay.Relay_client.protocol_compat_of_health j with
  | Relay.Relay_client.Unknown -> ()
  | _ -> fail "pre-B121 health without protocol_version should be Unknown"

let test_compat_client_too_old () =
  let server_pv = Version.relay_protocol_version + 1 in
  let j =
    `Assoc
      [ ("ok", `Bool true);
        ("protocol_version", `Int server_pv);
        ("min_client_protocol_version", `Int server_pv);
        ("version", `String "0.11.0") ]
  in
  match Relay.Relay_client.protocol_compat_of_health j with
  | Relay.Relay_client.Client_too_old
      { server_protocol; client_protocol; min_client; server_version } ->
      check int "server_protocol" server_pv server_protocol;
      check int "client_protocol" Version.relay_protocol_version client_protocol;
      check int "min_client" server_pv min_client;
      check (option string) "server_version" (Some "0.11.0") server_version
  | _ -> fail "expected Client_too_old"

let test_compat_client_too_new () =
  (* Client speaks vN but server only speaks a lower version. *)
  let j =
    `Assoc
      [ ("ok", `Bool true);
        ("protocol_version", `Int 0);
        ("min_client_protocol_version", `Int 0);
        ("version", `String "0.9.0") ]
  in
  match
    Relay.Relay_client.protocol_compat_of_health ~client_protocol:1 j
  with
  | Relay.Relay_client.Client_too_new { server_protocol; client_protocol; _ } ->
      check int "server_protocol" 0 server_protocol;
      check int "client_protocol" 1 client_protocol
  | _ -> fail "expected Client_too_new"

let test_upgrade_message_shape () =
  let compat =
    Relay.Relay_client.Client_too_old
      { server_protocol = 2;
        client_protocol = 1;
        min_client = 2;
        server_version = Some "0.11.0" }
  in
  match Relay.Relay_client.upgrade_message ~url:"https://relay.c2c.im" compat with
  | None -> fail "expected upgrade message"
  | Some msg ->
      check bool "names protocol v2" true
        (contains ~needle:"protocol v2" msg);
      check bool "names client v1" true
        (contains ~needle:"this client speaks v1" msg);
      check bool "names server version" true
        (contains ~needle:"server 0.11.0" msg);
      check bool "upgrade fix" true
        (contains ~needle:"git pull && just install-all" msg);
      check bool "relay url" true
        (contains ~needle:"https://relay.c2c.im" msg)

let test_transport_not_incompatible () =
  let transport =
    `Assoc
      [ ("ok", `Bool false);
        ("error_code", `String "connection_error");
        ("error", `String "request_timeout");
        ("transport", `Bool true) ]
  in
  check bool "transport is transport" true
    (Relay.Relay_client.is_transport_error transport);
  check bool "transport is not protocol-incompatible" false
    (Relay.Relay_client.is_protocol_incompatible transport)

(* --- live: scripted /health with bumped protocol_version --------------- *)

let test_health_rewrites_when_server_protocol_ahead () =
  let routes =
    [ S.route ~meth:"GET" ~path:"/health"
        [ S.response (health_body ~protocol_version:(Version.relay_protocol_version + 1) ()) ]
    ]
  in
  S.with_server ~routes (fun t ->
      let url = Printf.sprintf "http://127.0.0.1:%d" t.S.port in
      let client = Relay.Relay_client.make ~timeout:2.0 url in
      let json = Lwt_main.run (Relay.Relay_client.health client) in
      check bool "ok:false" true (json_member "ok" json = `Bool false);
      check bool "error_code=incompatible_client" true
        (json_member "error_code" json = `String "incompatible_client");
      check bool "not a transport error" false
        (Relay.Relay_client.is_transport_error json);
      check bool "is_protocol_incompatible" true
        (Relay.Relay_client.is_protocol_incompatible json);
      (match json_member "error" json with
       | `String msg ->
           check bool "upgrade message in error" true
             (contains ~needle:"upgrade c2c" msg
              && contains ~needle:"protocol v" msg
              && contains ~needle:url msg)
       | _ -> fail "missing error string");
      ())

let test_health_compatible_when_versions_match () =
  let routes =
    [ S.route ~meth:"GET" ~path:"/health"
        [ S.response
            (health_body ~protocol_version:Version.relay_protocol_version
               ~version:Version.version ()) ]
    ]
  in
  S.with_server ~routes (fun t ->
      let url = Printf.sprintf "http://127.0.0.1:%d" t.S.port in
      let client = Relay.Relay_client.make ~timeout:2.0 url in
      let json = Lwt_main.run (Relay.Relay_client.health client) in
      check bool "ok:true" true (json_member "ok" json = `Bool true);
      check bool "not incompatible" false
        (Relay.Relay_client.is_protocol_incompatible json);
      check bool "protocol_version preserved" true
        (json_member "protocol_version" json
         = `Int Version.relay_protocol_version);
      ())

let test_health_unknown_pre_b121_passes () =
  let body =
    Yojson.Safe.to_string
      (`Assoc
         [ ("ok", `Bool true);
           ("version", `String "0.9.0");
           ("git_hash", `String "abc");
           ("auth_mode", `String "dev") ])
  in
  let routes =
    [ S.route ~meth:"GET" ~path:"/health" [ S.response body ] ]
  in
  S.with_server ~routes (fun t ->
      let url = Printf.sprintf "http://127.0.0.1:%d" t.S.port in
      let client = Relay.Relay_client.make ~timeout:2.0 url in
      let json = Lwt_main.run (Relay.Relay_client.health client) in
      check bool "ok:true (legacy health)" true
        (json_member "ok" json = `Bool true);
      check bool "not incompatible" false
        (Relay.Relay_client.is_protocol_incompatible json);
      ())

let test_failed_op_rewrites_opaque_error_to_upgrade () =
  (* A failing /send would previously surface signature_invalid. With a
     bumped /health protocol_version the client must rewrite to
     incompatible_client + upgrade text, keeping the underlying code. *)
  let routes =
    [ S.route ~meth:"GET" ~path:"/health"
        [ S.response
            (health_body
               ~protocol_version:(Version.relay_protocol_version + 1)
               ~version:"0.11.0" ()) ];
      S.route ~meth:"POST" ~path:"/send"
        [ S.response ~status:400 opaque_fail_body ];
    ]
  in
  S.with_server ~routes (fun t ->
      let url = Printf.sprintf "http://127.0.0.1:%d" t.S.port in
      let client = Relay.Relay_client.make ~timeout:2.0 url in
      let json =
        Lwt_main.run
          (Relay.Relay_client.send client ~from_alias:"a" ~to_alias:"b"
             ~content:"hi" ())
      in
      check bool "ok:false" true (json_member "ok" json = `Bool false);
      check bool "error_code rewritten to incompatible_client" true
        (json_member "error_code" json = `String "incompatible_client");
      check bool "underlying_error_code preserved" true
        (json_member "underlying_error_code" json
         = `String "signature_invalid");
      check bool "not transport" false
        (Relay.Relay_client.is_transport_error json);
      (match json_member "error" json with
       | `String msg ->
           check bool "surfaces upgrade not signature_invalid as primary" true
             (contains ~needle:"upgrade c2c" msg
              && contains ~needle:"protocol v" msg
              && not (contains ~needle:"signature verification failed" msg))
       | _ -> fail "missing error string");
      ())

let test_failed_op_compatible_keeps_opaque_error () =
  (* When protocol matches, a genuine signature_invalid must stay
     signature_invalid — no false upgrade claim. *)
  let routes =
    [ S.route ~meth:"GET" ~path:"/health"
        [ S.response
            (health_body ~protocol_version:Version.relay_protocol_version ()) ];
      S.route ~meth:"POST" ~path:"/send"
        [ S.response ~status:400 opaque_fail_body ];
    ]
  in
  S.with_server ~routes (fun t ->
      let url = Printf.sprintf "http://127.0.0.1:%d" t.S.port in
      let client = Relay.Relay_client.make ~timeout:2.0 url in
      let json =
        Lwt_main.run
          (Relay.Relay_client.send client ~from_alias:"a" ~to_alias:"b"
             ~content:"hi" ())
      in
      check bool "ok:false" true (json_member "ok" json = `Bool false);
      check bool "error_code stays signature_invalid" true
        (json_member "error_code" json = `String "signature_invalid");
      check bool "not rewritten to incompatible_client" false
        (Relay.Relay_client.is_protocol_incompatible json);
      ())

let test_unreachable_stays_transport () =
  (* Connection refused: must remain transport, not incompatible_client. *)
  let port = S.closed_port () in
  let url = Printf.sprintf "http://127.0.0.1:%d" port in
  let client = Relay.Relay_client.make ~timeout:0.5 url in
  let json = Lwt_main.run (Relay.Relay_client.health client) in
  check bool "ok:false" true (json_member "ok" json = `Bool false);
  check bool "is transport" true (Relay.Relay_client.is_transport_error json);
  check bool "not protocol-incompatible" false
    (Relay.Relay_client.is_protocol_incompatible json)

let with_pow_env_off f =
  let previous = Sys.getenv_opt "C2C_RELAY_POW" in
  let restore () =
    match previous with
    | Some v -> Unix.putenv "C2C_RELAY_POW" v
    | None -> Unix.putenv "C2C_RELAY_POW" ""
  in
  Unix.putenv "C2C_RELAY_POW" "";
  Fun.protect ~finally:restore f

let test_real_relay_health_advertises_protocol_version () =
  with_pow_env_off @@ fun () ->
  Relay_test_support_real.with_server (fun ~base_url ~relay:_ ->
      let open Lwt.Infix in
      Relay_test_support_real.call_json ~base_url ~meth:`GET ~path:"/health" ()
      >>= fun health ->
      (match health.Relay_test_support_real.json with
       | Some j ->
           check bool "ok" true (json_member "ok" j = `Bool true);
           check bool "protocol_version present" true
             (json_member "protocol_version" j
              = `Int Version.relay_protocol_version);
           check bool "min_client present" true
             (json_member "min_client_protocol_version" j
              = `Int Version.relay_min_client_protocol_version)
       | None -> fail "/health body was not JSON");
      Lwt.return_unit)

let () =
  run "relay_protocol_compat_b121"
    [ ( "pure",
        [ test_case "matching versions → Compatible" `Quick
            test_compat_matching_versions;
          test_case "missing protocol_version → Unknown" `Quick
            test_compat_missing_field_is_unknown;
          test_case "server ahead → Client_too_old" `Quick
            test_compat_client_too_old;
          test_case "server behind → Client_too_new" `Quick
            test_compat_client_too_new;
          test_case "upgrade_message shape" `Quick test_upgrade_message_shape;
          test_case "transport ≠ incompatible" `Quick
            test_transport_not_incompatible;
        ] );
      ( "scripted",
        [ test_case "health rewrites when server protocol ahead" `Quick
            test_health_rewrites_when_server_protocol_ahead;
          test_case "health passes when versions match" `Quick
            test_health_compatible_when_versions_match;
          test_case "pre-B121 health without protocol_version ok" `Quick
            test_health_unknown_pre_b121_passes;
          test_case "failed op rewrites opaque error to upgrade" `Quick
            test_failed_op_rewrites_opaque_error_to_upgrade;
          test_case "compatible failed op keeps original error_code" `Quick
            test_failed_op_compatible_keeps_opaque_error;
          test_case "unreachable stays transport" `Quick
            test_unreachable_stays_transport;
        ] );
      ( "real",
        [ test_case "/health advertises protocol_version" `Quick
            test_real_relay_health_advertises_protocol_version;
        ] );
    ]
