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
    ];
    "mobile bindings", [
      Alcotest.test_case "add/remove/dedupe" `Quick test_mobile_bindings_add_remove;
    ];
  ]
