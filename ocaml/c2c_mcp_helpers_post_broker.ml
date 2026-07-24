(* Hoisted from c2c_mcp.ml as part of #450 Slice 0.5 — substrate for
   handler-cluster extraction (S1-S7). Pure mechanical move; no behavior
   change. Holds post-Broker helpers used by tool-call handlers:
   structured-log emitters, channel notification + envelope decrypt, room
   info JSON, session-resolution glue ([with_session], [with_session_lwt]),
   sender-impersonation guard, self-PASS detector, etc.

   Layered above [C2c_broker]: this module opens the Broker module to
   reach Broker.t and the room/registration types. Contrast
   [C2c_mcp_helpers], which is opened BY [C2c_broker] and may not refer
   to Broker types. *)

open C2c_mcp_helpers
module Broker = C2c_broker


(* #286: send-memory handoff.
   After a per-agent memory entry with [shared_with] is written, broker-DM
   each recipient with the path so they don't have to poll
   `memory list --shared-with-me`. Returns the list of aliases successfully
   notified (recipients we couldn't reach are silently skipped).

   Globally-shared entries (`shared:true`) skip the targeted handoff: the
   audience is everyone, so a per-recipient DM is noise.

   Notifications are deferrable (no push-spam) and best-effort
   (try/with swallows enqueue failures so the entry write itself never
   fails because of a notification).

   #327: every handoff attempt is logged to broker.log as
   `{"ts", "event": "send_memory_handoff", "from", "to", "name", "ok",
   "error"?}` so silent failures (handoff didn't reach the recipient
   inbox despite the entry write succeeding) are diagnosable after-
   the-fact. The 2026-04-27 #327 case had no broker-side trace until
   this logging existed. *)

(* #388: log_broker_event lives in C2c_mcp_helpers (shared with Broker).
   All other helpers below are post-Broker layer; C2c_mcp_helpers has
   no dependency on Broker types. *)

let log_handoff_attempt ~broker_root ~from_alias ~to_alias ~name ~ok ~error =
  let ts = Unix.gettimeofday () in
  let fields =
    [ ("ts", `Float ts)
    ; ("from", `String from_alias)
    ; ("to", `String to_alias)
    ; ("name", `String name)
    ; ("ok", `Bool ok) ]
    @ (match error with None -> [] | Some e -> [ ("error", `String e) ])
  in
  log_broker_event ~broker_root "send_memory_handoff" fields

(* #29 H2b: log every peer-pass DM verification attempt that ends in a
   strict-mode reject. The detailed reason (pin pubkey fingerprints,
   sha mismatch detail, etc.) is appended here; the user-facing reject
   message stays generic so attacker-placed artifact contents do not
   echo back to the sender. *)
let log_peer_pass_reject ~broker_root ~from_alias ~to_alias ~claim_alias ~claim_sha ~reason ~ts =
  log_broker_event ~broker_root "peer_pass_reject"
    [ ("ts", `Float ts)
    ; ("from", `String from_alias)
    ; ("to", `String to_alias)
    ; ("claim_alias", `String claim_alias)
    ; ("claim_sha", `String claim_sha)
    ; ("reason", `String reason) ]

(* #55: every TOFU pubkey-pin rotation gets a structured audit line in
   broker.log so an attacker who compromises one keypair cannot stealth-
   rotate the pin out from under the swarm — every rotation leaves a
   forensic trail. Sibling to [log_peer_pass_reject] above; same file,
   same shape, different event tag.

   The hook is registered on [Peer_review.set_pin_rotate_logger] at
   broker startup so any caller of [Peer_review.pin_rotate] (CLI verify
   --rotate-pin, future MCP rotate-pin tool, anything internal)
   produces the log line without having to remember to. *)
let log_peer_pass_pin_rotate ~broker_root ~alias ~old_pubkey ~new_pubkey
    ~prior_first_seen ~ts =
  let prior_field = match prior_first_seen with
    | None -> []
    | Some f -> [ ("prior_first_seen", `Float f) ]
  in
  log_broker_event ~broker_root "peer_pass_pin_rotate"
    (("ts", `Float ts)
     :: ("alias", `String alias)
     :: ("old_pubkey", `String old_pubkey)
     :: ("new_pubkey", `String new_pubkey)
     :: prior_field)

(* Wire the broker.log writer as the default pin-rotate logger. The
   hook event includes the pin-store [path], from which we recover the
   broker_root (the pin store lives at <broker_root>/peer-pass-trust.json
   on the canonical broker; the CLI install resolver sets the same).
   Any caller that explicitly passes [?path] to [pin_rotate] still
   produces a log line (the file is alongside the pin-store, which is
   what an audit trail wants). *)
let () =
  Peer_review.set_pin_rotate_logger (fun (event : Peer_review.pin_rotate_log_event) ->
    let broker_root = Filename.dirname event.path in
    log_peer_pass_pin_rotate
      ~broker_root
      ~alias:event.alias
      ~old_pubkey:event.old_pubkey
      ~new_pubkey:event.new_pubkey
      ~prior_first_seen:event.prior_first_seen
      ~ts:event.ts)

(* Slice B-min-version: forensic audit-log line on every receive
   rejected by the per-alias min-observed-version pin. Same shape as
   [log_peer_pass_pin_rotate_unauth] below so log readers can grep
   [event] consistently. Best-effort, swallows all errors (audit-log
   emission must never block the broker's primary verify path). *)
let log_version_downgrade_rejected ~broker_root ~alias ~observed ~pinned_min ~ts =
  log_broker_event ~broker_root "version_downgrade_rejected"
    [ ("ts", `Float ts)
    ; ("alias", `String alias)
    ; ("observed_envelope_version", `Int observed)
    ; ("pinned_min_envelope_version", `Int pinned_min) ]

(* Slice B follow-up: structured audit-log line on every Ed25519 pin
   mismatch reject. Closes slate's flagged observability gap from the
   Slice B PASS — the security invariant (reject + pin-unchanged + no
   plaintext leak) was already enforced and surfaced via [enc_status:
   "key-changed"], but operators had no broker.log line to correlate
   suspected attacks across the swarm. Same shape as
   [log_version_downgrade_rejected] above; best-effort, swallows
   errors. *)
let log_relay_e2e_pin_mismatch ~broker_root ~alias
      ~pinned_ed25519_b64 ~claimed_ed25519_b64 ~ts =
  log_broker_event ~broker_root "relay_e2e_pin_mismatch"
    [ ("ts", `Float ts)
    ; ("alias", `String alias)
    ; ("pinned_ed25519_b64", `String pinned_ed25519_b64)
    ; ("claimed_ed25519_b64", `String claimed_ed25519_b64) ]

(* TOFU first-contact audit line: symmetric to [log_relay_e2e_pin_mismatch]
   (#432 CRIT-1 Slice B follow-up). When a sender has no prior pin and the
   envelope carries a claimed Ed25519 key, the broker pins it. Operators have
   no visibility into first-contact pins today — this line provides that
   forensic signal. Same best-effort shape as [log_relay_e2e_pin_mismatch].
   Written immediately after [Broker.pin_ed25519_sync] succeeds inside the
   first-contact branch (pinned=None, claimed=Some). *)
let log_relay_e2e_pin_first_seen ~broker_root ~alias ~pinned_ed25519_b64 ~ts =
  log_broker_event ~broker_root "relay_e2e_pin_first_seen"
    [ ("ts", `Float ts)
    ; ("alias", `String alias)
    ; ("pinned_ed25519_b64", `String pinned_ed25519_b64) ]

(* CRIT-2 register-path observability: structured audit-log line on
   every register-path TOFU pin-mismatch reject (Ed25519 OR X25519).
   Sibling of [log_relay_e2e_pin_mismatch] above, distinct event-name
   ([relay_e2e_register_pin_mismatch]) and an extra [key_class] field
   ("ed25519" | "x25519") so operators can correlate which pubkey
   class tripped the reject. Best-effort, swallows errors. Closes
   the observability gap from the envelope-path Slice B follow-up:
   that helper covers in-flight envelope mismatches; this one covers
   the registration-handshake mismatches that block a session before
   any envelope is sent. *)
let log_relay_e2e_register_pin_mismatch ~broker_root ~alias
      ~key_class ~pinned_b64 ~claimed_b64 ~ts =
  log_broker_event ~broker_root "relay_e2e_register_pin_mismatch"
    [ ("ts", `Float ts)
    ; ("alias", `String alias)
    ; ("key_class", `String key_class)
    ; ("pinned_b64", `String pinned_b64)
    ; ("claimed_b64", `String claimed_b64) ]

(* #432 TOFU 5 observability follow-up: sibling logger for
   pin_rotate REJECT path. Same broker.log file, same shape as
   pending_cap_reject — best-effort, swallows all errors, distinct
   event-name so log readers can grep for it independently of
   successful rotates. Registered alongside the success-path logger
   above so every caller of [Peer_review.pin_rotate] that's rejected
   at the operator-attestation gate produces a forensic line. *)
let log_peer_pass_pin_rotate_unauth ~broker_root ~alias ~reason ~ts =
  log_broker_event ~broker_root "peer_pass_pin_rotate_unauth"
    [ ("ts", `Float ts)
    ; ("alias", `String alias)
    ; ("reason", `String reason) ]

let () =
  Peer_review.set_pin_rotate_unauth_logger
    (fun (event : Peer_review.pin_rotate_unauth_event) ->
      let broker_root = Filename.dirname event.path in
      log_peer_pass_pin_rotate_unauth
        ~broker_root
        ~alias:event.alias
        ~reason:event.reason
        ~ts:event.ts)

(* #432 Slice D: pending-permission decision audit log. Two events on
   broker.log — [pending_open] (after Broker.open_pending_permission
   succeeds) and [pending_check] (after every check_pending_reply
   outcome decision: valid / invalid_non_supervisor / unknown_perm /
   expired). Closes Finding 5 of the 2026-04-29 audit
   (.collab/research/2026-04-29-stanza-coder-pending-permissions-audit.md):
   today broker.log records {ts, tool, ok} per RPC, so we know *that*
   the call fired but not perm_id, kind, supervisors, requester, or
   outcome — forensics ("who approved what for whom") was impossible.

   Privacy: perm_id and requester_session_id are bearer-shaped (anyone
   who knows the perm_id can call check_pending_reply and read out the
   requester's session_id; Finding 4 hole). Hash both with SHA-256
   truncated to 16 hex chars — collision-free at this volume, still
   correlatable across the open/check pair for the same request.
   Aliases stay plaintext (mcp__c2c__list exposes them anyway).
   kind / outcome / ttl_seconds plaintext — bookkeeping.

   Write path: synchronous, best-effort, swallows all errors.
   Mirrors log_peer_pass_pin_rotate above exactly — failed audit
   write must not break a working pending-reply RPC. Piggybacks on
   broker.log rotation (#61), no new knobs. *)
let short_hash s =
  let h = Digestif.SHA256.digest_string s |> Digestif.SHA256.to_hex in
  String.sub h 0 16

let log_pending_open
    ~broker_root ~perm_id ~kind ~requester_session_id ~requester_alias
    ~supervisors ~ttl_seconds ~ts =
  log_broker_event ~broker_root "pending_open"
    [ ("ts", `Float ts)
    ; ("perm_id_hash", `String (short_hash perm_id))
    ; ("kind", `String kind)
    ; ("requester_session_hash", `String (short_hash requester_session_id))
    ; ("requester_alias", `String requester_alias)
    ; ("supervisors", `List (List.map (fun s -> `String s) supervisors))
    ; ("ttl_seconds", `Float ttl_seconds) ]

let log_pending_check
    ~broker_root ~perm_id ~outcome ~reply_from_alias
    ?kind ?requester_alias ?requester_session_id ?supervisors ~ts () =
  let base =
    [ ("ts", `Float ts)
    ; ("perm_id_hash", `String (short_hash perm_id))
    ; ("reply_from_alias", `String reply_from_alias)
    ; ("outcome", `String outcome) ]
  in
  let with_kind = match kind with
    | Some k -> base @ [ ("kind", `String k) ] | None -> base
  in
  let with_alias = match requester_alias with
    | Some a -> with_kind @ [ ("requester_alias", `String a) ]
    | None -> with_kind
  in
  let with_session = match requester_session_id with
    | Some sid ->
        with_alias @ [ ("requester_session_hash", `String (short_hash sid)) ]
    | None -> with_alias
  in
  let fields = match supervisors with
    | Some sups ->
        with_session @ [ ("supervisors", `List (List.map (fun s -> `String s) sups)) ]
    | None -> with_session
  in
  log_broker_event ~broker_root "pending_check" fields

(* Coord-backup fallthrough audit log
   (slice/coord-backup-fallthrough). Emits one
   [event=coord_fallthrough_fired] line per fired tier. Schema:
     ts                : float (unix seconds)
     event             : "coord_fallthrough_fired"
     perm_id_hash      : 16-hex truncation of SHA256(perm_id) — same
                         discipline as #432 Slice D
     tier              : 1 = backup1 DM'd, 2 = backup2 DM'd,
                         broadcast tier carries [tier = N+1] where N
                         is len(chain) - 1
     primary_alias     : the chain[0] entry that was supposed to answer
     backup_alias      : the alias DM'd this tier ("<broadcast>" for
                         the swarm-lounge broadcast tier)
     requester_alias   : the original opener of the pending entry
     elapsed_s         : seconds from open_pending_reply to this fire
   Best-effort write; mirrors [log_pending_open] / [log_nudge_tick]
   exactly so a failed audit write never breaks the scheduler. *)
let log_coord_fallthrough_fired
    ~broker_root ~perm_id ~tier ~primary_alias ~backup_alias
    ~requester_alias ~elapsed_s ~ts =
  log_broker_event ~broker_root "coord_fallthrough_fired"
    [ ("ts", `Float ts)
    ; ("perm_id_hash", `String (short_hash perm_id))
    ; ("tier", `Int tier)
    ; ("primary_alias", `String primary_alias)
    ; ("backup_alias", `String backup_alias)
    ; ("requester_alias", `String requester_alias)
    ; ("elapsed_s", `Float elapsed_s) ]

let notify_shared_with_recipients
    ~broker ~from_alias ~name ?description ~shared ~shared_with () =
  if shared && shared_with <> [] then []
  else
    let descr_suffix = match description with
      | Some d when d <> "" -> Printf.sprintf " — %s" d
      | _ -> ""
    in
    let msg = Printf.sprintf
      "memory shared with you: .c2c/memory/%s/%s.md (from %s)%s"
      from_alias name from_alias descr_suffix
    in
    let broker_root = Broker.root broker in
    let enqueue_rejected_prefix = "enqueue_message rejected:" in
    List.filter_map
      (fun recipient ->
        if recipient = from_alias then None
        else
          try
            (* #307b: handoff DMs are non-deferrable (push-immediately).
               The substrate-reaches-back behavior depends on the recipient
               seeing the path as soon as the entry is saved; deferrable
               would require an explicit poll_inbox to surface it. *)
            Broker.enqueue_message broker
              ~from_alias ~to_alias:recipient
              ~content:msg ~deferrable:false ();
            log_handoff_attempt ~broker_root ~from_alias
              ~to_alias:recipient ~name ~ok:true ~error:None;
            Some recipient
          with Invalid_argument err_msg
                 when String.length err_msg >= String.length enqueue_rejected_prefix
                   && String.sub err_msg 0 (String.length enqueue_rejected_prefix)
                        = enqueue_rejected_prefix ->
            (* #silent-send Bug 3 regression guard: enqueue_message now raises
               for unknown local aliases. For cross-host memory handoff (#286),
               unknown aliases must still reach the relay outbox. Fall back
               explicitly so the handoff path is preserved. *)
            (try
               C2c_relay_connector.append_outbox_entry broker_root
                 ~from_alias ~to_alias:recipient ~content:msg ();
               log_handoff_attempt ~broker_root ~from_alias
                 ~to_alias:recipient ~name ~ok:true ~error:None;
               Some recipient
             with relay_err ->
               log_handoff_attempt ~broker_root ~from_alias
                 ~to_alias:recipient ~name ~ok:false
                 ~error:(Some (Printexc.to_string relay_err));
               None)
          | e ->
            log_handoff_attempt ~broker_root ~from_alias
              ~to_alias:recipient ~name ~ok:false
              ~error:(Some (Printexc.to_string e));
            None)
      shared_with

let channel_notification ?(role : string option = None) ?(with_reply_hint = true) ({ from_alias; to_alias; content; ts; _ } : message) =
  (* The meta JSON keys here are rendered by Claude Code as XML
     attributes on the `<channel …>` tag in the agent transcript.
     They are deliberately named `from` / `to` (not `from_alias` /
     `to_alias`) because the transcript-visible reading is "the
     sender" and "the recipient" — agents misread `to_alias=` as
     a sender field on 2026-04-29. The internal record fields
     remain `from_alias` / `to_alias`; only this serialization
     uses the short attribute names. The `ts` field gives UTC HH:MM
     of the message timestamp, making blocked-agent elapsed-time
     visible in the `<channel …>` tag. *)
  let ts_str = format_ts_hhmm ts in
  let meta =
    let base = [ ("from", `String from_alias); ("to", `String to_alias); ("ts", `String ts_str) ] in
    match role with
    | Some r -> base @ [ ("role", `String r) ]
    | None   -> base
  in
  (* Reply-hint (Slice F of the 2026-06-18 design): the channel
     notification is LLM-visible by definition — Claude Code renders
     the [content] field as the body of a <channel source="c2c"> tag
     in the agent's transcript. Without the hint, agents may reply
     in plain text and the sender never sees the reply. The hint
     uses the same shape as [C2c_mcp.format_reply_hint], so push
     and drain paths look identical to the agent. The hint
     mentions only [c2c_send] / [c2c_send_room]; clients that need
     a client-specific tool name (e.g. pi-c2c's [c2c_pi_send])
     suppress or override locally. *)
  let content_with_hint =
    if with_reply_hint
    then content ^ "\n" ^ C2c_mcp_helpers.format_reply_hint ~from:from_alias ~to_alias ()
    else content
  in
  `Assoc
    [ ("jsonrpc", `String "2.0")
    ; ("method", `String "notifications/claude/channel")
    ; ( "params",
        `Assoc
          [ ("content", `String content_with_hint)
          ; ("meta", `Assoc meta)
          ] )
    ]

(** [#432 §7] Unified envelope-decrypt helper. Two pre-#432 call sites
    (`decrypt_message_for_push` for the channel-notification push path,
    and the inline [process_msg] inside [poll_inbox]) implemented the
    same plain / box-x25519-v1 decrypt+verify+pin flow with only one
    observable difference: poll_inbox tracked an [enc_status] tuple
    field, push discarded it. Lifting them to one helper that returns
    the tuple eliminates the bug-fix surface where any envelope-format
    change had to be edited twice. The push site discards the status.

    Behavior is byte-equivalent to the prior poll_inbox block (the
    more-detailed of the two — Failed / Key_changed / Not_for_me). The
    push site's observable output is unchanged because it only reads
    the content; the previously-thrown-away "redundant case" in the
    push block (decrypt_for_me=None + sender_x25519_pk=Some had two
    arms both returning content, tripping Warning 11) is replaced by
    the poll_inbox shape's pinned-mismatch-returns-content-with-Key_changed.
    Push still observes content; status is dropped at the call site.

    Side-effects preserved: [Broker.set_downgrade_state] always fires
    on a parseable envelope (both blocks did this); [pin_x25519_sync]
    fires on the success path (both blocks did this). *)
let decrypt_envelope ~(our_x25519 : Relay_enc.t option) ~our_ed25519
    ~(to_alias : string) ~(content : string) : string * string option =
  let _ = our_ed25519 in
  (* our_ed25519's only role is to gate the box-x25519-v1 path on
     "we have a signing identity loaded"; the actual sig-verify uses
     the SENDER's pinned ed25519 pubkey, so the local identity isn't
     dereferenced. The pattern below matches `Some _ed25519` to
     enforce the gate without consuming the value. *)
  match Yojson.Safe.from_string content with
  | exception _ -> content, None
  | env_json ->
    match Relay_e2e.envelope_of_json env_json with
    | Error _ -> content, None
    | Ok env ->
      (* Slice B-min-version: per-alias minimum-observed-envelope-version
         policy check. Fires BEFORE sig-verify dispatch so a downgraded
         envelope (attacker rewriting envelope_version=2 → 1 to bypass
         CRIT-1+B canonical-blob coverage) is rejected with a forensic
         audit-log line attributable to the policy, not silent
         sig-mismatch. Default-open: peers we've never received a v2
         envelope from carry no min-version pin and proceed normally;
         the pin floor is set by [bump_min_observed_version] AFTER
         every successful verify in the box-x25519-v1 path below. *)
      (match Broker.check_version_downgrade ~alias:env.from_ ~observed:env.envelope_version with
       | Some pinned_min ->
         (match Broker.get_relay_pins_root () with
          | Some broker_root ->
            log_version_downgrade_rejected
              ~broker_root
              ~alias:env.from_
              ~observed:env.envelope_version
              ~pinned_min
              ~ts:(Unix.gettimeofday ())
          | None -> ());
         content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Version_downgrade)
       | None ->
      let ds = Broker.get_downgrade_state env.from_ in
      let (status, ds) = Relay_e2e.decide_enc_status ds env in
      Broker.set_downgrade_state env.from_ ds;
      match env.enc with
      | "plain" ->
        (match Relay_e2e.find_my_recipient ~my_alias:to_alias env.recipients with
         | Some r -> r.ciphertext, Some (Relay_e2e.enc_status_to_string status)
         | None -> content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Not_for_me))
      | "box-x25519-v1" ->
        (match our_x25519, our_ed25519 with
         | Some x25519, Some _ed25519 ->
            (match Relay_e2e.find_my_recipient ~my_alias:to_alias env.recipients with
             | None -> content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Not_for_me)
             | Some recipient ->
               (match recipient.nonce with
                | None -> content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Failed)
                | Some nonce_b64 ->
                  let sender_x25519_pk = env.from_x25519 in
                  (match Relay_e2e.decrypt_for_me
                    ~ct_b64:recipient.ciphertext
                    ~nonce_b64
                    ~sender_pk_b64:(match sender_x25519_pk with Some pk -> pk | None -> "")
                    ~our_sk_seed:x25519.private_key_seed with
                   | None ->
                     (match sender_x25519_pk with
                      | Some pk ->
                        let pinned = Broker.get_pinned_x25519 env.from_ in
                        if pinned <> None && pinned <> Some pk then
                          content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Key_changed)
                        else
                          content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Failed)
                      | None -> content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Failed))
                   | Some pt ->
                      (* Slice B (CRIT-2): Ed25519 TOFU on first-contact.
                         Pin store holds Ed25519 pubkeys as b64url strings
                         (matching producer pin_ed25519_sync convention).
                         Verify key must be 32 raw bytes — decode at the
                         boundary. Claimed [from_ed25519] (v2 envelope)
                         takes precedence over pinned for verify; pinned
                         is the legacy-v1 fallback when the envelope
                         carries no claim. *)
                      let claimed_ed25519_b64 = env.from_ed25519 in
                      let pinned_ed25519_b64 = Broker.get_pinned_ed25519 env.from_ in
                      let mismatch =
                        match pinned_ed25519_b64, claimed_ed25519_b64 with
                        | Some p, Some c -> p <> c
                        | _ -> false
                      in
                      if mismatch then begin
                        (* Slice B follow-up: structured audit-log line on
                           every Ed25519 pin mismatch reject. Mirrors
                           [version_downgrade_rejected] from B-min-version.
                           Closes slate's flagged observability gap from
                           the Slice B PASS — the security invariant
                           (reject + pin-unchanged + no plaintext leak) was
                           already enforced and surfaced via [enc_status:
                           "key-changed"], but operators had no broker.log
                           line to correlate suspected attacks. *)
                        (match Broker.get_relay_pins_root (),
                               pinned_ed25519_b64, claimed_ed25519_b64 with
                         | Some broker_root, Some pinned, Some claimed ->
                           log_relay_e2e_pin_mismatch
                             ~broker_root
                             ~alias:env.from_
                             ~pinned_ed25519_b64:pinned
                             ~claimed_ed25519_b64:claimed
                             ~ts:(Unix.gettimeofday ())
                         | _ -> ());
                        content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Key_changed)
                      end else
                        let try_decode b64 =
                          match Relay_e2e.b64_decode b64 with
                          | Ok raw when String.length raw = 32 -> Some raw
                          | _ -> None
                        in
                        let verify_pk_raw_opt =
                          match claimed_ed25519_b64 with
                          | Some b64 -> try_decode b64
                          | None ->
                            (match pinned_ed25519_b64 with
                             | Some b64 -> try_decode b64
                             | None -> None)
                        in
                        (match verify_pk_raw_opt with
                         | None ->
                           content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Failed)
                         | Some pk ->
                           let sig_ok = Relay_e2e.verify_envelope_sig ~pk env in
                           if not sig_ok then
                             content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Key_changed)
                           else (
                             (* TOFU first-contact: pin claimed Ed25519 if
                                no existing pin and the envelope carried a
                                claim. Skip when pin already exists (no-op
                                same-key, mismatch already rejected above)
                                or when no claim was present (legacy v1). *)
                             (match pinned_ed25519_b64, claimed_ed25519_b64 with
                              | None, Some claimed_b64 ->
                                Broker.pin_ed25519_sync ~alias:env.from_ ~pk:claimed_b64 |> ignore;
                                (match Broker.get_relay_pins_root () with
                                 | Some broker_root ->
                                   log_relay_e2e_pin_first_seen
                                     ~broker_root
                                     ~alias:env.from_
                                     ~pinned_ed25519_b64:claimed_b64
                                     ~ts:(Unix.gettimeofday ())
                                 | None -> ())
                              | _ -> ());
                             (match sender_x25519_pk with
                              | Some pk -> Broker.pin_x25519_sync ~alias:env.from_ ~pk |> ignore
                              | None -> ());
                             (* Slice B-min-version: bump per-alias min
                                pin after every successful verify. Sets
                                the floor for subsequent receives to
                                close the downgrade window from THIS
                                envelope's [envelope_version] forward. *)
                             let _ = Broker.bump_min_observed_version
                               ~alias:env.from_
                               ~observed:env.envelope_version
                             in
                             pt, Some (Relay_e2e.enc_status_to_string status))))))
         | _ -> content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Failed))
      | _ -> content, None)

let decrypt_message_for_push (msg : message) ~alias =
  let our_x25519 = match Relay_enc.load_or_generate ~alias () with Ok k -> Some k | Error _ -> None in
  let our_ed25519 = Some (Broker.load_or_create_ed25519_identity ()) in
  let { to_alias; content; _ } = msg in
  let (decrypted_content, _enc_status) =
    decrypt_envelope ~our_x25519 ~our_ed25519 ~to_alias ~content
  in
  { msg with content = decrypted_content }

let room_member_detail_json (detail : Broker.room_member_info) =
  `Assoc
    [ ("alias", `String detail.rmi_alias)
    ; ("session_id", `String detail.rmi_session_id)
    ; ( "alive",
        match detail.rmi_alive with
        | Some value -> `Bool value
        | None -> `Null )
    ]

let room_info_json (r : Broker.room_info) =
  `Assoc
    [ ("room_id", `String r.ri_room_id)
    ; ("member_count", `Int r.ri_member_count)
    ; ("members", `List (List.map (fun a -> `String a) r.ri_members))
    ; ("alive_member_count", `Int r.ri_alive_member_count)
    ; ("dead_member_count", `Int r.ri_dead_member_count)
    ; ("unknown_member_count", `Int r.ri_unknown_member_count)
    ; ("member_details", `List (List.map room_member_detail_json r.ri_member_details))
    ; ("visibility",
        match r.ri_visibility with
        | Public -> `String "public"
        | Unlisted -> `String "unlisted"
        | Gated -> `String "gated"
        | Private -> `String "private")
    ; ("invited_members", `List (List.map (fun a -> `String a) r.ri_invited_members))
    ]
(* Required-string variant: raises [Invalid_argument] on missing or
   wrong-typed field. The pure option-returning equivalent lives in
   [Json_util.string_member]; this wrapper adds the strict
   raise-on-missing semantic that JSON-RPC tool dispatchers want. Audit
   #388 — single source of truth for the option-returning side. *)
let string_member name json =
  let open Yojson.Safe.Util in
  match json |> member name with
  | `String s -> s
  | `Null ->
      invalid_arg
        (Printf.sprintf "missing required string argument '%s'" name)
  | other ->
      invalid_arg
        (Printf.sprintf
           "argument '%s' must be a string, got %s"
           name
           (match other with
            | `Int _ -> "int"
            | `Float _ -> "float"
            | `Bool _ -> "bool"
            | `List _ -> "array"
            | `Assoc _ -> "object"
            | `Null -> "null"
            | _ -> "other"))

(* Like [string_member] but accepts a list of candidate argument names
   and picks the first one that is present and non-empty. Used for
   send / send_all / send_room where OpenCode's model frequently
   substitutes [alias] for [from_alias] because [join_room] takes
   [alias]. Keeps existing [from_alias] callers working while
   unblocking opencode round-trips. *)
let string_member_any names json =
  let open Yojson.Safe.Util in
  let rec find = function
    | [] ->
        (match names with
         | [] -> invalid_arg "string_member_any: no candidate names"
         | [ first ] ->
             invalid_arg
               (Printf.sprintf "missing required string argument '%s'" first)
         | first :: rest ->
             invalid_arg
               (Printf.sprintf
                  "missing required string argument '%s' (or alternatives: %s)"
                  first
                  (String.concat ", " rest)))
    | name :: rest ->
        (match json |> member name with
         | `Null -> find rest
         | value ->
             (try
                let text = to_string value in
                if String.trim text = "" then find rest else text
              with _ -> find rest))
  in
  find names

(* Option-returning variant with trim-to-None semantics. Defers to
   [Json_util.string_member] for the pure accessor; this thin wrapper
   adds the "treat whitespace-only as missing" policy that tool
   dispatchers expect. Audit #388 — converged with [c2c_start.ml]'s
   former local copy via [Json_util]. *)
let optional_string_member name json =
  match Json_util.string_member name json with
  | Some text when String.trim text <> "" -> Some text
  | _ -> None

let optional_member name json =
  let open Yojson.Safe.Util in
  try
    match json |> member name with
    | `Null -> None
    | value -> Some value
  with _ -> None

(* Lenient bool extraction from a Yojson value. JSON-RPC clients vary in
   coercion behavior — some send `Bool b`, some send `String "true"` /
   `String "false"` (especially shell-based callers piping CLI args), some
   send `Int 0`/`Int 1`. Returns [None] for anything else (including the
   ambiguous `String "yes"`, `Float 1.0`, etc.) so callers can choose to
   error or apply a documented default. *)
let bool_of_arg : Yojson.Safe.t -> bool option = function
  | `Bool b -> Some b
  | `String s ->
      (match String.lowercase_ascii (String.trim s) with
       | "true" -> Some true
       | "false" -> Some false
       | _ -> None)
  | `Int 1 -> Some true
  | `Int 0 -> Some false
  | _ -> None

let first_nonempty_env keys =
  let rec loop = function
    | [] -> None
    | key :: rest ->
        (match Sys.getenv_opt key with
         | Some value ->
             let trimmed = String.trim value in
             if trimmed = "" then loop rest else Some trimmed
         | None -> loop rest)
  in
  loop keys

(* CLAUDE_SESSION_ID is the historical Claude Code export; current Claude Code
   (>= v2.1.x) exports CLAUDE_CODE_SESSION_ID into Bash-tool environments
   instead. Keep the legacy key FIRST so it still wins when both are set
   (back-compat with wrappers that set CLAUDE_SESSION_ID explicitly). *)
let native_session_id_env_keys = function
  | "claude" -> [ "CLAUDE_SESSION_ID"; "CLAUDE_CODE_SESSION_ID" ]
  | "codex" -> [ "CODEX_THREAD_ID" ]
  | "opencode" -> [ "C2C_OPENCODE_SESSION_ID" ]
  | "grok" -> [ "GROK_SESSION_ID" ]
  (* Antigravity (agy): conversation id is the stable session key hooks use. *)
  | "agy" -> [ "ANTIGRAVITY_CONVERSATION_ID" ]
  (* Kimi Code: managed `c2c start kimi` exports KIMI_SESSION_ID; unmanaged
     sessions usually lack it and resolve via session_index (B233). *)
  | "kimi" -> [ "KIMI_SESSION_ID" ]
  | "crush" | "codex-headless" | "cursor" -> []
  | _ -> []

let truthy_env_flag = function
  | Some v ->
      let v = String.lowercase_ascii (String.trim v) in
      v <> "" && not (List.mem v [ "0"; "false"; "no" ])
  | None -> false

(* --- process ancestry --------------------------------------------------- *)

let read_ppid pid =
  try
    let ic = open_in (Printf.sprintf "/proc/%d/status" pid) in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let rec loop () =
        match input_line ic with
        | line when String.length line >= 5 && String.sub line 0 5 = "PPid:" ->
            int_of_string_opt (String.trim (String.sub line 5 (String.length line - 5)))
        | _ -> loop ()
        | exception End_of_file -> None
      in
      loop ())
  with _ -> None

let ancestor_pids ?(max_depth = 32) start_pid =
  let rec walk pid depth acc =
    if depth <= 0 || pid <= 1 then List.rev acc
    else
      match read_ppid pid with
      | None -> List.rev (pid :: acc)
      | Some ppid -> walk ppid (depth - 1) (pid :: acc)
  in
  walk start_pid max_depth []

(* /proc/<pid>/comm is the 15-char-truncated process name; "cursor-agent"
   (12 chars) survives truncation. *)
let read_proc_comm pid =
  try
    let ic = open_in (Printf.sprintf "/proc/%d/comm" pid) in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      match input_line ic with
      | line -> Some (String.trim line)
      | exception End_of_file -> None)
  with _ -> None

(* /proc/<pid>/cmdline is NUL-separated argv; in_channel_length reports 0 for
   procfs, so read the bytes directly and take the basename of argv0. This
   recovers the real program name when comm was rewritten (e.g. a node-based
   cursor-agent whose comm is "node"). *)
let proc_cmdline_argv0_basename pid =
  try
    let ic = open_in_bin (Printf.sprintf "/proc/%d/cmdline" pid) in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let buf = Buffer.create 256 in
      let chunk = Bytes.create 4096 in
      let rec loop () =
        let n = input ic chunk 0 4096 in
        if n > 0 then (Buffer.add_subbytes buf chunk 0 n; loop ())
      in
      loop ();
      let content = Buffer.contents buf in
      let argv0 =
        match String.index_opt content '\000' with
        | Some i -> String.sub content 0 i
        | None -> content
      in
      let argv0 = String.trim argv0 in
      if argv0 = "" then None else Some (Filename.basename argv0))
  with _ -> None

(* Ancestor process command names, most-recent-first. Test seam: when
   C2C_DETECT_ANCESTOR_COMMS is set (colon-separated), it stands in for the
   walked ancestor names so process-based detection is hermetic (mirrors the
   C2C_GROK_ACTIVE_SESSIONS override pattern). *)
let ancestor_command_names () =
  match Sys.getenv_opt "C2C_DETECT_ANCESTOR_COMMS" with
  | Some s when String.trim s <> "" ->
      String.split_on_char ':' s
      |> List.filter_map (fun x ->
             let x = String.trim x in
             if x = "" then None else Some x)
  | _ ->
      let pids = ancestor_pids (Unix.getpid ()) in
      List.concat_map
        (fun pid ->
          (match read_proc_comm pid with Some c -> [ c ] | None -> [])
          @ (match proc_cmdline_argv0_basename pid with Some b -> [ b ] | None -> []))
        pids

(* B288: some cursor-agent invocation contexts do not export CURSOR_* env
   markers (measured live: PATH-visible cursor-agent, no CURSOR_AGENT), so env
   inference alone mislabels the session. The parent process chain still names
   cursor-agent — specific, unambiguous evidence that wins even when several
   agent CLIs share the PATH (where PATH-uniqueness must fail closed). Match the
   basename "cursor-agent" exactly (not bare "cursor", which would also catch
   the unrelated Cursor editor binary). *)
let cursor_agent_process_ancestor () =
  List.exists
    (fun name ->
      let b = Filename.basename (String.trim name) in
      b = "cursor-agent")
    (ancestor_command_names ())

(* Cursor Agent (unofficial / best-effort — B134 labeling + B284 session id):
   not a first-class install/hooks client, but must not be mislabeled as Codex
   when CURSOR_AGENT / CURSOR_INVOKED_AS markers are present, and should resolve
   a stable session id from Cursor-native signals when available. *)
let cursor_agent_env_present () =
  truthy_env_flag (Sys.getenv_opt "CURSOR_AGENT")
  ||
  match Sys.getenv_opt "CURSOR_INVOKED_AS" with
  | Some v when String.lowercase_ascii (String.trim v) = "cursor-agent" -> true
  | _ -> false

(* Parse CURSOR_ASKPASS_SOCKET=/tmp/cursor-askpass-<token>.sock → <token>.
   Live Cursor Agent shells export this; the token is stable for the agent
   conversation and is the best native session key we have (B284). *)
let cursor_askpass_token_from_socket_path path =
  let base = Filename.basename (String.trim path) in
  let prefix = "cursor-askpass-" in
  let suffix = ".sock" in
  let bl = String.length base in
  let pl = String.length prefix in
  let sl = String.length suffix in
  if bl > pl + sl
     && String.sub base 0 pl = prefix
     && String.sub base (bl - sl) sl = suffix
  then
    let token = String.sub base pl (bl - pl - sl) in
    if token = "" then None else Some token
  else None

let session_id_from_cursor_askpass () =
  match Sys.getenv_opt "CURSOR_ASKPASS_SOCKET" with
  | Some path when String.trim path <> "" ->
      (match cursor_askpass_token_from_socket_path path with
       | Some token -> Some ("cursor-askpass-" ^ token)
       | None -> None)
  | _ -> None

(* Grok Build TUI tool shells export GROK_AGENT (often "1") but do NOT export
   GROK_SESSION_ID — that key is hook-process-only. Treat any non-falsey
   GROK_AGENT as a client-type marker so init/whoami/statusline detect Grok
   without a session-id key (B173). *)
let grok_agent_env_present () = truthy_env_flag (Sys.getenv_opt "GROK_AGENT")

(* Antigravity (agy) tool shells / hooks export ANTIGRAVITY_* markers. Without
   these, an agy shell can fall through to a broker statefile or AUTO_REGISTER
   alias from another client and present that identity as success (B187). *)
let agy_env_present () =
  first_nonempty_env
    [ "ANTIGRAVITY_CONVERSATION_ID"; "ANTIGRAVITY_HOOK_EVENT"; "ANTIGRAVITY_LS_ADDRESS" ]
  <> None

let inferred_client_type_from_env () =
  match first_nonempty_env [ "C2C_MCP_CLIENT_TYPE" ] with
  | Some client_type -> Some client_type
  | None ->
      (* Prefer genuine harness-native session keys over unofficial Cursor
         markers so CODEX_THREAD_ID / Claude / OpenCode / Grok still win. *)
      if first_nonempty_env [ "CODEX_THREAD_ID" ] <> None then Some "codex"
      else if first_nonempty_env [ "CLAUDE_SESSION_ID"; "CLAUDE_CODE_SESSION_ID" ] <> None then Some "claude"
      else if first_nonempty_env [ "C2C_OPENCODE_SESSION_ID" ] <> None then Some "opencode"
      else if first_nonempty_env [ "GROK_SESSION_ID" ] <> None then Some "grok"
      else if grok_agent_env_present () then Some "grok"
      else if agy_env_present () then Some "agy"
      else if cursor_agent_env_present () then Some "cursor"
      (* B288: no env marker matched — fall back to process ancestry so a
         cursor-agent session with no CURSOR_* env still self-labels cursor.
         Kept last so every genuine harness-native marker wins first. *)
      else if cursor_agent_process_ancestor () then Some "cursor"
      else None

(* Grok tool shells lack GROK_SESSION_ID. Resolve the live session by matching
   an ancestor pid against ~/.grok/active_sessions.json (written by the TUI).
   Override path via C2C_GROK_ACTIVE_SESSIONS for tests. *)
let grok_active_sessions_path () =
  match Sys.getenv_opt "C2C_GROK_ACTIVE_SESSIONS" with
  | Some p when String.trim p <> "" -> String.trim p
  | _ ->
      let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
      Filename.concat home (Filename.concat ".grok" "active_sessions.json")

let session_id_from_grok_active_sessions () =
  let path = grok_active_sessions_path () in
  if not (Sys.file_exists path) then None
  else
    match (try Some (Yojson.Safe.from_file path) with _ -> None) with
    | Some (`List entries) ->
        let ancestors = ancestor_pids (Unix.getpid ()) in
        let matches =
          List.filter_map
            (function
              | `Assoc fields ->
                  let sid =
                    match List.assoc_opt "session_id" fields with
                    | Some (`String s) when String.trim s <> "" ->
                        Some (String.trim s)
                    | _ -> None
                  in
                  let pid =
                    match List.assoc_opt "pid" fields with
                    | Some (`Int p) -> Some p
                    | Some (`Intlit s) -> int_of_string_opt s
                    | Some (`Float f) -> Some (int_of_float f)
                    | _ -> None
                  in
                  (match sid, pid with
                   | Some sid, Some pid when List.mem pid ancestors -> Some sid
                   | _ -> None)
              | _ -> None)
            entries
        in
        (match matches with
         | [ sid ] -> Some sid
         | sid :: _ -> Some sid (* multiple rare; first listed is fine *)
         | [] -> None)
    | _ -> None

(* B233: Kimi Code does not inject a per-session id into mcp.json env (one
   global ~/.kimi-code/mcp.json serves every session). SessionStart hooks
   register the real Kimi session id (`session_<uuid>`) from the hook payload;
   MCP must resolve the same id so whoami/send land on the hook identity.

   Discovery mirrors C2c_kimi_deliver.session_id_for_workdir (kept local to
   avoid a module cycle with post_broker ↔ c2c_mcp ↔ kimi_deliver):
   read ~/.kimi-code/session_index.jsonl and pick the most recent entry whose
   workDir matches this process cwd. Override home via KIMI_CODE_HOME. *)
let kimi_code_home_for_session_index () =
  match Sys.getenv_opt "KIMI_CODE_HOME" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
      let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
      Filename.concat home ".kimi-code"

let kimi_session_index_path () =
  Filename.concat (kimi_code_home_for_session_index ()) "session_index.jsonl"

let session_id_from_kimi_session_index ?workdir () =
  let workdir =
    match workdir with
    | Some w ->
        let w = String.trim w in
        if w <> "" then w else (try Sys.getcwd () with Sys_error _ -> "")
    | None -> (try Sys.getcwd () with Sys_error _ -> "")
  in
  if workdir = "" then None
  else
    let path = kimi_session_index_path () in
    if not (Sys.file_exists path) then None
    else
      let entries =
        try
          let ic = open_in path in
          Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
            let rec loop acc =
              match input_line ic with
              | line ->
                  let parsed =
                    try
                      match Yojson.Safe.from_string line with
                      | `Assoc fields ->
                          let sid =
                            match List.assoc_opt "sessionId" fields with
                            | Some (`String s) when String.trim s <> "" ->
                                Some (String.trim s)
                            | _ -> None
                          in
                          let wd =
                            match List.assoc_opt "workDir" fields with
                            | Some (`String s) -> String.trim s
                            | _ -> ""
                          in
                          let updated =
                            match List.assoc_opt "updated_at" fields with
                            | Some (`String s) -> String.trim s
                            | _ -> ""
                          in
                          (match sid with
                           | Some sid when wd = workdir -> Some (sid, updated)
                           | _ -> None)
                      | _ -> None
                    with _ -> None
                  in
                  (match parsed with
                   | Some row -> loop (row :: acc)
                   | None -> loop acc)
              | exception End_of_file -> acc
            in
            loop [])
        with _ -> []
      in
      match entries with
      | [] -> None
      | _ ->
          (* Prefer non-empty updated_at (newest first); else last append for
             this workdir — session_index.jsonl is append-only. *)
          let with_ts, without_ts =
            List.partition (fun (_, ts) -> ts <> "") entries
          in
          let sorted =
            List.sort (fun (_, a) (_, b) -> String.compare b a) with_ts
          in
          (match sorted with
           | (sid, _) :: _ -> Some sid
           | [] ->
               (match without_ts with
                | (sid, _) :: _ -> Some sid
                | [] -> None))

let session_id_from_env ?client_type () =
  match first_nonempty_env [ "C2C_MCP_SESSION_ID" ] with
  | Some session_id ->
      if debug_enabled then Printf.eprintf "[DEBUG session_id_from_env] found C2C_MCP_SESSION_ID=%s\n%!" session_id;
      Some session_id
  | None ->
      let resolved_client_type =
        match client_type with
        | Some kind when String.trim kind <> "" -> Some (String.trim kind)
        | _ -> inferred_client_type_from_env ()
      in
      let fallback_keys =
        match resolved_client_type with
        | Some kind -> native_session_id_env_keys kind
        | None -> []
      in
      (match first_nonempty_env fallback_keys with
       | Some _ as sid -> sid
       | None ->
           (* B173: Grok tool shells export GROK_AGENT but not GROK_SESSION_ID. *)
           let want_grok =
             match resolved_client_type with
             | Some "grok" -> true
             | _ -> grok_agent_env_present ()
           in
           if want_grok then session_id_from_grok_active_sessions ()
           else
             (* B233: Kimi MCP has no per-session C2C_MCP_SESSION_ID in the
                global mcp.json; resolve via session_index for this cwd. *)
             let want_kimi =
               match resolved_client_type with
               | Some "kimi" -> true
               | _ -> false
             in
             if want_kimi then session_id_from_kimi_session_index ()
             else
               (* B284: Cursor Agent has no harness session env; derive from
                  CURSOR_ASKPASS_SOCKET when present. *)
               let want_cursor =
                 match resolved_client_type with
                 | Some "cursor" -> true
                 | _ -> cursor_agent_env_present ()
               in
               if want_cursor then session_id_from_cursor_askpass () else None)

let current_session_id () =
  session_id_from_env ()

let managed_instances_dir () =
  match Sys.getenv_opt "C2C_INSTANCES_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
      let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
      Filename.concat home ".local/share/c2c/instances"

let string_field_of_assoc fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" ->
      Some (String.trim value)
  | _ -> None

(* Prefer the durable app-server mapping (codex-session.json). Managed
   `c2c new/start codex` persists the live Codex thread there on discovery
   (B131), while legacy config.json thread fields are written in the same
   pass — both are consulted so CLI whoami and MCP hooks share one map. *)
let managed_session_id_from_codex_session_json ~instance_dir ~thread_id =
  let path = Filename.concat instance_dir "codex-session.json" in
  if not (Sys.file_exists path) then None
  else
    try
      let fields =
        match Yojson.Safe.from_file path with
        | `Assoc assoc -> assoc
        | _ -> []
      in
      match string_field_of_assoc fields "thread_id",
            string_field_of_assoc fields "session_id" with
      | Some tid, Some sid when String.equal tid thread_id -> Some sid
      | _ -> None
    with _ -> None

let managed_session_id_from_codex_config_json ~instance_dir ~broker_root ~thread_id =
  let config_path = Filename.concat instance_dir "config.json" in
  if not (Sys.file_exists config_path) then None
  else
    try
      let fields =
        match Yojson.Safe.from_file config_path with
        | `Assoc assoc -> assoc
        | _ -> []
      in
      let string_field = string_field_of_assoc fields in
      let is_codex_family =
        match string_field "client" with
        | Some ("codex" | "codex-headless") -> true
        | _ -> false
      in
      let broker_matches =
        match string_field "broker_root" with
        | Some root -> String.equal root broker_root
        (* #504 intentionally omits a default broker root from managed
           instance configs so they do not pin a stale fingerprint.
           An omitted value therefore means "this invocation's
           resolver-default broker", not "unmanaged".  Requiring a
           serialized root here made an app-server SessionStart miss
           its own thread mapping and mint a second Codex alias. *)
        | None -> true
      in
      let thread_matches =
        (match string_field "resume_session_id" with
         | Some value -> String.equal value thread_id
         | None -> false)
        || (match string_field "codex_resume_target" with
            | Some value -> String.equal value thread_id
            | None -> false)
      in
      if is_codex_family && broker_matches && thread_matches
      then string_field "session_id"
      else None
    with _ -> None

(* #24: one-shot-per-thread stderr signal for the genuinely dangerous
   ambiguous-and-none-live split-brain state. Guarded behind [debug_enabled]
   AND deduped per thread_id so a per-tool-call hot path never spams. *)
let codex_thread_split_brain_warned : (string, unit) Hashtbl.t = Hashtbl.create 8

(* #24: resolve a Codex thread id to its managed session id. A thread can end
   up mapped by more than one managed instance (split-brain); routing/`whoami`
   MUST agree with whichever identity the live deliver loop is watching, not
   whichever [Sys.readdir] happens to list first. This resolver is a PURE read:
   it consults the broker registry for liveness but never mutates broker state,
   writes files, or registers. Ranking is fully deterministic — liveness tier,
   then newest [registered_at], then lexicographic [session_id] — so identical
   inputs always pick the same winner regardless of readdir order. *)
let managed_session_id_from_codex_thread ~broker_root ~thread_id =
  let instances_dir = managed_instances_dir () in
  if not (Sys.file_exists instances_dir && Sys.is_directory instances_dir) then None
  else
    let entries = try Array.to_list (Sys.readdir instances_dir) with _ -> [] in
    let matches =
      List.filter_map
        (fun name ->
          let instance_dir = Filename.concat instances_dir name in
          if not (Sys.file_exists instance_dir && Sys.is_directory instance_dir) then None
          else
            match managed_session_id_from_codex_session_json ~instance_dir ~thread_id with
            | Some sid -> Some (sid, name)
            | None ->
                (match
                   managed_session_id_from_codex_config_json
                     ~instance_dir ~broker_root ~thread_id
                 with
                 | Some sid -> Some (sid, name)
                 | None -> None))
        entries
    in
    match matches with
    | [] -> None
    | [ (session_id, _) ] ->
        (* Single mapping: keep working even when the session is offline
           (whoami/send for a legitimately-idle managed unit). No broker read,
           no ambiguity — the deterministic winner is trivially itself. *)
        Some session_id
    | _ :: _ :: _ ->
        (* Ambiguous: >=2 instances claim this thread. Rank by liveness so we
           follow whichever identity the live deliver loop is watching. Broker
           access is best-effort and read-only. *)
        let regs =
          try Broker.list_registrations (Broker.create ~root:broker_root)
          with _ -> []
        in
        (* Higher is better. Tier: 2 = alive (live pid / fresh lease),
           1 = pidless Unknown (treated alive by [registration_is_alive]),
           0 = dead or entirely unregistered. *)
        let rank (session_id, _name) =
          let tier, registered_at =
            match
              List.find_opt
                (fun (r : registration) -> r.session_id = session_id)
                regs
            with
            | None -> (0, None)
            | Some r ->
                let tier =
                  match Broker.registration_liveness_state r with
                  | Broker.Alive -> 2
                  | Broker.Unknown -> 1
                  | Broker.Dead -> 0
                in
                (tier, r.registered_at)
          in
          (tier, Option.value registered_at ~default:neg_infinity, session_id)
        in
        (* Strict total order over candidates (distinct session_ids guarantee a
           unique max via the lexicographic final tiebreak): better tier wins,
           then newer [registered_at], then smaller [session_id]. *)
        let better a b =
          let ta, ra, sa = rank a in
          let tb, rb, sb = rank b in
          if ta <> tb then ta > tb
          else if ra <> rb then ra > rb
          else String.compare sa sb < 0
        in
        let winner =
          List.fold_left
            (fun best c -> if better c best then c else best)
            (List.hd matches) (List.tl matches)
        in
        let winner_sid, _ = winner in
        let winner_tier, _, _ = rank winner in
        (* Ambiguous AND no live candidate is the dangerous state: whoami/send
           will pick a deterministic-but-possibly-stale identity. Emit once per
           thread (debug-gated) so operators can spot the split-brain. *)
        if winner_tier = 0
           && debug_enabled
           && not (Hashtbl.mem codex_thread_split_brain_warned thread_id)
        then begin
          Hashtbl.replace codex_thread_split_brain_warned thread_id ();
          Printf.eprintf
            "[DEBUG managed_session_id_from_codex_thread] ambiguous split-brain \
             thread %s: %d managed instances claim it and NONE are live; \
             deterministically picking session %s (#24)\n%!"
            thread_id (List.length matches) winner_sid
        end;
        Some winner_sid

let codex_turn_metadata_session_id params =
  let open Yojson.Safe.Util in
  try
    match params |> member "_meta" |> member "x-codex-turn-metadata" |> member "session_id" with
    | `String value when String.trim value <> "" -> Some (String.trim value)
    | _ -> None
  with _ -> None

let request_session_id_override ~broker_root ~tool_name ~params =
  match tool_name with
  | "register" | "whoami" | "rename" | "debug" | "poll_inbox" | "peek_inbox" | "history" | "my_rooms"
  | "send" | "send_all" | "send_room" | "join_room" | "leave_room" | "send_room_invite" | "set_room_visibility"
  | "open_pending_reply" | "check_pending_reply" | "set_compact" | "clear_compact"
  | "stop_self" ->
      (* Codex does not reliably pass parent env through to MCP subprocesses,
         but it does attach the real thread id on each tools/call request.
         For managed sessions we map that native thread id back to the stable
         c2c instance session_id; otherwise we fall back to the raw thread id. *)
      (match codex_turn_metadata_session_id params with
       | Some thread_id ->
           (match managed_session_id_from_codex_thread ~broker_root ~thread_id with
            | Some session_id -> Some session_id
            | None -> Some thread_id)
       | None -> None)
  | _ -> None

(* Derive a session_id from the alias when C2C_MCP_SESSION_ID is not set.
   Uses alias as-is so the plugin (which reads the same alias from the
   sidecar or env) passes a consistent session_id in MCP tool calls.
   Managed sessions (c2c start) always inherit C2C_MCP_SESSION_ID via env,
   so this fallback only fires for plain opencode runs without that env var. *)
let derived_session_id_from_alias alias = alias

(* B188: sticky alias across broker-fingerprint changes.
   When remote.origin.url appears (or changes), the broker root fingerprint
   switches and a fresh empty broker would otherwise mint a new random alias
   for the same session_id. Before minting, look up session_id under every
   known ~/.c2c/repos/*/broker (and C2C_STATE_HOME / XDG equivalents) and
   reuse the prior sticky alias. *)

type prior_session_hit =
  { broker_root : string
  ; fingerprint : string
  ; registration : registration
  }

let normalize_broker_root path =
  let p = String.trim path in
  if p = "" then ""
  else
    let abs =
      if Filename.is_relative p then Filename.concat (Sys.getcwd ()) p else p
    in
    let len = String.length abs in
    if len > 1 && abs.[len - 1] = '/' then String.sub abs 0 (len - 1) else abs

let find_session_hits_across_brokers ~session_id ?(exclude_roots = []) () =
  if session_id = "" then []
  else
    let excluded =
      List.filter
        (fun r -> r <> "")
        (List.map normalize_broker_root exclude_roots)
    in
    let is_excluded root =
      let n = normalize_broker_root root in
      List.exists (fun e -> e = n) excluded
    in
    let hits = ref [] in
    let consider ~fp ~root =
      if not (is_excluded root) then
        try
          let broker = Broker.create ~root in
          match
            List.find_opt
              (fun (r : registration) -> r.session_id = session_id)
              (Broker.list_registrations broker)
          with
          | Some reg ->
              hits :=
                { broker_root = root; fingerprint = fp; registration = reg }
                :: !hits
          | None -> ()
        with _ -> ()
    in
    (try
       List.iter
         (fun (fp, root) -> consider ~fp ~root)
         (C2c_repo_fp.list_all_broker_roots ())
     with _ -> ());
    (* Optional extra scan dirs (tests / operators), colon-separated. *)
    (match Sys.getenv_opt "C2C_BROKER_SCAN_DIRS" with
     | Some dirs when String.trim dirs <> "" ->
         String.split_on_char ':' (String.trim dirs)
         |> List.iter (fun d ->
                let d = String.trim d in
                if d <> "" then consider ~fp:"scan" ~root:d)
     | _ -> ());
    !hits

let prior_hit_rank (hit : prior_session_hit) =
  let reg = hit.registration in
  let alive = Broker.registration_is_alive reg in
  let has_pid = Option.is_some reg.pid in
  let ts = match reg.registered_at with Some t -> t | None -> 0. in
  (* Higher is better: prefer alive+pid, then alive, then newest. *)
  let tier =
    if alive && has_pid then 3 else if alive then 2 else if has_pid then 1 else 0
  in
  (tier, ts)

let pick_best_prior_session_hit hits =
  match hits with
  | [] -> None
  | _ ->
      Some
        (List.fold_left
           (fun best h ->
             if prior_hit_rank h > prior_hit_rank best then h else best)
           (List.hd hits) (List.tl hits))

(** [Some hit] when [session_id] is already registered on another known broker
    root (excluding [exclude_root] and any other [exclude_roots]). Used by
    auto-register surfaces to keep sticky alias across fingerprint changes. *)
let find_prior_session_across_brokers ~session_id ?exclude_root
    ?(exclude_roots = []) () =
  let exclude_roots =
    match exclude_root with
    | Some r when String.trim r <> "" -> r :: exclude_roots
    | _ -> exclude_roots
  in
  pick_best_prior_session_hit
    (find_session_hits_across_brokers ~session_id ~exclude_roots ())

(** Copy alias-keyed Ed25519 material from [from_root] into [to_root] when the
    destination is missing it. Does not move (old broker stays usable) and
    never overwrites existing destination keys. X25519 keys are global by
    alias under ~/.config/c2c/keys and need no migration. *)
let migrate_alias_ed25519_keys ~from_root ~to_root ~alias =
  if from_root = "" || to_root = "" || alias = "" then 0
  else if normalize_broker_root from_root = normalize_broker_root to_root then 0
  else
    let src_dir = Filename.concat from_root "keys" in
    let dst_dir = Filename.concat to_root "keys" in
    let suffixes = [ ".ed25519"; ".ed25519.ssh"; ".ed25519.ssh.pub" ] in
    let copied = ref 0 in
    List.iter
      (fun sfx ->
        let src = Filename.concat src_dir (alias ^ sfx) in
        let dst = Filename.concat dst_dir (alias ^ sfx) in
        if Sys.file_exists src && not (Sys.file_exists dst) then
          try
            mkdir_p ~mode:0o700 dst_dir;
            let data = C2c_io.read_file src in
            let mode =
              try (Unix.stat src).Unix.st_perm with _ -> 0o600
            in
            let oc = open_out_gen [ Open_wronly; Open_creat; Open_excl ] mode dst in
            (try
               output_string oc data;
               close_out oc
             with e ->
               close_out_noerr oc;
               (try Sys.remove dst with _ -> ());
               raise e);
            incr copied
          with _ -> ())
      suffixes;
    !copied

(** {1 B191: global per-session registration lock}

    The B188 cross-broker sticky-alias scan and the subsequent
    [Broker.register] are not atomic across brokers: two concurrent
    registrations of the same session id under two different broker roots
    (agent runs [cd ../x && c2c ...] and [cd ../y && c2c ...] at the same
    time) both scan, both find nothing, and both mint distinct aliases.
    Per-broker registry flocks cannot see each other.

    This machine-global advisory lock — keyed by session id, following the
    same state-home chain as broker roots so [C2C_STATE_HOME] relocation
    moves it together with the brokers it guards — is held across the
    [scan -> alias choice -> register] critical section on every
    registration surface, making the sequence atomic: the second
    registrant blocks, then observes the first's row and adopts its alias.

    Best-effort: acquisition failure (unwritable lock dir) degrades to the
    unlocked pre-B191 behavior — registration must never hard-fail because
    of the lock.

    NON-REENTRANT: [Unix.lockf] locks do not conflict within one process,
    and an inner unlock drops the outer lock. Never nest two locked
    sections for the same session id in one process. *)

let session_registration_locks_dir () =
  match C2c_repo_fp.c2c_state_home () with
  | Some s -> Filename.concat (Filename.concat s "c2c") "locks"
  | None ->
      (match Sys.getenv_opt "HOME" with
       | Some h when String.trim h <> "" ->
           Filename.concat (Filename.concat (String.trim h) ".c2c") "locks"
       | _ -> Filename.concat (Filename.get_temp_dir_name ()) "c2c-locks")

(** Deterministic lock path for [session_id]. Hashed so arbitrary session
    ids (UUIDs, thread ids, synthesized ids) are always filename-safe. *)
let session_registration_lock_path ~session_id =
  let hex = Digestif.SHA256.(to_hex (digest_string session_id)) in
  Filename.concat
    (session_registration_locks_dir ())
    (Printf.sprintf "session-reg-%s.lock" (String.sub hex 0 16))

(** Acquire the per-session registration lock (blocking). [None] on
    failure — callers proceed unlocked rather than failing registration.
    Fd is [O_CLOEXEC] so shell-outs inside the critical section (e.g.
    [c2c init]'s relay-identity subprocess) never inherit it. *)
let acquire_session_registration_lock ~session_id () =
  try
    let dir = session_registration_locks_dir () in
    mkdir_p ~mode:0o700 dir;
    let fd =
      Unix.openfile
        (session_registration_lock_path ~session_id)
        [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ]
        0o600
    in
    (try
       Unix.lockf fd Unix.F_LOCK 0;
       Some fd
     with e ->
       (try Unix.close fd with _ -> ());
       raise e)
  with _ -> None

let release_session_registration_lock = function
  | None -> ()
  | Some fd ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
      (try Unix.close fd with _ -> ())

(** Closure form. Note: [Stdlib.exit] inside [f] skips the finalizer; the
    kernel releases the lock at process exit, so CLI error paths that
    [exit] under the lock are still safe. *)
let with_session_registration_lock ~session_id f =
  let lock = acquire_session_registration_lock ~session_id () in
  Fun.protect ~finally:(fun () -> release_session_registration_lock lock) f

(** Resolve the alias to use when auto-registering [session_id] on [broker_root].
    Prefers a prior sticky registration for the same session_id on another
    broker fingerprint. Returns [(alias, from_auto_gen, prior_hit_opt)].
    [mint] is only called when no prior sticky alias is available. *)
let resolve_auto_register_alias ~session_id ~broker_root ~mint () =
  match find_prior_session_across_brokers ~session_id ~exclude_root:broker_root () with
  | Some hit ->
      (* Refuse to reclaim an alias that is live under a different session on
         the target broker (hijack guard). Fall back to minting in that case. *)
      let target = Broker.alias_casefold hit.registration.alias in
      let occupied =
        try
          let broker = Broker.create ~root:broker_root in
          List.exists
            (fun (reg : registration) ->
              Broker.alias_casefold reg.alias = target
              && reg.session_id <> session_id
              && Option.is_some reg.pid
              && Broker.registration_is_alive reg)
            (Broker.list_registrations broker)
        with _ -> false
      in
      if occupied then
        let alias, from_auto_gen = mint () in
        (alias, from_auto_gen, None)
      else
        let from_auto_gen =
          match hit.registration.registered_by with
          | Some _ -> true
          | None -> true (* prior sticky was established; treat as auto for blocklist *)
        in
        (hit.registration.alias, from_auto_gen, Some hit)
  | None ->
      let alias, from_auto_gen = mint () in
      (alias, from_auto_gen, None)

(** B191: the common auto-register sequence — [resolve_auto_register_alias]
    -> Ed25519 key migration from the prior broker -> the caller's
    [register] — executed atomically under the per-session registration
    lock so concurrent registrations of one session id across different
    broker roots converge on a single alias. [register] performs the
    actual [Broker.register] (each surface passes different metadata) and
    may [exit] on failure. Returns [(alias, from_auto_gen, prior_hit)]. *)
let locked_sticky_auto_register ~session_id ~broker_root ~mint ~register () =
  with_session_registration_lock ~session_id (fun () ->
      let alias, from_auto_gen, prior_hit =
        resolve_auto_register_alias ~session_id ~broker_root ~mint ()
      in
      (match prior_hit with
       | Some hit ->
           ignore
             (migrate_alias_ed25519_keys ~from_root:hit.broker_root
                ~to_root:broker_root ~alias)
       | None -> ());
      register ~alias ~from_auto_gen;
      (alias, from_auto_gen, prior_hit))

let auto_register_alias () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let auto_register_alias_from_auto_gen () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN" with
  | Some value when String.trim value = "1" -> true
  | _ -> false

  let current_client_pid () =
    match Sys.getenv_opt "C2C_MCP_CLIENT_PID" with
    | Some value ->
        let trimmed = String.trim value in
        if trimmed = "" then None
        else if trimmed = "0" then
          (* Test-harness sentinel: C2C_MCP_CLIENT_PID="0" is set before the
             subprocess PID is known (race in some test runners). Fall back to
             the real PID so registration still gets a valid lease. *)
          Some (Unix.getpid ())
        else
          (try
             let pid = int_of_string trimmed in
             if pid > 0 && Sys.file_exists (Printf.sprintf "/proc/%d" pid)
             then Some pid
             else None
           with _ -> None)
    | None -> None

let current_client_type () =
  match Sys.getenv_opt "C2C_MCP_CLIENT_TYPE" with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let current_plugin_version () =
  match Sys.getenv_opt "C2C_MCP_PLUGIN_VERSION" with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let pending_channel_test_code : string option ref = ref None

let pop_channel_test_code () =
  let value = !pending_channel_test_code in
  pending_channel_test_code := None;
  value

(* B119: any same-session hook auto-registration (pid=None,
   registered_by="claude-hook"/"codex-hook"/"kimi-hook"), alias-agnostic.
   Shared by [auto_register_impl] (adopt-or-skip) and [auto_join_rooms_impl]
   (conflict → no room joins as the hook identity). *)
let same_session_hook_identity_row ~existing ~session_id =
  List.find_opt
    (fun (reg : registration) ->
      reg.session_id = session_id
      && reg.pid = None
      && Broker.is_hook_auto_registration reg)
    existing

(* B119: inherited-session-id contamination check — true when both this
   process's C2C_MCP_CLIENT_TYPE and the hook row's client_type are known
   and differ (e.g. a `kimi -p` child inheriting CLAUDE_SESSION_ID). *)
let hook_client_type_conflict_with (reg : registration) =
  match current_client_type (), reg.client_type with
  | Some mine, Some theirs ->
      String.lowercase_ascii mine <> String.lowercase_ascii theirs
  | _ -> false

(* B042: explicit auto-register opt-out. When C2C_NO_AUTO_REGISTER=1 an
   operator/wrapper has declared this process must not auto-register or drain.

   NOTE (B130): this is NOT a dispatched-subagent discriminator. An earlier
   B130 attempt added CLAUDE_CODE_CHILD_SESSION here, but that env var is set on
   EVERY hook fire and EVERY tool subprocess of EVERY Claude Code session
   (top-level and subagent alike, same session_id/ppid) — gating on it silently
   suppressed c2c delivery/onboarding for top-level sessions. A dispatched
   subagent is only distinguishable via the hook STDIN `agent_id`
   (C2c_hook_lib.stdin_is_subagent_turn), not process env. *)
let is_subagent_context () =
  match Sys.getenv_opt "C2C_NO_AUTO_REGISTER" with
  | Some v when String.trim v = "1" -> true
  | _ -> false

(* ---------------------------------------------------------------------------
 * Managed `c2c start kimi` identity predicates (#40 / #47 / #48).
 *
 * Hoisted here from [c2c_hook_cmd.ml] so BOTH surfaces that must recognise a
 * launcher-owned managed kimi row share ONE definition:
 *   - the SessionStart hook (`c2c hook kimi`), which adopts the row's
 *     session_id instead of minting a competing alias; and
 *   - the in-session MCP server's startup auto-register ([auto_register_impl]
 *     below), which under #48 must NOT mint/rebind the install-time sticky
 *     alias when a managed row already owns this cwd — one global
 *     `~/.kimi-code/mcp.json` bakes a single install alias with no
 *     C2C_MCP_SESSION_ID, so without this the MCP server registered a SECOND
 *     identity that tripped #40's "2 live managed kimi instances share cwd"
 *     ambiguity guard on relaunch.
 *
 * The reasoning behind each predicate (why pid+start_time, why pid=None is a
 * reclaim signal, the co-located-vanilla and unbounded-reclaim caveats) is
 * unchanged from the #40/#47 hook documentation; see the c2c_hook_cmd.ml
 * call site and CLAUDE.md's kimi delivery notes. Pure over [regs].
 * ------------------------------------------------------------------------- *)

(* #40 F7: normalize both sides. The launcher writes [Sys.getcwd ()] (already
   canonical) but a client-supplied cwd is whatever the client passes, so a
   trailing slash or a symlinked path would silently defeat the match and
   resurrect the competing-alias bug. realpath is best-effort: on failure
   fall back to a trailing-slash strip rather than dropping the match. *)
let normalize_hook_cwd p =
  let p = String.trim p in
  let stripped =
    let n = String.length p in
    if n > 1 && p.[n - 1] = '/' then String.sub p 0 (n - 1) else p
  in
  try Unix.realpath stripped with _ -> stripped

(* The identity half of the match: a managed (launcher-written, not
   hook-written) kimi row owning [cwd]. Says nothing about liveness. *)
let is_managed_kimi_row_for_cwd ~(want : string) (r : registration) =
  r.client_type = Some "kimi"
  && r.registered_by <> Some "kimi-hook"
  && (match r.cwd with Some c -> normalize_hook_cwd c = want | None -> false)

(* #40: live managed `c2c start kimi` rows owning [cwd]. Liveness is the
   pid + pid_start_time pair (anti-PID-reuse), which does not decay, so no
   recency window is applied — managed sessions legitimately run for days. *)
let live_managed_kimi_registrations ~(cwd : string)
    (regs : registration list) : registration list =
  let want = normalize_hook_cwd cwd in
  let pid_is_live p start_time =
    p > 0
    && Sys.file_exists (Printf.sprintf "/proc/%d" p)
    &&
    match start_time with
    | None -> true (* pre-#40 row: pid existence is all we have *)
    | Some recorded -> (
        match Broker.capture_pid_start_time (Some p) with
        | Some now -> now = recorded
        | None -> false (* unreadable now but recorded then → fail closed *))
  in
  List.filter
    (fun (r : registration) ->
       is_managed_kimi_row_for_cwd ~want r
       && (match r.pid with
           | Some p -> pid_is_live p r.pid_start_time
           | None -> false))
    regs

(* #47: managed kimi rows for [cwd] whose liveness fields were STRIPPED on
   teardown ([C2c_start.clear_registration_pid] nulls pid+pid_start_time but
   keeps the row as the workspace's sticky alias). [pid = None] here is a
   positive RECLAIM signal because only c2c writes it, and only on teardown
   of a row it owns. Deliberately NOT extended to [pid = Some p] where p is
   dead (a stale liveness claim). See the #40/#47 hook documentation for the
   full caveat about Broker.register's None handling. *)
let reclaimable_managed_kimi_registrations ~(cwd : string)
    (regs : registration list) : registration list =
  let want = normalize_hook_cwd cwd in
  List.filter
    (fun (r : registration) ->
       is_managed_kimi_row_for_cwd ~want r && r.pid = None)
    regs

(* True when any live or reclaimable managed kimi row owns [cwd] for a kimi
   process. Used to suppress mint/rebind of the install-time alias (#48) and
   to fail closed on auto-join when self cannot be resolved uniquely. *)
let managed_kimi_owns_cwd_of ~(regs : registration list) =
  current_client_type () = Some "kimi"
  && (match (try Sys.getcwd () with Sys_error _ -> "") with
      | "" -> false
      | cwd ->
          live_managed_kimi_registrations ~cwd regs <> []
          || reclaimable_managed_kimi_registrations ~cwd regs <> [])

(* #48: the managed `c2c start kimi` launcher row that an UNREGISTERED
   in-session kimi MCP server belongs to, if any.

   The global ~/.kimi-code/mcp.json carries no per-session C2C_MCP_SESSION_ID,
   so a managed kimi MCP server resolves its own session id from the kimi
   session_index (a uuid) that never matches the launcher row's session_id (the
   instance name). Since #48 the startup auto-register no longer mints a
   competing row under that uuid, so identity resolution BY SESSION_ID finds
   nothing — [whoami] would report "unregistered" and [send] would fail with
   missing-sender / be rejected as impersonation of the launcher row. This
   binds the session to its launcher identity BY CWD so whoami reports the
   managed alias and send sends AS it (single authority — #48 option 1).

   Deliberately narrow. Returns [Some] only when ALL hold:
     - this process declares client_type = kimi (a non-kimi MCP server sharing
       the directory is never bound to a kimi row);
     - the process's own session_id has NO registration (a session that already
       owns an identity must not be relabelled as another row's alias — this is
       what keeps the impersonation carve-out below from letting a registered
       session send as someone else);
     - EXACTLY ONE managed (registered_by <> "kimi-hook") kimi row owns the
       current normalized cwd. Two or more is the #40 ambiguity — fail closed
       to [None] rather than guess which launcher is self.
   This does not widen the trust boundary beyond #40's already-accepted
   co-located-vanilla-kimi adoption: same normalized cwd + kimi already means
   "the workspace's managed identity", and the broker is a local-only file a
   co-located process could write directly regardless.

   THREAT MODEL — [C2C_MCP_CLIENT_TYPE=kimi] is env-spoofable, so this guard's
   safety rests ENTIRELY on c2c's same-UID local-file model (a process that can
   set that env and chdir into the workspace can already write the registry).
   It must NOT be relied on as a security boundary if the broker ever gains a
   cross-UID or remote-write surface.

   Defined here (before auto_register/auto_join) so both startup paths share
   one resolution of "self" for managed kimi. *)
let self_managed_kimi_row ?session_id_override broker =
  if current_client_type () <> Some "kimi" then None
  else
    let regs = Broker.list_registrations broker in
    let own_sid =
      match session_id_override with
      | Some sid -> Some sid
      | None -> current_session_id ()
    in
    let own_row_exists =
      match own_sid with
      | Some sid -> List.exists (fun (r : registration) -> r.session_id = sid) regs
      | None -> false
    in
    if own_row_exists then None
    else
      match (try Sys.getcwd () with Sys_error _ -> "") with
      | "" -> None
      | cwd -> (
          match live_managed_kimi_registrations ~cwd regs with
          | [ m ] -> Some m
          | _ :: _ -> None (* #40 ambiguity: >= 2 managed rows share cwd *)
          | [] -> (
              match reclaimable_managed_kimi_registrations ~cwd regs with
              | [ m ] -> Some m
              | _ -> None))

let auto_register_impl ~broker_root ?session_id_override () =
  match auto_register_alias () with
  | None -> ()
  | Some env_alias ->
  (* B042: skip auto-registration when C2C_NO_AUTO_REGISTER=1 (explicit
     operator/wrapper opt-out). See [is_subagent_context]. *)
  (if is_subagent_context ()
   then ()
   else
  let session_id =
    match session_id_override with
    | Some sid when String.trim sid <> "" -> String.trim sid
    | _ ->
        (match current_session_id () with
         | Some sid -> sid
         | None -> derived_session_id_from_alias env_alias)
  in
  (* B191: hold the global per-session registration lock across the
     [registry read -> cross-broker sticky scan -> register] sequence so a
     concurrent registration of the same session id under another broker
     root cannot interleave (both minting distinct aliases). *)
  with_session_registration_lock ~session_id @@ fun () ->
  begin
      let broker = Broker.create ~root:broker_root in
      (* Safety guard: if an alive registration already exists for this
         session_id with a DIFFERENT alias, skip auto-register. This
         prevents session hijack when a child process (e.g. kimi -p) inherits
         CLAUDE_SESSION_ID from a running Claude Code session but has a
         different C2C_MCP_AUTO_REGISTER_ALIAS configured. *)
      let existing = Broker.list_registrations broker in
      (* #48: managed-kimi single authority. The global ~/.kimi-code/mcp.json
         bakes ONE install-time C2C_MCP_AUTO_REGISTER_ALIAS with no
         C2C_MCP_SESSION_ID, so every managed kimi session's in-session MCP
         server would auto-register that same sticky alias under its own
         (session-index-derived) session id — a SECOND identity competing with
         the AUTHORITATIVE launcher row (#40). `whoami` then resolves the
         install alias while delivery uses the launcher row, and on relaunch the
         extra managed-looking row trips #40's "2 live managed kimi instances
         share cwd" ambiguity guard. When a LIVE (or torn-down/reclaimable,
         #47) managed kimi row already owns this cwd, the launcher owns identity:
         RESOLVE to it, do not mint/rebind. Gated on client_type=kimi so a
         non-kimi MCP server sharing a directory is unaffected, and on a managed
         (registered_by <> "kimi-hook") row so vanilla kimi — whose hook row is
         adopted below via [same_session_hook_identity_row] — still registers
         its install alias exactly as before. *)
      let managed_kimi_owns_cwd = managed_kimi_owns_cwd_of ~regs:existing in
      if managed_kimi_owns_cwd then begin
        (try
           let cwd = try Sys.getcwd () with Sys_error _ -> "?" in
           Printf.eprintf
             "[auto_register_startup] kimi: a managed `c2c start kimi` row owns \
              cwd %s — resolving to the launcher identity, not \
              minting/rebinding install-time alias %S (#48).\n%!"
             cwd env_alias
         with _ -> ())
      end else begin
      (* B119 / B233: hook auto-registrations are the identity authority for
         their session_id. The SessionStart hooks (`c2c hook claude` /
         `c2c hook codex` / `c2c hook kimi`) register a fresh per-session
         alias (pid=None, registered_by="*-hook") and bake it into the
         injected onboarding context BEFORE the MCP server connects. The MCP
         env alias (C2C_MCP_AUTO_REGISTER_ALIAS) is static — picked once at
         `c2c install` time — so registering it here would clobber the alias
         the model was just told it has (identity split: DMs to the announced
         alias bounce). Guards 1–4 all deliberately exclude pid=None rows
         (#345 post-OOM semantics), so without this adoption the hook row
         protects nothing and last-writer-wins.


         Resolution: ADOPT the hook row's alias (the register below then
         updates that row in place, upgrading it with our live pid, keys and
         metadata while Broker.register preserves DND/confirmed state).
         registered_by is carried over so SessionEnd hook cleanup still
         recognises its own auto-registration.

         Exception: when both client types are known and DIFFER (e.g. a
         `kimi -p` child inheriting CLAUDE_SESSION_ID with its own MCP env),
         this is inherited-session-id contamination, not the same agent —
         skip registration entirely rather than adopt or clobber.

         Pidless rows with registered_by=None (post-OOM zombies, cleared
         managed rows) keep the #345 behavior: the fresh env alias wins. *)
      (* Any same-session hook row, alias-agnostic: the client-type
         conflict guard must fire even when the env alias happens to
         casefold-match the hook alias (otherwise a conflicting client
         would silently overwrite the row's pid/client_type/registered_by). *)
      let hook_identity_row = same_session_hook_identity_row ~existing ~session_id in
      let hook_client_type_conflict =
        match hook_identity_row with
        | None -> false
        | Some reg -> hook_client_type_conflict_with reg
      in
      (* B188: when this broker has no row for session_id yet, prefer a sticky
         alias from another fingerprint (path→remote.origin.url) over the
         static install-time env alias, which would otherwise fork identity. *)
      let prior_cross_broker =
        if List.exists (fun (r : registration) -> r.session_id = session_id) existing
        then None
        else
          find_prior_session_across_brokers ~session_id ~exclude_root:broker_root ()
      in
      let alias, adopted_registered_by =
        match hook_identity_row with
        | Some reg when not hook_client_type_conflict ->
            (* Adopt the hook alias; carry registered_by so SessionEnd hook
               cleanup still recognises its own auto-registration (also when
               the aliases already match). *)
            (reg.alias, reg.registered_by)
        | _ ->
            (match prior_cross_broker with
             | Some hit ->
                 ignore
                   (migrate_alias_ed25519_keys ~from_root:hit.broker_root
                      ~to_root:broker_root ~alias:hit.registration.alias);
                 (* Carry registered_by when present so SessionEnd cleanup still
                    matches; otherwise mark cross-broker sticky so
                    from_auto_gen=true and client-prefix blocklist is skipped
                    (the prior alias was already validated when first minted). *)
                 let adopted_rb =
                   match hit.registration.registered_by with
                   | Some _ as rb -> rb
                   | None -> Some "cross-broker-sticky"
                 in
                 (hit.registration.alias, adopted_rb)
             | None -> (env_alias, None))
      in
      (* Guard 1: if an alive registration already exists for this session_id
         with a DIFFERENT alias, skip — prevents session hijack when a child
         process inherits CLAUDE_SESSION_ID but has a different alias. *)
      let hijack_guard =
        (* #345: exclude pid=None for the reasons documented at Guard 3
           below — pidless zombie rows cannot prove ownership against a
           legitimate post-OOM resume. *)
        List.exists
          (fun reg ->
            Option.is_some reg.pid
            && reg.session_id = session_id
            && reg.alias <> alias
            && Broker.registration_is_alive reg)
          existing
      in
      (* Guard 2: if an alive registration already exists for this ALIAS
         with a DIFFERENT session_id, skip — prevents a one-shot or probe
         process from evicting an active peer that owns this alias. A new
         session is allowed to claim the alias once the existing holder dies
         (its PID check will return false, making this guard inactive).
         The SAME pid is always allowed to re-register so session-id drift
         (e.g. after refresh-peer or outer-loop env changes) self-heals. *)
      let pid =
        match current_client_pid () with
        | Some pid -> Some pid
        | None -> Some (Unix.getppid ())
      in
      let alias_occupied_guard =
        (* #345: exclude pid=None for the reasons documented at Guard 3
           below — this is the highest-impact post-OOM-resume site, where
           a pidless zombie row from the prior crashed session would
           otherwise block the legitimate fresh-session resume.
           #432 follow-up (slate-coder 2026-04-29): compare case-folded
           aliases here too — same asymmetric-guard exploit shape as the
           MCP register tool's [alias_hijack_conflict]. See
           .collab/findings/2026-04-29T14-25-00Z-slate-coder-alias-casefold-guard-asymmetry-takeover.md. *)
        let target = Broker.alias_casefold alias in
        List.exists
          (fun reg ->
            Option.is_some reg.pid
            && Broker.alias_casefold reg.alias = target
            && reg.session_id <> session_id
            && Broker.registration_is_alive reg
            && reg.pid <> pid)
          existing
      in
      (* Guard 3: if an alive registration already exists for this exact
         session_id + alias with a DIFFERENT pid, skip — prevents a child
         process (e.g. kimi launched from codex) from inheriting a wrong
         C2C_MCP_CLIENT_PID and clobbering the correct liveness entry.
         Legitimate restarts are still allowed because the old PID will be
         dead by the time the new process starts.
         IMPORTANT: exclude pid=None entries. After c2c start cleans up,
         clear_registration_pid strips the PID so the entry has pid=None.
         registration_is_alive returns true for pid=None (legacy compat), so
         without this exclusion Guard 3 would block re-registration on resume
         (None != Some new_pid triggers the guard incorrectly). A no-pid row
         cannot "own" an alias — treat it as an empty slot. *)
      let same_session_alive_different_pid =
        List.exists
          (fun reg ->
             reg.session_id = session_id
             && reg.alias = alias
             && reg.pid <> None
             && Broker.registration_is_alive reg
             && reg.pid <> pid)
          existing
      in
      (* Guard 4: if an alive registration already exists with the SAME pid
         but a DIFFERENT session_id and DIFFERENT alias, skip — prevents
         child processes launched inside a managed session (e.g. OpenCode
         from Codex) from inheriting the same C2C_MCP_CLIENT_PID and
         creating a permanent ghost alias that accumulates messages. *)
      let same_pid_alive_different_session =
        (* #345: exclude pid=None for the reasons documented at Guard 3
           above — defense-in-depth + intent-locking. Functionally a
           no-op today since `pid` falls back to Unix.getppid () so the
           `reg.pid = pid` clause already structurally rejects None,
           but the explicit filter pins the predicate to its semantic
           intent ("a row whose pid we know matches ours"). *)
        List.exists
          (fun reg ->
             Option.is_some reg.pid
             && reg.session_id <> session_id
             && reg.alias <> alias
             && Broker.registration_is_alive reg
             && reg.pid = pid)
          existing
      in
      if not hijack_guard && not alias_occupied_guard && not same_session_alive_different_pid
         && not same_pid_alive_different_session && not hook_client_type_conflict
      then begin
        let pid_start_time = Broker.capture_pid_start_time pid in
        let client_type = current_client_type () in
        let plugin_version = current_plugin_version () in
        let enc_pubkey =
          match Relay_enc.load_or_generate ~alias () with
          | Ok enc -> Some (Relay_enc.public_key_b64 enc)
          | Error e ->
              Printf.eprintf "[auto_register_startup] warning: could not load X25519 key: %s\n%!" e;
              None
        in
        let cwd = try Some (Sys.getcwd ()) with Sys_error _ -> None in
        (* Wake-target capture (codex-wake-inject): managed sessions set
           C2C_TMUX_LOCATION via `c2c start` build_env; herdr pane env is
           inherited from the launching pane. Mirrors the register-tool
           fallbacks so startup auto-registration carries the targets too
           (the codex SessionStart hook refreshes them later regardless). *)
        let nonempty_env name =
          match Sys.getenv_opt name with
          | Some v when String.trim v <> "" -> Some (String.trim v)
          | _ -> None
        in
        Broker.register broker ~session_id ~alias ~pid ~pid_start_time ~client_type
          ~plugin_version ~enc_pubkey ~cwd
          ~tmux_location:(nonempty_env "C2C_TMUX_LOCATION")
          ~herdr_pane:(nonempty_env "HERDR_PANE_ID")
          ~herdr_socket:(nonempty_env "HERDR_SOCKET_PATH")
          ~registered_by:adopted_registered_by
          (* Adopted hook aliases were validated (incl. blocklist) at their
             original registration — skip the user-supplied-only blocklist. *)
          ~from_auto_gen:(Option.is_some adopted_registered_by
                          || auto_register_alias_from_auto_gen ()) ();
        ignore (Broker.redeliver_dead_letter_for_session broker ~session_id ~alias)
      end else begin
        (* Log which guard triggered and by which registration, for debugging.
           Each guard recomputes the same predicate it used for its boolean guard,
           then logs the matching registration if found. *)
        let log_guard_if_fired ~label ?(reg_pid_fn = fun reg -> reg.pid) pred =
          match List.find_opt pred existing with
          | Some reg ->
              let pid_str = match reg_pid_fn reg with None -> "none" | Some p -> string_of_int p in
              Printf.eprintf "[auto_register_startup] %s: skipping — alias=%S session_id=%S pid=%s\n%!"
                label reg.alias reg.session_id pid_str
          | None -> ()
        in
        let target = Broker.alias_casefold alias in
        (* B119 follow-up: logging predicates must match the actual guards
           (incl. the Option.is_some pid clause) — otherwise a preserved
           pid=None hook row emits a false "hijack_guard" diagnostic on the
           client-type-conflict skip path. *)
        log_guard_if_fired ~label:"hijack_guard"
          (fun reg -> Option.is_some reg.pid && reg.session_id = session_id
                      && reg.alias <> alias && Broker.registration_is_alive reg);
        log_guard_if_fired ~label:"alias_occupied_guard"
          (fun reg -> Option.is_some reg.pid && Broker.alias_casefold reg.alias = target
                       && reg.session_id <> session_id
                       && reg.pid <> pid && Broker.registration_is_alive reg);
        log_guard_if_fired ~label:"same_session_alive_different_pid"
          (fun reg -> reg.session_id = session_id && reg.alias = alias && reg.pid <> None
                      && reg.pid <> pid && Broker.registration_is_alive reg);
        log_guard_if_fired ~label:"same_pid_alive_different_session"
          ~reg_pid_fn:(fun _ -> pid)
          (fun reg -> reg.pid = pid && reg.session_id <> session_id && reg.alias <> alias
                      && Broker.registration_is_alive reg);
        (if hook_client_type_conflict then
           match hook_identity_row with
           | Some reg ->
               Printf.eprintf
                 "[auto_register_startup] hook_client_type_conflict: skipping — \
                  session_id=%S is owned by hook registration alias=%S \
                  (client_type=%s) but this process declares client_type=%s\n%!"
                 reg.session_id reg.alias
                 (Option.value reg.client_type ~default:"?")
                 (Option.value (current_client_type ()) ~default:"?")
           | None -> ())
      end
      end (* #48: close the managed-kimi [else begin] guard *)
  end)

let auto_register_startup ~broker_root = auto_register_impl ~broker_root ()

(** Auto-join rooms listed in C2C_MCP_AUTO_JOIN_ROOMS (comma-separated) on
    server startup. Only runs when auto-registration is also configured (both
    C2C_MCP_AUTO_REGISTER_ALIAS must be set; C2C_MCP_SESSION_ID is optional
    (derived from alias+ppid when absent). This is
    the social-layer entry point: operators set
      C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge
    in the MCP env so every agent session joins the persistent social channel
    automatically on first startup. Idempotent — joining the same room twice
    is a no-op on the broker side. *)
let auto_join_rooms_impl ~broker_root ?session_id_override () =
  match auto_register_alias () with
  | None -> ()
  | Some alias ->
  let session_id =
    match session_id_override with
    | Some sid when String.trim sid <> "" -> String.trim sid
    | _ ->
        (match current_session_id () with
         | Some sid -> sid
         | None -> derived_session_id_from_alias alias)
  in
  let rooms_raw =
    match Sys.getenv_opt "C2C_MCP_AUTO_JOIN_ROOMS" with
    | Some v -> String.trim v
    | None -> ""
  in
  if rooms_raw <> "" then begin
    let rooms =
      String.split_on_char ',' rooms_raw
      |> List.map String.trim
      |> List.filter (fun s -> s <> "")
    in
    let broker = Broker.create ~root:broker_root in
    let existing = Broker.list_registrations broker in
    (* B119 follow-up: on a hook client-type conflict the register path
       skips, but the session lookup below would still resolve the
       preserved hook row — joining rooms AS the hook identity from the
       contaminating child. Skip auto-join entirely in that case. *)
    let contaminated =
      match same_session_hook_identity_row ~existing ~session_id with
      | Some reg when hook_client_type_conflict_with reg ->
          Printf.eprintf
            "[auto_join_rooms] hook_client_type_conflict: skipping room \
             auto-join — session_id=%S is owned by hook registration \
             alias=%S (client_type=%s) but this process declares \
             client_type=%s\n%!"
            reg.session_id reg.alias
            (Option.value reg.client_type ~default:"?")
            (Option.value (current_client_type ()) ~default:"?");
          true
      | _ -> false
    in
    if not contaminated then begin
      (* Resolve join identity: prefer a row already registered under this
         session_id; else bind to the managed launcher row (#48) so room
         membership is under the launcher alias+session_id, never the
         install-time sticky alias / MCP-derived uuid. [Broker.join_room]
         treats same-alias+new-session_id as a restart and would REBIND a
         managed member's session_id if we joined as managed-alias + MCP
         uuid — so both fields must come from the launcher row. When a
         managed row owns cwd but self cannot be resolved uniquely (#40
         ambiguity), skip entirely rather than fall through to the install
         alias (that would mint a competing room identity). *)
      let alias, session_id =
        match
          List.find_opt
            (fun reg -> reg.session_id = session_id)
            existing
        with
        | Some reg -> (reg.alias, reg.session_id)
        | None ->
            (match self_managed_kimi_row ?session_id_override broker with
             | Some m -> (m.alias, m.session_id)
             | None ->
                 if managed_kimi_owns_cwd_of ~regs:existing then
                   ("", "") (* fail closed: do not join as install alias *)
                 else (alias, session_id))
      in
      if alias <> "" && session_id <> "" then
        List.iter
          (fun room_id ->
            if Broker.valid_room_id room_id then
              ignore (Broker.join_room broker ~room_id ~alias ~session_id)
            (* silently skip invalid room IDs so a misconfiguration doesn't
               crash the server *))
          rooms
    end
  end

let auto_join_rooms_startup ~broker_root = auto_join_rooms_impl ~broker_root ()

let ensure_request_session_bootstrap ~broker_root ?session_id_override () =
  match session_id_override, auto_register_alias () with
  | Some _, Some _ ->
      auto_register_impl ~broker_root ?session_id_override ();
      auto_join_rooms_impl ~broker_root ?session_id_override ()
  | _ -> ()

let resolve_session_id ?session_id_override arguments =
  match optional_string_member "session_id" arguments with
  | Some session_id when session_id <> "" -> session_id
  | _ ->
      (match session_id_override with
       | Some session_id -> session_id
       | None ->
           (match current_session_id () with
            | Some session_id -> session_id
            | None ->
                (* Align with auto_register_impl / auto_join_rooms_impl: when
                   C2C_MCP_SESSION_ID (and client-native fallbacks) are absent
                   but install left C2C_MCP_AUTO_REGISTER_ALIAS, derive the
                   session id from the alias. Without this, MCP whoami/send
                   hard-fail with "missing session_id" while auto-register
                   still succeeds under the derived id (B233). Prefer real
                   client session keys above; this is last-resort only. *)
                (match auto_register_alias () with
                 | Some alias -> derived_session_id_from_alias alias
                 | None -> invalid_arg "missing session_id")))

(* [#432 §3] [with_session] — kills the 14× resolve+touch boilerplate.
   Resolves the session id (honoring the `session_id` argument > override
   > env-derived precedence enforced by [resolve_session_id]), stamps
   [last_activity_ts] via [Broker.touch_session], then runs [f
   ~session_id]. The label is `~session_id_override` (required,
   matching [handle_tool_call]) so the option is forwarded explicitly.
   [with_session_lwt] is the same combinator with an [_ Lwt.t] return
   type for handlers in the dispatch chain. *)
let with_session ~session_id_override broker arguments f =
  let session_id =
    resolve_session_id ?session_id_override:session_id_override arguments
  in
  Broker.touch_session broker ~session_id;
  f ~session_id

let with_session_lwt ~session_id_override broker arguments f =
  let session_id =
    resolve_session_id ?session_id_override:session_id_override arguments
  in
  Broker.touch_session broker ~session_id;
  f ~session_id

let current_registered_alias ?session_id_override broker =
  let by_session_id =
    match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
    | None -> None
    | Some session_id ->
        Broker.list_registrations broker
        |> List.find_opt
             (fun reg -> reg.session_id = session_id)
        |> Option.map (fun reg -> reg.alias)
  in
  match by_session_id with
  | Some _ -> by_session_id
  | None ->
      (* #48: an unregistered managed-kimi MCP session resolves to its launcher
         identity by cwd, so whoami/send/room/memory all act AS the managed
         alias rather than failing to resolve any alias at all. *)
      Option.map
        (fun (m : registration) -> m.alias)
        (self_managed_kimi_row ?session_id_override broker)

let alias_for_current_session_or_argument ?session_id_override broker arguments =
  match current_registered_alias ?session_id_override broker with
  | Some alias -> Some alias
  | None ->
      (match optional_string_member "from_alias" arguments with
       | Some a -> Some a
       | None -> optional_string_member "alias" arguments)

let missing_sender_alias_result tool_name =
  tool_result
    ~content:
      (Printf.sprintf
         "%s: missing sender alias. Register this session first or pass \
          from_alias explicitly."
         tool_name)
    ~is_error:true

let missing_member_alias_result tool_name =
  tool_result
    ~content:
      (Printf.sprintf
         "%s: missing member alias. Register this session first or pass alias \
          explicitly."
         tool_name)
    ~is_error:true

(* Guard: reject send/send_all/send_room if from_alias is held by an alive
   session with a different session_id. This prevents unregistered callers (or
   callers whose session isn't bound to this alias) from impersonating live
   peers.
   - If the caller IS registered with this alias (same session_id) → None (ok).
   - If no session_id context is available → None (allow legacy / system calls).
   - Otherwise, returns Some conflict_reg if alive different-session holds alias. *)
let send_alias_impersonation_check ?session_id_override broker from_alias =
  let from_cf = Broker.alias_casefold from_alias in
  (* #48: sending as a managed `c2c start kimi` launcher row that owns this cwd
     is SELF for an unregistered in-session kimi MCP session, not impersonation.
     [self_managed_kimi_row] is the narrow predicate (kimi client_type + own
     session_id unregistered + exactly one same-cwd managed row); it returns
     [None] for any registered session, any non-kimi session, and any
     different cwd, so the normal guard below still fires in all those cases. *)
  match self_managed_kimi_row ?session_id_override broker with
  | Some m when Broker.alias_casefold m.alias = from_cf -> None
  | _ ->
  match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
  | None -> None
  | Some current_sid ->
      List.find_opt
        (fun reg ->
           Broker.alias_casefold reg.alias = from_cf
           && reg.session_id <> current_sid
           (* Require a real pid that /proc confirms is running. Pidless
              registrations are legacy/ambiguous — we do not block on them
              to avoid false positives in CLI tests and operator tooling
              that writes registry entries without pids. *)
           && reg.pid <> None
           && Broker.registration_is_alive reg)
        (Broker.list_registrations broker)

(** Self-PASS detector strictness: "warn" (default) adds warning to receipt,
    "strict" rejects the message. *)
let self_pass_detector_strictness () =
  match Sys.getenv_opt "C2C_SELF_PASS_DETECTOR" with
  | Some "strict" -> `Strict
  | Some "warn" | None -> `Warn
  | Some _ -> `Warn

(** Extract the alias identifier that follows "peer-PASS by " in content.
    Aliases are alphanumeric with hyphens/underscores, case-insensitive.
    Returns the alias if found after the marker (skipping whitespace, delimited by whitespace/punct),
    or None if no valid alias follows. *)
let extract_alias_after_peer_pass content start_pos =
  let len = String.length content in
  let rec skip_whitespace i =
    if i >= len then None
    else
      let c = content.[i] in
      if c = ' ' || c = '\n' || c = '\t' || c = '\r' || c = '.' || c = ',' || c = ':'
      then skip_whitespace (i + 1)
      else Some i
  in
  match skip_whitespace start_pos with
  | None -> None
  | Some pos ->
      let rec read_alias acc i =
        if i >= len then Some (acc, i)
        else
          let c = content.[i] in
          if c = ' ' || c = '\n' || c = '\t' || c = '\r' || c = '.' || c = ',' || c = ':'
          then Some (acc, i)
          else if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                  || (c >= '0' && c <= '9') || c = '-' || c = '_'
          then read_alias (acc ^ String.make 1 c) (i + 1)
          else None
      in
      read_alias "" pos

(** Detect "peer-PASS by <alias>" self-review violation in message content.
    Returns Some warning_message if sender's own alias appears in that pattern,
    None otherwise. Case-insensitive alias comparison. *)
let check_self_pass_content ~from_alias content =
  let needle = String.lowercase_ascii "peer-PASS by" in
  let needle_len = String.length needle in
  let lc = String.lowercase_ascii content in
  let lc_from_alias = String.lowercase_ascii from_alias in
  let rec search pos =
    match String.index_from_opt lc pos needle.[0] with
    | None -> None
    | Some i ->
        if i + needle_len <= String.length lc
           && String.sub lc i needle_len = needle
        then
          match extract_alias_after_peer_pass content (i + needle_len) with
          | Some (claimed_alias, _) ->
              if String.lowercase_ascii claimed_alias = lc_from_alias
              then Some (Printf.sprintf "self-review-via-skill violation: 'peer-PASS by %s' detected in message content (your own alias)" from_alias)
              else search (i + 1)
          | None -> search (i + 1)
        else search (i + 1)
  in
  search 0
