(* B325 regression: relay_client's request economy.

   Two defects, both CLI-side one-shot/daemon paths (whoami --relay,
   doctor --relay, mesh status, relay list, ws client):

   1. maybe_annotate_protocol_skew fired an extra GET /health after EVERY
      non-transport, non-ok error response — including 429s — deepening the
      very rate-limit bucket that produced the error and doubling per-op
      latency. The B121 contract (a failing op is rewritten into
      incompatible_client when /health advertises a skewed wire version) is
      preserved, but the health/compat verdict is now cached per client (at
      most one probe per client lifetime) and a 429 never probes at all: a
      rate-limit answer cannot be protocol skew, and probing it deepens the
      bucket.

   2. net_ctx_of_bundle re-read and re-parsed the CA PEM on every request.
      The finished TLS ctx is now cached per bundle path and re-parsed only
      when the file's mtime moves (bundle rotation). Deletion of the file
      after a successful parse keeps the cached ctx working — the anchors
      are already in memory. *)

open Alcotest
module S = Relay_test_support

let json_member name = function
  | `Assoc fields -> List.assoc_opt name fields |> Option.value ~default:`Null
  | _ -> `Null

let ok_body = {|{"ok":true}|}

let rate_limited_body =
  {|{"ok":false,"error_code":"rate_limit_exceeded","retry_after":1}|}

let opaque_fail_body =
  {|{"ok":false,"error_code":"signature_invalid","error":"signature verification failed"}|}

let health_body ~protocol_version =
  Yojson.Safe.to_string
    (`Assoc
       [ ("ok", `Bool true);
         ("version", `String "0.11.0");
         ("git_hash", `String "deadbeef");
         ("protocol_version", `Int protocol_version);
         ("min_client_protocol_version", `Int protocol_version);
         ("auth_mode", `String "prod") ])

let paths_of requests = List.map (fun (r : S.captured_request) -> r.S.path) requests

let count_path requests path =
  paths_of requests |> List.filter (fun p -> p = path) |> List.length

(* A 429 can never be protocol skew: the op must cost exactly ONE request,
   with the rate-limit body passed through untouched. *)
let test_429_op_issues_exactly_one_request () =
  let routes =
    [ S.route ~meth:"POST" ~path:"/send" [ S.response ~status:429 rate_limited_body ] ]
  in
  S.with_server ~routes (fun t ->
      let client =
        Relay.Relay_client.make ~timeout:2.0 (Printf.sprintf "http://127.0.0.1:%d" t.S.port)
      in
      let json =
        Lwt_main.run
          (Relay.Relay_client.send client ~from_alias:"a" ~to_alias:"b" ~content:"hi" ())
      in
      check bool "ok:false" true (json_member "ok" json = `Bool false);
      check bool "error_code preserved" true
        (json_member "error_code" json = `String "rate_limit_exceeded");
      check bool "not transport" false (Relay.Relay_client.is_transport_error json);
      check bool "not incompatible" false
        (Relay.Relay_client.is_protocol_incompatible json);
      let reqs = S.requests t in
      check int "exactly one request (no /health probe)" 1 (List.length reqs);
      check int "it is the /send" 1 (count_path reqs "/send"))

(* A successful op must also cost exactly one request. *)
let test_ok_op_issues_exactly_one_request () =
  let routes =
    [ S.route ~meth:"POST" ~path:"/send" [ S.response ok_body ] ]
  in
  S.with_server ~routes (fun t ->
      let client =
        Relay.Relay_client.make ~timeout:2.0 (Printf.sprintf "http://127.0.0.1:%d" t.S.port)
      in
      let json =
        Lwt_main.run
          (Relay.Relay_client.send client ~from_alias:"a" ~to_alias:"b" ~content:"hi" ())
      in
      check bool "ok:true" true (json_member "ok" json = `Bool true);
      let reqs = S.requests t in
      check int "exactly one request" 1 (List.length reqs))

(* B121 stays: the FIRST opaque error on a skewed relay still probes /health
   once and rewrites into incompatible_client. The amplification is what
   goes: the verdict is cached per client, so N erroring ops cost N+1
   requests, not 2N, and every rewritten op carries the upgrade message. *)
let test_skew_probe_fires_at_most_once_per_client () =
  let routes =
    [ S.route ~meth:"GET" ~path:"/health"
        [ S.response (health_body ~protocol_version:(Version.relay_protocol_version + 1)) ];
      S.route ~meth:"POST" ~path:"/send" [ S.response ~status:400 opaque_fail_body ];
    ]
  in
  S.with_server ~routes (fun t ->
      let client =
        Relay.Relay_client.make ~timeout:2.0 (Printf.sprintf "http://127.0.0.1:%d" t.S.port)
      in
      let send_once () =
        Lwt_main.run
          (Relay.Relay_client.send client ~from_alias:"a" ~to_alias:"b" ~content:"hi" ())
      in
      let r1 = send_once () and r2 = send_once () and r3 = send_once () in
      List.iter
        (fun (n, r) ->
          check bool
            (Printf.sprintf "op %d rewritten to incompatible_client (B121)" n)
            true
            (Relay.Relay_client.is_protocol_incompatible r))
        [ (1, r1); (2, r2); (3, r3) ];
      let reqs = S.requests t in
      check int "three sends" 3 (count_path reqs "/send");
      check int "one health probe total (was one per error)" 1
        (count_path reqs "/health"))

(* Self-signed test certificate (CN=c2c-b314-test, valid to 2126) — same
   embedded fixture the B314 suite uses, so no external tool is needed. *)
let fixture_cert_pem = {|
-----BEGIN CERTIFICATE-----
MIIDJDCCAgygAwIBAgIUBj/YWGnIMXrmTHPvQlcElOTIf30wDQYJKoZIhvcNAQEL
BQAwGDEWMBQGA1UEAwwNYzJjLWIzMTQtdGVzdDAgFw0yNjA5MTcxNzE1MjZaGA8y
MTI2MDgyNDE3MTUyNlowGDEWMBQGA1UEAwwNYzJjLWIzMTQtdGVzdDCCASIwDQYJ
KoZIhvcNAQEBBQADggEPADCCAQoCggEBAMsMHvKifieDmCkGjIktwgWOOYmw3k2N
ckm2NFiIQ/tLoBttijrCPTjEP4QlW7d2InxNjur6o0fz8mnteweum6A6xfQthqst
JYMZsR2kfQbxEm3ZNJ3wT6s+gmxeMYYMdY9bF8yWrXEf75h23pfw4jTDRWvku1dy
MGi1WzXrQWMNFXuc0HHweafIeLnhq/ytzeV2ZBAfhIwRYTesJ4C2LUgUxtntVuFm
8ltUv98ihFTBbb6Lq61TKjCAPpW4U3X4F6UUQFY2K9wpGXe0F2hWC2d2Rphi0kzT
hu+68Sxh6g+Tp9WNlFeMolgKJa8awoniX4cSf3IxDuXhpi9Ze4MZ+8cCAwEAAaNk
MGIwHQYDVR0OBBYEFOLZCLioT2sA1/vUyUKFWc3nUMRNMB8GA1UdIwQYMBaAFOLZ
CLioT2sA1/vUyUKFWc3nUMRNMA8GA1UdEwEB/wQFMAMBAf8wDwYDVR0RBAgwBocE
fwAAATANBgkqhkiG9w0BAQsFAAOCAQEAri6wHCHZi17asxRp+zkPzSxLAKIlq/Mz
YE+3C8Y6B1oleozpLdeOT7w8cWMO6PVlV5VIwgPwoAkn8u+oKtCHuHJr4G0dPia4
BhMbeGNbYzshvV4L6utTetdiSbDVVLMdGGJN5zmjQLbpm6ugnHTy9THhTmt+Ji3H
7AIbNB4rJdQ0qgdpVdEOdrgG2JgztLP5FkhyKQeL29lTyeauQ0MzMxlWyNplMWcc
im9CTisusrrWJmuW9cPzzZZZUm/QTHTc45Ng699YneVyVpqfnnlRKLuT19MG42ww
0bNwRXVp15I94F9axfjf2mH99M2pNhLpHE7J77eDbGHDYa3qImhL5Q==
-----END CERTIFICATE-----
|}

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "c2c-b325-test-%d-%d" (Unix.getpid ()) (Random.int 1_000_000))
  in
  Unix.mkdir dir 0o755;
  dir

let rmrf path =
  let rec aux p =
    match (Unix.lstat p).st_kind with
    | Unix.S_DIR ->
        let entries = Sys.readdir p in
        Array.iter (fun e -> aux (Filename.concat p e)) entries;
        Unix.rmdir p
    | _ -> Unix.unlink p
    | exception _ -> ()
  in
  try aux path with _ -> ()

(* The CA bundle must be read once, not once per request: after two ops the
   file is deleted and a third op must still succeed on the cached ctx
   (today it dies with connection_error because the ctx is rebuilt per
   request). Rewriting the file with a bumped mtime must invalidate the
   cache and keep working (rotation re-parses). All ops over plain http so
   no TLS server is needed — building the ctx is the behavior under test. *)
let test_ca_bundle_ctx_reused_across_ops () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let bundle = Filename.concat tmp "ca.pem" in
  let write_bundle () =
    let oc = open_out bundle in
    output_string oc fixture_cert_pem;
    close_out oc
  in
  write_bundle ();
  let routes =
    [ S.route ~meth:"POST" ~path:"/send" [ S.response ok_body ] ]
  in
  S.with_server ~routes (fun t ->
      let client =
        Relay.Relay_client.make ~timeout:2.0 ~ca_bundle:bundle
          (Printf.sprintf "http://127.0.0.1:%d" t.S.port)
      in
      let send_once () =
        Lwt_main.run
          (Relay.Relay_client.send client ~from_alias:"a" ~to_alias:"b" ~content:"hi" ())
      in
      let r1 = send_once () and r2 = send_once () in
      check bool "op1 ok" true (json_member "ok" r1 = `Bool true);
      check bool "op2 ok" true (json_member "ok" r2 = `Bool true);
      Unix.unlink bundle;
      let r3 = send_once () in
      check bool
        "op3 ok after the bundle file was deleted (cached ctx, no re-read)"
        true
        (json_member "ok" r3 = `Bool true);
      write_bundle ();
      (* Force a distinct mtime so rotation is deterministic on any fs. *)
      Unix.utimes bundle 1.0 2.0;
      let r4 = send_once () in
      check bool "op4 ok after bundle rotation (re-parsed)" true
        (json_member "ok" r4 = `Bool true);
      let reqs = S.requests t in
      check int "four ops, four requests" 4 (List.length reqs);
      check int "no /health probes at all" 0 (count_path reqs "/health"))

let () =
  run "c2c-relay-b325-relay-client"
    [ ( "request economy"
      , [ test_case "429 op issues exactly one request" `Quick
            test_429_op_issues_exactly_one_request;
          test_case "ok op issues exactly one request" `Quick
            test_ok_op_issues_exactly_one_request;
          test_case "skew probe fires at most once per client" `Quick
            test_skew_probe_fires_at_most_once_per_client ] );
      ( "ca bundle ctx"
      , [ test_case "ctx reused across ops; rotation re-parses" `Quick
            test_ca_bundle_ctx_reused_across_ops ] );
    ]
