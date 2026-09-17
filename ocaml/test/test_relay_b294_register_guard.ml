(* B294: `c2c relay register` must not steal a lease a live relay-connect
   connector owns — and the relay's own error text must stop telling
   operators to run it.

   Three layers pinned here:
   - pure key resolution: explicit --node-id/--session-id (flags over
     C2C_RELAY_NODE_ID/C2C_RELAY_SESSION_ID) are the supported way to hand
     a lease to a chosen pair; the default stays cli-<alias>/cli-<alias>;
   - the refusal: connector-state.json evidence (alias managed + live pid
     or fresh successful sync) blocks a default-key register, --force
     overrides, explicit keys are a deliberate choice and are not blocked;
   - the rewritten B184 hint: key-drift advice points at restarting
     relay-connect / read-only peek, never at `c2c relay register`. *)

open Alcotest
module S = Relay_test_support
module RS = Relay.Relay_server (Relay.SqliteRelay)
open Lwt.Infix

let rm_rf dir = ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

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

let with_temp_dir prefix f =
  let dir = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_file path s =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc s)

(* --- fixture connector-state.json --------------------------------------- *)

(* [managed]: alias recorded in "sessions" (and "registered" — the two
   spellings of connector-managed, the latter empty in steady state).
   [age]: how old last_ok_ts / last_sync_ts are. [pid]: recorded pid.
   [last_error_op]: the op recorded in the file's last_error_op field
   (B324: register vs other ops discriminates the alive-but-failing case). *)
let write_connector_state ~(last_error_op : string option) ~dir ~managed ~age ~pid =
  let now = Unix.gettimeofday () in
  let ts = now -. age in
  (* Both spellings of "connector manages this alias": sessions (the
     durable alias -> session binding) and registered (aliases registered
     on the pass that wrote the file). *)
  let sessions =
    if managed then `Assoc [ ("b294-probe", `String "sess-b294") ]
    else `Assoc [ ("somebody-else", `String "sess-other") ]
  in
  let registered =
    if managed then [ `String "b294-probe" ] else [ `String "somebody-else" ]
  in
  write_file (Filename.concat dir "connector-state.json")
    (Yojson.Safe.to_string
       (`Assoc
          [ ("last_sync_ts", `Float ts)
          ; ("last_ok_ts", `Float ts)
          ; ("pid", match pid with Some p -> `Int p | None -> `Null)
          ; ("registered", `List registered)
          ; ("outbox_forwarded", `Int 0)
          ; ("outbox_failed", `Int 0)
          ; ("outbox_dlqed", `Int 0)
          ; ("inbound_delivered", `Int 0)
          ; ("inbound_rejected", `Int 0)
          ; ("inbound_rejected_note", `Null)
          ; ("last_error_op",
             match last_error_op with
             | Some op -> `String op
             | None -> `Null)
          ; ("sessions", sessions)
          ]))

(* A pid that cannot be ours: pid 1 is excluded by connector_pid_alive, and
   a huge pid does not exist, so the pid arm never fires in these fixtures —
   the freshness arm is what is under test. *)
let dead_pid = 4_000_000

(* --- pure: key resolution ------------------------------------------------ *)

let test_register_key_resolution () =
  let resolve ?flag_node ?flag_session ?env_node ?env_session () =
    C2c_relay_connector.resolve_register_inbox_key ~alias:"b294-probe"
      ~flag_node_id:flag_node ~flag_session_id:flag_session
      ~env_node_id:env_node ~env_session_id:env_session
  in
  let ok_key r = match r with
    | Ok k -> k
    | Error m -> Alcotest.failf "unexpected refusal: %s" m
  in
  check (pair string string) "default keeps the cli convention"
    ("cli-b294-probe", "cli-b294-probe") (ok_key (resolve ()));
  check (pair string string) "both flags" ("n1", "s1")
    (ok_key (resolve ~flag_node:"n1" ~flag_session:"s1" ()));
  check (pair string string) "node alone implies node/node" ("n1", "n1")
    (ok_key (resolve ~flag_node:"n1" ()));
  check (pair string string) "env pair" ("en", "es")
    (ok_key (resolve ~env_node:"en" ~env_session:"es" ()));
  check (pair string string) "flags win over env" ("fn", "fs")
    (ok_key (resolve ~flag_node:"fn" ~flag_session:"fs" ~env_node:"en" ~env_session:"es" ()));
  check (pair string string) "flag node over env node" ("fn", "es")
    (ok_key (resolve ~flag_node:"fn" ~env_session:"es" ()));
  (match resolve ~flag_session:"s1" () with
   | Error advice ->
       check bool "session-only is refused with advice" true
         (contains ~needle:"--node-id" advice)
   | Ok _ -> fail "session without node must not resolve");
  (match resolve ~env_session:"s1" () with
   | Error _ -> check bool "env session alone refused too" true true
   | Ok _ -> fail "env session without node must not resolve")

(* --- pure: connector ownership evidence --------------------------------- *)

let test_connector_owns_alias_evidence () =
  with_temp_dir "c2c_b294_own" (fun dir ->
    let owns ~managed ~age ~pid =
      write_connector_state ~dir ~managed ~age ~pid ~last_error_op:None;
      C2c_relay_connector.connector_owns_alias ~broker_root:dir
        ~alias:"b294-probe" ~now:(Unix.gettimeofday ())
    in
    let no_state_owner =
      (try ignore (Sys.remove (Filename.concat dir "connector-state.json"))
       with _ -> ());
      C2c_relay_connector.connector_owns_alias ~broker_root:dir
        ~alias:"b294-probe" ~now:(Unix.gettimeofday ())
    in
    check (option string) "no state file -> no owner" None no_state_owner;
    check bool "fresh sync + managed alias -> owned" true
      (owns ~managed:true ~age:10.0 ~pid:(Some dead_pid) <> None);
    check bool "stale sync (past the 120s doctor window) -> not owned" false
      (owns ~managed:true ~age:300.0 ~pid:(Some dead_pid) <> None);
    check bool "fresh sync but alias not managed -> not owned" false
      (owns ~managed:false ~age:10.0 ~pid:(Some dead_pid) <> None);
    (* the strongest evidence: a live recorded pid, even with a stale sync *)
    check bool "live pid owns regardless of sync age" true
      (owns ~managed:true ~age:3600.0 ~pid:(Some (Unix.getpid ())) <> None);
    (* alias match is case-insensitive (repo rule) *)
    check bool "case-insensitive alias match" true
      (match
         C2c_relay_connector.connector_owns_alias ~broker_root:dir
           ~alias:"B294-PROBE" ~now:(Unix.gettimeofday ())
       with
       | Some _ -> true
       | None -> false))

(* B324: pid-alive is DEMOTED below last_ok freshness when the recorded
   last_error_op is register. An alive connector whose register arm fails
   on every pass (identity binding drift after a rename) is not evidence
   of ownership: the documented repair (CLI relay register) must stay
   available while the connector cycles wedge cooldowns. A healthy
   connector — fresh last_ok, or failing at an op that does not bear on
   the identity — keeps pid-alive as authoritative evidence. *)
let test_connector_owns_alias_alive_but_register_failing () =
  with_temp_dir "c2c_b324_own" (fun dir ->
    let owns ~last_error_op ~age =
      write_connector_state ~dir ~managed:true ~age
        ~pid:(Some (Unix.getpid ())) ~last_error_op;
      C2c_relay_connector.connector_owns_alias ~broker_root:dir
        ~alias:"b294-probe" ~now:(Unix.gettimeofday ())
    in
    check (option string)
      "live pid + register failing + stale last_ok -> NOT owned" None
      (owns ~last_error_op:(Some "register") ~age:3600.0);
    check bool
      "live pid + register failing + FRESH last_ok -> owned (healthy)" true
      (owns ~last_error_op:(Some "register") ~age:10.0 <> None);
    check bool
      "live pid + OTHER op failing + stale last_ok -> still owned" true
      (owns ~last_error_op:(Some "heartbeat") ~age:3600.0 <> None);
    check bool
      "live pid + no recorded error + stale last_ok -> still owned" true
      (owns ~last_error_op:None ~age:3600.0 <> None);
    (* dead pid + register failing + stale last_ok: neither arm fires *)
    write_connector_state ~dir ~managed:true ~age:3600.0
      ~pid:(Some dead_pid) ~last_error_op:(Some "register");
    check (option string)
      "dead pid + register failing + stale last_ok -> NOT owned" None
      (C2c_relay_connector.connector_owns_alias ~broker_root:dir
         ~alias:"b294-probe" ~now:(Unix.gettimeofday ()));
    (* dead pid + register failing + fresh last_ok: freshness still owns *)
    write_connector_state ~dir ~managed:true ~age:10.0
      ~pid:(Some dead_pid) ~last_error_op:(Some "register");
    check bool
      "dead pid + register failing + fresh last_ok -> owned" true
      (C2c_relay_connector.connector_owns_alias ~broker_root:dir
         ~alias:"b294-probe" ~now:(Unix.gettimeofday ()) <> None))

(* --- binary: refusal + key override against a scripted relay ------------ *)

let c2c_binary =
  let exe = Sys.executable_name in
  let exe =
    if Filename.is_relative exe then Filename.concat (Sys.getcwd ()) exe else exe
  in
  let exe = try Unix.realpath exe with _ -> exe in
  let test_dir = Filename.dirname exe in
  let ocaml_dir = Filename.dirname test_dir in
  Filename.concat ocaml_dir (Filename.concat "cli" "c2c.exe")

(* Scrub host session keys (same rationale as test_c2c_cli) and pin every
   c2c-owned path into the temp dir so the binary cannot touch the operator's
   identity or broker state. *)
let run_c2c ?(extra_env = "") broker_root identity_path args =
  let out = Filename.temp_file "c2c_b294_out" ".log" in
  let err = Filename.temp_file "c2c_b294_err" ".log" in
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

let register_calls srv =
  List.filter
    (fun (r : S.captured_request) -> r.S.path = "/register")
    (S.requests srv)

let register_body_field (r : S.captured_request) key =
  match Yojson.Safe.from_string r.S.body with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> s
       | _ -> "")
  | _ -> ""

let reg_ok = {|{"ok":true,"result":"ok","lease":{"alias":"b294-probe"}}|}

let with_relay_server f =
  S.with_server
    ~routes:
      [ S.route ~meth:"POST" ~path:"/register" [ S.response reg_ok ] ]
    (fun srv -> f srv)

(* B294 core: a default-key register while a live connector owns the alias
   is refused before any request leaves the machine. *)
let test_register_refuses_when_connector_owns_alias () =
  with_temp_dir "c2c_b294_refuse" (fun dir ->
    write_connector_state ~dir ~managed:true ~age:5.0 ~pid:(Some dead_pid) ~last_error_op:None;
    with_relay_server (fun srv ->
        let status, _out, err = run_c2c dir (Filename.concat dir "id.json")
            [ "relay"; "register"; "--alias"; "b294-probe";
              "--relay-url"; S.url srv ] in
        check bool "refused (non-zero exit)" true (status <> 0);
        check bool "error names the connector" true
          (contains ~needle:"relay-connect appears to own alias b294-probe" err);
        check bool "advises restarting the connector" true
          (contains ~needle:"c2c restart relay-connect" err);
        check bool "names the override escape hatch" true
          (contains ~needle:"--force" err);
        check int "no register request left the machine" 0
          (List.length (register_calls srv))))

let test_register_force_overrides () =
  with_temp_dir "c2c_b294_force" (fun dir ->
    write_connector_state ~dir ~managed:true ~age:5.0 ~pid:(Some dead_pid) ~last_error_op:None;
    with_relay_server (fun srv ->
        let status, _out, err = run_c2c dir (Filename.concat dir "id.json")
            [ "relay"; "register"; "--alias"; "b294-probe";
              "--relay-url"; S.url srv; "--force" ] in
        check bool "forced register succeeds" true (status = 0);
        check bool "warns about the fight" true
          (contains ~needle:"--force overrides a live relay-connect connector"
             err);
        check int "register reached the relay" 1
          (List.length (register_calls srv))))

let test_register_allows_when_connector_state_stale () =
  with_temp_dir "c2c_b294_stale" (fun dir ->
    (* past the 120s window and no live pid: nothing to protect *)
    write_connector_state ~dir ~managed:true ~age:600.0 ~pid:(Some dead_pid) ~last_error_op:None;
    with_relay_server (fun srv ->
        let status, _out, _err = run_c2c dir (Filename.concat dir "id.json")
            [ "relay"; "register"; "--alias"; "b294-probe";
              "--relay-url"; S.url srv ] in
        check bool "stale connector state does not block" true (status = 0);
        check int "register reached the relay" 1
          (List.length (register_calls srv));
        match register_calls srv with
        | [ r ] ->
            check string "default key is still cli-<alias>" "cli-b294-probe"
              (register_body_field r "node_id");
            check string "default session key" "cli-b294-probe"
              (register_body_field r "session_id")
        | _ -> fail "expected exactly one register call"))

let test_register_explicit_keys_and_env () =
  with_temp_dir "c2c_b294_keys" (fun dir ->
    (* explicit keys are a deliberate choice: even a connector-owned alias
       is not blocked — handing the lease BACK is the supported repair *)
    write_connector_state ~dir ~managed:true ~age:5.0 ~pid:(Some dead_pid) ~last_error_op:None;
    with_relay_server (fun srv ->
        let status, _out, _err =
          run_c2c ~extra_env:"C2C_RELAY_NODE_ID=env-n C2C_RELAY_SESSION_ID=env-s"
            dir (Filename.concat dir "id.json")
            [ "relay"; "register"; "--alias"; "b294-probe";
              "--relay-url"; S.url srv ]
        in
        check bool "env key pair is not blocked" true (status = 0);
        (match register_calls srv with
         | [ r ] ->
             check string "env node_id honoured" "env-n"
               (register_body_field r "node_id");
             check string "env session_id honoured" "env-s"
               (register_body_field r "session_id")
         | _ -> fail "expected one register call"));
    ignore (Sys.remove (Filename.concat dir "id.json"));
    with_relay_server (fun srv ->
        let status, _out, _err = run_c2c dir (Filename.concat dir "id.json")
            [ "relay"; "register"; "--alias"; "b294-probe";
              "--relay-url"; S.url srv;
              "--node-id"; "flag-n"; "--session-id"; "flag-s" ] in
        check bool "flag keys register" true (status = 0);
        match register_calls srv with
        | [ r ] ->
            check string "flags win over env" "flag-n"
              (register_body_field r "node_id");
            check string "flag session" "flag-s"
              (register_body_field r "session_id")
        | _ -> fail "expected one register call"))

let test_register_node_only_implies_pair () =
  with_temp_dir "c2c_b294_nodeonly" (fun dir ->
    with_relay_server (fun srv ->
        let status, _out, _err = run_c2c dir (Filename.concat dir "id.json")
            [ "relay"; "register"; "--alias"; "b294-probe";
              "--relay-url"; S.url srv; "--node-id"; "flag-n" ] in
        check bool "node-only registers" true (status = 0);
        match register_calls srv with
        | [ r ] ->
            check string "node_id from flag" "flag-n"
              (register_body_field r "node_id");
            check string "session_id implied by node" "flag-n"
              (register_body_field r "session_id")
        | _ -> fail "expected one register call"))

let test_register_session_only_is_an_error () =
  with_temp_dir "c2c_b294_sessonly" (fun dir ->
    with_relay_server (fun srv ->
        let status, _out, err = run_c2c dir (Filename.concat dir "id.json")
            [ "relay"; "register"; "--alias"; "b294-probe";
              "--relay-url"; S.url srv; "--session-id"; "s1" ] in
        check bool "session without node exits non-zero" true (status <> 0);
        check bool "explains what is missing" true
          (contains ~needle:"--node-id" err);
        check int "no request made" 0 (List.length (register_calls srv))))

(* --- relay: the rewritten B184 hint -------------------------------------- *)

let loopback_socket () =
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt fd Unix.SO_REUSEADDR true;
  Lwt_unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) >>= fun () ->
  Lwt_unix.listen fd 16;
  match Lwt_unix.getsockname fd with
  | Unix.ADDR_INET (_, port) -> Lwt.return (fd, port)
  | _ -> Lwt.fail_with "loopback_socket: expected INET socket"

let with_token_sqlite_server f =
  with_temp_dir "c2c_b294_srv" (fun dir ->
    Lwt_main.run
      (loopback_socket () >>= fun (fd, port) ->
       let relay = Relay.SqliteRelay.create ~persist_dir:dir () in
       let rate_limiter = Relay.Rate_limiter_inst.create ~gc_interval:300.0 () in
       let stop, wake_stop = Lwt.wait () in
       (* Token-configured (prod-shaped): a peer route whose Ed25519 header
         fails to verify is refused with the verifier's own error text —
         on a tokenless relay /heartbeat falls back to the unsigned path and
         the B184 message never reaches the client. *)
       let callback (conn, _) req body =
         RS.make_callback relay (Some "b294-tok") conn req body
           ?broker_root:None ~native_tls:false ~rate_limiter
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
            server)))

let test_b184_hint_never_recommends_register () =
  with_temp_dir "c2c_b294_hint" (fun dir ->
    (* Bind the alias under identity A through the real signed /register
       (exactly as production stores the alias→identity binding), then send
       a signed request as the alias with identity B: the signature does not
       verify against the bound key — the key-drift case the B184 message
       exists for. *)
    let id_a =
      Relay_identity.load_or_create_at
        ~path:(Filename.concat dir "id-a.json") ~alias_hint:"b294-holder"
    in
    let id_b =
      Relay_identity.load_or_create_at
        ~path:(Filename.concat dir "id-b.json") ~alias_hint:"b294-other"
    in
    with_token_sqlite_server (fun ~base_url ->
      let client =
        Relay.Relay_client.make ~token:"b294-tok" ~timeout:5.0 base_url
      in
      let p = Relay_signed_ops.sign_register id_a ~alias:"b294-holder"
          ~relay_url:base_url in
      Relay.Relay_client.register_signed client
        ~node_id:"b294n" ~session_id:"b294s" ~alias:"b294-holder"
        ~client_type:"cli"
        ~identity_pk_b64:p.Relay_signed_ops.identity_pk_b64
        ~sig_b64:p.Relay_signed_ops.sig_b64
        ~nonce:p.Relay_signed_ops.nonce ~ts:p.Relay_signed_ops.ts ()
      >>= fun reg ->
      check bool "setup register ok" true
        (match reg with
         | `Assoc fields -> List.assoc_opt "ok" fields = Some (`Bool true)
         | _ -> false);
      let header =
        Relay_signed_ops.sign_request id_b ~alias:"b294-holder" ~meth:"POST"
          ~path:"/heartbeat" ~body_str:"" ()
      in
      Relay.Relay_client.heartbeat_signed client
        ~node_id:"b294n" ~session_id:"b294s" ~auth_header:header
      >>= fun hb ->
      let code =
        match hb with
        | `Assoc fields ->
            (match List.assoc_opt "error_code" fields with
             | Some (`String c) -> c
             | _ -> "")
        | _ -> ""
      in
      let msg = Yojson.Safe.to_string hb in
      check string "still signature_invalid" "signature_invalid" code;
      check bool "keeps the diagnostic detail (B184)" true
        (contains ~needle:"bound_pk=" msg);
      check bool "points at restarting the connector" true
        (contains ~needle:"c2c restart relay-connect" msg);
      check bool "offers a read-only probe" true
        (contains ~needle:"c2c relay dm peek --alias b294-holder" msg);
      check bool "never recommends re-registering" false
        (contains ~needle:"re-run: c2c relay register" msg);
      check bool "explicitly warns off register" true
        (contains ~needle:"Do NOT run c2c relay register" msg);
      Lwt.return_unit))

let () =
  run "B294 relay register lease guard"
    [ ("register key resolution",
       [ test_case "flags/env/default precedence" `Quick
           test_register_key_resolution ])
    ; ("connector ownership evidence",
       [ test_case "fresh vs stale vs unmanaged vs live pid" `Quick
           test_connector_owns_alias_evidence
       ; test_case "alive-but-register-failing demotes pid-alive (B324)" `Quick
           test_connector_owns_alias_alive_but_register_failing
       ])
    ; ("c2c relay register binary",
       [ test_case "refuses when connector owns the alias" `Quick
           test_register_refuses_when_connector_owns_alias
       ; test_case "--force overrides" `Quick
           test_register_force_overrides
       ; test_case "stale connector state allows" `Quick
           test_register_allows_when_connector_state_stale
       ; test_case "env pair + flags choose the lease keys" `Quick
           test_register_explicit_keys_and_env
       ; test_case "node-only implies node/node" `Quick
           test_register_node_only_implies_pair
       ; test_case "session-only is an error" `Quick
           test_register_session_only_is_an_error
       ])
    ; ("B184 hint",
       [ test_case "key-drift advice never says register" `Quick
           test_b184_hint_never_recommends_register ])
    ]
