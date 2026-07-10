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
   - backend preference (herdr over tmux)
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

let register ?tmux_location ?herdr_pane ?herdr_socket ctx ~session_id ~alias =
  let b = broker ctx in
  C2c_mcp.Broker.register b ~session_id ~alias ~pid:(Some (Unix.getpid ()))
    ~pid_start_time:(C2c_mcp.Broker.capture_pid_start_time (Some (Unix.getpid ())))
    ~client_type:(Some "codex")
    ?tmux_location:(Option.map Option.some tmux_location)
    ?herdr_pane:(Option.map Option.some herdr_pane)
    ?herdr_socket:(Option.map Option.some herdr_socket)
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
    check int "exactly two commands" 2 (List.length lines);
    let nudge = "c2c: 2 message(s) waiting - poll your inbox" in
    check (list string) "literal send-keys first"
      [ "tmux"; "send-keys"; "-l"; "-t"; "%7"; nudge ]
      (argv_of (List.nth lines 0));
    check (list string) "then Enter"
      [ "tmux"; "send-keys"; "-t"; "%7"; "Enter" ]
      (argv_of (List.nth lines 1)))

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

let test_herdr_preferred_over_tmux () =
  with_ctx (fun ctx ->
    let sid = "zw-wake-both" in
    ignore
      (register ctx ~session_id:sid ~alias:sid ~tmux_location:"%5"
         ~herdr_pane:"w3:p2");
    enqueue ctx ~to_alias:sid ~from_session:"zw-wake-peer-f" ~from_alias:"zw-wake-peer-f"
      ~content:"hi";
    (match inject ctx ~session_id:sid with
     | Injected { backend; _ } -> check string "herdr wins" "herdr" backend
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
    check int "four commands total" 4 (List.length lines))

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
        ; test_case "herdr preferred over tmux" `Quick test_herdr_preferred_over_tmux
        ; test_case "backoff + inbox-growth dedupe" `Quick
            test_backoff_and_new_message_dedupe
        ; test_case "backoff env-tunable" `Quick test_backoff_env_tunable
        ; test_case "never drains the inbox" `Quick test_never_drains_inbox
        ; test_case "wake targets from env" `Quick test_wake_targets_from_env
        ; test_case "wake targets round-trip registry" `Quick
            test_wake_targets_roundtrip_registry
        ; test_case "update_wake_targets semantics" `Quick test_update_wake_targets
        ] )
    ]
