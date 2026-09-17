(* B308: three traps in CLI relay DM key resolution (relay dm poll/peek).

   (a) LONE-NODE-ID DIVERGENCE: `relay register` treats a lone
       C2C_RELAY_NODE_ID as (node_id, node_id); dm poll/peek treated it as a
       NON-override (connector_peek_key fallback), so register-then-poll
       under the same env targeted DIFFERENT keys. Aligned: a lone node id
       (flag or env) overrides resolution to (n, n).
   (b) DEAD-CONNECTOR PREFERENCE: resolve_cli_dm_inbox_key_at preferred the
       connector (node_id, cs_sessions[alias]) key whenever
       connector-state.json LISTED the alias — no liveness/freshness check.
       After the connector dies, an operator following the Direct_cli hint
       registers cli-X/cli-X successfully, then poll/peek still target the
       dead connector key (signature_invalid / empty inbox on mail just
       re-registered). The connector-key preference is now gated on the same
       liveness predicate connector_owns_alias uses (B324 register-arm
       demotion composed in).
   (c) NO FLAGS: dm poll/peek expose no --node-id/--session-id; added with
       register's B294 semantics (flags over env, both-or-lone-node-id,
       session-only rejected with guidance), and the B294 refusal hint's
       dm-peek recommendation now explains that peek follows the live lease,
       so it stays coherent once the connector is dead.

   Hermetic: pure resolver assertions + the shared scripted loopback relay
   (forked child, canned responses, request capture) driving the c2c binary;
   no network, no live relay. *)

open Alcotest

module Conn = C2c_relay_connector
module S = Relay_test_support

let rm_rf dir = ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

let with_temp_dir prefix f =
  let dir = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_file path s =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc s)

let contains ~needle hay =
  let nl = String.length needle and hl = String.length hay in
  if nl = 0 then true
  else
    let rec go i =
      if i + nl > hl then false
      else if String.sub hay i nl = needle then true
      else go (i + 1)
    in
    go 0

(* A pid that cannot be ours (B294-suite trick): the pid arm never fires —
   the freshness/liveness arm is what is under test. *)
let dead_pid = 4_000_000

(* Fixture connector-state.json (same shape as the B294 suite's). *)
let write_connector_state ?last_error_op ~dir ~managed ~age ~pid () =
  let now = Unix.gettimeofday () in
  let ts = now -. age in
  let sessions =
    if managed then `Assoc [ ("b308-probe", `String "sess-b308") ]
    else `Assoc [ ("somebody-else", `String "sess-other") ]
  in
  let registered =
    if managed then [ `String "b308-probe" ] else [ `String "somebody-else" ]
  in
  write_file
    (Filename.concat dir "connector-state.json")
    (Yojson.Safe.to_string
       (`Assoc
         [ ("last_sync_ts", `Float ts)
         ; ("last_ok_ts", `Float ts)
         ; ("node_id", `String "conn-node")
         ; ("pid", match pid with Some p -> `Int p | None -> `Null)
         ; ("registered", `List registered)
         ; ("outbox_forwarded", `Int 0)
         ; ("outbox_failed", `Int 0)
         ; ("outbox_dlqed", `Int 0)
         ; ("inbound_delivered", `Int 0)
         ; ("inbound_rejected", `Int 0)
         ; ("inbound_rejected_note", `Null)
         ; ("last_error_op",
            match last_error_op with Some op -> `String op | None -> `Null)
         ; ("sessions", sessions) ]))

(* Thin call wrapper so the resolution assertions below are stable: expected
   KEYS are the spec, not the plumbing. *)
let resolve_dm ?flag_node_id ?flag_session_id ~(env_node_id : string option)
    ~(env_session_id : string option)
    ~(connector_state : Conn.connector_state option)
    ?broker_root ~alias () : (string * string, string) result =
  let fallback_node_id = "host-hash-b308" in
  match broker_root with
  | Some dir ->
      Conn.resolve_cli_dm_inbox_key_at ~broker_root:dir ~alias ~flag_node_id
        ~flag_session_id ~env_node_id ~env_session_id
  | None ->
      Conn.resolve_cli_dm_inbox_key ~alias ~now:(Unix.gettimeofday ())
        ~connector_state ~fallback_node_id ~flag_node_id ~flag_session_id
        ~env_node_id ~env_session_id

let ok_key r = match r with Ok k -> k | Error m -> Alcotest.failf "unexpected refusal: %s" m

(* Live connector state VALUE (pid = this test process -> alive). *)
let live_connector_state () =
  { Conn.cs_last_sync_ts = Unix.gettimeofday ();
    cs_last_ok_ts = Unix.gettimeofday ();
    cs_last_error_op = None; cs_last_error_detail = None;
    cs_last_error_ts = None;
    cs_registered = [ "b308-probe" ];
    cs_node_id = Some "conn-node";
    cs_sessions = [ ("b308-probe", "sess-b308") ];
    cs_pid = Some (Unix.getpid ());
    cs_outbox_forwarded = 0; cs_outbox_failed = 0; cs_outbox_dlqed = 0;
    cs_inbound_delivered = 0; cs_inbound_rejected = 0;
    cs_inbound_rejected_note = None;
    cs_wedged_since = None; cs_wedge_reason = None; cs_wedge_count = 0;
    cs_errors = []; cs_rate_limited = false; cs_retry_after_s = None;
    cs_pass_duration_s = None; cs_pass_interval_s = None }

(* --- (a) lone C2C_RELAY_NODE_ID must mean (n, n), same as register ------ *)

let test_dm_lone_env_node_matches_register () =
  (* register's convention (already correct): *)
  check (pair string string) "register: lone env node -> (n,n)"
    ("env-n", "env-n")
    (ok_key
       (Conn.resolve_register_inbox_key ~alias:"b308-probe"
          ~flag_node_id:None ~flag_session_id:None ~env_node_id:(Some "env-n")
          ~env_session_id:None));
  (* dm poll/peek under the SAME env must target the SAME key — both when a
     live connector owns the alias and when there is no state at all. *)
  check (pair string string)
    "dm: lone env node overrides a live connector key -> (n,n)"
    ("env-n", "env-n")
    (ok_key
       (resolve_dm ~env_node_id:(Some "env-n") ~env_session_id:None
          ~connector_state:(Some (live_connector_state ())) ~alias:"b308-probe"
          ()));
  check (pair string string)
    "dm: lone env node with no connector state -> (n,n)"
    ("env-n", "env-n")
    (ok_key
       (resolve_dm ~env_node_id:(Some "env-n") ~env_session_id:None
          ~connector_state:None ~alias:"b308-probe" ()))

(* --- (b) dead connector state must not own the resolution --------------- *)

let test_dm_dead_connector_state_resolves_cli_key () =
  with_temp_dir "c2c_b308_dead" (fun dir ->
      (* Connector DIED: stale last_ok, recorded pid long gone, no live
         process. The operator re-registered cli-b308-probe/cli-b308-probe;
         poll/peek must follow the CLI key, not the dead connector key. *)
      write_connector_state ~dir ~managed:true ~age:600.0
        ~pid:(Some dead_pid) ();
      check (pair string string)
        "dead connector: poll/peek resolve the cli key" ("cli-b308-probe", "cli-b308-probe")
        (ok_key
           (resolve_dm ~env_node_id:None ~env_session_id:None
              ~connector_state:None ~broker_root:dir
              ~alias:"b308-probe" ()));
      (* Contrast (must keep working): a LIVE connector (fresh last_ok)
         still owns the resolution. *)
      write_connector_state ~dir ~managed:true ~age:5.0 ~pid:(Some dead_pid) ();
      check (pair string string)
        "live (fresh) connector: poll/peek keep the connector key"
        ("conn-node", "sess-b308")
        (ok_key
           (resolve_dm ~env_node_id:None ~env_session_id:None
              ~connector_state:None ~broker_root:dir
              ~alias:"b308-probe" ())))

(* B324 composition: pid ALIVE but the register arm keeps failing past the
   fixed 120s floor -> demoted; the documented repair (CLI register) worked,
   so peek/poll must resolve the CLI key, not the demoted connector key. *)
let test_dm_register_arm_failing_resolves_cli_key () =
  with_temp_dir "c2c_b308_b324" (fun dir ->
      write_connector_state ~last_error_op:"register" ~dir
        ~managed:true ~age:3600.0 ~pid:(Some (Unix.getpid ())) ();
      check (pair string string)
        "register-arm demotion: resolution follows the cli key"
        ("cli-b308-probe", "cli-b308-probe")
        (ok_key
           (resolve_dm ~env_node_id:None ~env_session_id:None
              ~connector_state:None ~broker_root:dir
              ~alias:"b308-probe" ())))

(* --- binary: flags, env parity, refusal hint ---------------------------- *)

let c2c_binary =
  let exe = Sys.executable_name in
  let exe =
    if Filename.is_relative exe then Filename.concat (Sys.getcwd ()) exe else exe
  in
  let exe = try Unix.realpath exe with _ -> exe in
  let test_dir = Filename.dirname exe in
  let ocaml_dir = Filename.dirname test_dir in
  Filename.concat ocaml_dir (Filename.concat "cli" "c2c.exe")

let run_c2c ?(extra_env = "") broker_root identity_path args =
  let out = Filename.temp_file "c2c_b308_out" ".log" in
  let err = Filename.temp_file "c2c_b308_err" ".log" in
  let cmd =
    Printf.sprintf
      "env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID \
       -u C2C_OPENCODE_SESSION_ID -u GROK_SESSION_ID \
       -u ANTIGRAVITY_CONVERSATION_ID -u KIMI_SESSION_ID %s \
       C2C_MCP_BROKER_ROOT=%s C2C_RELAY_IDENTITY_PATH=%s %s %s > %s 2> %s"
      extra_env (Filename.quote broker_root) (Filename.quote identity_path)
      (Filename.quote c2c_binary) (String.concat " " (List.map Filename.quote args))
      (Filename.quote out) (Filename.quote err)
  in
  let status = Sys.command cmd in
  let read p =
    let ic = open_in p in
    Fun.protect ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  in
  let o = try read out with _ -> "" in
  let e = try read err with _ -> "" in
  ignore (Sys.remove out);
  ignore (Sys.remove err);
  (status, o, e)

let reg_ok = {|{"ok":true,"result":"ok","lease":{"alias":"b308-probe"}}|}
let dm_ok = {|{"ok":true,"messages":[]}|}
let inbox_routes =
  [ S.route ~meth:"POST" ~path:"/register" [ S.response reg_ok ]
  ; S.route ~meth:"POST" ~path:"/peek_inbox" [ S.response dm_ok ]
  ; S.route ~meth:"POST" ~path:"/poll_inbox" [ S.response dm_ok ] ]

let with_dm_server f = S.with_server ~routes:inbox_routes (fun srv -> f srv)

let captured_paths srv =
  List.map (fun (r : S.captured_request) -> r.S.path) (S.requests srv)

let captured_of_path srv path =
  match
    List.filter
      (fun (r : S.captured_request) -> r.S.path = path)
      (S.requests srv)
  with
  | [ r ] -> (
      match Yojson.Safe.from_string r.S.body with
      | `Assoc fields ->
          (fun k ->
             match List.assoc_opt k fields with
             | Some (`String s) -> s
             | _ -> "")
      | _ -> (fun _ -> ""))
  | _ -> (fun _ -> "NO-REQUEST")

let body_field srv path key = captured_of_path srv path key

(* (c) the new flags reach the relay on both poll and peek, and win over
   the connector key. *)
let test_dm_flags_reach_the_relay () =
  with_temp_dir "c2c_b308_flags" (fun dir ->
    (* connector state present and LIVE: flags must still override *)
      write_connector_state ~dir ~managed:true ~age:5.0 ~pid:(Some dead_pid) ();
      with_dm_server (fun srv ->
          let url = S.url srv in
          let status, _o, _e =
            run_c2c dir (Filename.concat dir "id.json")
              [ "relay"; "dm"; "peek"; "--alias"; "b308-probe";
                "--relay-url"; url; "--node-id"; "flag-n"; "--session-id";
                "flag-s" ]
          in
          check bool "peek with flags exits 0" true (status = 0);
          check string "peek flag node_id" "flag-n"
            (body_field srv "/peek_inbox" "node_id");
          check string "peek flag session_id" "flag-s"
            (body_field srv "/peek_inbox" "session_id"));
      with_dm_server (fun srv ->
          let url = S.url srv in
          let status, _o, _e =
            run_c2c dir (Filename.concat dir "id.json")
              [ "relay"; "dm"; "poll"; "--alias"; "b308-probe";
                "--relay-url"; url; "--node-id"; "flag-n"; "--session-id";
                "flag-s" ]
          in
          check bool "poll with flags exits 0" true (status = 0);
          check string "poll flag node_id" "flag-n"
            (body_field srv "/poll_inbox" "node_id");
          check string "poll flag session_id" "flag-s"
            (body_field srv "/poll_inbox" "session_id")))

(* (a) end-to-end: register then peek under the SAME lone C2C_RELAY_NODE_ID
   must hit the SAME (n, n) key. *)
let test_register_then_peek_lone_env_node_same_key () =
  with_temp_dir "c2c_b308_envnode" (fun dir ->
      with_dm_server (fun srv ->
          let url = S.url srv in
          let status, _o, _e =
            run_c2c ~extra_env:"C2C_RELAY_NODE_ID=env-n" dir
              (Filename.concat dir "id.json")
              [ "relay"; "register"; "--alias"; "b308-probe"; "--relay-url";
                url ]
          in
          check bool "register under lone env node exits 0" true (status = 0);
          check string "register targeted (env-n, env-n)" "env-n"
            (body_field srv "/register" "session_id");
          let _status, _o, _e =
            run_c2c ~extra_env:"C2C_RELAY_NODE_ID=env-n" dir
              (Filename.concat dir "id.json")
              [ "relay"; "dm"; "peek"; "--alias"; "b308-probe"; "--relay-url";
                url ]
          in
          check string "peek targets the SAME key register used" "env-n"
            (body_field srv "/peek_inbox" "session_id");
          check string "peek node_id also env-n" "env-n"
            (body_field srv "/peek_inbox" "node_id")))

(* (c) session-only is rejected with the register-shaped guidance. *)
let test_dm_session_only_flag_rejected_with_guidance () =
  with_temp_dir "c2c_b308_sessonly" (fun dir ->
      with_dm_server (fun srv ->
          let status, _o, err =
            run_c2c dir (Filename.concat dir "id.json")
              [ "relay"; "dm"; "peek"; "--alias"; "b308-probe"; "--relay-url";
                S.url srv; "--session-id"; "s1" ]
          in
          check bool "session without node exits non-zero" true (status <> 0);
          check bool "explains what is missing (--node-id)" true
            (contains ~needle:"--node-id" err);
          check int "no request left the machine" 0
            (List.length (captured_paths srv)))

      )

(* (c) the B294 refusal hint's dm-peek recommendation stays coherent when
   the connector dies: peek follows the live lease. *)
let test_refusal_hint_names_peek_follows_lease () =
  with_temp_dir "c2c_b308_hint" (fun dir ->
      write_connector_state ~dir ~managed:true ~age:5.0
        ~pid:(Some dead_pid) ();
      with_dm_server (fun srv ->
          let status, _o, err =
            run_c2c dir (Filename.concat dir "id.json")
              [ "relay"; "register"; "--alias"; "b308-probe"; "--relay-url";
                S.url srv ]
          in
          check bool "refused (non-zero exit)" true (status <> 0);
          check bool "hint still recommends the peek probe" true
            (contains ~needle:"dm peek" err);
          check bool "hint explains peek follows the live lease" true
            (contains ~needle:"follows the live lease" err);
          check int "no register request left the machine" 0
            (List.length (captured_paths srv))))

(* Pin the flag/env precedence (register B294 semantics, mirrored here). *)
let test_dm_flags_precedence_pure () =
  check (pair string string) "flags beat env pair" ("fn", "fs")
    (ok_key
       (resolve_dm ~flag_node_id:"fn" ~flag_session_id:"fs"
          ~env_node_id:(Some "en") ~env_session_id:(Some "es")
          ~connector_state:(Some (live_connector_state ()))
          ~alias:"b308-probe" ()));
  check (pair string string) "flag node alone -> (n,n)" ("fn", "fn")
    (ok_key
       (resolve_dm ~flag_node_id:"fn" ~env_node_id:(Some "en")
          ~env_session_id:None ~connector_state:None ~alias:"b308-probe" ()));
  check (pair string string) "flag node + env session form a pair" ("fn", "es")
    (ok_key
       (resolve_dm ~flag_node_id:"fn" ~env_node_id:None
          ~env_session_id:(Some "es") ~connector_state:None
          ~alias:"b308-probe" ()));
  match
    resolve_dm ~flag_session_id:"s1"
      ~env_node_id:None ~env_session_id:None ~connector_state:None
      ~alias:"b308-probe" ()
  with
  | Error advice ->
      check bool "guidance names --node-id" true
        (contains ~needle:"--node-id" advice)
  | Ok _ -> fail "session-only flag must not resolve"

let () =
  run "relay-b308-dm-key-resolution"
    [
      ( "lone node id",
        [
          Alcotest.test_case "lone C2C_RELAY_NODE_ID means (n,n) everywhere"
            `Quick test_dm_lone_env_node_matches_register;
        ] );
      ( "dead connector",
        [
          Alcotest.test_case "dead connector state resolves the cli key" `Quick
            test_dm_dead_connector_state_resolves_cli_key;
          Alcotest.test_case "B324 demotion follows the cli key" `Quick
            test_dm_register_arm_failing_resolves_cli_key;
        ] );
      ( "flags",
        [
          Alcotest.test_case "flag/env precedence matches register" `Quick
            test_dm_flags_precedence_pure;
        ] );
      ( "binary",
        [
          Alcotest.test_case "flags reach the relay on poll and peek" `Quick
            test_dm_flags_reach_the_relay;
          Alcotest.test_case
            "register-then-peek under lone env node targets one key" `Quick
            test_register_then_peek_lone_env_node_same_key;
          Alcotest.test_case "session-only flag rejected with guidance" `Quick
            test_dm_session_only_flag_rejected_with_guidance;
          Alcotest.test_case "refusal hint: peek follows the live lease" `Quick
            test_refusal_hint_names_peek_follows_lease;
        ] );
    ]
