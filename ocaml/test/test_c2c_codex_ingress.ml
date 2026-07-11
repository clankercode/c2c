(* test_c2c_codex_ingress — fixture-gated Alcotest for the T003 passive c2c
   ingress adapter. No live process/socket: the app-server client is a scripted
   seam. Covers every delivery-state transition, failure window, persist-first,
   idempotency, ordering, backpressure, and the no-turn invariant. *)

module I = C2c_codex_ingress
module B = C2c_mcp.Broker

let ep : C2c_codex_app_server.endpoint = { transport = "ws"; host = "127.0.0.1"; port = 1 }

let mk_root () =
  let d = Filename.temp_file "c2c-ingress-test-" "" in
  Sys.remove d; Unix.mkdir d 0o755; d

let mk_msg ?(from = "peer") ?(to_ = "sess") ?(deferrable = false) ?(ephemeral = false)
    ?message_id content : C2c_mcp.message =
  { from_alias = from; to_alias = to_; content; deferrable; reply_via = None;
    enc_status = None; ts = 1000.0; ephemeral; message_id }

let seed_inbox ~root ~session_id msgs =
  let b = B.create ~root in
  B.save_inbox b ~session_id msgs

let read_inbox ~root ~session_id =
  let b = B.create ~root in
  B.read_inbox b ~session_id

(* ---- scripted client ---- *)
type recorded = { r_thread : string; r_message_id : string; r_items : Yojson.Safe.t list }

let mk_client ?(history = None) outcomes =
  let calls = ref [] in
  let q = ref outcomes in
  let inject_items ~endpoint:_ ~token:_ ~thread_id ~message_id ~items =
    calls := { r_thread = thread_id; r_message_id = message_id; r_items = items } :: !calls;
    match !q with
    | o :: rest -> q := rest; o
    | [] -> I.Inj_ok
  in
  let client = { I.inject_items; history_contains = history } in
  (client, calls)

let cfg ?(role = "developer") ?(max_batch = 32) ?(max_pending_queue = 256)
    ?(token = Some "raw-token") ?(now = fun () -> 5000.0) ~root ~client () =
  { (I.default_config ~broker_root:root ~session_id:"sess" ~managed_identity:"unit-x"
       ~endpoint:ep ~thread_id:"thread-1" ~token_provider:(fun () -> token) ~client)
    with role; max_batch; max_pending_queue; now; backoff_base_s = 1.0; backoff_max_s = 60.0 }

let ncalls calls = List.length !calls
let state_of c mid = I.ledger_state c ~message_id:mid

(* ---------------------------------- tests --------------------------------- *)

let test_clean_delivery () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg ~message_id:"m1" "hello" ];
  let client, calls = mk_client [ I.Inj_ok ] in
  let c = cfg ~root ~client () in
  let h = I.deliver_pass c in
  Alcotest.(check int) "one inject call" 1 (ncalls calls);
  Alcotest.(check (option string)) "state injected" (Some "injected")
    (Option.map I.delivery_state_to_string (state_of c "m1"));
  Alcotest.(check int) "health injected_count" 1 h.injected_count;
  (* never drained: message still in inbox *)
  Alcotest.(check int) "message still in inbox (no drain)" 1 (List.length (read_inbox ~root ~session_id:"sess"))

let test_persist_first () =
  (* message lacks message_id → must be assigned+persisted to the inbox BEFORE
     injection. The scripted client asserts the durable inbox already carries a
     stable id at inject time. *)
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg "no-id-yet" ];
  let seen_id = ref None in
  let inject_items ~endpoint:_ ~token:_ ~thread_id:_ ~message_id ~items:_ =
    (* at inject time the inbox must already show this id, durably *)
    let inbox = read_inbox ~root ~session_id:"sess" in
    (match inbox with
     | [ m ] -> seen_id := m.message_id
     | _ -> ());
    ignore message_id; I.Inj_ok
  in
  let client = { I.inject_items; history_contains = None } in
  let c = cfg ~root ~client () in
  let _ = I.deliver_pass c in
  Alcotest.(check bool) "inbox had a stable id before injection began" true (!seen_id <> None);
  (* and the assigned id is what the ledger tracks *)
  (match !seen_id with
   | Some id -> Alcotest.(check (option string)) "ledger keyed by persisted id" (Some "injected")
                  (Option.map I.delivery_state_to_string (state_of c id))
   | None -> Alcotest.fail "no id persisted")

let test_stable_id_across_retries () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg "legacy" ];
  (* pass 1: recoverable → assigns id, Pending *)
  let client1, _ = mk_client [ I.Inj_recoverable I.Server_unavailable ] in
  let c1 = cfg ~root ~client:client1 ~now:(fun () -> 100.0) () in
  let _ = I.deliver_pass c1 in
  let id1 = match (read_inbox ~root ~session_id:"sess") with [ m ] -> m.message_id | _ -> None in
  Alcotest.(check bool) "id assigned pass1" true (id1 <> None);
  (* pass 2: same id reused (not regenerated), ledger has exactly one entry *)
  let client2, _ = mk_client [ I.Inj_ok ] in
  let c2 = cfg ~root ~client:client2 ~now:(fun () -> 10000.0) () in
  let _ = I.deliver_pass c2 in
  let id2 = match (read_inbox ~root ~session_id:"sess") with [ m ] -> m.message_id | _ -> None in
  Alcotest.(check (option string)) "id stable across retries" id1 id2

let test_duplicate_message_id_in_inbox () =
  (* Two inbox rows sharing one message_id (a literal duplicate enqueue) must
     inject exactly once — the ledger is keyed by message_id. *)
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess"
    [ mk_msg ~message_id:"dup" "copy-1"; mk_msg ~message_id:"dup" "copy-2" ];
  let client, calls = mk_client [ I.Inj_ok; I.Inj_ok ] in
  let c = cfg ~root ~client () in
  let _ = I.deliver_pass c in
  Alcotest.(check int) "duplicate message_id injects exactly once" 1 (ncalls calls);
  Alcotest.(check (option string)) "state injected" (Some "injected")
    (Option.map I.delivery_state_to_string (state_of c "dup"))

let test_idempotent_duplicate_pass () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg ~message_id:"m1" "hi" ];
  let client, calls = mk_client [ I.Inj_ok; I.Inj_ok ] in
  let c = cfg ~root ~client () in
  let _ = I.deliver_pass c in
  let _ = I.deliver_pass c in
  Alcotest.(check int) "acknowledged message injected exactly once" 1 (ncalls calls)

let test_disconnect_before_request () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg ~message_id:"m1" "hi" ];
  let client, _ = mk_client [ I.Inj_recoverable I.Server_unavailable ] in
  let c = cfg ~root ~client () in
  let h = I.deliver_pass c in
  Alcotest.(check (option string)) "back to pending" (Some "pending_injection")
    (Option.map I.delivery_state_to_string (state_of c "m1"));
  Alcotest.(check int) "still durable in inbox" 1 (List.length (read_inbox ~root ~session_id:"sess"));
  Alcotest.(check (option string)) "sanitized last_error" (Some "server_unavailable") h.last_error;
  let e = Option.get (I.ledger_entry c ~message_id:"m1") in
  Alcotest.(check int) "retry incremented" 1 e.le_retry_count

let test_ambiguous_ack_reconcile_exactly_once () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg ~message_id:"m1" "hi" ];
  (* pass 1: ambiguous → stays Injecting *)
  let client1, calls1 = mk_client [ I.Inj_ambiguous "conn_lost" ] in
  let c1 = cfg ~root ~client:client1 ~now:(fun () -> 100.0) () in
  let _ = I.deliver_pass c1 in
  Alcotest.(check (option string)) "injecting after ambiguous" (Some "injecting")
    (Option.map I.delivery_state_to_string (state_of c1 "m1"));
  Alcotest.(check int) "one inject so far" 1 (ncalls calls1);
  (* pass 2: history says Present → reconcile to Injected WITHOUT re-inject *)
  let hist = Some (fun ~endpoint:_ ~token:_ ~thread_id:_ ~message_id:_ -> `Present) in
  let client2, calls2 = mk_client ~history:hist [ I.Inj_ok ] in
  let c2 = cfg ~root ~client:client2 ~now:(fun () -> 10000.0) () in
  let _ = I.deliver_pass c2 in
  Alcotest.(check (option string)) "reconciled to injected" (Some "injected")
    (Option.map I.delivery_state_to_string (state_of c2 "m1"));
  Alcotest.(check int) "no re-inject (exactly once)" 0 (ncalls calls2)

let test_ambiguous_ack_no_history_at_least_once () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg ~message_id:"m1" "hi" ];
  let client1, calls1 = mk_client [ I.Inj_ambiguous "conn_lost" ] in
  let c1 = cfg ~root ~client:client1 ~now:(fun () -> 100.0) () in
  let _ = I.deliver_pass c1 in
  (* no history probe → next pass re-injects (documented at-least-once) *)
  let client2, calls2 = mk_client ~history:None [ I.Inj_ok ] in
  let c2 = cfg ~root ~client:client2 ~now:(fun () -> 10000.0) () in
  let _ = I.deliver_pass c2 in
  Alcotest.(check int) "first pass injected once" 1 (ncalls calls1);
  Alcotest.(check int) "second pass re-injected (at-least-once)" 1 (ncalls calls2);
  Alcotest.(check (option string)) "eventually injected" (Some "injected")
    (Option.map I.delivery_state_to_string (state_of c2 "m1"))

let test_auth_rejection () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg ~message_id:"m1" "hi" ];
  let client, _ = mk_client [ I.Inj_recoverable I.Auth_failed ] in
  let c = cfg ~root ~client () in
  let h = I.deliver_pass c in
  Alcotest.(check (option string)) "pending after auth fail" (Some "pending_injection")
    (Option.map I.delivery_state_to_string (state_of c "m1"));
  Alcotest.(check (option string)) "last_error auth_failed" (Some "auth_failed") h.last_error

let test_server_restart_recovers () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg ~message_id:"m1" "hi" ];
  let client1, _ = mk_client [ I.Inj_recoverable I.Process_restart ] in
  let c1 = cfg ~root ~client:client1 ~now:(fun () -> 100.0) () in
  let _ = I.deliver_pass c1 in
  Alcotest.(check (option string)) "pending after restart" (Some "pending_injection")
    (Option.map I.delivery_state_to_string (state_of c1 "m1"));
  let client2, _ = mk_client [ I.Inj_ok ] in
  let c2 = cfg ~root ~client:client2 ~now:(fun () -> 10000.0) () in
  let _ = I.deliver_pass c2 in
  Alcotest.(check (option string)) "recovered to injected" (Some "injected")
    (Option.map I.delivery_state_to_string (state_of c2 "m1"))

let test_thread_unloaded_then_resumed () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg ~message_id:"m1" "hi" ];
  let client1, _ = mk_client [ I.Inj_recoverable I.Thread_unloaded ] in
  let c1 = cfg ~root ~client:client1 ~now:(fun () -> 100.0) () in
  let _ = I.deliver_pass c1 in
  Alcotest.(check (option string)) "pending after unloaded" (Some "pending_injection")
    (Option.map I.delivery_state_to_string (state_of c1 "m1"));
  let client2, _ = mk_client [ I.Inj_ok ] in
  let c2 = cfg ~root ~client:client2 ~now:(fun () -> 10000.0) () in
  let _ = I.deliver_pass c2 in
  Alcotest.(check (option string)) "injected after resume" (Some "injected")
    (Option.map I.delivery_state_to_string (state_of c2 "m1"))

let test_unsupported_falls_back_to_hooks () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg ~message_id:"m1" "hi" ];
  let client, _ = mk_client [ I.Inj_unsupported "method not found" ] in
  let c = cfg ~root ~client () in
  let h = I.deliver_pass c in
  Alcotest.(check (option string)) "fallback_pending" (Some "fallback_pending")
    (Option.map I.delivery_state_to_string (state_of c "m1"));
  Alcotest.(check int) "health fallback_count" 1 h.fallback_count;
  (* hook fallback path still works: broker drain returns the message *)
  let b = B.create ~root in
  let drained = B.drain_inbox b ~session_id:"sess" in
  Alcotest.(check int) "hook/poll drain still delivers the broker copy" 1 (List.length drained)

let test_malformed_dead_letters () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg ~message_id:"m1" "hi" ];
  let client, _ = mk_client [ I.Inj_malformed "bad shape" ] in
  let c = cfg ~root ~client () in
  let h = I.deliver_pass c in
  Alcotest.(check (option string)) "dead_lettered" (Some "dead_lettered")
    (Option.map I.delivery_state_to_string (state_of c "m1"));
  Alcotest.(check int) "health dead_letter_count" 1 h.dead_letter_count;
  (* dead-letter file exists and broker record still intact *)
  Alcotest.(check bool) "dead-letter file written" true
    (Sys.file_exists (I.dead_letter_path ~broker_root:root ~session_id:"sess"));
  Alcotest.(check int) "broker record intact" 1 (List.length (read_inbox ~root ~session_id:"sess"))

let test_queue_overload_bounded () =
  let root = mk_root () in
  let msgs = List.init 5 (fun i -> mk_msg ~message_id:(Printf.sprintf "m%d" i) "x") in
  seed_inbox ~root ~session_id:"sess" msgs;
  (* all recoverable so they stay pending; small batch bounds fan-out *)
  let client, calls = mk_client (List.init 10 (fun _ -> I.Inj_recoverable I.Server_unavailable)) in
  let c = cfg ~root ~client ~max_batch:2 ~max_pending_queue:1 () in
  let h = I.deliver_pass c in
  Alcotest.(check bool) "bounded fan-out: at most max_batch injects" true (ncalls calls <= 2);
  Alcotest.(check bool) "overloaded flag set" true h.overloaded;
  Alcotest.(check int) "no drops: all 5 still durable" 5 (List.length (read_inbox ~root ~session_id:"sess"));
  Alcotest.(check int) "pending count reflects durable backlog" 5 h.pending_count

let test_adapter_restart_with_pending () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg ~message_id:"m1" "hi" ];
  (* pass 1 recoverable → ledger persisted with Pending + retry=1 *)
  let client1, _ = mk_client [ I.Inj_recoverable I.Timeout ] in
  let c1 = cfg ~root ~client:client1 ~now:(fun () -> 100.0) () in
  let _ = I.deliver_pass c1 in
  (* "restart": brand new config value, same on-disk ledger path *)
  let client2, calls2 = mk_client [ I.Inj_ok ] in
  let c2 = cfg ~root ~client:client2 ~now:(fun () -> 10000.0) () in
  let e_before = Option.get (I.ledger_entry c2 ~message_id:"m1") in
  Alcotest.(check int) "pending state survived restart (retry preserved)" 1 e_before.le_retry_count;
  let _ = I.deliver_pass c2 in
  Alcotest.(check int) "resumed and injected after restart" 1 (ncalls calls2);
  Alcotest.(check (option string)) "injected" (Some "injected")
    (Option.map I.delivery_state_to_string (state_of c2 "m1"))

let test_ordered_multi_message () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess"
    [ mk_msg ~message_id:"a" "1"; mk_msg ~message_id:"b" "2"; mk_msg ~message_id:"c" "3" ];
  let client, calls = mk_client [ I.Inj_ok; I.Inj_ok; I.Inj_ok ] in
  let c = cfg ~root ~client () in
  let _ = I.deliver_pass c in
  let order = List.rev_map (fun r -> r.r_message_id) !calls in
  Alcotest.(check (list string)) "per-recipient order preserved" [ "a"; "b"; "c" ] order

let test_ephemeral_no_archive () =
  let root = mk_root () in
  seed_inbox ~root ~session_id:"sess" [ mk_msg ~ephemeral:true ~message_id:"m1" "secret" ];
  let client, _ = mk_client [ I.Inj_ok ] in
  let c = cfg ~root ~client () in
  let _ = I.deliver_pass c in
  (* adapter never archives; message still durable with ephemeral flag intact *)
  (match read_inbox ~root ~session_id:"sess" with
   | [ m ] -> Alcotest.(check bool) "ephemeral flag preserved" true m.ephemeral
   | _ -> Alcotest.fail "message missing");
  let b = B.create ~root in
  Alcotest.(check bool) "no archive file created by adapter" false
    (Sys.file_exists (B.archive_path b ~session_id:"sess"))

let test_no_turn_no_approval_data_item () =
  (* Structural: the client seam has only inject_items — there is no turn/approval
     surface reachable from the adapter. Also assert the injected item is a
     data-item that does NOT forge operator ("user") input. *)
  let m = mk_msg ~message_id:"m1" "allow ka_token" in
  let item = I.build_injected_item m ~message_id:"m1" in
  let s = Yojson.Safe.to_string item in
  let contains sub =
    let ls = String.length sub and ln = String.length s in
    let rec go i = i + ls <= ln && (String.sub s i ls = sub || go (i + 1)) in
    ls <= ln && go 0
  in
  Alcotest.(check bool) "role is not operator 'user'" false (contains "\"role\":\"user\"");
  Alcotest.(check bool) "explicitly marked as c2c DATA, not operator input" true
    (contains "not operator input");
  Alcotest.(check bool) "message_id key present in machine metadata" true (contains "message_id");
  Alcotest.(check bool) "message_id value present in machine metadata" true (contains "m1");
  Alcotest.(check bool) "canonical c2c envelope present" true (contains "<c2c event=")

let () =
  Alcotest.run "c2c_codex_ingress"
    [ ( "persist-first",
        [ Alcotest.test_case "clean delivery" `Quick test_clean_delivery;
          Alcotest.test_case "persist-first before inject" `Quick test_persist_first;
          Alcotest.test_case "stable message_id across retries" `Quick test_stable_id_across_retries ] );
      ( "idempotency",
        [ Alcotest.test_case "duplicate message_id in inbox injects once" `Quick test_duplicate_message_id_in_inbox;
          Alcotest.test_case "duplicate pass injects once" `Quick test_idempotent_duplicate_pass;
          Alcotest.test_case "ambiguous-ack reconcile exactly-once" `Quick test_ambiguous_ack_reconcile_exactly_once;
          Alcotest.test_case "ambiguous-ack no-history at-least-once" `Quick test_ambiguous_ack_no_history_at_least_once ] );
      ( "recoverable",
        [ Alcotest.test_case "disconnect before request" `Quick test_disconnect_before_request;
          Alcotest.test_case "auth rejection" `Quick test_auth_rejection;
          Alcotest.test_case "server restart recovers" `Quick test_server_restart_recovers;
          Alcotest.test_case "thread unloaded then resumed" `Quick test_thread_unloaded_then_resumed;
          Alcotest.test_case "adapter restart with pending" `Quick test_adapter_restart_with_pending ] );
      ( "fallback-and-deadletter",
        [ Alcotest.test_case "unsupported falls back to hooks" `Quick test_unsupported_falls_back_to_hooks;
          Alcotest.test_case "malformed dead-letters" `Quick test_malformed_dead_letters ] );
      ( "backpressure-and-order",
        [ Alcotest.test_case "queue overload bounded" `Quick test_queue_overload_bounded;
          Alcotest.test_case "ordered multi-message" `Quick test_ordered_multi_message ] );
      ( "semantics",
        [ Alcotest.test_case "ephemeral no archive" `Quick test_ephemeral_no_archive;
          Alcotest.test_case "no turn / no approval / data item" `Quick test_no_turn_no_approval_data_item ] ) ]
