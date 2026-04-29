(** Pure-function tests for C2c_relay_connector.

    The connector is mostly side-effecting (HTTP, sockets, signal handling),
    but a handful of helpers are testable in isolation:
    - URL/path constructors (local_inbox_path, outbox_path, etc.)
    - parse_relay_url (host:port splitter)
    - Relay_client.make base-url normalization
    - Relay_client.is_admin_path / is_unauth_path classifiers
    - JSON helpers (json_bool_member, json_list_member)
    - Outbox round-trip (read after write, append-only entry)
    - Mobile-bindings round-trip (add/remove)
*)

module Conn = C2c_relay_connector

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
    (Printf.sprintf "c2c-conn-test-%d-%d"
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

(* --- path constructors --- *)

let test_local_inbox_path () =
  let p = Conn.local_inbox_path "/tmp/broker" "sess-abc" in
  Alcotest.(check string) "joined inbox path"
    "/tmp/broker/sess-abc.inbox.json" p

let test_outbox_path () =
  let p = Conn.outbox_path "/tmp/broker" in
  Alcotest.(check string) "outbox jsonl path"
    "/tmp/broker/remote-outbox.jsonl" p

let test_pseudo_reg_path () =
  let p = Conn.pseudo_reg_path "/var/c2c" in
  Alcotest.(check string) "pseudo registrations path"
    "/var/c2c/pseudo_registrations.json" p

let test_mobile_bindings_path () =
  let p = Conn.mobile_bindings_path "/var/c2c" in
  Alcotest.(check string) "mobile bindings path"
    "/var/c2c/mobile_bindings.json" p

(* --- parse_relay_url --- *)

let test_parse_relay_url_host_port () =
  let host, port = Conn.parse_relay_url "localhost:9000" in
  Alcotest.(check string) "host" "localhost" host;
  Alcotest.(check int) "port" 9000 port

let test_parse_relay_url_no_colon_default_port () =
  (* No ':' → falls through to default-port branch. Plain host string
     does not start with "https" so port defaults to 80. *)
  let host, port = Conn.parse_relay_url "relay.local" in
  Alcotest.(check string) "host bare" "relay.local" host;
  Alcotest.(check int) "default port" 80 port

(* --- Relay_client.make base-url normalization --- *)

let test_relay_client_make_strips_trailing_slash () =
  let c = Conn.Relay_client.make "http://relay.example.com:9000/" in
  Alcotest.(check string) "trailing slash stripped"
    "http://relay.example.com:9000" c.base_url

let test_relay_client_make_preserves_no_slash () =
  let c = Conn.Relay_client.make "http://relay.example.com:9000" in
  Alcotest.(check string) "no slash preserved"
    "http://relay.example.com:9000" c.base_url

let test_relay_client_make_empty () =
  let c = Conn.Relay_client.make "" in
  Alcotest.(check string) "empty base url passes through" "" c.base_url

(* --- path classifiers --- *)

let test_is_admin_path () =
  Alcotest.(check bool) "/gc admin" true (Conn.Relay_client.is_admin_path "/gc");
  Alcotest.(check bool) "/dead_letter admin" true (Conn.Relay_client.is_admin_path "/dead_letter");
  Alcotest.(check bool) "/admin/unbind admin" true (Conn.Relay_client.is_admin_path "/admin/unbind");
  Alcotest.(check bool) "/remote_inbox/X admin" true (Conn.Relay_client.is_admin_path "/remote_inbox/some-alias");
  Alcotest.(check bool) "/list admin (prefix)" true (Conn.Relay_client.is_admin_path "/list");
  Alcotest.(check bool) "/list_rooms admin (prefix)" true (Conn.Relay_client.is_admin_path "/list_rooms");
  Alcotest.(check bool) "/send not admin" false (Conn.Relay_client.is_admin_path "/send");
  Alcotest.(check bool) "/health not admin" false (Conn.Relay_client.is_admin_path "/health")

let test_is_unauth_path () =
  Alcotest.(check bool) "/health unauth" true (Conn.Relay_client.is_unauth_path "/health");
  Alcotest.(check bool) "/ unauth" true (Conn.Relay_client.is_unauth_path "/");
  Alcotest.(check bool) "/send not unauth" false (Conn.Relay_client.is_unauth_path "/send");
  Alcotest.(check bool) "/heartbeat not unauth" false (Conn.Relay_client.is_unauth_path "/heartbeat")

(* --- JSON helpers --- *)

let test_json_bool_member () =
  let j = `Assoc [("ok", `Bool true); ("nope", `Bool false); ("other", `String "x")] in
  Alcotest.(check bool) "ok=true" true (Conn.json_bool_member ~key:"ok" j);
  Alcotest.(check bool) "nope=false" false (Conn.json_bool_member ~key:"nope" j);
  Alcotest.(check bool) "missing key → false" false (Conn.json_bool_member ~key:"missing" j);
  Alcotest.(check bool) "wrong-type key → false" false (Conn.json_bool_member ~key:"other" j)

let test_json_list_member () =
  let j = `Assoc [("messages", `List [`String "a"; `String "b"]); ("scalar", `Int 3)] in
  let msgs = Conn.json_list_member ~key:"messages" j in
  Alcotest.(check int) "list length" 2 (List.length msgs);
  let empty = Conn.json_list_member ~key:"missing" j in
  Alcotest.(check int) "missing → []" 0 (List.length empty);
  let wrong_type = Conn.json_list_member ~key:"scalar" j in
  Alcotest.(check int) "wrong-type → []" 0 (List.length wrong_type)

(* --- outbox round-trip (file IO via tmpdir) --- *)

let test_outbox_roundtrip () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    (* Empty outbox: read returns [] *)
    let initial = Conn.read_outbox dir in
    Alcotest.(check int) "empty initial" 0 (List.length initial);
    (* Append two entries *)
    Conn.append_outbox_entry dir
      ~from_alias:"alice" ~to_alias:"bob@host" ~content:"hi" ();
    Conn.append_outbox_entry dir
      ~from_alias:"alice" ~to_alias:"carol@host" ~content:"yo"
      ~message_id:"msg-123" ();
    let entries = Conn.read_outbox dir in
    Alcotest.(check int) "two entries after append" 2 (List.length entries);
    let e1 = List.nth entries 0 in
    let e2 = List.nth entries 1 in
    Alcotest.(check string) "first from" "alice" e1.ob_from;
    Alcotest.(check string) "first to" "bob@host" e1.ob_to;
    Alcotest.(check string) "first content" "hi" e1.ob_content;
    Alcotest.(check (option string)) "first msg_id none" None e1.ob_msg_id;
    Alcotest.(check string) "second to" "carol@host" e2.ob_to;
    Alcotest.(check (option string)) "second msg_id" (Some "msg-123") e2.ob_msg_id;
    (* write_outbox [] removes file *)
    Conn.write_outbox dir [];
    Alcotest.(check bool) "file removed after empty write"
      false (Sys.file_exists (Conn.outbox_path dir));
    let after_clear = Conn.read_outbox dir in
    Alcotest.(check int) "empty again after clear" 0 (List.length after_clear)
  )

(* --- mobile bindings round-trip --- *)

let test_mobile_bindings_add_remove () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    Alcotest.(check int) "empty initial"
      0 (List.length (Conn.read_mobile_bindings dir));
    Conn.add_mobile_binding dir ~binding_id:"bind-1";
    Conn.add_mobile_binding dir ~binding_id:"bind-2";
    let xs = Conn.read_mobile_bindings dir in
    Alcotest.(check int) "two bindings" 2 (List.length xs);
    let ids = List.map (fun mb -> mb.Conn.mb_binding_id) xs in
    Alcotest.(check bool) "contains bind-1" true (List.mem "bind-1" ids);
    Alcotest.(check bool) "contains bind-2" true (List.mem "bind-2" ids);
    (* re-add bind-1: should not duplicate *)
    Conn.add_mobile_binding dir ~binding_id:"bind-1";
    let xs2 = Conn.read_mobile_bindings dir in
    Alcotest.(check int) "still two after re-add" 2 (List.length xs2);
    (* remove one *)
    Conn.remove_mobile_binding dir ~binding_id:"bind-1";
    let xs3 = Conn.read_mobile_bindings dir in
    Alcotest.(check int) "one after remove" 1 (List.length xs3);
    let id = (List.hd xs3).Conn.mb_binding_id in
    Alcotest.(check string) "remaining is bind-2" "bind-2" id
  )

(* --- classify_error --- *)

let test_classify_error () =
  (* Relay send error format: {ok:false, error_code:<code>, error:<msg>} *)
  let unknown_alias_json = `Assoc [
    ("ok", `Bool false);
    ("error_code", `String "unknown_alias");
    ("error", `String "no registration for alias");
  ] in
  Alcotest.(check string) "unknown_alias"
    "unknown_alias" (Conn.classify_error unknown_alias_json);
  let recipient_dead_json = `Assoc [
    ("ok", `Bool false);
    ("error_code", `String "recipient_dead");
    ("error", `String "lease expired");
  ] in
  Alcotest.(check string) "recipient_dead"
    "recipient_dead" (Conn.classify_error recipient_dead_json);
  let conn_err_json = `Assoc [
    ("ok", `Bool false);
    ("error_code", `String "connection_error");
    ("error", `String "connection refused");
  ] in
  Alcotest.(check string) "connection_error"
    "connection_error" (Conn.classify_error conn_err_json);
  let other_json = `Assoc [
    ("ok", `Bool false);
    ("error_code", `String "rate_limited");
    ("error", `String "slow down");
  ] in
  Alcotest.(check string) "other (unknown error_code)"
    "other" (Conn.classify_error other_json);
  let no_error_code_json = `Assoc [
    ("ok", `Bool false);
    ("error", `String "something went wrong");
  ] in
  Alcotest.(check string) "other (missing error_code)"
    "other" (Conn.classify_error no_error_code_json)

(* --- outbox with new fields (attempts, enqueued_at, last_error) --- *)

let test_outbox_new_fields () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    Conn.append_outbox_entry dir
      ~from_alias:"alice" ~to_alias:"bob@host" ~content:"hello" ();
    let entries = Conn.read_outbox dir in
    Alcotest.(check int) "one entry" 1 (List.length entries);
    let e = List.hd entries in
    Alcotest.(check int) "attempts=1 on fresh entry" 1 e.ob_attempts;
    Alcotest.(check bool) "enqueued_at > 0" true (e.ob_enqueued_at > 0.0);
    Alcotest.(check (option string)) "last_error=None on fresh entry"
      None e.ob_last_error
  )

(* --- outbox backward compat: legacy entry without new fields --- *)

let test_outbox_backward_compat () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    (* Manually write a legacy entry (pre-fix format) *)
    let oc = open_out (Conn.outbox_path dir) in
    Fun.protect ~finally:(fun () -> close_out oc)
      (fun () ->
        output_string oc "{\"from_alias\":\"alice\",\"to_alias\":\"bob@host\",\"content\":\"hi\"}\n");
    let entries = Conn.read_outbox dir in
    Alcotest.(check int) "one legacy entry" 1 (List.length entries);
    let e = List.hd entries in
    Alcotest.(check int) "attempts=0 for legacy (default)" 0 e.ob_attempts;
    Alcotest.(check bool) "enqueued_at > 0 (default = now, not epoch)"
      true (e.ob_enqueued_at > 100_000_000.0);
    Alcotest.(check (option string)) "last_error=None for legacy"
      None e.ob_last_error
  )

(* --- outbox enqueued_at accepts Int (whole-second float) --- *)

let test_outbox_enqueued_at_int () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    (* Write entry with enqueued_at as JSON Int (Yojson emits whole-second as Int) *)
    let oc = open_out (Conn.outbox_path dir) in
    Fun.protect ~finally:(fun () -> close_out oc)
      (fun () ->
        output_string oc "{\"from_alias\":\"alice\",\"to_alias\":\"bob@host\",\"content\":\"hi\",\"attempts\":3,\"enqueued_at\":1717200000}\n");
    let entries = Conn.read_outbox dir in
    Alcotest.(check int) "one entry" 1 (List.length entries);
    let e = List.hd entries in
    Alcotest.(check int) "attempts=3" 3 e.ob_attempts;
    Alcotest.(check bool) "enqueued_at parsed from Int"
      true (e.ob_enqueued_at > 1_717_000_000.0 && e.ob_enqueued_at < 1_718_000_000.0)
  )

(* --- outbox lock path and with_outbox_lock --- *)

let test_outbox_lock_path () =
  let p = Conn.outbox_lock_path "/tmp/broker" in
  Alcotest.(check string) "lock sidecar path"
    "/tmp/broker/remote-outbox.lock" p

let test_with_outbox_lock_executes () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    let result = Conn.with_outbox_lock dir (fun () -> 42) in
    Alcotest.(check int) "lock returns inner function result" 42 result;
    (* Sidecar file should exist after lock *)
    Alcotest.(check bool) "lock sidecar created"
      true (Sys.file_exists (Conn.outbox_lock_path dir))
  )

let () =
  Random.self_init ();
  Alcotest.run "c2c_relay_connector" [
    "paths", [
      Alcotest.test_case "local_inbox_path" `Quick test_local_inbox_path;
      Alcotest.test_case "outbox_path" `Quick test_outbox_path;
      Alcotest.test_case "pseudo_reg_path" `Quick test_pseudo_reg_path;
      Alcotest.test_case "mobile_bindings_path" `Quick test_mobile_bindings_path;
    ];
    "parse_relay_url", [
      Alcotest.test_case "host:port" `Quick test_parse_relay_url_host_port;
      Alcotest.test_case "no colon → default port" `Quick test_parse_relay_url_no_colon_default_port;
    ];
    "Relay_client.make", [
      Alcotest.test_case "strips trailing slash" `Quick test_relay_client_make_strips_trailing_slash;
      Alcotest.test_case "preserves no-slash" `Quick test_relay_client_make_preserves_no_slash;
      Alcotest.test_case "empty url" `Quick test_relay_client_make_empty;
    ];
    "path classifiers", [
      Alcotest.test_case "is_admin_path" `Quick test_is_admin_path;
      Alcotest.test_case "is_unauth_path" `Quick test_is_unauth_path;
    ];
    "json helpers", [
      Alcotest.test_case "json_bool_member" `Quick test_json_bool_member;
      Alcotest.test_case "json_list_member" `Quick test_json_list_member;
    ];
    "outbox", [
      Alcotest.test_case "round-trip + append + clear" `Quick test_outbox_roundtrip;
      Alcotest.test_case "lock path" `Quick test_outbox_lock_path;
      Alcotest.test_case "with_outbox_lock executes and returns" `Quick test_with_outbox_lock_executes;
    ];
    "mobile bindings", [
      Alcotest.test_case "add/remove/dedupe" `Quick test_mobile_bindings_add_remove;
    ];
    "classify_error", [
      Alcotest.test_case "error_code dispatch" `Quick test_classify_error;
    ];
    "outbox new fields", [
      Alcotest.test_case "fresh entry has attempts=1, enqueued_at>0" `Quick test_outbox_new_fields;
      Alcotest.test_case "legacy entry defaults to now (not epoch)" `Quick test_outbox_backward_compat;
      Alcotest.test_case "enqueued_at parses Int variant" `Quick test_outbox_enqueued_at_int;
    ];
  ]
