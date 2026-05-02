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
          with e ->
            log_handoff_attempt ~broker_root ~from_alias
              ~to_alias:recipient ~name ~ok:false
              ~error:(Some (Printexc.to_string e));
            None)
      shared_with

let channel_notification ?(role : string option = None) ({ from_alias; to_alias; content; ts; _ } : message) =
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
  `Assoc
    [ ("jsonrpc", `String "2.0")
    ; ("method", `String "notifications/claude/channel")
    ; ( "params",
        `Assoc
          [ ("content", `String content)
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
        | Invite_only -> `String "invite_only")
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

let native_session_id_env_keys = function
  | "claude" -> [ "CLAUDE_SESSION_ID" ]
  | "codex" -> [ "CODEX_THREAD_ID" ]
  | "opencode" -> [ "C2C_OPENCODE_SESSION_ID" ]
  | "kimi" | "crush" | "codex-headless" -> []
  | _ -> []

let inferred_client_type_from_env () =
  match first_nonempty_env [ "C2C_MCP_CLIENT_TYPE" ] with
  | Some client_type -> Some client_type
  | None ->
      if first_nonempty_env [ "CODEX_THREAD_ID" ] <> None then Some "codex"
      else if first_nonempty_env [ "CLAUDE_SESSION_ID" ] <> None then Some "claude"
      else if first_nonempty_env [ "C2C_OPENCODE_SESSION_ID" ] <> None then Some "opencode"
      else None

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
      first_nonempty_env fallback_keys

let current_session_id () =
  session_id_from_env ()

let managed_instances_dir () =
  match Sys.getenv_opt "C2C_INSTANCES_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
      let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
      Filename.concat home ".local/share/c2c/instances"

let managed_session_id_from_codex_thread ~broker_root ~thread_id =
  let instances_dir = managed_instances_dir () in
  if not (Sys.file_exists instances_dir && Sys.is_directory instances_dir) then None
  else
    let entries = try Array.to_list (Sys.readdir instances_dir) with _ -> [] in
    let matches =
      List.filter_map
        (fun name ->
          let config_path =
            Filename.concat (Filename.concat instances_dir name) "config.json"
          in
          if not (Sys.file_exists config_path) then None
          else
            try
              let json = Yojson.Safe.from_file config_path in
              let fields = match json with `Assoc assoc -> assoc | _ -> [] in
              let string_field key =
                match List.assoc_opt key fields with
                | Some (`String value) when String.trim value <> "" ->
                    Some (String.trim value)
                | _ -> None
              in
              let is_codex_family =
                match string_field "client" with
                | Some ("codex" | "codex-headless") -> true
                | _ -> false
              in
              let broker_matches =
                match string_field "broker_root" with
                | Some root -> String.equal root broker_root
                | None -> false
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
            with _ -> None)
        entries
    in
    match matches with
    | session_id :: _ -> Some session_id
    | [] -> None

let codex_turn_metadata_session_id params =
  let open Yojson.Safe.Util in
  try
    match params |> member "_meta" |> member "x-codex-turn-metadata" |> member "session_id" with
    | `String value when String.trim value <> "" -> Some (String.trim value)
    | _ -> None
  with _ -> None

let request_session_id_override ~broker_root ~tool_name ~params =
  match tool_name with
  | "register" | "whoami" | "debug" | "poll_inbox" | "peek_inbox" | "history" | "my_rooms"
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

let auto_register_alias () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let current_client_pid () =
  match Sys.getenv_opt "C2C_MCP_CLIENT_PID" with
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None
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

let auto_register_impl ~broker_root ?session_id_override () =
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
  begin
      let broker = Broker.create ~root:broker_root in
      (* Safety guard: if an alive registration already exists for this
         session_id with a DIFFERENT alias, skip auto-register. This
         prevents session hijack when a child process (e.g. kimi -p) inherits
         CLAUDE_SESSION_ID from a running Claude Code session but has a
         different C2C_MCP_AUTO_REGISTER_ALIAS configured. *)
      let existing = Broker.list_registrations broker in
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
         && not same_pid_alive_different_session
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
        Broker.register broker ~session_id ~alias ~pid ~pid_start_time ~client_type ~plugin_version ~enc_pubkey ();
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
        log_guard_if_fired ~label:"hijack_guard"
          (fun reg -> reg.session_id = session_id && reg.alias <> alias && Broker.registration_is_alive reg);
        log_guard_if_fired ~label:"alias_occupied_guard"
          (fun reg -> Broker.alias_casefold reg.alias = target && reg.session_id <> session_id
                       && reg.pid <> pid && Broker.registration_is_alive reg);
        log_guard_if_fired ~label:"same_session_alive_different_pid"
          (fun reg -> reg.session_id = session_id && reg.alias = alias && reg.pid <> None
                      && reg.pid <> pid && Broker.registration_is_alive reg);
        log_guard_if_fired ~label:"same_pid_alive_different_session"
          ~reg_pid_fn:(fun _ -> pid)
          (fun reg -> reg.pid = pid && reg.session_id <> session_id && reg.alias <> alias
                      && Broker.registration_is_alive reg)
      end
  end

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
    let alias =
      match
        List.find_opt
          (fun reg -> reg.session_id = session_id)
          (Broker.list_registrations broker)
      with
      | Some reg -> reg.alias
      | None -> alias
    in
    List.iter
      (fun room_id ->
        if Broker.valid_room_id room_id then
          ignore (Broker.join_room broker ~room_id ~alias ~session_id)
        (* silently skip invalid room IDs so a misconfiguration doesn't
           crash the server *))
      rooms
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
            | None -> invalid_arg "missing session_id"))

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
  match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
  | None -> None
  | Some session_id ->
      Broker.list_registrations broker
      |> List.find_opt
           (fun reg -> reg.session_id = session_id)
      |> Option.map (fun reg -> reg.alias)

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
  match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
  | None -> None
  | Some current_sid ->
      List.find_opt
        (fun reg ->
          reg.alias = from_alias
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
