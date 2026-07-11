(* c2c_codex_autoturn — safe auto-turn dispatcher for eligible local c2c mail on
   an app-server-managed Codex session (P1.M1.E1.T007).

   See c2c_codex_autoturn.mli for the full contract. This module sits ON TOP of
   the T003 passive-ingress adapter ({!C2c_codex_ingress}): a pass first makes
   eligible mail model-visible via T003 `thread/inject_items` (persist-first,
   idempotent), THEN — for LOCAL-broker-provenance mail only, DND off, session
   active, and no turn already in flight — starts at most ONE batched Codex
   `turn/start` so the agent acts/responds.

   Invariants (each has a fixture test):
   - PERSIST-FIRST. The broker inbox is authoritative; the T003 injection step
     persists stable message_ids before any turn. A crash between persist / claim
     / turn-request / ack never loses a message and never double-fires a turn once
     acknowledgement or reconciliation proves acceptance.
   - LOCAL PROVENANCE ONLY triggers a turn. Relay/remote mail (from_alias carries
     an `@host` marker) is still injected as DATA by T003 but NEVER batched into a
     turn — it stays durable+queued until a future trust policy changes it.
   - SERIALIZED. The app-server does NOT self-serialize turns (T004 Finding B: a
     concurrent turn/start is accepted as a distinct turn). This module owns the
     queue-if-active gate: at most one non-terminal batch at a time, tracked via
     `thread/status` (idle<->active). Mid-turn arrivals accumulate and start ONE
     batched follow-up turn after the active turn completes. Never turn/steer,
     never turn/interrupt.
   - DND HONORED. DND active -> no inject, no turn, message left durably queued.
     DND clear/expiry -> reevaluated on the next pass through the same serialized
     dispatcher.
   - APPROVAL ISOLATION (B098). The turn only makes injected DATA model-visible;
     it never writes an approval verdict. A message literally containing
     `allow`/`deny` cannot satisfy `await-reply` or invoke `authorize`. The
     turn nudge is a neutral, content-free DATA item.
   - IDEMPOTENT / AMBIGUITY-SAFE. A durable turn-ledger keyed by
     (thread_id, ordered message_ids) makes the acknowledged path fire once. The
     ambiguous-ack window (request written, response lost) is HELD (observable
     `turn_ambiguous`) and NEVER blindly replayed — replaying a turn would make
     the agent act twice. Reconcile against thread history when the protocol
     permits; otherwise stay held.

   Ownership: T006 owns public grammar/aliases; T005 owns doctor/status wiring;
   T003 owns injection + the inject ledger. This module embeds no CLI policy. *)

module Ep = C2c_codex_app_server
module Ingress = C2c_codex_ingress

(* ------------------------------ provenance -------------------------------- *)

type provenance = [ `Local | `Remote ]

let provenance_to_string = function `Local -> "local" | `Remote -> "remote"

(* Local-vs-remote provenance on the SENDER, fail-closed. Relay-forwarded mail
   always carries a routing-marked [from_alias]: [name@host] (see
   {!Relay_forwarder.build_body}), which is exactly the marker the broker itself
   uses to classify a remote alias ({!C2c_broker}.is_remote_alias =
   [String.exists ((=) '@')]). Canonical cross-host/room forms additionally carry
   a [#] routing marker. A local-broker DM carries a bare alias with NEITHER
   marker. We therefore treat a sender as LOCAL only when it carries no routing
   marker at all, and fail closed (→ Remote → durable+queued, never auto-turned)
   on anything ambiguous. This is deliberately stricter than a bare `@` test so a
   relay/canonical-form sender can never slip through into an auto-turn. *)
let default_provenance (m : C2c_mcp.message) : provenance =
  if String.contains m.from_alias '@' || String.contains m.from_alias '#'
  then `Remote else `Local

(* ------------------------------ turn client ------------------------------- *)

type thread_status = [ `Idle | `Active | `Unknown ]

let thread_status_to_string = function
  | `Idle -> "idle" | `Active -> "active" | `Unknown -> "unknown"

type turn_start_outcome =
  | Turn_started of string
  | Turn_ambiguous of string
  | Turn_recoverable of Ingress.recoverable
  | Turn_unsupported of string
  | Turn_rejected of string

let turn_start_outcome_to_string = function
  | Turn_started id -> "started:" ^ id
  | Turn_ambiguous _ -> "ambiguous"
  | Turn_recoverable r -> "recoverable:" ^ Ingress.recoverable_to_string r
  | Turn_unsupported _ -> "unsupported"
  | Turn_rejected _ -> "rejected"

type history_probe = [ `Present | `Absent | `Unknown ]

type turn_client = {
  thread_status :
    endpoint:Ep.endpoint -> token:string -> thread_id:string -> thread_status;
  start_turn :
    endpoint:Ep.endpoint ->
    token:string ->
    thread_id:string ->
    batch_key:string ->
    items:Yojson.Safe.t list ->
    turn_start_outcome;
  turn_in_history :
    (endpoint:Ep.endpoint ->
     token:string ->
     thread_id:string ->
     batch_key:string ->
     history_probe)
    option;
      (** [None] => no way to prove a held ambiguous turn actually started =>
          the batch stays held (never blindly replayed). *)
}

(* ------------------------------ batch state ------------------------------- *)

type batch_state =
  | Batch_claimed        (** write-ahead: turn/start about to be issued *)
  | Turn_running of string  (** turn id from turn/start response; turn in flight *)
  | Turn_ambiguous_held of string  (** request written, ack lost — held, not replayed *)
  | Turn_done            (** thread returned to idle after this turn *)
  | Turn_failed          (** unsupported/rejected — messages stay durable+queued *)

let batch_state_to_string = function
  | Batch_claimed -> "batch_claimed"
  | Turn_running _ -> "turn_running"
  | Turn_ambiguous_held _ -> "turn_ambiguous_held"
  | Turn_done -> "turn_done"
  | Turn_failed -> "turn_failed"

(* A non-terminal batch holds the serialization gate. Turn_failed is terminal for
   its own messages (they were claimed then failed) but does NOT block the next
   batch; only claimed/running/ambiguous batches block. *)
let batch_blocks_serialization = function
  | Batch_claimed | Turn_running _ | Turn_ambiguous_held _ -> true
  | Turn_done | Turn_failed -> false

type batch = {
  b_key : string;
  b_state : batch_state;
  b_message_ids : string list;   (** ordered by broker seq/time *)
  b_first_seen : float;
  b_last_attempt : float;
  b_retry_count : int;
  b_last_error : string option;  (** sanitized reason only — no content/creds *)
}

(* --------------------------------- config --------------------------------- *)

type config = {
  ingress_cfg : Ingress.config;
      (** reused for broker_root, session_id, managed_identity, endpoint,
          thread_id, token_provider, and the T003 inject client. *)
  turn_client : turn_client;
  session_active : unit -> bool;   (** false => offline: leave queued, no inject/turn *)
  is_dnd : unit -> bool;           (** true => leave queued, no inject/turn *)
  provenance : C2c_mcp.message -> provenance;
  now : unit -> float;
  max_turn_batch : int;            (** cap message_ids coalesced into one turn *)
  backoff_base_s : float;
  backoff_max_s : float;
}

let default_config ~ingress_cfg ~turn_client ~session_active ~is_dnd =
  { ingress_cfg; turn_client; session_active; is_dnd;
    provenance = default_provenance; now = Unix.gettimeofday;
    max_turn_batch = 64; backoff_base_s = 1.0; backoff_max_s = 60.0 }

(* --------------------------------- ledger --------------------------------- *)

let ingress_dir ~broker_root = Filename.concat broker_root "codex-appserver-ingress"

let turn_ledger_path ~broker_root ~session_id =
  Filename.concat (ingress_dir ~broker_root) (session_id ^ ".turns.json")

type ledger = {
  tl_managed_identity : string;
  tl_thread_id : string;
  mutable tl_active_batch_key : string option;
  mutable tl_batches : (string, batch) Hashtbl.t;
  mutable tl_last_error : string option;
}

let batch_state_to_json = function
  | Batch_claimed -> `Assoc [ ("kind", `String "batch_claimed") ]
  | Turn_running id -> `Assoc [ ("kind", `String "turn_running"); ("turn_id", `String id) ]
  | Turn_ambiguous_held why ->
      `Assoc [ ("kind", `String "turn_ambiguous_held"); ("detail", `String why) ]
  | Turn_done -> `Assoc [ ("kind", `String "turn_done") ]
  | Turn_failed -> `Assoc [ ("kind", `String "turn_failed") ]

let batch_state_of_json j =
  let open Json_util in
  match string_member "kind" j with
  | Some "batch_claimed" -> Some Batch_claimed
  | Some "turn_running" ->
      Some (Turn_running (Option.value (string_member "turn_id" j) ~default:""))
  | Some "turn_ambiguous_held" ->
      Some (Turn_ambiguous_held (Option.value (string_member "detail" j) ~default:""))
  | Some "turn_done" -> Some Turn_done
  | Some "turn_failed" -> Some Turn_failed
  | _ -> None

let batch_to_json b =
  `Assoc
    [ ("key", `String b.b_key);
      ("state", batch_state_to_json b.b_state);
      ("message_ids", `List (List.map (fun s -> `String s) b.b_message_ids));
      ("first_seen", `Float b.b_first_seen);
      ("last_attempt", `Float b.b_last_attempt);
      ("retry_count", `Int b.b_retry_count);
      ( "last_error",
        match b.b_last_error with Some s -> `String s | None -> `Null ) ]

let batch_of_json j =
  let open Json_util in
  match string_member "key" j with
  | None -> None
  | Some key ->
      let st =
        match j with
        | `Assoc l -> (
            match List.assoc_opt "state" l with
            | Some sj -> Option.value (batch_state_of_json sj) ~default:Turn_failed
            | None -> Turn_failed)
        | _ -> Turn_failed
      in
      let mids =
        match j with
        | `Assoc l -> (
            match List.assoc_opt "message_ids" l with
            | Some (`List xs) ->
                List.filter_map (function `String s -> Some s | _ -> None) xs
            | _ -> [])
        | _ -> []
      in
      let fl name d =
        match j with
        | `Assoc l -> (
            match List.assoc_opt name l with
            | Some (`Float f) -> f
            | Some (`Int i) -> float_of_int i
            | _ -> d)
        | _ -> d
      in
      Some
        { b_key = key; b_state = st; b_message_ids = mids;
          b_first_seen = fl "first_seen" 0.0; b_last_attempt = fl "last_attempt" 0.0;
          b_retry_count = Option.value (int_member "retry_count" j) ~default:0;
          b_last_error = string_member "last_error" j }

let load_ledger (cfg : config) : ledger =
  let broker_root = cfg.ingress_cfg.broker_root in
  let session_id = cfg.ingress_cfg.session_id in
  let path = turn_ledger_path ~broker_root ~session_id in
  let tbl = Hashtbl.create 32 in
  let lg =
    { tl_managed_identity = cfg.ingress_cfg.managed_identity;
      tl_thread_id = cfg.ingress_cfg.thread_id;
      tl_active_batch_key = None; tl_batches = tbl; tl_last_error = None }
  in
  (match Json_util.from_file_opt path with
   | Some (`Assoc top) ->
       (match List.assoc_opt "batches" top with
        | Some (`List bs) ->
            List.iter
              (fun j -> match batch_of_json j with Some b -> Hashtbl.replace tbl b.b_key b | None -> ())
              bs
        | _ -> ());
       lg.tl_active_batch_key <- Json_util.string_member "active_batch_key" (`Assoc top);
       lg.tl_last_error <- Json_util.string_member "last_error" (`Assoc top)
   | _ -> ());
  lg

let save_ledger (cfg : config) (lg : ledger) : unit =
  let broker_root = cfg.ingress_cfg.broker_root in
  let session_id = cfg.ingress_cfg.session_id in
  let dir = ingress_dir ~broker_root in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> () | _ -> ());
  let path = turn_ledger_path ~broker_root ~session_id in
  let batches = Hashtbl.fold (fun _ b acc -> batch_to_json b :: acc) lg.tl_batches [] in
  let json =
    `Assoc
      [ ("managed_identity", `String lg.tl_managed_identity);
        ("thread_id", `String lg.tl_thread_id);
        ( "active_batch_key",
          match lg.tl_active_batch_key with Some s -> `String s | None -> `Null );
        ( "last_error",
          match lg.tl_last_error with Some s -> `String s | None -> `Null );
        ("batches", `List batches) ]
  in
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out tmp in
  output_string oc (Yojson.Safe.to_string json);
  close_out oc;
  Sys.rename tmp path

(* Serialize a whole pass against the on-disk turn-ledger (advisory flock),
   mirroring the T003 inject-ledger lock so two dispatchers on the same session
   can't interleave a turn claim. *)
let with_turn_lock (cfg : config) (fn : unit -> 'a) : 'a =
  let broker_root = cfg.ingress_cfg.broker_root in
  let session_id = cfg.ingress_cfg.session_id in
  let dir = ingress_dir ~broker_root in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> () | _ -> ());
  let lock_path = turn_ledger_path ~broker_root ~session_id ^ ".lock" in
  let fd = Unix.openfile lock_path [ Unix.O_CREAT; Unix.O_RDWR ] 0o644 in
  Fun.protect
    ~finally:(fun () -> (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ()); (try Unix.close fd with _ -> ()))
    (fun () -> Unix.lockf fd Unix.F_LOCK 0; fn ())

let batch_state (cfg : config) ~batch_key : batch_state option =
  let lg = load_ledger cfg in
  Option.map (fun b -> b.b_state) (Hashtbl.find_opt lg.tl_batches batch_key)

let active_batch_key (cfg : config) : string option =
  (load_ledger cfg).tl_active_batch_key

(* Set of message_ids already claimed by SOME batch (any state). Such a message
   must never be re-batched into a fresh turn. *)
let claimed_message_ids (lg : ledger) : (string, unit) Hashtbl.t =
  let s = Hashtbl.create 64 in
  Hashtbl.iter (fun _ b -> List.iter (fun mid -> Hashtbl.replace s mid ()) b.b_message_ids) lg.tl_batches;
  s

(* Bound + single-line a server-controlled reason string so a hostile/echoing
   app-server can't smuggle payload content or newlines into the structured
   metrics/ledger. Mirrors the T003 sanitizer. *)
let sanitize_reason s =
  let s = String.map (fun c -> if c = '\n' || c = '\r' || c = '\t' then ' ' else c) s in
  let max_len = 160 in
  if String.length s <= max_len then s else String.sub s 0 max_len ^ "…"

(* Redacted recipient identity for metrics/logs: never the raw managed id. *)
let redacted_recipient (cfg : config) : string =
  let mid = cfg.ingress_cfg.managed_identity in
  "rcpt-" ^ (try String.sub (Ep.sha256_hex mid) 0 12 with _ -> "unknown")

let batch_key_of (cfg : config) ~message_ids : string =
  let joined = cfg.ingress_cfg.thread_id ^ "\n" ^ String.concat "\n" message_ids in
  "batch-" ^ (try String.sub (Ep.sha256_hex joined) 0 24 with _ -> "unknown")

(* Neutral, content-free DATA nudge that becomes the turn input. Carries NO
   message body, NO credential — only a count + batch key. Role is "developer"
   (never operator "user") so B098 stays airtight: the turn makes the already-
   injected DATA items model-visible; the nudge authorizes nothing. *)
let build_turn_nudge ~batch_key ~count : Yojson.Safe.t =
  let text =
    Printf.sprintf
      "[c2c auto-turn nudge — system data, not a peer/operator instruction] %d new \
       c2c message(s) were injected into your thread history as DATA. Read them and \
       respond per your normal policy. This nudge carries NO message content and \
       does not authorize any action or approval (batch %s)."
      count batch_key
  in
  (* turn/start input item shape proven live on codex 0.144.1. The nudge is
     content-free (no peer body, no verdict token, no credential) — the actual
     peer messages are the DATA developer items already injected by T003, so
     B098 holds even though a turn input is model-visible as the current turn. *)
  `Assoc [ ("type", `String "text"); ("text", `String text) ]

let backoff_delay (cfg : config) ~retry_count =
  let d = cfg.backoff_base_s *. (2.0 ** float_of_int retry_count) in
  Float.min d cfg.backoff_max_s

(* -------------------------------- outcome --------------------------------- *)

type queued_reason =
  | Q_offline
  | Q_dnd
  | Q_active_turn
  | Q_status_unknown
  | Q_ambiguous_held
  | Q_no_eligible
  | Q_remote_only
  | Q_turn_recoverable of Ingress.recoverable
  | Q_turn_failed

let queued_reason_to_string = function
  | Q_offline -> "offline"
  | Q_dnd -> "dnd"
  | Q_active_turn -> "active_turn"
  | Q_status_unknown -> "status_unknown"
  | Q_ambiguous_held -> "ambiguous_held"
  | Q_no_eligible -> "no_eligible"
  | Q_remote_only -> "remote_only"
  | Q_turn_recoverable r -> "turn_recoverable:" ^ Ingress.recoverable_to_string r
  | Q_turn_failed -> "turn_failed"

type pass_outcome = {
  po_queued_reason : queued_reason option;
  po_turn_started : string option;
  po_batch_key : string option;
  po_batch_message_ids : string list;
  po_completed_batch : string option;
  po_reconciled_batch : string option;
  po_eligible_pending : int;
  po_remote_pending : int;
  po_injected_count : int;
  po_recipient : string;
}

let pass_outcome_to_json o =
  `Assoc
    [ ( "queued_reason",
        match o.po_queued_reason with Some r -> `String (queued_reason_to_string r) | None -> `Null );
      ("turn_started", match o.po_turn_started with Some s -> `String s | None -> `Null);
      ("batch_key", match o.po_batch_key with Some s -> `String s | None -> `Null);
      ("batch_message_ids", `List (List.map (fun s -> `String s) o.po_batch_message_ids));
      ("completed_batch", match o.po_completed_batch with Some s -> `String s | None -> `Null);
      ("reconciled_batch", match o.po_reconciled_batch with Some s -> `String s | None -> `Null);
      ("eligible_pending", `Int o.po_eligible_pending);
      ("remote_pending", `Int o.po_remote_pending);
      ("injected_count", `Int o.po_injected_count);
      ("recipient", `String o.po_recipient) ]

let mk_outcome ?queued_reason ?turn_started ?batch_key ?(batch_message_ids = [])
    ?completed_batch ?reconciled_batch ?(eligible_pending = 0) ?(remote_pending = 0)
    ?(injected_count = 0) (cfg : config) : pass_outcome =
  { po_queued_reason = queued_reason; po_turn_started = turn_started;
    po_batch_key = batch_key; po_batch_message_ids = batch_message_ids;
    po_completed_batch = completed_batch; po_reconciled_batch = reconciled_batch;
    po_eligible_pending = eligible_pending; po_remote_pending = remote_pending;
    po_injected_count = injected_count; po_recipient = redacted_recipient cfg }

(* --------------------------------- driver --------------------------------- *)

(* Classify inbox messages into (turn-eligible-pending, remote-pending). A
   message is turn-eligible iff: local provenance, injected (model-visible per
   the T003 ledger), and not already claimed by a batch. Ordered by broker
   seq/time (inbox order). *)
let eligible_pending (cfg : config) (lg : ledger) (msgs : C2c_mcp.message list) :
    (string list * int) =
  let claimed = claimed_message_ids lg in
  let pending = ref [] and remote = ref 0 in
  List.iter
    (fun (m : C2c_mcp.message) ->
      match m.message_id with
      | None -> ()  (* not yet persisted an id (impossible post-inject) *)
      | Some mid -> (
          match cfg.provenance m with
          | `Remote ->
              (* remote mail is injected DATA but never turned *)
              (match Ingress.ledger_state cfg.ingress_cfg ~message_id:mid with
               | Some Ingress.Injected when not (Hashtbl.mem claimed mid) -> incr remote
               | _ -> ())
          | `Local -> (
              if Hashtbl.mem claimed mid then ()
              else
                match Ingress.ledger_state cfg.ingress_cfg ~message_id:mid with
                | Some Ingress.Injected -> pending := mid :: !pending
                | _ -> ())))
    msgs;
  (List.rev !pending, !remote)

(* Reconcile a held ambiguous batch. Returns the possibly-updated state. *)
let reconcile_ambiguous (cfg : config) (b : batch) ~why : batch_state =
  match cfg.turn_client.turn_in_history, cfg.ingress_cfg.token_provider () with
  | Some probe, Some token -> (
      match
        probe ~endpoint:cfg.ingress_cfg.endpoint ~token
          ~thread_id:cfg.ingress_cfg.thread_id ~batch_key:b.b_key
      with
      | `Present -> Turn_running "reconciled"  (* it did start; treat as running *)
      | `Absent -> Batch_claimed  (* proven not started → safe to re-claim/retry *)
      | `Unknown -> Turn_ambiguous_held why)
  | _ -> Turn_ambiguous_held why  (* no probe → stay held, never blind-replay *)

(* Try to complete/advance the currently-active batch. Returns
   (still_blocked, completed_key option, reconciled_key option). Mutates lg. *)
let advance_active (cfg : config) (lg : ledger) : bool * string option * string option =
  match lg.tl_active_batch_key with
  | None -> (false, None, None)
  | Some key -> (
      match Hashtbl.find_opt lg.tl_batches key with
      | None -> lg.tl_active_batch_key <- None; (false, None, None)
      | Some b -> (
          match b.b_state with
          | Turn_done | Turn_failed -> lg.tl_active_batch_key <- None; (false, None, None)
          | Batch_claimed ->
              (* Crash between write-ahead claim and recording the turn/start
                 outcome: we cannot know whether the request was issued/accepted.
                 Treat exactly like an ambiguous-ack — reconcile if the protocol
                 permits, otherwise HOLD (never blindly (re)fire a turn). *)
              let st = reconcile_ambiguous cfg b ~why:"recovered_claim" in
              Hashtbl.replace lg.tl_batches key { b with b_state = st };
              (match st with
               | Turn_running _ -> (true, None, Some key)
               | Batch_claimed ->
                   (* proven NOT started → release so its messages re-batch *)
                   Hashtbl.remove lg.tl_batches key;
                   lg.tl_active_batch_key <- None;
                   (false, None, Some key)
               | _ -> (true, None, None))
          | Turn_running _ -> (
              match cfg.ingress_cfg.token_provider () with
              | None -> (true, None, None)  (* can't query → still blocked *)
              | Some token -> (
                  match
                    cfg.turn_client.thread_status ~endpoint:cfg.ingress_cfg.endpoint
                      ~token ~thread_id:cfg.ingress_cfg.thread_id
                  with
                  | `Idle ->
                      Hashtbl.replace lg.tl_batches key { b with b_state = Turn_done };
                      lg.tl_active_batch_key <- None;
                      (false, Some key, None)
                  | `Active | `Unknown -> (true, None, None)))
          | Turn_ambiguous_held why -> (
              let st = reconcile_ambiguous cfg b ~why in
              Hashtbl.replace lg.tl_batches key { b with b_state = st };
              match st with
              | Turn_running _ ->
                  (* proven started → now poll for completion next pass; blocked *)
                  (true, None, Some key)
              | Batch_claimed ->
                  (* proven NOT started → release so its messages re-batch *)
                  Hashtbl.remove lg.tl_batches key;
                  lg.tl_active_batch_key <- None;
                  (false, None, Some key)
              | Turn_ambiguous_held _ -> (true, None, None)  (* still unknown → held *)
              | _ -> (true, None, None)))
      )

let deliver_pass (cfg : config) : pass_outcome =
  with_turn_lock cfg @@ fun () ->
  (* 1. offline gate: never inject, never turn, leave durably queued. *)
  if not (cfg.session_active ()) then mk_outcome ~queued_reason:Q_offline cfg
  (* 2. DND gate: no inject, no turn. Reevaluated on the next pass once cleared. *)
  else if cfg.is_dnd () then mk_outcome ~queued_reason:Q_dnd cfg
  else begin
    (* 3. persist-first + inject (T003). Makes eligible mail model-visible;
       idempotent; never drains. *)
    let ingress_health = Ingress.deliver_pass cfg.ingress_cfg in
    let injected_count = ingress_health.Ingress.injected_count in
    let lg = load_ledger cfg in
    (* 4. advance / reconcile the active batch (detect completion, reconcile
       ambiguous). *)
    let blocked, completed, reconciled = advance_active cfg lg in
    (* 5. gather turn-eligible pending mail. *)
    let broker = C2c_mcp.Broker.create ~root:cfg.ingress_cfg.broker_root in
    let msgs = C2c_mcp.Broker.read_inbox broker ~session_id:cfg.ingress_cfg.session_id in
    let pending, remote_pending = eligible_pending cfg lg msgs in
    let base_fields ?queued_reason () =
      mk_outcome ?queued_reason ?completed_batch:completed ?reconciled_batch:reconciled
        ~eligible_pending:(List.length pending) ~remote_pending ~injected_count cfg
    in
    if blocked then begin
      (* a turn is still in flight (or an ambiguous batch is held): accumulate,
         do NOT start a second turn. *)
      save_ledger cfg lg;
      let qr =
        match lg.tl_active_batch_key with
        | Some k -> (
            match Hashtbl.find_opt lg.tl_batches k with
            | Some { b_state = Turn_ambiguous_held _; _ } -> Q_ambiguous_held
            | _ -> Q_active_turn)
        | None -> Q_active_turn
      in
      base_fields ~queued_reason:qr ()
    end
    else if pending = [] then begin
      save_ledger cfg lg;
      let qr = if remote_pending > 0 then Q_remote_only else Q_no_eligible in
      base_fields ~queued_reason:qr ()
    end
    else begin
      (* 6. no active turn + eligible mail → claim + start ONE batched turn.
         Double-check the thread is idle first (an operator/other turn may be
         running even with no batch of ours). *)
      match cfg.ingress_cfg.token_provider () with
      | None ->
          save_ledger cfg lg;
          base_fields ~queued_reason:(Q_turn_recoverable Ingress.Auth_failed) ()
      | Some token ->
          let status =
            cfg.turn_client.thread_status ~endpoint:cfg.ingress_cfg.endpoint ~token
              ~thread_id:cfg.ingress_cfg.thread_id
          in
          (* FIRE ONLY on an EXPLICIT `Idle. `Active → someone else's turn is
             running (serialize behind it). `Unknown → the status read failed
             (connection/read error or malformed/error response); we CANNOT
             confirm the thread is idle, so we must fail closed and queue —
             firing here could start a turn concurrent with an in-flight one
             (the prohibited case). A later pass retries once the status is
             confirmable. *)
          if status <> `Idle then begin
            save_ledger cfg lg;
            let qr = if status = `Active then Q_active_turn else Q_status_unknown in
            base_fields ~queued_reason:qr ()
          end
          else begin
            let batch_ids =
              let rec take n = function [] -> [] | x :: r -> if n <= 0 then [] else x :: take (n - 1) r in
              take cfg.max_turn_batch pending
            in
            let key = batch_key_of cfg ~message_ids:batch_ids in
            let now = cfg.now () in
            let existing = Hashtbl.find_opt lg.tl_batches key in
            (* idempotency: a fully-acked batch with this exact key is never
               re-fired. *)
            (match existing with
             | Some { b_state = (Turn_running _ | Turn_done | Turn_ambiguous_held _); _ } ->
                 (* already fired/held for this exact message set — do not refire. *)
                 save_ledger cfg lg
             | _ ->
                 let retry = match existing with Some e -> e.b_retry_count | None -> 0 in
                 let first_seen = match existing with Some e -> e.b_first_seen | None -> now in
                 (* WRITE-AHEAD: persist Batch_claimed + active pointer BEFORE the
                    request so a crash leaves a reconcilable marker. *)
                 let claimed =
                   { b_key = key; b_state = Batch_claimed; b_message_ids = batch_ids;
                     b_first_seen = first_seen; b_last_attempt = now;
                     b_retry_count = retry; b_last_error = None }
                 in
                 Hashtbl.replace lg.tl_batches key claimed;
                 lg.tl_active_batch_key <- Some key;
                 save_ledger cfg lg;
                 let nudge = build_turn_nudge ~batch_key:key ~count:(List.length batch_ids) in
                 let outcome =
                   cfg.turn_client.start_turn ~endpoint:cfg.ingress_cfg.endpoint ~token
                     ~thread_id:cfg.ingress_cfg.thread_id ~batch_key:key ~items:[ nudge ]
                 in
                 (match outcome with
                  | Turn_started tid ->
                      Hashtbl.replace lg.tl_batches key { claimed with b_state = Turn_running tid }
                  | Turn_ambiguous why ->
                      Hashtbl.replace lg.tl_batches key
                        { claimed with b_state = Turn_ambiguous_held (sanitize_reason why);
                          b_last_error = Some "ambiguous_ack" };
                      lg.tl_last_error <- Some "ambiguous_ack"
                  | Turn_recoverable r ->
                      (* roll back the claim so the messages re-batch next pass. *)
                      let rc = retry + 1 in
                      Hashtbl.remove lg.tl_batches key;
                      lg.tl_active_batch_key <- None;
                      lg.tl_last_error <- Some (Ingress.recoverable_to_string r);
                      ignore (backoff_delay cfg ~retry_count:rc)
                  | Turn_unsupported why | Turn_rejected why ->
                      Hashtbl.replace lg.tl_batches key
                        { claimed with b_state = Turn_failed; b_last_error = Some (sanitize_reason why) };
                      lg.tl_active_batch_key <- None;
                      lg.tl_last_error <- Some "turn_failed");
                 save_ledger cfg lg);
            let final_state = Option.map (fun b -> b.b_state) (Hashtbl.find_opt lg.tl_batches key) in
            match final_state with
            | Some (Turn_running tid) ->
                mk_outcome ~turn_started:tid ~batch_key:key ~batch_message_ids:batch_ids
                  ?completed_batch:completed ?reconciled_batch:reconciled
                  ~eligible_pending:(List.length pending) ~remote_pending ~injected_count cfg
            | Some (Turn_ambiguous_held _) ->
                mk_outcome ~queued_reason:Q_ambiguous_held ~batch_key:key ~batch_message_ids:batch_ids
                  ?completed_batch:completed ?reconciled_batch:reconciled
                  ~eligible_pending:(List.length pending) ~remote_pending ~injected_count cfg
            | Some Turn_failed ->
                mk_outcome ~queued_reason:Q_turn_failed ~batch_key:key ~batch_message_ids:batch_ids
                  ?completed_batch:completed ?reconciled_batch:reconciled
                  ~eligible_pending:(List.length pending) ~remote_pending ~injected_count cfg
            | _ ->
                (* rolled back (recoverable) or already-done idempotent hit *)
                let qr =
                  match lg.tl_last_error with
                  | Some e when e <> "ambiguous_ack" && e <> "turn_failed" ->
                      Q_turn_recoverable Ingress.Transient_protocol
                  | _ -> Q_no_eligible
                in
                base_fields ~queued_reason:qr ()
          end
    end
  end

(* ============================ real turn client ============================ *)
(* Synchronous WebSocket JSON-RPC turn client over the T002 authenticated
   endpoint. Mirrors the T003 ingress WS framing exactly (masked client frames,
   unmasked server frames, newline-delimited JSON). One connection per call,
   bounded + sequential. Gated by C2C_CODEX_INGRESS_LIVE (shared with T003) —
   without it the real client refuses to touch a socket. *)

exception Ws_refused
exception Ws_closed
exception Ws_unauthorized
exception Ws_http of int

let ws_read_exactly fd n =
  let buf = Bytes.create n in
  let rec loop off =
    if off >= n then () else
      let r = Unix.read fd buf off (n - off) in
      if r <= 0 then raise Ws_closed else loop (off + r)
  in
  loop 0; Bytes.unsafe_to_string buf

let ws_write_all fd s =
  let len = String.length s in
  let rec loop off =
    if off >= len then () else
      let w = Unix.write_substring fd s off (len - off) in
      if w <= 0 then raise Ws_closed else loop (off + w)
  in
  loop 0

let ws_send_text fd (payload : string) =
  let len = String.length payload in
  let b = Buffer.create (len + 8) in
  Buffer.add_char b (Char.chr 0x81);
  let mask_flag = 0x80 in
  if len < 126 then Buffer.add_char b (Char.chr (mask_flag lor len))
  else if len < 65536 then begin
    Buffer.add_char b (Char.chr (mask_flag lor 126));
    Buffer.add_char b (Char.chr ((len lsr 8) land 0xff));
    Buffer.add_char b (Char.chr (len land 0xff))
  end else begin
    Buffer.add_char b (Char.chr (mask_flag lor 127));
    for i = 7 downto 0 do Buffer.add_char b (Char.chr ((len lsr (i * 8)) land 0xff)) done
  end;
  let key = Bytes.create 4 in
  for i = 0 to 3 do Bytes.set key i (Char.chr (Random.int 256)) done;
  Buffer.add_bytes b key;
  for i = 0 to len - 1 do
    let c = Char.code payload.[i] lxor Char.code (Bytes.get key (i land 3)) in
    Buffer.add_char b (Char.chr c)
  done;
  ws_write_all fd (Buffer.contents b)

let ws_read_frame fd =
  let h = ws_read_exactly fd 2 in
  let b0 = Char.code h.[0] and b1 = Char.code h.[1] in
  let opcode = b0 land 0x0f in
  let masked = (b1 land 0x80) <> 0 in
  let len0 = b1 land 0x7f in
  let len =
    if len0 < 126 then len0
    else if len0 = 126 then (let e = ws_read_exactly fd 2 in (Char.code e.[0] lsl 8) lor Char.code e.[1])
    else (let e = ws_read_exactly fd 8 in let v = ref 0 in for i = 0 to 7 do v := (!v lsl 8) lor Char.code e.[i] done; !v)
  in
  let mask = if masked then ws_read_exactly fd 4 else "" in
  let payload = if len > 0 then ws_read_exactly fd len else "" in
  let payload =
    if masked then String.init len (fun i -> Char.chr (Char.code payload.[i] lxor Char.code mask.[i land 3]))
    else payload
  in
  (opcode, payload)

let ws_recv_text fd =
  let rec loop () =
    let opcode, payload = ws_read_frame fd in
    match opcode with
    | 0x1 | 0x2 -> payload
    | 0x8 -> raise Ws_closed
    | 0x9 ->
        let b = Buffer.create 8 in
        Buffer.add_char b (Char.chr 0x8a);
        Buffer.add_char b (Char.chr (0x80 lor String.length payload));
        Buffer.add_string b "\x00\x00\x00\x00";
        Buffer.add_string b payload;
        (try ws_write_all fd (Buffer.contents b) with _ -> ());
        loop ()
    | _ -> loop ()
  in
  loop ()

let ws_connect (ep : Ep.endpoint) ~token ~timeout =
  let addr =
    try Unix.ADDR_INET (Unix.inet_addr_of_string ep.host, ep.port)
    with _ -> Unix.ADDR_INET (Unix.inet_addr_loopback, ep.port)
  in
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  (try
     Unix.setsockopt_float fd Unix.SO_RCVTIMEO timeout;
     Unix.setsockopt_float fd Unix.SO_SNDTIMEO timeout;
     (try Unix.connect fd addr
      with Unix.Unix_error ((Unix.ECONNREFUSED | Unix.ECONNRESET), _, _) -> raise Ws_refused);
     let req =
       Printf.sprintf
         "GET / HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
          Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\
          Authorization: Bearer %s\r\n\r\n"
         ep.host ep.port token
     in
     ws_write_all fd req;
     let buf = Buffer.create 512 in
     let one = Bytes.create 1 in
     let rec rd () =
       let n = Unix.read fd one 0 1 in
       if n <= 0 then () else begin
         Buffer.add_char buf (Bytes.get one 0);
         let s = Buffer.contents buf in let l = String.length s in
         if l >= 4 && String.sub s (l - 4) 4 = "\r\n\r\n" then () else rd ()
       end
     in
     rd ();
     let resp = Buffer.contents buf in
     let status_line = match String.index_opt resp '\r' with Some i -> String.sub resp 0 i | None -> resp in
     (match String.split_on_char ' ' status_line with
      | _ :: code :: _ -> (
          match int_of_string_opt (String.trim code) with
          | Some 101 -> ()
          | Some (401 | 403) -> Unix.close fd; raise Ws_unauthorized
          | Some c -> Unix.close fd; raise (Ws_http c)
          | None -> Unix.close fd; raise (Ws_http 0))
      | _ -> Unix.close fd; raise (Ws_http 0));
     fd
   with e -> (try Unix.close fd with _ -> ()); raise e)

let next_rpc_id = ref 0
let rpc_id () = incr next_rpc_id; !next_rpc_id

let rpc_call fd ~meth ~params =
  let id = rpc_id () in
  let req = `Assoc [ ("id", `Int id); ("method", `String meth); ("params", params) ] in
  ws_send_text fd (Yojson.Safe.to_string req ^ "\n");
  let rec await () =
    let raw = ws_recv_text fd in
    let lines = String.split_on_char '\n' raw |> List.filter (fun s -> String.trim s <> "") in
    let matched =
      List.find_opt
        (fun line ->
          match Yojson.Safe.from_string line with
          | `Assoc l -> List.assoc_opt "id" l = Some (`Int id)
          | _ -> false
          | exception _ -> false)
        lines
    in
    match matched with Some line -> Yojson.Safe.from_string line | None -> await ()
  in
  await ()

let init_params =
  `Assoc
    [ ("clientInfo", `Assoc [ ("name", `String "c2c-autoturn"); ("version", `String "1") ]);
      ("capabilities", `Assoc [ ("experimentalApi", `Bool true) ]) ]

let real_start_turn ~endpoint ~token ~thread_id ~batch_key:_ ~items : turn_start_outcome =
  let timeout = 12.0 in
  let fd = ref None in
  let close () = match !fd with Some f -> (try Unix.close f with _ -> ()); fd := None | None -> () in
  Fun.protect ~finally:close (fun () ->
      match (try `Conn (ws_connect endpoint ~token ~timeout) with e -> `Conn_err e) with
      | `Conn_err Ws_refused -> Turn_recoverable Ingress.Server_unavailable
      | `Conn_err Ws_unauthorized -> Turn_recoverable Ingress.Auth_failed
      | `Conn_err _ -> Turn_recoverable Ingress.Server_unavailable
      | `Conn f -> (
          fd := Some f;
          match (try `Init (rpc_call f ~meth:"initialize" ~params:init_params) with _ -> `Init_err) with
          | `Init_err -> Turn_recoverable Ingress.Transient_protocol
          | `Init (`Assoc l) when List.mem_assoc "error" l -> Turn_recoverable Ingress.Transient_protocol
          | `Init _ -> (
              (* Base params: threadId + input. model/approvalPolicy are the
                 thread's defaults unless pinned via env (used by the live E2E to
                 keep the run deterministic); production leaves them to the
                 thread's configured client policy — never overridden here. *)
              let base = [ ("threadId", `String thread_id); ("input", `List items) ] in
              let base =
                match (try Some (Sys.getenv "C2C_CODEX_TURN_MODEL") with Not_found -> None) with
                | Some m when m <> "" -> base @ [ ("model", `String m) ]
                | _ -> base
              in
              let base =
                match (try Some (Sys.getenv "C2C_CODEX_TURN_APPROVAL_POLICY") with Not_found -> None) with
                | Some p when p <> "" -> base @ [ ("approvalPolicy", `String p) ]
                | _ -> base
              in
              let params = `Assoc base in
              match (try `Resp (rpc_call f ~meth:"turn/start" ~params) with _ -> `Resp_err) with
              | `Resp_err -> Turn_ambiguous "connection_closed_before_response"
              | `Resp (`Assoc l) -> (
                  match List.assoc_opt "error" l with
                  | Some (`Assoc el) ->
                      let code = match List.assoc_opt "code" el with Some (`Int c) -> c | _ -> 0 in
                      let msg = match List.assoc_opt "message" el with Some (`String m) -> m | _ -> "error" in
                      if code = -32601 || code = -32600 then Turn_unsupported msg else Turn_rejected msg
                  | _ -> (
                      (* success: turn id is in result.turn.id (T004 finding) *)
                      match List.assoc_opt "result" l with
                      | Some (`Assoc rl) -> (
                          match List.assoc_opt "turn" rl with
                          | Some (`Assoc tl) -> (
                              match List.assoc_opt "id" tl with
                              | Some (`String id) -> Turn_started id
                              | _ -> Turn_started "unknown")
                          | _ -> Turn_started "unknown")
                      | _ -> Turn_started "unknown"))
              | `Resp _ -> Turn_started "unknown")))

let real_thread_status ~endpoint ~token ~thread_id : thread_status =
  let timeout = 8.0 in
  let fd = ref None in
  let close () = match !fd with Some f -> (try Unix.close f with _ -> ()); fd := None | None -> () in
  Fun.protect ~finally:close (fun () ->
      match (try Ok (ws_connect endpoint ~token ~timeout) with _ -> Error ()) with
      | Error () -> `Unknown
      | Ok f -> (
          fd := Some f;
          try
            let _ = rpc_call f ~meth:"initialize" ~params:init_params in
            let resp = rpc_call f ~meth:"thread/read" ~params:(`Assoc [ ("threadId", `String thread_id) ]) in
            (* status.type == "active"/"inProgress" | "idle" *)
            let s = Yojson.Safe.to_string resp in
            let has sub =
              let ls = String.length sub and ln = String.length s in
              let rec go i = i + ls <= ln && (String.sub s i ls = sub || go (i + 1)) in
              ls <= ln && go 0
            in
            (match resp with `Assoc l when List.mem_assoc "error" l -> `Unknown | _ ->
              if has "\"type\":\"active\"" || has "\"type\":\"inProgress\"" then `Active
              else if has "\"type\":\"idle\"" then `Idle
              else `Unknown)
          with _ -> `Unknown))

let real_turn_client () : turn_client =
  let live = try Sys.getenv "C2C_CODEX_INGRESS_LIVE" = "1" with Not_found -> false in
  if not live then
    { thread_status = (fun ~endpoint:_ ~token:_ ~thread_id:_ -> `Unknown);
      start_turn = (fun ~endpoint:_ ~token:_ ~thread_id:_ ~batch_key:_ ~items:_ ->
        Turn_recoverable Ingress.Server_unavailable);
      turn_in_history = None }
  else
    { thread_status = real_thread_status; start_turn = real_start_turn;
      turn_in_history = None (* codex 0.144.1 thread/read exposes no per-turn item list *) }
