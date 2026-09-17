(* B314 regression: the connector's inline HTTP client stored timeout=10.0 but
   request called Cohttp_lwt_unix.Client.call with NO deadline — the field was
   dead, so any request could hang until the process SIGALRM (which then costs
   the whole connector the B307 exit). The client also lacked the
   C2C_RELAY_CA_BUNDLE support relay_client.ml has (net_ctx_of_bundle), so a
   connector pointed at a self-signed/Tailscale HTTPS relay failed every op
   with connection_error while `c2c doctor --relay` on the same host succeeded.

   Fix contract:
   - timeout is a real per-call deadline (Lwt race with a timer INSIDE request;
     the nested Lwt_main.run structure around sync ops is why an outer sibling
     would never race those loops — same shape as relay_client.request_raw);
   - ca_bundle is resolved explicit-arg > C2C_RELAY_CA_BUNDLE env, and a
     bundle builds a custom Cohttp ctx (X509 chain_of_trust authenticator).
   No repo TLS-server fixture exists, so the TLS handshake itself is NOT
   covered end-to-end here; the ctx-selection and bundle-parsing paths are. *)

module Conn = C2c_relay_connector

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
    (Printf.sprintf "c2c-b314-test-%d-%d"
       (Unix.getpid ()) (Random.int 1_000_000)) in
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

let waitpid_until ~timeout_s pid =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ when Unix.gettimeofday () < deadline ->
        Unix.sleepf 0.02;
        loop ()
    | 0, _ -> None
    | _, status -> Some status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()

let contains_sub ~needle s =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length s then false
    else if String.sub s i n = needle then true
    else go (i + 1)
  in
  go 0

(* Accept-backlog-only socket: the kernel completes the TCP handshake, the
   client writes its request, and nothing ever answers — the deterministic
   "accepts but never responds" hang. *)
let hang_socket () =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt sock Unix.SO_REUSEADDR true;
  Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen sock 16;
  let port =
    match Unix.getsockname sock with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "hang_socket: expected INET socket"
  in
  (sock, Printf.sprintf "http://127.0.0.1:%d" port)

let expect_exit pid ~timeout_s ~code ~what =
  match waitpid_until ~timeout_s pid with
  | Some (Unix.WEXITED c) when c = code -> ()
  | Some (Unix.WEXITED c) ->
      Alcotest.failf "%s: expected exit %d, got exit %d" what code c
  | Some status ->
      Alcotest.failf "%s: expected exit %d, got %s" what code
        (match status with
         | Unix.WEXITED c -> Printf.sprintf "exit %d" c
         | Unix.WSIGNALED s -> Printf.sprintf "signal %d" s
         | Unix.WSTOPPED s -> Printf.sprintf "stopped %d" s)
  | None ->
      Unix.kill pid Sys.sigkill;
      ignore (Unix.waitpid [] pid);
      Alcotest.failf "%s: child did not exit within %.0fs" what timeout_s

(* The stored timeout must bound the request: against a socket that never
   answers, the ONLY way out is the per-call deadline. *)
let test_request_deadline_fires_against_hung_socket () =
  let lsock, url = hang_socket () in
  Fun.protect
    ~finally:(fun () -> try Unix.close lsock with _ -> ())
    @@ fun () ->
  match Unix.fork () with
  | 0 ->
      let c = Conn.Relay_client.make ~timeout:1.0 url in
      begin
        match Lwt_main.run (Conn.Relay_client.health c) with
        | `Assoc fields ->
            let ok =
              match List.assoc_opt "ok" fields with
              | Some (`Bool b) -> b
              | _ -> true
            in
            let err =
              match List.assoc_opt "error" fields with
              | Some (`String s) -> s
              | _ -> ""
            in
            if (not ok) && contains_sub ~needle:"request_timeout" err then
              Unix._exit 0
            else
              (* A response materialized without the deadline firing: the
                 relay socket behaved unexpectedly for this fixture. *)
              Unix._exit 7
        | _ -> Unix._exit 7
        | exception exn ->
            Printf.eprintf "health raised: %s\n%!" (Printexc.to_string exn);
            Unix._exit 8
      end
  | pid ->
      expect_exit pid ~timeout_s:8.0 ~code:0
        ~what:"request against never-responding socket"

(* Self-signed test certificate (CN=c2c-b314-test, valid to 2126, generated
   once with openssl and embedded so the suite needs no external tool). *)
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

let with_ca_bundle_env ~value f =
  let prev = Sys.getenv_opt "C2C_RELAY_CA_BUNDLE" in
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv "C2C_RELAY_CA_BUNDLE" v
      | None -> Unix.putenv "C2C_RELAY_CA_BUNDLE" "")
    (fun () ->
      Unix.putenv "C2C_RELAY_CA_BUNDLE" value;
      f ())

(* ca_bundle resolution: explicit arg > C2C_RELAY_CA_BUNDLE env > absent. *)
let test_ca_bundle_selection () =
  with_ca_bundle_env ~value:"/tmp/from-env.pem" (fun () ->
      let c = Conn.Relay_client.make "http://relay.example.com" in
      Alcotest.(check (option string)) "env bundle picked up"
        (Some "/tmp/from-env.pem") c.Conn.Relay_client.ca_bundle;
      let explicit =
        Conn.Relay_client.make ~ca_bundle:"/tmp/explicit.pem"
          "http://relay.example.com"
      in
      Alcotest.(check (option string)) "explicit arg wins over env"
        (Some "/tmp/explicit.pem") explicit.Conn.Relay_client.ca_bundle);
  with_ca_bundle_env ~value:"" (fun () ->
      let c = Conn.Relay_client.make "http://relay.example.com" in
      Alcotest.(check (option string)) "absent env -> None" None
        c.Conn.Relay_client.ca_bundle)

(* A parseable PEM bundle must build a custom TLS ctx (the ported
   net_ctx_of_bundle path); a garbage bundle must fail with the actionable
   parse-error message, not silently. *)
let test_net_ctx_of_bundle_valid_and_garbage () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let good = Filename.concat tmp "ca.pem" in
  let oc = open_out good in
  output_string oc fixture_cert_pem;
  close_out oc;
  Lwt_main.run
    (Lwt.bind (Conn.Relay_client.net_ctx_of_bundle good) (fun _ctx ->
         Lwt.return ()));
  let bad = Filename.concat tmp "garbage.pem" in
  let oc = open_out bad in
  (* A PEM block header with a non-base64 body — X509.decode_pem_multiple
     returns Ok [] for input with NO blocks, so the malformed-block case is
     the one that exercises the parse-error path. *)
  output_string oc
    "-----BEGIN CERTIFICATE-----\nnot base64!!!\n-----END CERTIFICATE-----\n";
  close_out oc;
  match Lwt_main.run (Conn.Relay_client.net_ctx_of_bundle bad) with
  | _ctx -> Alcotest.fail "garbage bundle must not build a ctx"
  | exception Failure m ->
      Alcotest.(check bool) "parse error is actionable" true
        (contains_sub ~needle:"C2C_RELAY_CA_BUNDLE parse error" m)
  | exception exn ->
      Alcotest.failf "unexpected error for garbage bundle: %s"
        (Printexc.to_string exn)

let () =
  Alcotest.run "c2c-relay-b314-http-client"
    [ ( "B314 inline HTTP client"
      , [ Alcotest.test_case
              "timeout is a real per-call deadline" `Quick
              test_request_deadline_fires_against_hung_socket
        ; Alcotest.test_case "ca_bundle selection arg > env > absent" `Quick
            test_ca_bundle_selection
        ; Alcotest.test_case
              "net_ctx_of_bundle accepts PEM, rejects garbage" `Quick
              test_net_ctx_of_bundle_valid_and_garbage ] ) ]
