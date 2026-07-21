(* Relay_test_support_real — F5a (friction-cn): serve the PRODUCTION relay
   handler in-process over a loopback HTTP listener.

   This is the "real semantics" half of the F5a support layer (see
   Relay_test_support for the scripted/fault half and the full
   extract-vs-fresh decision). It is an EXTRACTION of the pattern
   test_pow_relay.ml pioneered — [Relay.Relay_server(Relay.InMemoryRelay)]'s
   [make_callback] mounted on a Cohttp_lwt_unix server over a socket that is
   bound + listening BEFORE the server (and before any client) runs, so
   there is no accept-readiness race and the kernel assigns the port.

   NO relay semantics live here: every request is answered by the
   production [RS.make_callback] verbatim, against a fresh in-memory
   backend per bracket. Suites needing real behavior (PoW headers, auth,
   registration state, /list, /health) use this; suites needing scripted
   faults (5xx, truncation, delays) use Relay_test_support. F5b/F5c adopt
   both.

   Lifecycle: [with_server] runs the whole interaction under one
   [Lwt_main.run]; the server is stopped via its [stop] promise in a
   [Lwt.finalize], so the listener is closed deterministically even when
   the test body fails. In-process only — no forked children to reap.
   NOTE: the client must run on the same Lwt loop (use [call_json] /
   [call]); a blocking client in the same process would starve the
   server. Subprocess clients (driving the c2c binary) need the forked
   Relay_test_support server instead. *)

module RS = Relay.Relay_server (Relay.InMemoryRelay)

open Lwt.Infix

type http_result = {
  status : Cohttp.Code.status_code;
  headers : Cohttp.Header.t;
  body_text : string;
  json : Yojson.Safe.t option; (* None when the body is not JSON *)
}

let status_code r = Cohttp.Code.code_of_status r.status

(* Bind + listen on a kernel-assigned loopback port BEFORE anything else
   runs (verbatim shape from test_pow_relay.ml). *)
let loopback_socket () =
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt fd Unix.SO_REUSEADDR true;
  Lwt_unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) >>= fun () ->
  Lwt_unix.listen fd 16;
  match Lwt_unix.getsockname fd with
  | Unix.ADDR_INET (_, port) -> Lwt.return (fd, port)
  | _ -> Lwt.fail_with "loopback_socket: expected INET socket"

(* Serve the production relay callback on a loopback port for the duration
   of [f ~base_url ~relay]. Fresh InMemoryRelay per bracket; dev auth by
   default (token = None) — pass [?token] for a token-configured
   (production auth mode) bracket, e.g. the B116 binding-revoke suite;
   optional caller-supplied rate limiter. *)
let with_server ?token ?(native_tls = false) ?rate_limiter f =
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
       RS.make_callback relay token conn req body ?broker_root:None
         ~native_tls ~rate_limiter
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

(* One HTTP call against the bracket's server; total — a non-JSON body
   yields [json = None] rather than raising, so fault-matrix suites can
   assert on raw text too. *)
let call ~base_url ~meth ~path ?(headers = []) ?(body = "") () =
  let uri = Uri.of_string (base_url ^ path) in
  let headers = Cohttp.Header.of_list headers in
  let body = Cohttp_lwt.Body.of_string body in
  Cohttp_lwt_unix.Client.call ~headers ~body meth uri
  >>= fun (resp, resp_body) ->
  Cohttp_lwt.Body.to_string resp_body >|= fun text ->
  let json = try Some (Yojson.Safe.from_string text) with _ -> None in
  { status = Cohttp.Response.status resp;
    headers = Cohttp.Response.headers resp;
    body_text = text;
    json }

let call_json ~base_url ~meth ~path ?(headers = []) ?(body = `Assoc []) () =
  call ~base_url ~meth ~path
    ~headers:(("Content-Type", "application/json") :: headers)
    ~body:(Yojson.Safe.to_string body) ()
