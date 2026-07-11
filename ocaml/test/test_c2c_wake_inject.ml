(* test_c2c_wake_inject — unit tests for C2c_wake_inject (codex-wake-inject slice).

   Hermetic: temp broker root per test, all external effects gated behind
   C2C_WAKE_INJECT_FIXTURE (commands are recorded as JSON lines, never
   executed). Covers:
   - no-registration / empty-inbox / no-wake-target skips
   - tmux fixture command sequence (literal send-keys then Enter)
   - herdr fixture command shape (agent get status probe + pane run submit)
   - herdr socket env recorded on commands
   - no-inject when herdr reports working (status fixture)
   - tmux idle-gating on last_activity_ts
   - backoff + no-new-messages dedupe
   - injector never drains the inbox
   - backend preference (tmux over herdr — innermost surface wins)
   - wake_targets_from_env derivation *)

open Alcotest

let ( // ) = Filename.concat

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let mkdir_p path =
  let rec loop p =
    if Sys.file_exists p then ()
    else begin
      loop (Filename.dirname p);
      Unix.mkdir p 0o755
    end
  in
  if path <> "" && path <> Filename.dirname path then loop path

let read_file path =
  if not (Sys.file_exists path) then ""
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      really_input_string ic (in_channel_length ic))

(* Env hygiene: every test runs with the fixture armed and the knobs reset. *)
let with_env kvs f =
  let old = List.map (fun (k, _) -> (k, Sys.getenv_opt k)) kvs in
  List.iter (fun (k, v) -> match v with
    | Some v -> Unix.putenv k v
    | None -> Unix.putenv k "") kvs;
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (k, v) ->
        Unix.putenv k (Option.value v ~default:"")) old)
    (fun () -> f ())

type ctx = { broker_root : string; fixture : string }

let with_ctx f =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-wake-inject-%08x" (Random.bits ()) in
  let broker_root = dir // "broker" in
  mkdir_p broker_root;
  let fixture = dir // "fixture.jsonl" in
  Fun.protect
    ~finally:(fun () -> try remove_tree dir with _ -> ())
    (fun () ->
      with_env
        [ ("C2C_WAKE_INJECT_FIXTURE", Some fixture)
        ; ("C2C_WAKE_INJECT_HERDR_STATUS", None)
        ; ("C2C_WAKE_IDLE_THRESHOLD_S", None)
        ; ("C2C_WAKE_BACKOFF_S", None)
        ]
        (fun () -> f { broker_root; fixture }))

let broker ctx = C2c_mcp.Broker.create ~root:ctx.broker_root

let register ?tmux_location ?herdr_pane ?herdr_socket ?registered_by ctx
    ~session_id ~alias =
  let b = broker ctx in
  C2c_mcp.Broker.register b ~session_id ~alias ~pid:(Some (Unix.getpid ()))
    ~pid_start_time:(C2c_mcp.Broker.capture_pid_start_time (Some (Unix.getpid ())))
    ~client_type:(Some "codex")
    ?tmux_location:(Option.map Option.some tmux_location)
    ?herdr_pane:(Option.map Option.some herdr_pane)
    ?herdr_socket:(Option.map Option.some herdr_socket)
    ?registered_by:(Option.map Option.some registered_by)
    ();
  b

(* A hook auto-registration carries NO pid (vanilla codex hook auto-register
   sets pid=None) so it reads as pidless — but it IS the identity authority for
   its session_id. Mirror that shape here. *)
let register_hook ?tmux_location ?herdr_pane ctx ~session_id ~alias =
  let b = broker ctx in
  C2c_mcp.Broker.register b ~session_id ~alias ~pid:None
    ~pid_start_time:None
    ~client_type:(Some "codex")
    ?tmux_location:(Option.map Option.some tmux_location)
    ?herdr_pane:(Option.map Option.some herdr_pane)
    ~registered_by:(Some "codex-hook")
    ~from_auto_gen:true
    ();
  b

let enqueue ctx ~to_alias ~from_session ~from_alias ~content =
  let b = broker ctx in
  ignore
    (C2c_mcp.Broker.register b ~session_id:from_session ~alias:from_alias
       ~pid:(Some (Unix.getpid ()))
       ~pid_start_time:(C2c_mcp.Broker.capture_pid_start_time (Some (Unix.getpid ())))
       ());
  C2c_mcp.Broker.enqueue_message b ~from_alias ~to_alias ~content ()

let fixture_lines ctx : Yojson.Safe.t list =
  read_file ctx.fixture
  |> String.split_on_char '\n'
  |> List.filter (fun l -> String.trim l <> "")
  |> List.map Yojson.Safe.from_string

let argv_of (json : Yojson.Safe.t) : string list =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "argv" fields with
      | Some (`List xs) ->
          List.map (function `String s -> s | _ -> "?") xs
      | _ -> [])
  | _ -> []

let env_of (json : Yojson.Safe.t) : (string * string) list =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "env" fields with
      | Some (`Assoc kvs) ->
          List.map (fun (k, v) -> (k, match v with `String s -> s | _ -> "?")) kvs
      | _ -> [])
  | _ -> []

let outcome = testable
    (fun fmt o -> Format.pp_print_string fmt (C2c_wake_inject.outcome_to_string o))
    (fun a b -> a = b)

let inject ?now ctx ~session_id =
  C2c_wake_inject.maybe_inject ?now ~broker_root:ctx.broker_root ~session_id ()

(* --- skips --------------------------------------------------------------- *)

let test_skips_without_registration () =
  with_ctx (fun ctx ->
    check outcome "no registration" (Skipped "no_registration")
      (inject ctx ~session_id:"zw-wake-nobody"))

let test_skips_on_empty_inbox () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-empty" in
    ignore (register ctx ~session_id:sid ~alias:sid ~tmux_location:"%7");
    check outcome "empty inbox" (Skipped "inbox_empty") (inject ctx ~session_id:sid))

let test_skips_without_wake_target () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-notarget" in
    ignore (register ctx ~session_id:sid ~alias:sid);
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-a" ~from_alias:"zw-wake-peer-a"
      ~content:"hello";
    check outcome "no wake target" (Skipped "no_wake_target")
      (inject ctx ~session_id:sid);
    check string "no commands recorded" "" (String.trim (read_file ctx.fixture)))

(* --- tmux backend --------------------------------------------------------- *)

let test_tmux_command_sequence () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-tmuxseq" in
    ignore (register ctx ~session_id:sid ~alias:sid ~tmux_location:"%7");
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-b" ~from_alias:"zw-wake-peer-b"
      ~content:"one";
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-b" ~from_alias:"zw-wake-peer-b"
      ~content:"two";
    (match inject ctx ~session_id:sid with
     | Injected { backend; message_count } ->
         check string "tmux backend" "tmux" backend;
         check int "counts both messages" 2 message_count
     | o -> failf "expected Injected, got %s" (C2c_wake_inject.outcome_to_string o));
    let lines = fixture_lines ctx in
    (* literal text; then Enter wrapped in an extended-keys off/restore
       toggle (c2c-tmux-enter.sh parity — a CSI-u encoded Enter is not a
       submit). In fixture mode the `show` capture returns no output, so
       the restore arm re-sets "off". *)
    check int "exactly five commands" 5 (List.length lines);
    let nudge = "c2c: 2 message(s) waiting - poll your inbox" in
    check (list string) "literal send-keys first"
      [ "tmux"; "send-keys"; "-l"; "-t"; "%7"; nudge ]
      (argv_of (List.nth lines 0));
    check (list string) "read extended-keys"
      [ "tmux"; "show"; "-sv"; "extended-keys" ]
      (argv_of (List.nth lines 1));
    check (list string) "extended-keys off before Enter"
      [ "tmux"; "set"; "-s"; "extended-keys"; "off" ]
      (argv_of (List.nth lines 2));
    check (list string) "then Enter"
      [ "tmux"; "send-keys"; "-t"; "%7"; "Enter" ]
      (argv_of (List.nth lines 3));
    check (list string) "extended-keys restored"
      [ "tmux"; "set"; "-s"; "extended-keys"; "off" ]
      (argv_of (List.nth lines 4)))

let test_tmux_idle_gate_blocks_recent_activity () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-tmuxbusy" in
    let b = register ctx ~session_id:sid ~alias:sid ~tmux_location:"%3" in
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-c" ~from_alias:"zw-wake-peer-c"
      ~content:"ping";
    (* Fresh activity → not idle → no inject. *)
    C2c_mcp.Broker.touch_session b ~session_id:sid;
    check outcome "recent activity blocks inject" (Skipped "recent_activity")
      (inject ctx ~session_id:sid);
    check string "no commands recorded" "" (String.trim (read_file ctx.fixture));
    (* Same state evaluated 200s later → idle → inject. *)
    (match inject ~now:(Unix.gettimeofday () +. 200.0) ctx ~session_id:sid with
     | Injected _ -> ()
     | o -> failf "expected Injected once idle, got %s"
              (C2c_wake_inject.outcome_to_string o)))

(* --- herdr backend --------------------------------------------------------- *)

let test_herdr_command_shape_and_socket_env () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-herdr" in
    ignore
      (register ctx ~session_id:sid ~alias:sid ~herdr_pane:"w1:p9"
         ~herdr_socket:"/run/herdr/api.sock");
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-d" ~from_alias:"zw-wake-peer-d"
      ~content:"knock";
    (match inject ctx ~session_id:sid with
     | Injected { backend; message_count } ->
         check string "herdr backend" "herdr" backend;
         check int "one message" 1 message_count
     | o -> failf "expected Injected, got %s" (C2c_wake_inject.outcome_to_string o));
    let lines = fixture_lines ctx in
    check int "status probe + submit" 2 (List.length lines);
    check (list string) "idle probe first"
      [ "herdr"; "agent"; "get"; "w1:p9" ]
      (argv_of (List.nth lines 0));
    check (list string) "pane run submits text plus Enter"
      [ "herdr"; "pane"; "run"; "w1:p9"
      ; "c2c: 1 message(s) waiting - poll your inbox" ]
      (argv_of (List.nth lines 1));
    List.iter
      (fun line ->
        check (list (pair string string)) "HERDR_SOCKET_PATH exported"
          [ ("HERDR_SOCKET_PATH", "/run/herdr/api.sock") ]
          (env_of line))
      lines)

let test_herdr_working_blocks_inject () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-herdrbusy" in
    ignore (register ctx ~session_id:sid ~alias:sid ~herdr_pane:"w2:p1");
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-e" ~from_alias:"zw-wake-peer-e"
      ~content:"busy?";
    with_env [ ("C2C_WAKE_INJECT_HERDR_STATUS", Some "working") ] (fun () ->
      check outcome "working pane never injected"
        (Skipped "herdr_not_idle:working") (inject ctx ~session_id:sid));
    (* Only the status probe ran — no submit command. *)
    let lines = fixture_lines ctx in
    check int "probe only" 1 (List.length lines);
    check (list string) "probe argv" [ "herdr"; "agent"; "get"; "w2:p1" ]
      (argv_of (List.nth lines 0)))

let test_herdr_done_status_injectable () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-herdrdone" in
    ignore (register ctx ~session_id:sid ~alias:sid ~herdr_pane:"w2:p7");
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-e2" ~from_alias:"zw-wake-peer-e2"
      ~content:"turn over?";
    (* "done" = agent finished its last turn, sitting at the composer —
       observed live for at-rest codex panes; injectable. *)
    with_env [ ("C2C_WAKE_INJECT_HERDR_STATUS", Some "done") ] (fun () ->
      match inject ctx ~session_id:sid with
      | Injected { backend; _ } -> check string "herdr backend" "herdr" backend
      | o -> failf "expected Injected on done, got %s"
               (C2c_wake_inject.outcome_to_string o)))

(* Real `herdr agent get` output captured live 2026-07-10: the CLI wraps the
   agent payload under result.agent. The parser must find the nested
   agent_status (a naive top-level lookup reads "unknown" and the herdr
   backend never injects). *)
let test_parse_herdr_agent_status_real_shape () =
  let live =
    {|{"id":"cli:agent:get","result":{"agent":{"agent":"codex","agent_status":"idle","cwd":"/home/x/src/c2c","focused":false,"foreground_cwd":"/home/x/src/c2c","pane_id":"w1:p4","revision":0,"tab_id":"w1:t3","terminal_id":"term_65600961fbf4413","workspace_id":"w1"},"type":"agent_info"}}|}
  in
  check string "nested result.agent.agent_status" "idle"
    (C2c_wake_inject.parse_herdr_agent_status live);
  check string "top-level agent_status still accepted" "working"
    (C2c_wake_inject.parse_herdr_agent_status {|{"agent_status":"working"}|});
  check string "garbage is unknown" "unknown"
    (C2c_wake_inject.parse_herdr_agent_status "not json");
  check string "missing member is unknown" "unknown"
    (C2c_wake_inject.parse_herdr_agent_status {|{"result":{"type":"agent_info"}}|})

(* Innermost surface wins: a session inside tmux captures its exact pane via
   $TMUX_PANE; a herdr_pane seen alongside it is the OUTER herdr pane hosting
   the tmux client (env leak) — injecting there would type into whatever tmux
   window is active. Live-verified 2026-07-10. *)
let test_tmux_preferred_over_herdr () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-both" in
    ignore
      (register ctx ~session_id:sid ~alias:sid ~tmux_location:"%5"
         ~herdr_pane:"w3:p2");
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-f" ~from_alias:"zw-wake-peer-f"
      ~content:"hi";
    (match inject ctx ~session_id:sid with
     | Injected { backend; _ } -> check string "tmux wins" "tmux" backend
     | o -> failf "expected Injected, got %s" (C2c_wake_inject.outcome_to_string o)))

(* --- backoff / dedupe ------------------------------------------------------ *)

let test_backoff_and_new_message_dedupe () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-backoff" in
    ignore (register ctx ~session_id:sid ~alias:sid ~tmux_location:"%9");
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-g" ~from_alias:"zw-wake-peer-g"
      ~content:"first";
    let t0 = Unix.gettimeofday () in
    (match inject ~now:t0 ctx ~session_id:sid with
     | Injected _ -> ()
     | o -> failf "expected first Injected, got %s" (C2c_wake_inject.outcome_to_string o));
    (* Same inbox, still within backoff: message hasn't grown → dedupe. *)
    check outcome "no re-inject without inbox growth"
      (Skipped "no_new_messages_since_last_inject")
      (inject ~now:(t0 +. 1.0) ctx ~session_id:sid);
    (* New message but inside the backoff window → backoff. *)
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-g" ~from_alias:"zw-wake-peer-g"
      ~content:"second";
    check outcome "backoff window holds" (Skipped "backoff")
      (inject ~now:(t0 +. 5.0) ctx ~session_id:sid);
    (* New message + backoff elapsed → inject again. *)
    (match inject ~now:(t0 +. 500.0) ctx ~session_id:sid with
     | Injected { message_count; _ } -> check int "two queued now" 2 message_count
     | o -> failf "expected re-inject, got %s" (C2c_wake_inject.outcome_to_string o));
    let lines = fixture_lines ctx in
    (* 2 tmux commands per successful inject, 2 injects. *)
    (* two injects x 5 tmux commands (text, show, set off, Enter, restore) *)
    check int "ten commands total" 10 (List.length lines))

let test_backoff_env_tunable () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-backoffenv" in
    ignore (register ctx ~session_id:sid ~alias:sid ~tmux_location:"%2");
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-h" ~from_alias:"zw-wake-peer-h"
      ~content:"a";
    let t0 = Unix.gettimeofday () in
    with_env [ ("C2C_WAKE_BACKOFF_S", Some "1") ] (fun () ->
      (match inject ~now:t0 ctx ~session_id:sid with
       | Injected _ -> ()
       | o -> failf "expected Injected, got %s" (C2c_wake_inject.outcome_to_string o));
      enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-h" ~from_alias:"zw-wake-peer-h"
        ~content:"b";
      match inject ~now:(t0 +. 2.0) ctx ~session_id:sid with
      | Injected _ -> ()
      | o -> failf "expected inject after short backoff, got %s"
               (C2c_wake_inject.outcome_to_string o)))

(* --- never drains ----------------------------------------------------------- *)

let test_never_drains_inbox () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-nodrain" in
    let b = register ctx ~session_id:sid ~alias:sid ~tmux_location:"%4" in
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-i" ~from_alias:"zw-wake-peer-i"
      ~content:"still here";
    (match inject ctx ~session_id:sid with
     | Injected _ -> ()
     | o -> failf "expected Injected, got %s" (C2c_wake_inject.outcome_to_string o));
    let after = C2c_mcp.Broker.read_inbox b ~session_id:sid in
    check int "inbox untouched after inject" 1 (List.length after);
    (match after with
     | [ m ] -> check string "body intact" "still here" m.content
     | _ -> fail "expected exactly one message"))

(* --- env target derivation --------------------------------------------------- *)

let test_wake_targets_from_env () =
  with_ctx (fun _ctx ->
    with_env
      [ ("TMUX", Some "/tmp/tmux-1000/default,1234,0")
      ; ("TMUX_PANE", Some "%5")
      ; ("HERDR_PANE_ID", Some "w1:p9")
      ; ("HERDR_SOCKET_PATH", Some "/run/herdr/api.sock")
      ]
      (fun () ->
        let tmux, pane, socket = C2c_wake_inject.wake_targets_from_env () in
        check (option string) "tmux raw pane id" (Some "%5") tmux;
        check (option string) "herdr pane" (Some "w1:p9") pane;
        check (option string) "herdr socket" (Some "/run/herdr/api.sock") socket);
    with_env
      [ ("TMUX", None); ("TMUX_PANE", Some "%5")
      ; ("HERDR_PANE_ID", None); ("HERDR_SOCKET_PATH", None)
      ]
      (fun () ->
        let tmux, pane, socket = C2c_wake_inject.wake_targets_from_env () in
        check (option string) "TMUX_PANE without TMUX not trusted" None tmux;
        check (option string) "no herdr pane" None pane;
        check (option string) "no herdr socket" None socket))

(* --- registry round-trip (persistence fix) ----------------------------------- *)

let test_wake_targets_roundtrip_registry () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-persist" in
    ignore
      (register ctx ~session_id:sid ~alias:sid ~tmux_location:"%8"
         ~herdr_pane:"w4:p4" ~herdr_socket:"/tmp/h.sock");
    (* Fresh broker handle = fresh read from disk. *)
    let b2 = C2c_mcp.Broker.create ~root:ctx.broker_root in
    match
      List.find_opt
        (fun (r : C2c_mcp.registration) -> r.session_id = sid)
        (C2c_mcp.Broker.list_registrations b2)
    with
    | None -> fail "registration missing"
    | Some r ->
        check (option string) "tmux_location persisted" (Some "%8") r.tmux_location;
        check (option string) "herdr_pane persisted" (Some "w4:p4") r.herdr_pane;
        check (option string) "herdr_socket persisted" (Some "/tmp/h.sock")
          r.herdr_socket)

let test_update_wake_targets () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-update" in
    let b = register ctx ~session_id:sid ~alias:sid ~tmux_location:"%1" in
    (* Some overwrites; None preserves. *)
    C2c_mcp.Broker.update_wake_targets b ~session_id:sid
      ~herdr_pane:(Some "w5:p5") ();
    C2c_mcp.Broker.update_wake_targets b ~session_id:sid
      ~tmux_location:(Some "%2") ();
    (* Unregistered session: no-op, no raise. *)
    C2c_mcp.Broker.update_wake_targets b ~session_id:"zw-wake-ghost"
      ~tmux_location:(Some "%9") ();
    match
      List.find_opt
        (fun (r : C2c_mcp.registration) -> r.session_id = sid)
        (C2c_mcp.Broker.list_registrations b)
    with
    | None -> fail "registration missing"
    | Some r ->
        check (option string) "tmux updated" (Some "%2") r.tmux_location;
        check (option string) "herdr pane preserved through tmux update"
          (Some "w5:p5") r.herdr_pane)

(* --- B120: managed-codex resume identity split ------------------------------
   On resume the managed startup registers the deliver sidecar keyed by the
   instance NAME, while the codex SessionStart hook auto-registers the resumed
   conversation's session UUID (a hook auto-registration) sharing the SAME tmux
   pane. The sidecar must FOLLOW the hook registration, else it watches an
   inbox nobody DMs. resolve_wake_watch_target performs that adoption. *)

let resolve ctx ~session_id =
  C2c_wake_inject.resolve_wake_watch_target ~broker_root:ctx.broker_root
    ~session_id

let test_resolve_follows_hook_on_resume () =
  with_ctx (fun ctx ->
    (* Managed instance registration (session_id = instance name). *)
    ignore (register ctx ~session_id:"zw-b120-mgd" ~alias:"zw-b120-mgd"
              ~tmux_location:"%42");
    (* Hook auto-registration for the resumed conversation UUID, same pane. *)
    ignore (register_hook ctx ~session_id:"zw-b120-codexuuid"
              ~alias:"zw-b120-codexuuid" ~tmux_location:"%42");
    check string "sidecar follows the hook-registered session"
      "zw-b120-codexuuid" (resolve ctx ~session_id:"zw-b120-mgd"))

let test_resolve_no_hook_returns_self () =
  with_ctx (fun ctx ->
    ignore (register ctx ~session_id:"zw-b120-solo" ~alias:"zw-b120-solo"
              ~tmux_location:"%43");
    check string "no hook row -> watch self unchanged (fresh start)"
      "zw-b120-solo" (resolve ctx ~session_id:"zw-b120-solo"))

let test_resolve_standalone_hook_authority_unchanged () =
  with_ctx (fun ctx ->
    (* The standalone `c2c deliver wake-watch --alias X` path resolves an alias
       straight to its own hook registration. Resolving that hook session_id
       must return it unchanged even if a managed row shares the pane. *)
    ignore (register_hook ctx ~session_id:"zw-b120-hook" ~alias:"zw-b120-hook"
              ~tmux_location:"%44");
    ignore (register ctx ~session_id:"zw-b120-mgd2" ~alias:"zw-b120-mgd2"
              ~tmux_location:"%44");
    check string "hook authority is not re-pointed"
      "zw-b120-hook" (resolve ctx ~session_id:"zw-b120-hook"))

let test_resolve_different_target_not_followed () =
  with_ctx (fun ctx ->
    (* A hook row on a DIFFERENT pane belongs to another session — never
       cross-wire. cwd is deliberately not a match key. *)
    ignore (register ctx ~session_id:"zw-b120-mgd3" ~alias:"zw-b120-mgd3"
              ~tmux_location:"%45");
    ignore (register_hook ctx ~session_id:"zw-b120-other"
              ~alias:"zw-b120-other" ~tmux_location:"%99");
    check string "unrelated hook row not adopted"
      "zw-b120-mgd3" (resolve ctx ~session_id:"zw-b120-mgd3"))

let test_resolve_no_wake_target_returns_self () =
  with_ctx (fun ctx ->
    (* Managed row without a tmux/herdr target cannot be matched to a hook row
       by pane — return self (nothing to inject into anyway). *)
    ignore (register ctx ~session_id:"zw-b120-notgt" ~alias:"zw-b120-notgt");
    ignore (register_hook ctx ~session_id:"zw-b120-hook2"
              ~alias:"zw-b120-hook2" ~tmux_location:"%46");
    check string "no wake target -> self"
      "zw-b120-notgt" (resolve ctx ~session_id:"zw-b120-notgt"))

let test_resolve_herdr_pane_shared () =
  with_ctx (fun ctx ->
    ignore (register ctx ~session_id:"zw-b120-hmgd" ~alias:"zw-b120-hmgd"
              ~herdr_pane:"w7:p7");
    ignore (register_hook ctx ~session_id:"zw-b120-huuid"
              ~alias:"zw-b120-huuid" ~herdr_pane:"w7:p7");
    check string "herdr_pane also reconciles"
      "zw-b120-huuid" (resolve ctx ~session_id:"zw-b120-hmgd"))

(* End-to-end reproduction: a DM addressed to the HOOK identity lands in its
   inbox, not the managed instance's. Injecting on the raw managed session_id
   sees nothing (the split); resolving first, then injecting, wakes correctly. *)
let test_resolve_then_inject_reproduces_and_fixes_split () =
  with_ctx (fun ctx ->
    ignore (register ctx ~session_id:"zw-b120-e2e-mgd" ~alias:"zw-b120-e2e-mgd"
              ~tmux_location:"%50");
    ignore (register_hook ctx ~session_id:"zw-b120-e2e-uuid"
              ~alias:"zw-b120-e2e-uuid" ~tmux_location:"%50");
    (* Peer DMs the hook identity — where resumed-session DMs actually go. *)
    enqueue ctx ~to_alias:"zw-b120-e2e-uuid" ~from_session:"zw-b120-e2e-peer"
      ~from_alias:"zw-b120-e2e-peer" ~content:"wake up";
    (* The bug: watching the instance name sees an empty inbox. *)
    check outcome "instance-name inbox is empty (the split)"
      (Skipped "inbox_empty") (inject ctx ~session_id:"zw-b120-e2e-mgd");
    (* The fix: resolve to the hook identity, then inject succeeds. *)
    let target = resolve ctx ~session_id:"zw-b120-e2e-mgd" in
    check string "resolved to hook identity" "zw-b120-e2e-uuid" target;
    match inject ctx ~session_id:target with
    | Injected { backend; message_count } ->
        check string "tmux backend" "tmux" backend;
        check int "the queued message is seen" 1 message_count
    | o ->
        failf "expected Injected after resolve, got %s"
          (C2c_wake_inject.outcome_to_string o))

let () =
  Random.self_init ();
  run "c2c_wake_inject"
    [ ( "wake-inject"
      , [ test_case "skips without registration" `Quick test_skips_without_registration
        ; test_case "skips on empty inbox" `Quick test_skips_on_empty_inbox
        ; test_case "skips without wake target" `Quick test_skips_without_wake_target
        ; test_case "tmux: literal send-keys then Enter" `Quick test_tmux_command_sequence
        ; test_case "tmux: idle gate blocks recent activity" `Quick
            test_tmux_idle_gate_blocks_recent_activity
        ; test_case "herdr: probe + pane run, socket env" `Quick
            test_herdr_command_shape_and_socket_env
        ; test_case "herdr: working pane never injected" `Quick
            test_herdr_working_blocks_inject
        ; test_case "herdr: done status injectable" `Quick
            test_herdr_done_status_injectable
        ; test_case "herdr: parse real agent-get JSON shape" `Quick
            test_parse_herdr_agent_status_real_shape
        ; test_case "tmux preferred over herdr (innermost wins)" `Quick test_tmux_preferred_over_herdr
        ; test_case "backoff + inbox-growth dedupe" `Quick
            test_backoff_and_new_message_dedupe
        ; test_case "backoff env-tunable" `Quick test_backoff_env_tunable
        ; test_case "never drains the inbox" `Quick test_never_drains_inbox
        ; test_case "wake targets from env" `Quick test_wake_targets_from_env
        ; test_case "wake targets round-trip registry" `Quick
            test_wake_targets_roundtrip_registry
        ; test_case "update_wake_targets semantics" `Quick test_update_wake_targets
        ; test_case "B120: sidecar follows hook registration on resume" `Quick
            test_resolve_follows_hook_on_resume
        ; test_case "B120: no hook row -> watch self (fresh start)" `Quick
            test_resolve_no_hook_returns_self
        ; test_case "B120: standalone hook authority unchanged" `Quick
            test_resolve_standalone_hook_authority_unchanged
        ; test_case "B120: unrelated pane not followed" `Quick
            test_resolve_different_target_not_followed
        ; test_case "B120: no wake target -> self" `Quick
            test_resolve_no_wake_target_returns_self
        ; test_case "B120: herdr_pane reconciles" `Quick
            test_resolve_herdr_pane_shared
        ; test_case "B120: resolve-then-inject reproduces + fixes split" `Quick
            test_resolve_then_inject_reproduces_and_fixes_split
        ] )
    ]
