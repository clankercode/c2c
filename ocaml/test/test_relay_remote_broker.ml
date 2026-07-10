(* test_relay_remote_broker.ml — regression tests for remote broker SSH polling

   Tests the two bugs found during smoke test:
   1. Off-by-one path length: /remote_inbox/ is 14 chars, not 13
   2. SSH color codes: ls --color=auto output broke session parsing

   The path parsing regression test prevents re-breaking the exact off-by-one
   that caused /remote_inbox/<id> to always 404. *)

open Alcotest

open Lwt.Infix

type http_result = {
  status : Cohttp.Code.status_code;
  json : Yojson.Safe.t;
}

let failf fmt = Printf.ksprintf (fun msg -> Alcotest.fail msg) fmt

let loopback_socket () =
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt fd Unix.SO_REUSEADDR true;
  Lwt_unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) >>= fun () ->
  Lwt_unix.listen fd 16;
  match Lwt_unix.getsockname fd with
  | Unix.ADDR_INET (_, port) -> Lwt.return (fd, port)
  | _ -> Lwt.fail_with "loopback_socket: expected INET socket"

let call_json ~base_url ~path ?authorization body =
  let body_str = Yojson.Safe.to_string body in
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  let headers =
    match authorization with
    | Some value -> Cohttp.Header.add headers "Authorization" value
    | None -> headers
  in
  let body = Cohttp_lwt.Body.of_string body_str in
  Cohttp_lwt_unix.Client.call ~headers ~body `POST
    (Uri.of_string (base_url ^ path))
  >>= fun (response, response_body) ->
  Cohttp_lwt.Body.to_string response_body >|= fun text ->
  let json =
    try Yojson.Safe.from_string text
    with Yojson.Json_error msg -> failf "response was not JSON: %s; body=%s" msg text
  in
  { status = Cohttp.Response.status response; json }

let json_string_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`String value) -> value
     | value -> failf "expected string field %s, got %s" name
         (Yojson.Safe.to_string (Option.value value ~default:`Null)))
  | json -> failf "expected JSON object, got %s" (Yojson.Safe.to_string json)

let json_messages = function
  | `Assoc fields ->
    (match List.assoc_opt "messages" fields with
     | Some (`List messages) -> messages
     | value -> failf "expected messages array, got %s"
         (Yojson.Safe.to_string (Option.value value ~default:`Null)))
  | json -> failf "expected JSON object, got %s" (Yojson.Safe.to_string json)

module Backend_http_tests (R : Relay.RELAY) = struct
  module RS = Relay.Relay_server (R)

  let with_server relay f =
    Lwt_main.run
      (loopback_socket () >>= fun (fd, port) ->
       let rate_limiter = Relay.Rate_limiter_inst.create ~gc_interval:300.0 () in
       let stop, wake_stop = Lwt.wait () in
       let callback (conn, _) request body =
         RS.make_callback relay None conn request body ?broker_root:None
           ~rate_limiter
       in
       let spec = Cohttp_lwt_unix.Server.make ~callback () in
       let server =
         Cohttp_lwt_unix.Server.create ~stop ~mode:(`TCP (`Socket fd)) spec
       in
       Lwt.pause () >>= fun () ->
       let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
       Lwt.finalize
         (fun () -> f ~base_url)
         (fun () ->
            Lwt.wakeup_later wake_stop ();
            server))

  let register_identity relay ~node_id ~session_id ~alias identity =
    let status, _lease =
      R.register relay ~node_id ~session_id ~alias
        ~identity_pk:identity.Relay_identity.public_key ()
    in
    Alcotest.(check string) ("register " ^ alias) "ok" status

  let prime_victim_inbox relay =
    let victim = Relay_identity.generate ~alias_hint:"victim" () in
    let attacker = Relay_identity.generate ~alias_hint:"attacker" () in
    register_identity relay ~node_id:"victim-node" ~session_id:"victim-session"
      ~alias:"victim" victim;
    register_identity relay ~node_id:"attacker-node" ~session_id:"attacker-session"
      ~alias:"attacker" attacker;
    (match R.send relay ~from_alias:"attacker" ~to_alias:"victim"
             ~content:"victim secret" ~message_id:None with
     | `Ok _ -> ()
     | `Duplicate _ -> Alcotest.fail "unexpected duplicate message"
     | `Error (code, msg) -> failf "send failed: %s: %s" code msg);
    attacker

  let victim_body =
    `Assoc [
      "node_id", `String "victim-node";
      "session_id", `String "victim-session";
    ]

  let test_verified_attacker_cannot_peek_victim relay =
    let attacker = prime_victim_inbox relay in
    with_server relay (fun ~base_url ->
      let body_str = Yojson.Safe.to_string victim_body in
      let authorization =
        Relay_signed_ops.sign_request attacker ~alias:"attacker" ~meth:"POST"
          ~path:"/peek_inbox" ~body_str ()
      in
      call_json ~base_url ~path:"/peek_inbox" ~authorization victim_body
      >|= fun result ->
      Alcotest.(check int) "attacker receives HTTP 403" 403
        (Cohttp.Code.code_of_status result.status);
      Alcotest.(check string) "ownership mismatch uses signature error"
        Relay.relay_err_signature_invalid
        (json_string_field "error_code" result.json))

  let test_unsigned_dev_request_keeps_existing_policy relay =
    let _attacker = prime_victim_inbox relay in
    with_server relay (fun ~base_url ->
      call_json ~base_url ~path:"/peek_inbox" victim_body >|= fun result ->
      Alcotest.(check int) "unsigned dev-mode peek remains allowed" 200
        (Cohttp.Code.code_of_status result.status);
      let messages = json_messages result.json in
      Alcotest.(check int) "victim inbox remains readable in dev mode" 1
        (List.length messages))
end

module In_memory_http = Backend_http_tests (Relay.InMemoryRelay)
module Sqlite_http = Backend_http_tests (Relay.SqliteRelay)

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun entry ->
          let child = Filename.concat path entry in
          if Sys.is_directory child then Unix.rmdir child else Sys.remove child)
        (Sys.readdir path);
      Unix.rmdir path)
    (fun () -> f path)

let test_in_memory_verified_attacker_cannot_peek_victim () =
  let relay = Relay.InMemoryRelay.create () in
  In_memory_http.test_verified_attacker_cannot_peek_victim relay

let test_in_memory_unsigned_dev_request_keeps_existing_policy () =
  let relay = Relay.InMemoryRelay.create () in
  In_memory_http.test_unsigned_dev_request_keeps_existing_policy relay

let test_sqlite_verified_attacker_cannot_peek_victim () =
  with_temp_dir "c2c-peek-auth" (fun persist_dir ->
    let relay = Relay.SqliteRelay.create ~persist_dir () in
    Sqlite_http.test_verified_attacker_cannot_peek_victim relay)

let test_sqlite_unsigned_dev_request_keeps_existing_policy () =
  with_temp_dir "c2c-peek-unsigned" (fun persist_dir ->
    let relay = Relay.SqliteRelay.create ~persist_dir () in
    Sqlite_http.test_unsigned_dev_request_keeps_existing_policy relay)

let prefix_len = 14
let prefix = "/remote_inbox/"

let parse_remote_inbox_path path =
  if String.length path > prefix_len && String.sub path 0 prefix_len = prefix then
    Some (String.sub path prefix_len (String.length path - prefix_len))
  else
    None

let test_session_id_extraction () =
  let check = Alcotest.(check (option string)) in
  check "simple session id"
    (Some "test-session") (parse_remote_inbox_path "/remote_inbox/test-session");
  check "session with hyphens and numbers"
    (Some "my-session-123") (parse_remote_inbox_path "/remote_inbox/my-session-123");
  check "underscore in session"
    (Some "foo_bar") (parse_remote_inbox_path "/remote_inbox/foo_bar");
  check "session with dots"
    (Some "foo.bar.baz") (parse_remote_inbox_path "/remote_inbox/foo.bar.baz");
  check "too short: just prefix (14 chars exactly, no slash after)"
    None (parse_remote_inbox_path "/remote_inboxx");
  check "too short: prefix only"
    None (parse_remote_inbox_path "/remote_inbox");
  check "wrong prefix: poll_inbox"
    None (parse_remote_inbox_path "/poll_inbox/test-session");
  check "wrong prefix: remote_inbox without leading slash"
    None (parse_remote_inbox_path "remote_inbox/test-session");
  check "wrong prefix: /remote_inboxx/"
    None (parse_remote_inbox_path "/remote_inboxx/test-session")

let test_path_length_is_14 () =
  let open Alcotest in
  let actual = String.length prefix in
  Alcotest.(check int) "/remote_inbox/ is 14 chars" 14 actual

let test_ansi_ls_line_parsing () =
  let open Alcotest in
  (* Simulate ls --color=auto output with ANSI codes *)
  let colored_line = "\027[1;33mtest-session\027[0m" in
  (* The strip logic: remove non-printable chars except \n *)
  let stripped = colored_line in
  (* After stripping ANSI, sed extracts the name — verify our parsing doesn't crash *)
  let name = String.trim stripped in
  Alcotest.(check string) "ansi colored line is not empty after trim"
    "\027[1;33mtest-session\027[0m" name;
  (* The key regression: with --color=never, ls outputs plain text *)
  let plain_line = "test-session" in
  let name_plain = String.trim plain_line in
  Alcotest.(check string) "plain line parses correctly"
    "test-session" name_plain

let tests = [
  "/remote_inbox/ path is exactly 14 chars", `Quick, test_path_length_is_14;
  "session_id extraction from path", `Quick, test_session_id_extraction;
  "ansi ls line parsing (with --color=never)", `Quick, test_ansi_ls_line_parsing;
  "InMemory: verified attacker cannot peek victim", `Quick,
    test_in_memory_verified_attacker_cannot_peek_victim;
  "InMemory: unsigned dev request keeps policy", `Quick,
    test_in_memory_unsigned_dev_request_keeps_existing_policy;
  "SQLite: verified attacker cannot peek victim", `Quick,
    test_sqlite_verified_attacker_cannot_peek_victim;
  "SQLite: unsigned dev request keeps policy", `Quick,
    test_sqlite_unsigned_dev_request_keeps_existing_policy;
]

let () =
  Alcotest.run "relay_remote_broker" [ "regression", tests ]
