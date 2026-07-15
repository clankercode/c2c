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

(* --- B196: local relay ingress controls --- *)

let inbound_message ~sender content =
  `Assoc [
    ("from_alias", `String sender);
    ("to_alias", `String "local-agent");
    ("content", `String content);
  ]

let test_inbound_policy_defaults () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    match Conn.load_inbound_policy dir with
    | Error e -> Alcotest.fail e
    | Ok policy ->
        Alcotest.(check int) "default max bytes" (256 * 1024)
          policy.Conn.default_max_bytes;
        Alcotest.(check int) "default sender messages" 60
          policy.Conn.default_sender_rate.rate_messages;
        Alcotest.(check int) "default machine messages" 600
          policy.Conn.machine_rate.rate_messages)

let test_inbound_policy_parses_sender_override () =
  let json = `Assoc [
    ("default_max_bytes", `Int 4096);
    ("default_sender_rate", `Assoc [
      ("messages", `Int 12); ("window_seconds", `Float 30.0) ]);
    ("machine_rate", `Assoc [
      ("messages", `Int 100); ("window_seconds", `Int 10) ]);
    ("senders", `Assoc [
      ("Alice@Remote", `Assoc [
        ("max_bytes", `Int 512);
        ("rate", `Assoc [
          ("messages", `Int 2); ("window_seconds", `Int 60) ]) ]) ]);
  ] in
  match Conn.parse_inbound_policy json with
  | Error e -> Alcotest.fail e
  | Ok policy ->
      let alice = Conn.inbound_sender_policy policy "ALICE@REMOTE" in
      Alcotest.(check int) "override max" 512 alice.Conn.sender_max_bytes;
      Alcotest.(check int) "override rate" 2
        alice.Conn.sender_rate.rate_messages;
      let other = Conn.inbound_sender_policy policy "other@remote" in
      Alcotest.(check int) "other gets default max" 4096
        other.Conn.sender_max_bytes;
      Alcotest.(check int) "other gets default rate" 12
        other.Conn.sender_rate.rate_messages

let test_inbound_policy_invalid_fails () =
  let invalid = `Assoc [ ("machine_rate", `Assoc [ ("messages", `Int 0) ]) ] in
  match Conn.parse_inbound_policy invalid with
  | Error _ as invalid_policy ->
      let state = Conn.create_inbound_rate_state () in
      let accepted, rejected =
        Conn.filter_inbound_messages_guarded ~now:100.0 invalid_policy state
          [ inbound_message ~sender:"alice@remote" "must not deliver" ]
      in
      Alcotest.(check int) "invalid policy accepts nothing" 0
        (List.length accepted);
      Alcotest.(check (list string)) "invalid policy rejection"
        [ "policy" ] (List.map Conn.inbound_rejection_name rejected)
  | Ok _ -> Alcotest.fail "zero machine rate must not silently disable controls"

let test_inbound_policy_rejects_unknown_and_duplicate_keys () =
  let rejects label json =
    match Conn.parse_inbound_policy json with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail (label ^ " must fail closed")
  in
  rejects "top-level typo" (`Assoc [ ("default_max_byte", `Int 1) ]);
  rejects "rate typo"
    (`Assoc [ ("machine_rate", `Assoc [ ("message", `Int 1) ]) ]);
  rejects "sender typo"
    (`Assoc [ ("senders", `Assoc [
      ("alice@remote", `Assoc [ ("max_byte", `Int 1) ]) ]) ]);
  rejects "duplicate key"
    (`Assoc [ ("default_max_bytes", `Int 1);
              ("default_max_bytes", `Int 2) ]);
  rejects "case-colliding sender"
    (`Assoc [ ("senders", `Assoc [
      ("Alice@Remote", `Assoc []); ("alice@remote", `Assoc []) ]) ])

let policy ~max_bytes ~sender_messages ~machine_messages = {
  Conn.default_max_bytes = max_bytes;
  default_sender_rate = {
    Conn.rate_messages = sender_messages; rate_window_s = 60.0 };
  machine_rate = {
    Conn.rate_messages = machine_messages; rate_window_s = 60.0 };
  sender_overrides = [];
}

let rejection_names reasons = List.map Conn.inbound_rejection_name reasons

let test_inbound_size_and_schema_filter () =
  let state = Conn.create_inbound_rate_state () in
  let bounded = inbound_message ~sender:"alice@remote" "1234" in
  let max_bytes = Conn.inbound_row_size_bytes bounded in
  let rows = [
    bounded;
    inbound_message ~sender:"alice@remote" "12345";
    `Assoc [ ("from_alias", `String "alice@remote") ];
  ] in
  let accepted, rejected =
    Conn.filter_inbound_messages ~now:100.0
      (policy ~max_bytes ~sender_messages:10 ~machine_messages:10)
      state rows
  in
  Alcotest.(check int) "only bounded valid row accepted" 1
    (List.length accepted);
  Alcotest.(check (list string)) "rejection reasons"
    [ "oversize"; "schema" ] (rejection_names rejected)

let test_inbound_per_sender_rate_and_recovery () =
  let state = Conn.create_inbound_rate_state () in
  let policy = policy ~max_bytes:100 ~sender_messages:2 ~machine_messages:10 in
  let rows = [
    inbound_message ~sender:"Alice@Remote" "one";
    inbound_message ~sender:"alice@remote" "two";
    inbound_message ~sender:"ALICE@REMOTE" "three";
  ] in
  let accepted, rejected =
    Conn.filter_inbound_messages ~now:100.0 policy state rows
  in
  Alcotest.(check int) "two sender messages accepted" 2 (List.length accepted);
  Alcotest.(check (list string)) "casefolded sender limit"
    [ "sender_rate" ] (rejection_names rejected);
  let accepted_after_window, rejected_after_window =
    Conn.filter_inbound_messages ~now:161.0 policy state
      [ inbound_message ~sender:"alice@remote" "four" ]
  in
  Alcotest.(check int) "sender recovers after window" 1
    (List.length accepted_after_window);
  Alcotest.(check int) "no rejection after recovery" 0
    (List.length rejected_after_window)

let test_inbound_machine_rate_across_senders () =
  let state = Conn.create_inbound_rate_state () in
  let policy = policy ~max_bytes:100 ~sender_messages:10 ~machine_messages:3 in
  let rows = [
    inbound_message ~sender:"a@remote" "one";
    inbound_message ~sender:"b@remote" "two";
    inbound_message ~sender:"c@remote" "three";
    inbound_message ~sender:"d@remote" "four";
  ] in
  let accepted, rejected =
    Conn.filter_inbound_messages ~now:100.0 policy state rows
  in
  Alcotest.(check int) "aggregate machine cap" 3 (List.length accepted);
  Alcotest.(check (list string)) "machine rejection"
    [ "machine_rate" ] (rejection_names rejected)

let test_inbound_machine_rate_persists_across_instances () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    let policy = Ok (policy ~max_bytes:1000 ~sender_messages:10
      ~machine_messages:1) in
    let first, first_rejected, first_error =
      Conn.filter_inbound_messages_persisted ~now:100.0 ~broker_root:dir
        policy [ inbound_message ~sender:"a@remote" "one" ]
    in
    Alcotest.(check int) "first instance accepts" 1 (List.length first);
    Alcotest.(check int) "first instance rejects none" 0
      (List.length first_rejected);
    Alcotest.(check (option string)) "first state write succeeds" None first_error;
    let second, second_rejected, second_error =
      Conn.filter_inbound_messages_persisted ~now:101.0 ~broker_root:dir
        policy [ inbound_message ~sender:"b@remote" "two" ]
    in
    Alcotest.(check int) "fresh instance cannot reset machine allowance" 0
      (List.length second);
    Alcotest.(check (list string)) "persisted aggregate rejection"
      [ "machine_rate" ] (rejection_names second_rejected);
    Alcotest.(check (option string)) "second state read succeeds" None second_error;
    let after_window, _, _ =
      Conn.filter_inbound_messages_persisted ~now:161.0 ~broker_root:dir
        policy [ inbound_message ~sender:"b@remote" "three" ]
    in
    Alcotest.(check int) "persisted state recovers after sliding window" 1
      (List.length after_window))

let test_inbound_machine_rate_serializes_concurrent_processes () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    let policy = Ok (policy ~max_bytes:1000 ~sender_messages:10
      ~machine_messages:1) in
    let start_r, start_w = Unix.pipe () in
    let spawn sender =
      match Unix.fork () with
      | 0 ->
          Unix.close start_w;
          let gate = Bytes.create 1 in
          ignore (Unix.read start_r gate 0 1);
          let accepted, rejected, error =
            Conn.filter_inbound_messages_persisted ~now:100.0
              ~broker_root:dir policy [ inbound_message ~sender "one" ]
          in
          let code =
            if error <> None then 12
            else if List.length accepted = 1 then 10
            else if rejection_names rejected = [ "machine_rate" ] then 11
            else 13
          in
          Unix._exit code
      | pid -> pid
    in
    let p1 = spawn "a@remote" in
    let p2 = spawn "b@remote" in
    Unix.close start_r;
    ignore (Unix.write_substring start_w "xx" 0 2);
    Unix.close start_w;
    let status pid = match snd (Unix.waitpid [] pid) with
      | Unix.WEXITED code -> code
      | _ -> 99
    in
    let statuses = List.sort Int.compare [ status p1; status p2 ] in
    Alcotest.(check (list int)) "exactly one concurrent process consumes slot"
      [ 10; 11 ] statuses)

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

(* --- B010: alert delivery injects c2c-system messages into local inboxes --- *)

let read_inbox_messages root session_id =
  let path = Conn.local_inbox_path root session_id in
  match (try Some (Yojson.Safe.from_file path) with _ -> None) with
  | Some (`List items) -> items
  | _ -> []

let msg_field key json =
  match Yojson.Safe.Util.member key json with `String s -> s | _ -> ""

let contains_sub ~needle s =
  let nl = String.length needle and sl = String.length s in
  let rec go i = i + nl <= sl && (String.sub s i nl = needle || go (i + 1)) in
  nl = 0 || go 0

(* A dead-letter event must enqueue a c2c-system DM to the originating sender
   (the concrete first instance of B010's relay-event passthrough). Exercised
   end-to-end through the pure decider + the connector's file-IO injection. *)
let test_dlq_injects_system_dm_to_sender () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    let regs = [
      ("sess-alice", "alice", "claude");
      ("sess-bob", "bob", "codex");   (* unrelated peer — must NOT get the DM *)
    ] in
    let dlqs = [
      { C2c_relay_alert.dlq_sender = "alice"; dlq_to = "bob@host";
        dlq_reason = "recipient_dead" } ] in
    let emissions, _ =
      C2c_relay_alert.step C2c_relay_alert.initial_state
        { C2c_relay_alert.obs_difficulty = None; obs_rate_limited = false;
          obs_pow_retry_failed = false; obs_pow_retry_sender = None;
          obs_dlqs = dlqs } in
    let delivered = Conn.deliver_alert_emissions dir regs emissions in
    Alcotest.(check int) "one system message delivered" 1 delivered;
    (* alice's inbox got exactly one c2c-system message about the DLQ *)
    let alice_msgs = read_inbox_messages dir "sess-alice" in
    Alcotest.(check int) "alice inbox has one message" 1 (List.length alice_msgs);
    let m = List.hd alice_msgs in
    Alcotest.(check string) "from c2c-system" "c2c-system" (msg_field "from_alias" m);
    Alcotest.(check string) "to alice" "alice" (msg_field "to_alias" m);
    let content = msg_field "content" m in
    Alcotest.(check bool) "content tagged ERR" true
      (contains_sub ~needle:"[c2c-relay ERR]" content);
    Alcotest.(check bool) "content names recipient" true
      (contains_sub ~needle:"bob@host" content);
    (* bob (unrelated) must have no inbox messages *)
    Alcotest.(check int) "bob inbox untouched" 0
      (List.length (read_inbox_messages dir "sess-bob"))
  )

(* A broadcast emission (e.g. difficulty increase) must reach every session. *)
let test_broadcast_reaches_all_sessions () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    let regs = [ ("sess-a", "alice", "claude"); ("sess-b", "bob", "codex") ] in
    let emissions, _ =
      C2c_relay_alert.step C2c_relay_alert.initial_state
        { C2c_relay_alert.obs_difficulty = Some 4; obs_rate_limited = false;
          obs_pow_retry_failed = false; obs_pow_retry_sender = None;
          obs_dlqs = [] } in
    let delivered = Conn.deliver_alert_emissions dir regs emissions in
    Alcotest.(check int) "delivered to both sessions" 2 delivered;
    Alcotest.(check int) "alice got it" 1 (List.length (read_inbox_messages dir "sess-a"));
    Alcotest.(check int) "bob got it" 1 (List.length (read_inbox_messages dir "sess-b"))
  )

(* --- B087: response_difficulty must not crash on any input shape ---

   [response_difficulty] previously did [member "difficulty" (member "required"
   json)], and [Yojson.Safe.Util.member] RAISES Type_error on non-objects. A
   normal success response has no [required] key, so [member "required"]
   returned [Null] and the next [member "difficulty" Null] crashed on EVERY
   success — taking down the whole sync pass. These fixtures must all return
   None (or the correct int) without raising. *)
let test_response_difficulty_no_crash () =
  (* null / non-object top-level *)
  Alcotest.(check (option int)) "null top-level -> None"
    None (Conn.response_difficulty `Null);
  Alcotest.(check (option int)) "string top-level -> None"
    None (Conn.response_difficulty (`String "oops"));
  Alcotest.(check (option int)) "int top-level -> None"
    None (Conn.response_difficulty (`Int 5));
  (* empty object *)
  Alcotest.(check (option int)) "empty object -> None"
    None (Conn.response_difficulty (`Assoc []));
  (* success-shaped response: ok:true, no required field (the crash case) *)
  let success = `Assoc [("ok", `Bool true); ("alias", `String "lyra-quill")] in
  Alcotest.(check (option int)) "success body -> None"
    None (Conn.response_difficulty success);
  (* required present but null *)
  Alcotest.(check (option int)) "required:null -> None"
    None (Conn.response_difficulty (`Assoc [("required", `Null)]));
  (* required present but wrong type *)
  Alcotest.(check (option int)) "required:string -> None"
    None (Conn.response_difficulty (`Assoc [("required", `String "nope")]));
  (* required object missing difficulty *)
  Alcotest.(check (option int)) "required without difficulty -> None"
    None (Conn.response_difficulty
            (`Assoc [("required", `Assoc [("epoch", `Int 1)])]));
  (* valid required.difficulty (Int) *)
  Alcotest.(check (option int)) "required.difficulty:Int -> Some 7"
    (Some 7) (Conn.response_difficulty
                (`Assoc [("required", `Assoc [("difficulty", `Int 7)])]));
  (* valid required.difficulty (Float) *)
  Alcotest.(check (option int)) "required.difficulty:Float -> Some 3"
    (Some 3) (Conn.response_difficulty
                (`Assoc [("required", `Assoc [("difficulty", `Float 3.0)])]));
  (* pow_minted_difficulty annotation (success after minting) *)
  Alcotest.(check (option int)) "pow_minted_difficulty -> Some 9"
    (Some 9) (Conn.response_difficulty
                (`Assoc [("ok", `Bool true); ("pow_minted_difficulty", `Int 9)]));
  (* nested relay_response.required.difficulty (pow_retry_failed wraps it) *)
  let nested = `Assoc [
    ("error_code", `String "pow_retry_failed");
    ("relay_response", `Assoc [("required", `Assoc [("difficulty", `Int 6)])])
  ] in
  Alcotest.(check (option int)) "relay_response.required.difficulty -> Some 6"
    (Some 6) (Conn.response_difficulty nested);;
  (* relay_response present but not an object *)
  Alcotest.(check (option int)) "relay_response:string -> None"
    None (Conn.response_difficulty (`Assoc [("relay_response", `String "garbage")]))

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
    "B196 relay inbound policy", [
      Alcotest.test_case "safe defaults" `Quick test_inbound_policy_defaults;
      Alcotest.test_case "sender override parse + casefold" `Quick
        test_inbound_policy_parses_sender_override;
      Alcotest.test_case "invalid config fails" `Quick
        test_inbound_policy_invalid_fails;
      Alcotest.test_case "unknown + duplicate keys fail" `Quick
        test_inbound_policy_rejects_unknown_and_duplicate_keys;
      Alcotest.test_case "size + schema rejection" `Quick
        test_inbound_size_and_schema_filter;
      Alcotest.test_case "per-sender rate + recovery" `Quick
        test_inbound_per_sender_rate_and_recovery;
      Alcotest.test_case "machine aggregate rate" `Quick
        test_inbound_machine_rate_across_senders;
      Alcotest.test_case "machine rate persists across instances" `Quick
        test_inbound_machine_rate_persists_across_instances;
      Alcotest.test_case "machine rate serializes concurrent processes" `Quick
        test_inbound_machine_rate_serializes_concurrent_processes;
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
    "B010 alert delivery", [
      Alcotest.test_case "DLQ injects c2c-system DM to sender" `Quick test_dlq_injects_system_dm_to_sender;
      Alcotest.test_case "broadcast reaches all sessions" `Quick test_broadcast_reaches_all_sessions;
    ];
    "B087 response_difficulty", [
      Alcotest.test_case "no crash on null/missing/wrong-type/valid" `Quick test_response_difficulty_no_crash;
    ];
  ]
