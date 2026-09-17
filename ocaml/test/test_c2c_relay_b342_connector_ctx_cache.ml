(* B342 regression: the connector's INLINE HTTP client
   (C2c_relay_connector.Relay_client) re-parsed the CA bundle PEM and rebuilt
   the TLS ctx on EVERY request while a bundle was set — a B314 port kept
   byte-equivalent to relay_client's pre-B325 version. The connector's poll
   loop re-paid a file read + X509 decode on every op.

   Fix contract (port of relay_client's B325 memoization):
   - the finished TLS ctx is cached per bundle path and re-parsed only when
     the file's mtime moves (bundle rotation);
   - deletion of the file after a successful parse keeps the cached ctx
     working (the anchors are in memory);
   - a failed parse is never cached, so a garbage bundle keeps failing
     loudly on every request.

   Same harness as the B325 ca-bundle suite: a scripted loopback server over
   plain http (no TLS server exists in the repo, so the TLS handshake itself
   is NOT covered end-to-end here) — the ctx build is the behavior under
   test. Observation channel: with a bundle set, net_ctx_of_bundle runs
   BEFORE the HTTP request; a request arriving at the server means the ctx
   build succeeded, a connection_error with no request means it raised. *)

open Alcotest
module Conn = C2c_relay_connector
module S = Relay_test_support

let json_member name = function
  | `Assoc fields -> List.assoc_opt name fields |> Option.value ~default:`Null
  | _ -> `Null

let json_str name j =
  match json_member name j with `String s -> s | _ -> ""

let ok_body = {|{"ok":true}|}

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "c2c-b342-test-%d-%d" (Unix.getpid ()) (Random.int 1_000_000))
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

(* Self-signed test certificate (CN=c2c-b314-test, valid to 2126) — the same
   embedded fixture the B314/B325 suites use, so no external tool is needed. *)
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

(* A PEM block header with a non-base64 body — X509.decode_pem_multiple
   returns Ok [] for input with NO blocks, so the malformed-block case is
   the one that exercises the parse-error path (same as the B314 suite). *)
let garbage_pem =
  "-----BEGIN CERTIFICATE-----\nnot base64!!!\n-----END CERTIFICATE-----\n"

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let paths_of requests = List.map (fun (r : S.captured_request) -> r.S.path) requests

let count_path requests path =
  paths_of requests |> List.filter (fun p -> p = path) |> List.length

let contains_sub ~needle s =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length s then false
    else if String.sub s i n = needle then true
    else go (i + 1)
  in
  go 0

(* Run one health op under its own Lwt_main.run — the same nested-run shape
   the connector's sync ops use (C2c_relay_connector runs each sync op via
   Lwt_main.run, and the module-level cache must survive across runs). *)
let op client = Lwt_main.run (Conn.Relay_client.health client)

(* Two ops on the same bundle must not re-read/re-parse per request: after
   the bundle file is DELETED, a third op must still succeed on the cached
   ctx (today the per-request rebuild dies with connection_error because
   open_in fails). All ops over plain http — building the ctx is the
   behavior under test. *)
let test_deleted_bundle_keeps_cached_ctx_working () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let bundle = Filename.concat tmp "ca.pem" in
  write_file bundle fixture_cert_pem;
  let routes =
    [ S.route ~meth:"GET" ~path:"/health" [ S.response ok_body ] ]
  in
  S.with_server ~routes (fun t ->
      let client =
        Conn.Relay_client.make ~timeout:2.0 ~ca_bundle:bundle (S.url t)
      in
      let r1 = op client and r2 = op client in
      check bool "op1 ok" true (json_member "ok" r1 = `Bool true);
      check bool "op2 ok" true (json_member "ok" r2 = `Bool true);
      Unix.unlink bundle;
      let r3 = op client in
      check bool
        "op3 ok after the bundle file was deleted (cached ctx, no re-read)"
        true
        (json_member "ok" r3 = `Bool true);
      let reqs = S.requests t in
      check int "three ops, three requests" 3 (List.length reqs);
      check int "every op reached the server (ctx never failed to build)" 3
        (count_path reqs "/health"))

(* Rotating the bundle (rewrite + utimes-bumped mtime) must invalidate the
   cache and the NEW content must be used: rotation to a valid bundle keeps
   ops working; rotation to a garbage bundle must make ops FAIL with the
   parse error (a cache that never re-reads would keep serving the old
   ctx and the op would still succeed). *)
let test_bundle_rotation_reparses_new_content () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let bundle = Filename.concat tmp "ca.pem" in
  write_file bundle fixture_cert_pem;
  Unix.utimes bundle 1.0 1.0;
  let routes =
    [ S.route ~meth:"GET" ~path:"/health" [ S.response ok_body ] ]
  in
  S.with_server ~routes (fun t ->
      let client =
        Conn.Relay_client.make ~timeout:2.0 ~ca_bundle:bundle (S.url t)
      in
      let r1 = op client in
      check bool "op1 ok on original bundle" true
        (json_member "ok" r1 = `Bool true);
      (* Rotate: same valid content, mtime bumped. *)
      write_file bundle fixture_cert_pem;
      Unix.utimes bundle 1.0 2.0;
      let r2 = op client in
      check bool "op2 ok after rotation to a valid bundle (re-parsed)" true
        (json_member "ok" r2 = `Bool true);
      (* Rotate to garbage: the new content must actually be re-read. *)
      write_file bundle garbage_pem;
      Unix.utimes bundle 1.0 3.0;
      let r3 = op client in
      check bool "op3 fails after rotation to garbage" false
        (json_member "ok" r3 = `Bool true);
      check bool
        "op3's failure is the actionable parse error (new content re-parsed)"
        true
        (contains_sub ~needle:"C2C_RELAY_CA_BUNDLE parse error" (json_str "error" r3)))

(* A garbage bundle must keep failing loudly on EVERY request (failed parses
   are never cached), and must stop failing as soon as the file is fixed —
   even when the fixed file carries the SAME mtime the garbage had (nothing
   was cached at failure time). Same-mtime pin: a cached-failure entry keyed
   on that mtime would keep the op failing here. *)
let test_garbage_bundle_fails_per_request_never_cached () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let bundle = Filename.concat tmp "ca.pem" in
  write_file bundle garbage_pem;
  Unix.utimes bundle 1.0 1.0;
  let routes =
    [ S.route ~meth:"GET" ~path:"/health" [ S.response ok_body ] ]
  in
  S.with_server ~routes (fun t ->
      let client =
        Conn.Relay_client.make ~timeout:2.0 ~ca_bundle:bundle (S.url t)
      in
      let r1 = op client and r2 = op client in
      check bool "op1 fails on garbage bundle" false
        (json_member "ok" r1 = `Bool true);
      check bool "op1 fails loudly (parse error named)" true
        (contains_sub ~needle:"C2C_RELAY_CA_BUNDLE parse error"
           (json_str "error" r1));
      check bool "op2 still fails (nothing cached)" false
        (json_member "ok" r2 = `Bool true);
      check bool "op2 still fails loudly" true
        (contains_sub ~needle:"C2C_RELAY_CA_BUNDLE parse error"
           (json_str "error" r2));
      check int "failed ops never reached the server" 0
        (count_path (S.requests t) "/health");
      (* Fix the file, keeping the SAME mtime the garbage had. *)
      write_file bundle fixture_cert_pem;
      Unix.utimes bundle 1.0 1.0;
      let r3 = op client in
      check bool
        "op3 ok once the file is valid (failed parse was never cached)"
        true
        (json_member "ok" r3 = `Bool true))

(* The cache is keyed on the bundle PATH: two clients with different bundle
   paths must not collide, even when both files carry the same mtime. *)
let test_two_bundle_paths_do_not_collide () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let good = Filename.concat tmp "good.pem" in
  let bad = Filename.concat tmp "bad.pem" in
  write_file good fixture_cert_pem;
  Unix.utimes good 1.0 1.0;
  write_file bad garbage_pem;
  Unix.utimes bad 1.0 1.0;
  let routes =
    [ S.route ~meth:"GET" ~path:"/health" [ S.response ok_body ] ]
  in
  S.with_server ~routes (fun t ->
      let good_client =
        Conn.Relay_client.make ~timeout:2.0 ~ca_bundle:good (S.url t)
      in
      let bad_client =
        Conn.Relay_client.make ~timeout:2.0 ~ca_bundle:bad (S.url t)
      in
      let r1 = op good_client in
      check bool "client on the good bundle ok" true
        (json_member "ok" r1 = `Bool true);
      let r2 = op bad_client in
      check bool "client on the garbage bundle still fails" false
        (json_member "ok" r2 = `Bool true);
      let r3 = op good_client in
      check bool "good client unaffected (per-path cache entries)" true
        (json_member "ok" r3 = `Bool true))

let () =
  Alcotest.run "c2c-relay-b342-connector-ctx-cache"
    [ ( "ca bundle ctx reuse (connector inline client)"
      , [ Alcotest.test_case
              "deleted bundle keeps cached ctx working" `Quick
              test_deleted_bundle_keeps_cached_ctx_working
        ; Alcotest.test_case "rotation re-parses the new content" `Quick
            test_bundle_rotation_reparses_new_content
        ; Alcotest.test_case
              "garbage bundle fails per request, never cached" `Quick
              test_garbage_bundle_fails_per_request_never_cached
        ; Alcotest.test_case "two bundle paths do not collide" `Quick
            test_two_bundle_paths_do_not_collide ] ) ]
