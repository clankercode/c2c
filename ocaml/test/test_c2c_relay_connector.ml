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

let rec mkdir_p path =
  if path = "" || path = "/" || Sys.file_exists path then ()
  else (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

let write_empty_registry broker =
  mkdir_p broker;
  let oc = open_out (Filename.concat broker "registry.json") in
  output_string oc "[]\n";
  close_out oc

let test_machine_broker_discovery_is_dynamic () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  match Unix.fork () with
  | 0 ->
      Unix.putenv "HOME" tmp;
      Unix.putenv "C2C_STATE_HOME" (Filename.concat tmp "state");
      Unix.putenv "XDG_STATE_HOME" (Filename.concat tmp "xdg");
      let primary = Filename.concat tmp "primary-broker" in
      let repo_a = Filename.concat tmp ".c2c/repos/aaaa/broker" in
      let repo_b = Filename.concat tmp ".c2c/repos/bbbb/broker" in
      write_empty_registry repo_a;
      let first = Conn.discover_machine_broker_roots ~primary in
      if not (List.mem primary first && List.mem repo_a first && not (List.mem repo_b first))
      then exit 10;
      write_empty_registry repo_b;
      let second = Conn.discover_machine_broker_roots ~primary in
      if List.mem primary second && List.mem repo_a second && List.mem repo_b second
      then exit 0 else exit 11
  | pid ->
      let _, status = Unix.waitpid [] pid in
      Alcotest.(check int) "primary + startup repo + later repo discovered" 0
        (match status with Unix.WEXITED n -> n | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n)

let test_relay_registration_filters_historical_rows () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let live_pid = Unix.getpid () in
  let live_start =
    match Conn.read_pid_start_time_local live_pid with
    | Some n -> n
    | None -> Alcotest.fail "current process must have a readable start time"
  in
  let live = `Assoc [
    "session_id", `String "live-session";
    "alias", `String "live-alias";
    "client_type", `String "codex";
    "pid", `Int live_pid;
    "pid_start_time", `Int live_start;
  ] in
  let dead =
    List.init 64 (fun i -> `Assoc [
      "session_id", `String (Printf.sprintf "dead-%d" i);
      "alias", `String (Printf.sprintf "dead-alias-%d" i);
      "pid", `Int (900_000 + i);
      "pid_start_time", `Int 1;
    ])
  in
  let unknown = `Assoc [
    "session_id", `String "pidless-history";
    "alias", `String "pidless-history";
  ] in
  let recent_hook = `Assoc [
    "session_id", `String "recent-hook";
    "alias", `String "recent-hook-alias";
    "client_type", `String "claude";
    "registered_by", `String "claude-hook";
    "last_activity_ts", `Float (Unix.gettimeofday ());
  ] in
  let stale_hook = `Assoc [
    "session_id", `String "stale-hook";
    "alias", `String "stale-hook-alias";
    "registered_by", `String "grok-hook";
    "last_activity_ts", `Float (Unix.gettimeofday () -. 25.0 *. 60.0 *. 60.0);
  ] in
  let oc = open_out (Filename.concat tmp "registry.json") in
  Yojson.Safe.to_channel oc (`List (live :: recent_hook :: stale_hook :: unknown :: dead));
  close_out oc;
  let regs, skipped = Conn.read_local_registrations_with_skipped tmp in
  Alcotest.(check int) "pid-live + recent hook" 2 (List.length regs);
  Alcotest.(check int) "dead + stale/unverified skipped" 66 skipped;
  Alcotest.(check (list (triple string string string))) "eligible identity"
    [ "live-session", "live-alias", "codex";
      "recent-hook", "recent-hook-alias", "claude" ] regs;
  Alcotest.(check (list string)) "cached dead sessions pruned"
    [ "live-session"; "recent-hook" ]
    (Conn.retain_eligible_registered regs
       [ "dead-1"; "live-session"; "recent-hook"; "pidless-history" ])

let test_docker_registration_lease_boundaries () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  match Unix.fork () with
  | 0 ->
      Unix.putenv "C2C_IN_DOCKER" "1";
      let mk session_id = Conn.{
        lr_session_id = session_id; lr_alias = session_id;
        lr_client_type = "codex"; lr_pid = Some 42;
        lr_pid_start_time = Some 1; lr_registered_at = None;
        lr_last_activity_ts = None; lr_registered_by = None;
      } in
      let lease_dir = Filename.concat tmp ".leases" in
      Unix.mkdir lease_dir 0o700;
      let fresh_path = Filename.concat lease_dir "fresh" in
      let stale_path = Filename.concat lease_dir "stale" in
      let touch path = let oc = open_out path in close_out oc in
      touch fresh_path; touch stale_path;
      let now = Unix.gettimeofday () in
      Unix.utimes stale_path (now -. 301.0) (now -. 301.0);
      let ok =
        Conn.relay_registration_is_eligible ~broker_root:tmp (mk "fresh")
        && not (Conn.relay_registration_is_eligible ~broker_root:tmp (mk "stale"))
        && not (Conn.relay_registration_is_eligible ~broker_root:tmp (mk "missing"))
      in
      exit (if ok then 0 else 12)
  | pid ->
      let _, status = Unix.waitpid [] pid in
      Alcotest.(check int) "fresh=true, expired/missing=false in originating root" 0
        (match status with Unix.WEXITED n -> n | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n)

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

let inbound_message ?(recipient = "local-agent") ~sender content =
  `Assoc [
    ("from_alias", `String sender);
    ("to_alias", `String recipient);
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
        Alcotest.(check int) "default recipient messages" 120
          policy.Conn.default_recipient_rate.rate_messages;
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
      Alcotest.(check bool) "override defaults to allow" true
        (alice.Conn.sender_action = Conn.Inbound_allow);
      Alcotest.(check int) "override max" 512 alice.Conn.sender_max_bytes;
      Alcotest.(check int) "override rate" 2
        alice.Conn.sender_rate.rate_messages;
      let other = Conn.inbound_sender_policy policy "other@remote" in
      Alcotest.(check int) "other gets default max" 4096
        other.Conn.sender_max_bytes;
      Alcotest.(check int) "other gets default rate" 12
        other.Conn.sender_rate.rate_messages

let test_inbound_policy_parses_admission_and_recipient_controls () =
  let json = `Assoc [
    ("default_sender_action", `String "deny");
    ("default_recipient_rate", `Assoc [
      ("messages", `Int 5); ("window_seconds", `Int 30) ]);
    ("senders", `Assoc [
      ("trusted@remote", `Assoc [ ("action", `String "allow") ]);
      ("blocked@remote", `Assoc [ ("action", `String "deny") ]);
    ]);
    ("recipients", `Assoc [
      ("Quiet-Agent", `Assoc [
        ("enabled", `Bool false);
        ("max_bytes", `Int 1024);
        ("rate", `Assoc [
          ("messages", `Int 2); ("window_seconds", `Int 60) ]);
      ]);
    ]);
  ] in
  match Conn.parse_inbound_policy json with
  | Error e -> Alcotest.fail e
  | Ok policy ->
      Alcotest.(check bool) "unknown sender denied by default" true
        ((Conn.inbound_sender_policy policy "unknown@remote").Conn.sender_action
          = Conn.Inbound_deny);
      Alcotest.(check bool) "trusted sender allowed" true
        ((Conn.inbound_sender_policy policy "TRUSTED@REMOTE").Conn.sender_action
          = Conn.Inbound_allow);
      let quiet = Conn.inbound_recipient_policy policy "quiet-agent" in
      Alcotest.(check bool) "recipient disabled" false
        quiet.Conn.recipient_enabled;
      Alcotest.(check int) "recipient max" 1024 quiet.Conn.recipient_max_bytes;
      Alcotest.(check int) "recipient rate" 2
        quiet.Conn.recipient_rate.rate_messages

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
  Conn.default_sender_action = Conn.Inbound_allow;
  Conn.default_max_bytes = max_bytes;
  default_sender_rate = {
    Conn.rate_messages = sender_messages; rate_window_s = 60.0 };
  default_recipient_rate = {
    Conn.rate_messages = 100_000; rate_window_s = 60.0 };
  machine_rate = {
    Conn.rate_messages = machine_messages; rate_window_s = 60.0 };
  sender_overrides = [];
  recipient_overrides = [];
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

let test_inbound_admission_and_recipient_controls () =
  let state = Conn.create_inbound_rate_state () in
  let base = policy ~max_bytes:1000 ~sender_messages:10 ~machine_messages:20 in
  let policy = {
    base with
    Conn.sender_overrides = [
      ("blocked@remote", {
        Conn.sender_action = Conn.Inbound_deny;
        sender_max_bytes = 1000;
        sender_rate = base.Conn.default_sender_rate;
      });
    ];
    recipient_overrides = [
      ("off-agent", {
        Conn.recipient_enabled = false;
        recipient_max_bytes = 1000;
        recipient_rate = base.Conn.default_recipient_rate;
      });
      ("quiet-agent", {
        Conn.recipient_enabled = true;
        recipient_max_bytes = 1000;
        recipient_rate = { Conn.rate_messages = 1; rate_window_s = 60.0 };
      });
    ];
  } in
  let accepted, rejected =
    Conn.filter_inbound_messages ~now:100.0 policy state [
      inbound_message ~sender:"blocked@remote" "denied";
      inbound_message ~recipient:"off-agent" ~sender:"ok@remote" "disabled";
      inbound_message ~recipient:"quiet-agent" ~sender:"a@remote" "one";
      inbound_message ~recipient:"quiet-agent" ~sender:"b@remote" "two";
    ]
  in
  Alcotest.(check int) "one recipient message accepted" 1
    (List.length accepted);
  Alcotest.(check (list string)) "admission and recipient reasons"
    [ "sender_denied"; "recipient_disabled"; "recipient_rate" ]
    (rejection_names rejected)

let test_inbound_rate_state_backward_compatible_without_recipients () =
  let json = `Assoc [
    ("machine", `List [ `Float 100.0 ]);
    ("senders", `Assoc [ ("alice@remote", `List [ `Float 100.0 ]) ]);
  ] in
  match Conn.inbound_rate_state_of_json json with
  | Error e -> Alcotest.fail e
  | Ok state ->
      Alcotest.(check int) "legacy sender restored" 1
        (Hashtbl.length state.Conn.sender_events);
      Alcotest.(check int) "missing recipients becomes empty" 0
        (Hashtbl.length state.Conn.recipient_events)

let test_inbound_expected_recipient_binding () =
  let state = Conn.create_inbound_rate_state () in
  let policy = policy ~max_bytes:1000 ~sender_messages:10 ~machine_messages:20 in
  let accepted, rejected =
    Conn.filter_inbound_messages ~expected_recipient:"sensitive-agent"
      ~now:100.0 policy state [
        inbound_message ~recipient:"other-agent" ~sender:"a@remote" "relabelled";
        inbound_message ~recipient:"SENSITIVE-AGENT" ~sender:"a@remote" "valid";
      ]
  in
  Alcotest.(check int) "case-insensitive intended recipient accepted" 1
    (List.length accepted);
  Alcotest.(check (list string)) "relabelling rejected"
    [ "recipient_mismatch" ] (rejection_names rejected)

let test_inbound_qualified_recipient_binding_and_policy () =
  let expected = "local-agent" in
  let base = policy ~max_bytes:1000 ~sender_messages:10 ~machine_messages:20 in
  let binding_state = Conn.create_inbound_rate_state () in
  let accepted, rejected =
    Conn.filter_inbound_messages ~expected_recipient:expected ~now:100.0
      base binding_state [
        inbound_message ~recipient:expected ~sender:"bare@remote" "bare";
        inbound_message ~recipient:"LOCAL-AGENT@0123456789ab" ~sender:"dm@remote"
          "qualified dm";
        inbound_message ~recipient:"local-agent#team-room" ~sender:"room@remote"
          "room fanout";
        inbound_message ~recipient:"local-agent#team-room@relay"
          ~sender:"roster@remote" "canonical room address";
        inbound_message ~recipient:"other-agent@0123456789ab" ~sender:"bad-dm@remote"
          "mismatched dm";
        inbound_message ~recipient:"other-agent#team-room" ~sender:"bad-room@remote"
          "mismatched room";
        inbound_message ~recipient:"local-agent@host#room"
          ~sender:"malformed@remote" "malformed delimiter order";
        inbound_message ~recipient:"local-agent@bad host"
          ~sender:"bad-host@remote" "malformed host";
        inbound_message ~recipient:"local-agent#../../fake"
          ~sender:"bad-room-id@remote" "malformed room id";
      ]
  in
  Alcotest.(check int) "bare, qualified, fanout, and roster forms bind" 4
    (List.length accepted);
  Alcotest.(check (list string)) "mismatched and malformed forms reject"
    [ "recipient_mismatch"; "recipient_mismatch"; "recipient_mismatch";
      "recipient_mismatch"; "recipient_mismatch" ]
    (rejection_names rejected);
  let disabled_policy = {
    base with
    Conn.recipient_overrides = [
      (expected, {
        Conn.recipient_enabled = false;
        recipient_max_bytes = 1000;
        recipient_rate = base.Conn.default_recipient_rate;
      });
    ];
  } in
  let _, disabled =
    Conn.filter_inbound_messages ~expected_recipient:expected ~now:100.0
      disabled_policy (Conn.create_inbound_rate_state ())
      [ inbound_message ~recipient:"local-agent@0123456789ab" ~sender:"ok@remote"
          "disabled by trusted recipient policy" ]
  in
  Alcotest.(check (list string)) "qualified form uses local enable policy"
    [ "recipient_disabled" ] (rejection_names disabled);
  let rate_policy = {
    base with
    Conn.recipient_overrides = [
      (expected, {
        Conn.recipient_enabled = true;
        recipient_max_bytes = 1000;
        recipient_rate = { Conn.rate_messages = 1; rate_window_s = 60.0 };
      });
    ];
  } in
  let rate_state = Conn.create_inbound_rate_state () in
  let accepted, rejected =
    Conn.filter_inbound_messages ~expected_recipient:expected ~now:100.0
      rate_policy rate_state [
        inbound_message ~recipient:"local-agent@0123456789ab" ~sender:"one@remote"
          "first";
        inbound_message ~recipient:"local-agent#team-room" ~sender:"two@remote"
          "same trusted recipient";
      ]
  in
  Alcotest.(check int) "first qualified row accepted" 1 (List.length accepted);
  Alcotest.(check (list string)) "fanout shares trusted recipient rate slot"
    [ "recipient_rate" ] (rejection_names rejected);
  Alcotest.(check int) "rate state has one trusted local recipient key" 1
    (Hashtbl.length rate_state.Conn.recipient_events);
  Alcotest.(check bool) "rate state key is the polled alias" true
    (Hashtbl.mem rate_state.Conn.recipient_events expected)

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
          obs_rate_limited_senders = [];
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

(* A connector-wide difficulty change is operational state, not an actionable
   agent message. It must be logged without touching any local inbox. *)
let test_difficulty_alert_does_not_reach_sessions () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    let regs = [ ("sess-a", "alice", "claude"); ("sess-b", "bob", "codex") ] in
    let emissions, _ =
      C2c_relay_alert.step C2c_relay_alert.initial_state
        { C2c_relay_alert.obs_difficulty = Some 4; obs_rate_limited = false;
          obs_rate_limited_senders = [];
          obs_pow_retry_failed = false; obs_pow_retry_sender = None;
          obs_dlqs = [] } in
    let delivered = Conn.deliver_alert_emissions dir regs emissions in
    Alcotest.(check int) "no system messages delivered" 0 delivered;
    Alcotest.(check int) "alice inbox untouched" 0
      (List.length (read_inbox_messages dir "sess-a"));
    Alcotest.(check int) "bob inbox untouched" 0
      (List.length (read_inbox_messages dir "sess-b"))
  )

let test_rate_limit_dms_only_affected_senders () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    let regs = [
      ("sess-alice", "alice", "claude");
      ("sess-bob", "bob", "codex");
      ("sess-carol", "carol", "opencode");
    ] in
    let emissions, _ =
      C2c_relay_alert.step C2c_relay_alert.initial_state
        { C2c_relay_alert.obs_difficulty = None;
          obs_rate_limited = true;
          obs_rate_limited_senders = ["alice"; "bob"];
          obs_pow_retry_failed = false; obs_pow_retry_sender = None;
          obs_dlqs = [] }
    in
    let delivered = Conn.deliver_alert_emissions dir regs emissions in
    Alcotest.(check int) "one DM per affected sender" 2 delivered;
    Alcotest.(check int) "alice gets one DM" 1
      (List.length (read_inbox_messages dir "sess-alice"));
    Alcotest.(check int) "bob gets one DM" 1
      (List.length (read_inbox_messages dir "sess-bob"));
    Alcotest.(check int) "unrelated carol inbox untouched" 0
      (List.length (read_inbox_messages dir "sess-carol"))
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

(* ---------------------------------------------------------------------------
 * B209: connector persists the per-alias (node_id, session_id) it registered
 * on the relay, and the monitor peeks that EXACT key instead of guessing
 * cli-<alias>. The relay keys leases by (node_id, session_id) with one row per
 * alias (ON CONFLICT(alias) DO UPDATE), so once the machine connector
 * registers a session it owns the alias's live lease under (connector node_id,
 * that session_id). A bare `c2c monitor` that fell back to cli-<alias>/
 * cli-<alias> (because its local session-id was unresolved — Grok CLI-first)
 * then failed the relay owner check with signature_invalid.
 * --------------------------------------------------------------------------- *)

let sync_result_with_sessions sessions : Conn.sync_result =
  { registered = List.map fst sessions;
    registered_sessions = sessions;
    heartbeated = [];
    outbox_forwarded = 0;
    outbox_failed = 0;
    outbox_dlqed = 0;
    inbound_delivered = 0;
    inbound_rejected = 0;
    alerts_emitted = 0;
    rate_limited = false;
    last_error = None }

(* Round-trip: write_connector_state persists [sessions]; read_connector_state
   recovers the alias -> session_id map (cs_sessions). *)
let test_connector_state_sessions_roundtrip () =
  let dir = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () ->
    let result =
      sync_result_with_sessions
        [ ("grok-powder-kelo-6z5j", "019f64e1-04be-73c0-83e3-c71a3b40d406")
        ; ("claude-fixture-alpha", "sid-claude-1") ]
    in
    Conn.write_connector_state ~node_id:"host-hash-abc" dir result;
    match Conn.read_connector_state dir with
    | None -> Alcotest.fail "read_connector_state returned None after write"
    | Some cs ->
        Alcotest.(check (option string)) "node_id persisted"
          (Some "host-hash-abc") cs.Conn.cs_node_id;
        Alcotest.(check (option string))
          "grok alias -> its real connector session_id"
          (Some "019f64e1-04be-73c0-83e3-c71a3b40d406")
          (List.assoc_opt "grok-powder-kelo-6z5j" cs.Conn.cs_sessions);
        Alcotest.(check (option string)) "second alias round-trips too"
          (Some "sid-claude-1")
          (List.assoc_opt "claude-fixture-alpha" cs.Conn.cs_sessions))

(* The regression: a CLI-first client (Grok) whose local session-id is
   UNRESOLVED (fallback_session_id = "") still resolves the connector's
   authoritative key from cs_sessions. Before B209 the monitor required a
   resolvable local session-id and otherwise fell back to cli-<alias>, which
   the relay rejected with signature_invalid. *)
let test_connector_peek_key_uses_recorded_session_when_local_unresolved () =
  let cs =
    { Conn.cs_last_sync_ts = 0.0; cs_last_ok_ts = 0.0;
      cs_last_error_op = None; cs_last_error_detail = None;
      cs_last_error_ts = None;
      cs_registered = [ "grok-powder-kelo-6z5j" ];
      cs_node_id = Some "host-hash-abc";
      cs_sessions =
        [ ("grok-powder-kelo-6z5j", "019f64e1-04be-73c0-83e3-c71a3b40d406") ];
      cs_pid = None;
      cs_outbox_forwarded = 0; cs_outbox_failed = 0; cs_outbox_dlqed = 0;
      cs_inbound_delivered = 0; cs_inbound_rejected = 0 }
  in
  (match
     Conn.connector_peek_key cs ~alias:"grok-powder-kelo-6z5j"
       ~fallback_node_id:"host-hash-abc" ~fallback_session_id:""
   with
   | Some (node_id, session_id) ->
       Alcotest.(check string) "peek node_id = connector node_id"
         "host-hash-abc" node_id;
       Alcotest.(check string)
         "peek session_id = connector-recorded session (NOT cli-<alias>)"
         "019f64e1-04be-73c0-83e3-c71a3b40d406" session_id
   | None ->
       Alcotest.fail
         "connector_peek_key returned None despite a recorded connector \
          session — this is the B209 signature_invalid regression");
  (* Case-insensitive alias match. *)
  (match
     Conn.connector_peek_key cs ~alias:"GROK-POWDER-KELO-6Z5J"
       ~fallback_node_id:"host-hash-abc" ~fallback_session_id:""
   with
   | Some (_, session_id) ->
       Alcotest.(check string) "case-insensitive alias resolves same session"
         "019f64e1-04be-73c0-83e3-c71a3b40d406" session_id
   | None -> Alcotest.fail "case-insensitive alias match failed");
  (* An alias the connector does not manage yields None (fall back to
     cli-<alias> at the call site). *)
  Alcotest.(check bool) "unmanaged alias -> None" true
    (Conn.connector_peek_key cs ~alias:"stranger-nope-9z9z"
       ~fallback_node_id:"host-hash-abc" ~fallback_session_id:"whatever"
     = None)

(* Backward-compat: a state file written before cs_sessions existed (no
   "sessions" key) still resolves a key by falling back to the locally
   resolved session-id. *)
let test_connector_peek_key_backward_compat_fallback () =
  let cs =
    { Conn.cs_last_sync_ts = 0.0; cs_last_ok_ts = 0.0;
      cs_last_error_op = None; cs_last_error_detail = None;
      cs_last_error_ts = None;
      cs_registered = [ "grok-powder-kelo-6z5j" ];
      cs_node_id = Some "host-hash-abc";
      cs_sessions = [];  (* pre-B209 state file *)
      cs_pid = None;
      cs_outbox_forwarded = 0; cs_outbox_failed = 0; cs_outbox_dlqed = 0;
      cs_inbound_delivered = 0; cs_inbound_rejected = 0 }
  in
  match
    Conn.connector_peek_key cs ~alias:"grok-powder-kelo-6z5j"
      ~fallback_node_id:"host-hash-abc" ~fallback_session_id:"local-sid-fallback"
  with
  | Some (node_id, session_id) ->
      Alcotest.(check string) "node_id" "host-hash-abc" node_id;
      Alcotest.(check string) "falls back to local session-id when no cs_sessions"
        "local-sid-fallback" session_id;
      (* The exact pre-B209 Grok situation: connector manages the alias but the
         monitor could resolve NEITHER a recorded session (old state file) NOR a
         local session-id -> no connector key, forcing the cli-<alias> fallback
         that the relay rejected. With cs_sessions populated (the other test)
         this no longer happens. *)
      Alcotest.(check bool) "no recorded + no local session-id -> None" true
        (Conn.connector_peek_key cs ~alias:"grok-powder-kelo-6z5j"
           ~fallback_node_id:"host-hash-abc" ~fallback_session_id:"" = None)
  | None -> Alcotest.fail "backward-compat fallback returned None"

(* B210: bounded, jittered 429 backoff. *)
let test_backoff_zero_strikes_is_base () =
  Alcotest.(check (float 1e-9)) "strikes=0 -> base" 30.0
    (Conn.rate_limit_backoff ~base:30.0 ~strikes:0)

let test_backoff_grows_then_caps () =
  let base = 30.0 in
  (* Jitter is in [0, base); assert on the lower bound (2^strikes * base) and
     the cap+jitter upper bound so the test is deterministic without seeding. *)
  let d1 = Conn.rate_limit_backoff ~base ~strikes:1 in
  let d2 = Conn.rate_limit_backoff ~base ~strikes:2 in
  Alcotest.(check bool) "strike 1 >= 2*base" true (d1 >= 2.0 *. base);
  Alcotest.(check bool) "strike 1 < 2*base + base (jitter)" true
    (d1 < 2.0 *. base +. base);
  Alcotest.(check bool) "strike 2 >= 4*base" true (d2 >= 4.0 *. base);
  (* Large strike count is capped at the cap (plus at most base of jitter),
     never runaway. *)
  let big = Conn.rate_limit_backoff ~base ~strikes:1000 in
  Alcotest.(check bool) "huge strike capped" true
    (big <= Conn.rate_limit_backoff_cap_s +. base);
  Alcotest.(check bool) "huge strike >= cap" true
    (big >= Conn.rate_limit_backoff_cap_s)

(* B211: staleness-exit watchdog for the alive-but-erroring wedge. *)
let mk_result ?(rate_limited = false) ?last_error () : Conn.sync_result =
  { registered = []; registered_sessions = []; heartbeated = [];
    outbox_forwarded = 0; outbox_failed = 0; outbox_dlqed = 0;
    inbound_delivered = 0; inbound_rejected = 0; alerts_emitted = 0;
    rate_limited; last_error }

let test_stale_exit_default_threshold () =
  (* default = max(600, interval*20); 30s interval -> 600s, 60s -> 1200s. *)
  Alcotest.(check (float 1e-9)) "30s interval -> 600s floor" 600.0
    (Conn.stale_exit_threshold_s ~interval:30.0);
  Alcotest.(check (float 1e-9)) "60s interval -> 20x" 1200.0
    (Conn.stale_exit_threshold_s ~interval:60.0)

let test_should_exit_stale_predicate () =
  let now = 10_000.0 in
  let threshold = 600.0 in
  (* fresh progress -> keep running *)
  Alcotest.(check bool) "recent progress -> no exit" false
    (Conn.should_exit_stale ~now ~last_progress:(now -. 60.0) ~threshold);
  (* stale past threshold -> exit *)
  Alcotest.(check bool) "hours-stale progress -> exit" true
    (Conn.should_exit_stale ~now ~last_progress:(now -. 7200.0) ~threshold);
  (* exactly at threshold -> exit (>=) *)
  Alcotest.(check bool) "exactly at threshold -> exit" true
    (Conn.should_exit_stale ~now ~last_progress:(now -. 600.0) ~threshold)

let test_sync_made_progress () =
  (* ok pass (no error) is progress; rate-limited pass is progress (relay up,
     throttling — restarting would not help); a plain errored pass is NOT. *)
  Alcotest.(check bool) "ok pass is progress" true
    (Conn.sync_made_progress (mk_result ()));
  Alcotest.(check bool) "rate-limited pass is progress" true
    (Conn.sync_made_progress
       (mk_result ~rate_limited:true
          ~last_error:{ Conn.err_op = "poll_inbox";
                        err_detail = "rate_limit_exceeded";
                        err_ts = 0.0 } ()));
  Alcotest.(check bool) "errored pass (request_timeout) is NOT progress" false
    (Conn.sync_made_progress
       (mk_result ~last_error:{ Conn.err_op = "poll_inbox";
                                err_detail = "request_timeout";
                                err_ts = 0.0 } ()))

let () =
  Random.self_init ();
  Alcotest.run "c2c_relay_connector" [
    "B210 rate-limit backoff", [
      Alcotest.test_case "strikes=0 is base interval" `Quick
        test_backoff_zero_strikes_is_base;
      Alcotest.test_case "grows exponentially then caps" `Quick
        test_backoff_grows_then_caps;
    ];
    "B211 staleness-exit watchdog", [
      Alcotest.test_case "default threshold = max(600, 20x interval)" `Quick
        test_stale_exit_default_threshold;
      Alcotest.test_case "exit predicate fires past threshold" `Quick
        test_should_exit_stale_predicate;
      Alcotest.test_case "ok/rate-limited count as progress, errors do not"
        `Quick test_sync_made_progress;
    ];
    "paths", [
      Alcotest.test_case "local_inbox_path" `Quick test_local_inbox_path;
      Alcotest.test_case "outbox_path" `Quick test_outbox_path;
      Alcotest.test_case "pseudo_reg_path" `Quick test_pseudo_reg_path;
      Alcotest.test_case "mobile_bindings_path" `Quick test_mobile_bindings_path;
    ];
    "B200 machine brokers", [
      Alcotest.test_case "dynamic repository discovery" `Quick
        test_machine_broker_discovery_is_dynamic;
    ];
    "B201 relay registration eligibility", [
      Alcotest.test_case "dead history skipped; recent hooks retained" `Quick
        test_relay_registration_filters_historical_rows;
      Alcotest.test_case "Docker leases are bounded and per-root" `Quick
        test_docker_registration_lease_boundaries;
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
    "B197 relay inbound admission", [
      Alcotest.test_case "admission + recipient config parse" `Quick
        test_inbound_policy_parses_admission_and_recipient_controls;
      Alcotest.test_case "sender deny + recipient safeguards" `Quick
        test_inbound_admission_and_recipient_controls;
      Alcotest.test_case "B196 rate state remains readable" `Quick
        test_inbound_rate_state_backward_compatible_without_recipients;
      Alcotest.test_case "row recipient binds to polled local agent" `Quick
        test_inbound_expected_recipient_binding;
      Alcotest.test_case "qualified destinations bind and use local policy" `Quick
        test_inbound_qualified_recipient_binding_and_policy;
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
      Alcotest.test_case "difficulty alert stays out of inboxes" `Quick test_difficulty_alert_does_not_reach_sessions;
      Alcotest.test_case "rate limit DMs only affected senders" `Quick
        test_rate_limit_dms_only_affected_senders;
    ];
    "B087 response_difficulty", [
      Alcotest.test_case "no crash on null/missing/wrong-type/valid" `Quick test_response_difficulty_no_crash;
    ];
    "B209 connector peek key", [
      Alcotest.test_case "alias -> session_id round-trips through connector-state" `Quick
        test_connector_state_sessions_roundtrip;
      Alcotest.test_case "recorded session used when local session-id unresolved" `Quick
        test_connector_peek_key_uses_recorded_session_when_local_unresolved;
      Alcotest.test_case "backward-compat fallback to local session-id" `Quick
        test_connector_peek_key_backward_compat_fallback;
    ];
  ]
