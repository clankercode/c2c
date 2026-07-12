(* test_c2c_codex_autoturn — fixture-gated Alcotest for the T007 safe auto-turn
   dispatcher. No live process/socket: the T003 inject client and the T007 turn
   client are scripted seams. Covers every kept state-table row (offline, DND-on,
   DND-clear, local vs remote provenance, idle->turn, active-turn batching,
   next-turn separation), the crash windows (write-ahead claim recovery,
   ambiguous-ack held-not-replayed), and idempotency across a simulated restart.

   Composer-state gating is INTENTIONALLY ABSENT (coordinator/Max clean-design
   decision + T004 proof that an app-server turn cannot touch the composer). *)

module A = C2c_codex_autoturn
module I = C2c_codex_ingress
module B = C2c_mcp.Broker

let ep : C2c_codex_app_server.endpoint = { transport = "ws"; host = "127.0.0.1"; port = 1 }

let mk_root () =
  let d = Filename.temp_file "c2c-autoturn-test-" "" in
  Sys.remove d; Unix.mkdir d 0o755; d

let mk_msg ?(from = "peer") ?(to_ = "sess") ~message_id content : C2c_mcp.message =
  { from_alias = from; to_alias = to_; content; deferrable = false; reply_via = None;
    enc_status = None; ts = 1000.0; ephemeral = false; message_id = Some message_id;
    pow_difficulty = None }

let seed_inbox ~root msgs = let b = B.create ~root in B.save_inbox b ~session_id:"sess" msgs

(* ---- scripted T003 inject client: always acks, records message ids ---- *)
let mk_inject_client () =
  let injected = ref [] in
  let inject_items ~endpoint:_ ~token:_ ~thread_id:_ ~message_id ~items:_ =
    injected := message_id :: !injected; I.Inj_ok
  in
  ({ I.inject_items; history_contains = None }, injected)

(* ---- scripted T007 turn client: settable thread status, outcome queue ---- *)
type turn_harness = {
  status : A.thread_status ref;
  outcomes : A.turn_start_outcome list ref;
  starts : (string * Yojson.Safe.t list) list ref;   (* (batch_key, items) *)
  client : A.turn_client;
}

let mk_turn_harness ?(history = None) () =
  let status = ref `Idle in
  let starts = ref [] in
  let outcomes = ref [] in
  let thread_status ~endpoint:_ ~token:_ ~thread_id:_ = !status in
  let start_turn ~endpoint:_ ~token:_ ~thread_id:_ ~batch_key ~items =
    starts := (batch_key, items) :: !starts;
    match !outcomes with
    | o :: rest -> outcomes := rest; o
    | [] -> A.Turn_started ("turn-" ^ string_of_int (List.length !starts))
  in
  let client = { A.thread_status; start_turn; turn_in_history = history } in
  { status; outcomes; starts; client }

let n_starts h = List.length !(h.starts)

let json_contains json needle =
  let hay = Yojson.Safe.to_string json in
  let ls = String.length needle and lh = String.length hay in
  let rec loop i =
    i + ls <= lh && (String.sub hay i ls = needle || loop (i + 1))
  in
  loop 0

(* ---- autoturn config with settable gates ---- *)
type cfg_handle = {
  active : bool ref;
  dnd : bool ref;
  cfg : A.config;
}

let mk_cfg ?(provenance = A.default_provenance) ?now ~root ~inject_client ~turn_client () =
  let active = ref true and dnd = ref false in
  let ing = I.default_config ~broker_root:root ~session_id:"sess" ~managed_identity:"unit-x"
      ~endpoint:ep ~thread_id:"thread-1" ~token_provider:(fun () -> Some "raw") ~client:inject_client in
  let base = A.default_config ~ingress_cfg:ing ~turn_client
      ~session_active:(fun () -> !active) ~is_dnd:(fun () -> !dnd) in
  let cfg = { base with provenance; now = Option.value now ~default:(fun () -> 5000.0) } in
  { active; dnd; cfg }

let qr o = Option.map A.queued_reason_to_string o.A.po_queued_reason

(* --------------------------------- tests ---------------------------------- *)

let test_offline () =
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~message_id:"m1" "hi" ];
  let ic, injected = mk_inject_client () in
  let th = mk_turn_harness () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  h.active := false;
  let o = A.deliver_pass h.cfg in
  Alcotest.(check (option string)) "offline queued" (Some "offline") (qr o);
  Alcotest.(check int) "no inject when offline" 0 (List.length !injected);
  Alcotest.(check int) "no turn when offline" 0 (n_starts th)

let test_dnd_on () =
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~message_id:"m1" "hi" ];
  let ic, injected = mk_inject_client () in
  let th = mk_turn_harness () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  h.dnd := true;
  let o = A.deliver_pass h.cfg in
  Alcotest.(check (option string)) "dnd queued" (Some "dnd") (qr o);
  Alcotest.(check int) "no inject under DND" 0 (List.length !injected);
  Alcotest.(check int) "no turn under DND" 0 (n_starts th)

let test_dnd_clear_reeval () =
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"peer" ~message_id:"m1" "hi" ];
  let ic, _ = mk_inject_client () in
  let th = mk_turn_harness () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  h.dnd := true;
  let o1 = A.deliver_pass h.cfg in
  Alcotest.(check (option string)) "pass1 dnd" (Some "dnd") (qr o1);
  Alcotest.(check int) "no turn while DND" 0 (n_starts th);
  (* clear DND → next pass reevaluates through the same dispatcher *)
  h.dnd := false;
  let o2 = A.deliver_pass h.cfg in
  Alcotest.(check (option string)) "pass2 turn started (no queued reason)" None (qr o2);
  Alcotest.(check bool) "turn id present" true (o2.A.po_turn_started <> None);
  Alcotest.(check int) "exactly one turn after DND clear" 1 (n_starts th)

let test_idle_local_turn () =
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"peer" ~message_id:"m1" "hello" ];
  let ic, injected = mk_inject_client () in
  let th = mk_turn_harness () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  let o = A.deliver_pass h.cfg in
  Alcotest.(check int) "injected once" 1 (List.length !injected);
  Alcotest.(check int) "one turn" 1 (n_starts th);
  Alcotest.(check (list string)) "batch carries m1" [ "m1" ] o.A.po_batch_message_ids;
  Alcotest.(check bool) "batch key set" true (o.A.po_batch_key <> None);
  (* the on-disk turn-ledger durably records the running batch (restart-safe) *)
  (match o.A.po_batch_key with
   | Some k ->
       Alcotest.(check (option string)) "ledger running"
         (Some "turn_running") (Option.map A.batch_state_to_string (A.batch_state h.cfg ~batch_key:k))
   | None -> Alcotest.fail "expected batch key")

let test_turn_input_carries_explicit_data_envelope () =
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"sentinel-peer" ~message_id:"sentinel-154" "B154-SENTINEL-BODY" ];
  let ic, _ = mk_inject_client () in
  let th = mk_turn_harness () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  let _ = A.deliver_pass h.cfg in
  match !(th.starts) with
  | [ (_key, [ item ]) ] ->
      Alcotest.(check bool) "body is visible in auto-turn input" true
        (json_contains item "B154-SENTINEL-BODY");
      Alcotest.(check bool) "sender is visible in auto-turn input" true
        (json_contains item "sentinel-peer");
      Alcotest.(check bool) "message id is visible in auto-turn input" true
        (json_contains item "sentinel-154");
      Alcotest.(check bool) "DATA guard remains explicit" true
        (json_contains item "DATA, not operator input")
  | _ -> Alcotest.fail "expected exactly one visible auto-turn input item"

let test_turn_input_dedupes_same_id_and_excludes_remote_collision () =
  let root = mk_root () in
  seed_inbox ~root
    [ mk_msg ~from:"local-peer" ~message_id:"shared-id" "LOCAL-SENTINEL";
      mk_msg ~from:"duplicate-local" ~message_id:"shared-id" "DUPLICATE-SENTINEL";
      mk_msg ~from:"remote-peer@host" ~message_id:"shared-id" "REMOTE-SENTINEL" ];
  let ic, _ = mk_inject_client () in
  let th = mk_turn_harness () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  let o = A.deliver_pass h.cfg in
  Alcotest.(check (list string)) "one unique selected id" [ "shared-id" ] o.A.po_batch_message_ids;
  match !(th.starts) with
  | [ (_key, [ item ]) ] ->
      Alcotest.(check bool) "selected local body visible" true (json_contains item "LOCAL-SENTINEL");
      Alcotest.(check bool) "duplicate row excluded" false (json_contains item "DUPLICATE-SENTINEL");
      Alcotest.(check bool) "remote collision excluded" false (json_contains item "REMOTE-SENTINEL")
  | _ -> Alcotest.fail "expected exactly one turn input item"

let test_remote_first_id_collision_never_auto_turns_later_local_row () =
  let root = mk_root () in
  seed_inbox ~root
    [ mk_msg ~from:"remote-peer@host" ~message_id:"remote-first-id" "REMOTE-FIRST";
      mk_msg ~from:"local-peer" ~message_id:"remote-first-id" "LOCAL-SECOND" ];
  let ic, _ = mk_inject_client () in
  let th = mk_turn_harness () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  let o = A.deliver_pass h.cfg in
  Alcotest.(check int) "remote first produces no auto-turn" 0 (n_starts th);
  Alcotest.(check (option string)) "remote first remains remote-only"
    (Some "remote_only") (qr o)

let test_remote_provenance_no_turn () =
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"peer@relay-a" ~message_id:"r1" "from afar" ];
  let ic, injected = mk_inject_client () in
  let th = mk_turn_harness () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  let o = A.deliver_pass h.cfg in
  (* still injected as DATA (T003), but never turned *)
  Alcotest.(check int) "remote message injected as data" 1 (List.length !injected);
  Alcotest.(check int) "no turn for remote provenance" 0 (n_starts th);
  Alcotest.(check (option string)) "remote_only queued" (Some "remote_only") (qr o);
  Alcotest.(check int) "remote_pending counted" 1 o.A.po_remote_pending

let test_canonical_form_fails_closed () =
  (* a canonical cross-host / room-form sender (carrying a `#` routing marker)
     must FAIL CLOSED → treated as remote → injected as DATA, never turned. *)
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"peer#somerepo" ~message_id:"c1" "canonical form" ];
  let ic, injected = mk_inject_client () in
  let th = mk_turn_harness () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  let o = A.deliver_pass h.cfg in
  Alcotest.(check int) "canonical-form message injected as data" 1 (List.length !injected);
  Alcotest.(check int) "no turn for canonical/#-form sender" 0 (n_starts th);
  Alcotest.(check (option string)) "canonical form queued (fail-closed)"
    (Some "remote_only") (qr o)

let test_unknown_status_fails_closed () =
  (* a status read that returns `Unknown (transient connection/read failure)
     must NOT fire a turn — firing could start one concurrent with an in-flight
     turn on the server. Fail closed + retry once status is confirmable. *)
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"peer" ~message_id:"m1" "hi" ];
  let ic, _ = mk_inject_client () in
  let th = mk_turn_harness () in
  th.status := `Unknown;
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  let o1 = A.deliver_pass h.cfg in
  Alcotest.(check (option string)) "unknown status queued (fail-closed)"
    (Some "status_unknown") (qr o1);
  Alcotest.(check int) "NO turn fired on unknown status" 0 (n_starts th);
  (* status becomes confirmable idle → fires exactly one turn now *)
  th.status := `Idle;
  let o2 = A.deliver_pass h.cfg in
  Alcotest.(check bool) "turn fired once status idle" true (o2.A.po_turn_started <> None);
  Alcotest.(check int) "exactly one turn after idle confirmed" 1 (n_starts th)

let test_active_turn_batching_next_turn () =
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"peer" ~message_id:"m1" "first" ];
  let ic, _ = mk_inject_client () in
  let th = mk_turn_harness () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  (* pass 1: idle → fire turn for m1 *)
  let o1 = A.deliver_pass h.cfg in
  Alcotest.(check int) "turn1 fired" 1 (n_starts th);
  let batch1 = o1.A.po_batch_key in
  (* turn is now running: a new message arrives mid-turn *)
  th.status := `Active;
  seed_inbox ~root [ mk_msg ~from:"peer" ~message_id:"m1" "first";
                     mk_msg ~from:"peer" ~message_id:"m2" "second" ];
  let o2 = A.deliver_pass h.cfg in
  Alcotest.(check (option string)) "mid-turn arrival queued behind active turn"
    (Some "active_turn") (qr o2);
  Alcotest.(check int) "NO second turn while active" 1 (n_starts th);
  (* the active turn completes → next pass starts ONE batched follow-up for m2 *)
  th.status := `Idle;
  let o3 = A.deliver_pass h.cfg in
  Alcotest.(check int) "exactly one follow-up turn" 2 (n_starts th);
  Alcotest.(check (option string)) "batch1 completed" batch1 o3.A.po_completed_batch;
  Alcotest.(check (list string)) "follow-up batch carries only m2" [ "m2" ] o3.A.po_batch_message_ids;
  Alcotest.(check bool) "follow-up batch differs from batch1" true
    (o3.A.po_batch_key <> batch1)

let test_ambiguous_ack_held_not_replayed () =
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"peer" ~message_id:"m1" "hi" ];
  let ic, _ = mk_inject_client () in
  let th = mk_turn_harness ~history:None () in
  th.outcomes := [ A.Turn_ambiguous "connection_closed_before_response" ];
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  let o1 = A.deliver_pass h.cfg in
  Alcotest.(check (option string)) "ambiguous held" (Some "ambiguous_held") (qr o1);
  Alcotest.(check int) "one turn attempt" 1 (n_starts th);
  (match o1.A.po_batch_key with
   | Some k -> Alcotest.(check (option string)) "ledger held" (Some "turn_ambiguous_held")
       (Option.map A.batch_state_to_string (A.batch_state h.cfg ~batch_key:k))
   | None -> Alcotest.fail "batch key expected");
  (* subsequent passes must NOT replay the turn (no history probe → stay held) *)
  let o2 = A.deliver_pass h.cfg in
  Alcotest.(check (option string)) "still held" (Some "ambiguous_held") (qr o2);
  Alcotest.(check int) "turn NEVER replayed" 1 (n_starts th)

let test_ambiguous_reconcile_present () =
  (* an ambiguous batch whose turn IS provably in history reconciles to running
     (still serialized), and is never replayed. *)
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"peer" ~message_id:"m1" "hi" ];
  let ic, _ = mk_inject_client () in
  let probe ~endpoint:_ ~token:_ ~thread_id:_ ~batch_key:_ = `Present in
  let th = mk_turn_harness ~history:(Some probe) () in
  th.outcomes := [ A.Turn_ambiguous "lost" ];
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  let _ = A.deliver_pass h.cfg in
  Alcotest.(check int) "one turn attempt" 1 (n_starts th);
  let o2 = A.deliver_pass h.cfg in
  (* reconciled → treated as running (blocked), not replayed *)
  Alcotest.(check int) "not replayed after reconcile-present" 1 (n_starts th);
  Alcotest.(check (option string)) "active after reconcile" (Some "active_turn") (qr o2)

let test_claim_recovery_absent_refires_once () =
  (* crash between write-ahead claim and turn/start ack: recover a Batch_claimed
     ledger. With a probe that proves the turn did NOT start, the batch releases
     and fires exactly once. *)
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"peer" ~message_id:"m1" "hi" ];
  let ic, _ = mk_inject_client () in
  (* first make m1 model-visible (inject) via a throwaway pass that we then
     overwrite the turn-ledger for, simulating a crash right after claim. *)
  let probe_absent ~endpoint:_ ~token:_ ~thread_id:_ ~batch_key:_ = `Absent in
  let th = mk_turn_harness ~history:(Some probe_absent) () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  (* run a pass to inject + fire; then hand-craft a Batch_claimed crash state *)
  let o1 = A.deliver_pass h.cfg in
  let key = Option.get o1.A.po_batch_key in
  let ledger_path = A.turn_ledger_path ~broker_root:root ~session_id:"sess" in
  let crashed =
    `Assoc [ ("managed_identity", `String "unit-x"); ("thread_id", `String "thread-1");
             ("active_batch_key", `String key);
             ("last_error", `Null);
             ("batches", `List [ `Assoc [ ("key", `String key);
                 ("state", `Assoc [ ("kind", `String "batch_claimed") ]);
                 ("message_ids", `List [ `String "m1" ]);
                 ("first_seen", `Float 5000.); ("last_attempt", `Float 5000.);
                 ("retry_count", `Int 0); ("last_error", `Null) ] ]) ]
  in
  let oc = open_out ledger_path in output_string oc (Yojson.Safe.to_string crashed); close_out oc;
  let before = n_starts th in
  let _ = A.deliver_pass h.cfg in
  (* Absent proof → batch released, m1 re-batched and fired exactly once more *)
  Alcotest.(check int) "claim-recovery fires exactly once" (before + 1) (n_starts th)

let test_claim_recovery_no_probe_holds () =
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"peer" ~message_id:"m1" "hi" ];
  let ic, _ = mk_inject_client () in
  let th = mk_turn_harness ~history:None () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  let o1 = A.deliver_pass h.cfg in
  let key = Option.get o1.A.po_batch_key in
  let ledger_path = A.turn_ledger_path ~broker_root:root ~session_id:"sess" in
  let crashed =
    `Assoc [ ("managed_identity", `String "unit-x"); ("thread_id", `String "thread-1");
             ("active_batch_key", `String key); ("last_error", `Null);
             ("batches", `List [ `Assoc [ ("key", `String key);
                 ("state", `Assoc [ ("kind", `String "batch_claimed") ]);
                 ("message_ids", `List [ `String "m1" ]);
                 ("first_seen", `Float 5000.); ("last_attempt", `Float 5000.);
                 ("retry_count", `Int 0); ("last_error", `Null) ] ]) ]
  in
  let oc = open_out ledger_path in output_string oc (Yojson.Safe.to_string crashed); close_out oc;
  let before = n_starts th in
  let _ = A.deliver_pass h.cfg in
  (* no probe → cannot prove non-start → HELD, never blindly replayed *)
  Alcotest.(check int) "claim-recovery without probe never replays" before (n_starts th)

let test_idempotent_restart () =
  (* after a turn fires, a fresh config over the SAME broker root (simulated
     restart) must not refire for the already-claimed message. *)
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"peer" ~message_id:"m1" "hi" ];
  let ic, _ = mk_inject_client () in
  let th = mk_turn_harness () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  let _ = A.deliver_pass h.cfg in
  Alcotest.(check int) "first fire" 1 (n_starts th);
  (* simulate restart: brand-new inject client + config, same root & turn client.
     The turn is still running (Active). *)
  th.status := `Active;
  let ic2, _ = mk_inject_client () in
  let h2 = mk_cfg ~root ~inject_client:ic2 ~turn_client:th.client () in
  let o = A.deliver_pass h2.cfg in
  Alcotest.(check (option string)) "restart sees active turn" (Some "active_turn") (qr o);
  Alcotest.(check int) "no refire on restart" 1 (n_starts th)

let test_metrics_no_bodies () =
  let root = mk_root () in
  seed_inbox ~root [ mk_msg ~from:"peer" ~message_id:"m1" "SECRET-BODY-XYZ" ];
  let ic, _ = mk_inject_client () in
  let th = mk_turn_harness () in
  let h = mk_cfg ~root ~inject_client:ic ~turn_client:th.client () in
  let o = A.deliver_pass h.cfg in
  let s = Yojson.Safe.to_string (A.pass_outcome_to_json o) in
  let contains hay sub =
    let ls = String.length sub and ln = String.length hay in
    let rec go i = i + ls <= ln && (String.sub hay i ls = sub || go (i + 1)) in
    ls <= ln && go 0
  in
  Alcotest.(check bool) "metrics never leak the body" false (contains s "SECRET-BODY-XYZ");
  Alcotest.(check bool) "recipient is redacted (no raw managed id)" false (contains s "unit-x");
  Alcotest.(check bool) "recipient present" true (contains s "rcpt-")

let () =
  Alcotest.run "c2c_codex_autoturn"
    [ ( "state table",
        [ Alcotest.test_case "offline: no inject/turn" `Quick test_offline;
          Alcotest.test_case "DND on: no inject/turn" `Quick test_dnd_on;
          Alcotest.test_case "DND clear: reevaluate + turn" `Quick test_dnd_clear_reeval;
          Alcotest.test_case "idle local: inject + one turn" `Quick test_idle_local_turn;
          Alcotest.test_case "auto-turn input carries explicit DATA envelope" `Quick
            test_turn_input_carries_explicit_data_envelope;
          Alcotest.test_case "auto-turn input dedupes IDs and excludes remote collision" `Quick
            test_turn_input_dedupes_same_id_and_excludes_remote_collision;
          Alcotest.test_case "remote-first ID collision never auto-turns later local row" `Quick
            test_remote_first_id_collision_never_auto_turns_later_local_row;
          Alcotest.test_case "remote provenance: inject, no turn" `Quick test_remote_provenance_no_turn;
          Alcotest.test_case "canonical/#-form sender fails closed (no turn)" `Quick
            test_canonical_form_fails_closed;
          Alcotest.test_case "unknown thread status fails closed (no concurrent turn)" `Quick
            test_unknown_status_fails_closed;
          Alcotest.test_case "active-turn batching + next-turn separation" `Quick
            test_active_turn_batching_next_turn ] );
      ( "crash windows",
        [ Alcotest.test_case "ambiguous ack: held, not replayed" `Quick
            test_ambiguous_ack_held_not_replayed;
          Alcotest.test_case "ambiguous reconcile present: not replayed" `Quick
            test_ambiguous_reconcile_present;
          Alcotest.test_case "claim recovery (absent proof): fires once" `Quick
            test_claim_recovery_absent_refires_once;
          Alcotest.test_case "claim recovery (no probe): holds" `Quick
            test_claim_recovery_no_probe_holds;
          Alcotest.test_case "idempotent across restart" `Quick test_idempotent_restart ] );
      ( "hygiene",
        [ Alcotest.test_case "metrics leak no bodies/creds" `Quick test_metrics_no_bodies ] ) ]
