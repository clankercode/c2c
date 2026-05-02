(* #450 Slice 6: Send cluster hoisted out of [c2c_mcp.ml]'s
   [handle_tool_call]. Each send-related tool branch is now a
   top-level function here; [handle_tool_call] dispatches one-line
   into the corresponding [C2c_send_handlers.X] entrypoint.

   Mechanical move — no behavior change. The bodies are byte-for-byte
   identical to the original arms with free locals lifted into named
   parameters ([broker], [session_id_override], [arguments]).

   #450 Slice 7: [encrypt_content_for_recipient] extracted from [send]
   lines 60-131 (mechanical hoist, same pattern as S6).

   #450 Slice 10: [broadcast_to_all] extracted from [send_all]
   (mechanical hoist, same pattern as S7-S9).

   #671 Slice 1: [broadcast_to_all] rewritten to encrypt per-recipient
   via [encrypt_content_for_recipient] + [Broker.enqueue_message] instead
   of the plaintext [Broker.send_all] fan-out.  Receipt enriched with
   [encrypted], [plaintext], and [key_changed] arrays. *)

open C2c_mcp_helpers
open C2c_mcp_helpers_post_broker
module Broker = C2c_broker

(* #450 S7: encryption helper — mechanically hoisted from [send] lines 60-131.
   Free vars lifted to named parameters: broker, from_alias, to_alias, content, ts.
   No behavior change. *)
let encrypt_content_for_recipient
    ~(broker : Broker.t)
    ~(from_alias : string)
    ~(to_alias : string)
    ~(content : string)
    ~(ts : float) : [> `Encrypted of string | `Key_changed of string | `Plain of string ] =
  (* #432: case-insensitive alias matching mirrors
     [resolve_live_session_id_by_alias] so the
     enc-pubkey lookup cannot disagree with the
     inbox-write target. *)
  let to_alias_cf = Broker.alias_casefold to_alias in
  let recipient_reg =
    Broker.list_registrations broker
    |> List.find_opt (fun r -> Broker.alias_casefold r.alias = to_alias_cf)
  in
  match recipient_reg with
  | Some _ -> `Plain content
  | None ->
    let recipient_reg =
      Broker.list_registrations broker
      |> List.find_opt (fun r -> Broker.alias_casefold r.alias = to_alias_cf && r.enc_pubkey <> None)
    in
    match recipient_reg with
    | None -> `Plain content
    | Some reg ->
      match reg.enc_pubkey with
      | None -> `Plain content
      | Some recipient_pk_b64 ->
        (match Broker.get_pinned_x25519 to_alias with
        | Some pinned when pinned <> recipient_pk_b64 ->
          `Key_changed to_alias
        | _ ->
          (match Relay_enc.load_or_generate ~alias:from_alias () with
           | Error e ->
             Printf.eprintf "send: load_or_generate x25519 failed: %s\n" e;
             `Plain content
           | Ok our_x25519 ->
             let sender_pk_b64 = Relay_enc.b64url_encode our_x25519.public_key in
             Broker.pin_x25519_sync ~alias:to_alias ~pk:recipient_pk_b64 |> ignore;
             let our_ed25519 = Broker.load_or_create_ed25519_identity () in
             let our_ed_pubkey_b64 = Relay_enc.b64url_encode our_ed25519.public_key in
             Broker.pin_ed25519_sync ~alias:from_alias ~pk:our_ed_pubkey_b64 |> ignore;
             let sk_seed = our_x25519.private_key_seed in
             match Relay_e2e.encrypt_for_recipient
                     ~pt:content
                     ~recipient_pk_b64:recipient_pk_b64
                     ~our_sk_seed:sk_seed with
             | None -> `Plain content
             | Some (ct_b64, nonce_b64) ->
               let recipient_entry = Relay_e2e.make_recipient
                 ~alias:to_alias ~ct_b64 ~nonce:nonce_b64
               in
               let our_ed25519_pk_b64 =
                 Relay_e2e.b64_encode our_ed25519.public_key
               in
               let envelope : Relay_e2e.envelope = {
                 from_ = from_alias;
                 from_x25519 = Some sender_pk_b64;
                 from_ed25519 = Some our_ed25519_pk_b64;
                 to_ = Some to_alias;
                 room = None;
                 ts = Int64.of_float ts;
                 enc = "box-x25519-v1";
                 recipients = [ recipient_entry ];
                 sig_b64 = "";
                 envelope_version = Relay_e2e.current_envelope_version;
                } in
                `Encrypted (Yojson.Safe.to_string (Relay_e2e.envelope_to_json (Relay_e2e.set_sig envelope ~sk_seed:our_ed25519.private_key_seed)))))

(** Receipt-visible side-channel data produced by [verify_peer_pass_dm].
    Available on [Allow] and [Warn] paths; callers include these fields
    in the send receipt JSON so the sender can see peer-pass status. *)
type pp_receipt_extras = {
  pp_verification : [ `Ok of string | `Missing of string | `Invalid of string ] option;
  pp_self_pass_warning : [ `Reject of string | `Warn of string ] option;
}

(** #450 S9: peer-pass verification pipeline extracted from [send].
    Returns the verification decision for a peer-pass-bearing DM:
    - [`Allow]       — message should be enqueued normally
    - [`Reject of string] — message should be rejected (reason in string)
    - [`Warn of string]   — message allowed but self-pass warning emitted

    Also returns [pp_receipt_extras] carrying the raw [peer_pass_verification]
    and [self_pass_warning] values needed to build the send receipt on the
    [Allow] / [Warn] paths. These are irrelevant on the [Reject] path.

    The function is pure modulo the broker log write on H2b reject and
    the git-commit-author lookup in the self-pass suppression path. *)
let verify_peer_pass_dm ~broker ~from_alias ~to_alias ~content
  : [`Allow | `Reject of string | `Warn of string] * pp_receipt_extras =
  let peer_pass_claim = Peer_review.claim_of_content content in
  let self_pass_warning =
    match check_self_pass_content ~from_alias content with
    | None -> None
    | Some msg ->
        (* Cross-check: if the body claims a peer-PASS for
           a SHA whose git author != from_alias, this is a
           cross-agent review announcement, not a self-
           pass. Suppress the warning. *)
         let sha_author_differs_from_sender =
           (* Reset the circuit breaker before the git spawn so
              prior activity in the same process doesn't cause
              this check to return None (false positive: the
              send gets rejected because the self-pass detector
              treats "git unavailable" as "author ≠ sender",
              bypassing the suppression logic). Matches the
              pattern in validate_signing_allowed (c2c_peer_pass.ml:92). *)
           Git_helpers.reset_git_circuit_breaker ();
           match peer_pass_claim with
           | None -> false
           | Some (_claimed_alias, sha) ->
               (match Git_helpers.git_commit_author_name sha with
                | None -> false
                | Some author ->
                    String.lowercase_ascii author
                    <> String.lowercase_ascii from_alias)
         in
        if sha_author_differs_from_sender then None
        else if self_pass_detector_strictness () = `Strict
        then Some (`Reject msg)
        else Some (`Warn msg)
  in
  let peer_pass_pin_path =
    Filename.concat (Broker.root broker) "peer-pass-trust.json"
  in
  let peer_pass_verification =
    match peer_pass_claim with
    | None -> None
    | Some (alias, sha) ->
        (* #29 H2b: pin-aware variant. The plain
           [verify_claim] only validates the signature
           against the artifact-embedded reviewer_pk, so
           a fresh-keypair forgery passed strict-mode H2.
           [verify_claim_with_pin] adds TOFU pubkey-pin
           enforcement: artifact pubkey must match the
           pin for this alias (or be first-seen). *)
        match
          Peer_review.verify_claim_with_pin
            ~root:(Some (Broker.root broker))
            ~path:peer_pass_pin_path ~alias ~sha ()
        with
        | Peer_review.Claim_valid msg -> Some (`Ok msg)
        | Peer_review.Claim_missing m -> Some (`Missing m)
        | Peer_review.Claim_invalid m -> Some (`Invalid m)
  in
  let invalid_peer_pass =
    match peer_pass_verification with
    | Some (`Invalid m) ->
        let claim_alias, claim_sha = match peer_pass_claim with
          | Some (a, s) -> a, s
          | None -> "", ""
        in
        (* Detailed reason -> stderr + broker.log only.
           User-facing message (below) is generic to
           avoid echoing attacker-placed artifact contents
           back to the sender (I3 from slate's review). *)
        Printf.eprintf
          "[peer-pass] WARN: rejecting forged peer-pass DM from=%s to=%s alias=%s sha=%s: %s\n%!"
          from_alias to_alias claim_alias claim_sha m;
        log_peer_pass_reject
          ~broker_root:(Broker.root broker)
          ~from_alias ~to_alias
          ~claim_alias ~claim_sha ~reason:m
          ~ts:(Unix.gettimeofday ());
        Some m
    | _ -> None
  in
  let extras = { pp_verification = peer_pass_verification; pp_self_pass_warning = self_pass_warning } in
  match invalid_peer_pass, self_pass_warning with
  | Some _m, _ ->
      `Reject "send rejected: peer-pass verification failed \
               (H2b: forged or pin-mismatched peer-pass DM not enqueued; \
               see broker.log for details)", extras
  | None, Some (`Reject msg) ->
      `Reject ("send rejected: " ^ msg), extras
  | None, Some (`Warn msg) ->
      `Warn msg, extras
  | None, None ->
      `Allow, extras

(** Build a send receipt JSON string from accumulated send state.
    Extracted from [send] for readability (#450 S8); no behavior change.
    Updated to accept [pp_receipt_extras] from S9's [verify_peer_pass_dm]. *)
let build_send_receipt
      ~(pp_extras : pp_receipt_extras)
      ~ts
      ~from_alias
      ~to_alias
      ~recipient_dnd
      ~recipient_compacting
      ~deferrable
  : string =
  let receipt_fields = ref
    [ ("queued", `Bool true)
    ; ("ts", `Float ts)
    ; ("from_alias", `String from_alias)
    ; ("to_alias", `String to_alias)
    ]
  in
  (match pp_extras.pp_self_pass_warning with
   | Some (`Warn msg) ->
       receipt_fields := !receipt_fields @ [("self_pass_warning", `String msg)]
   | _ -> ());
  (match pp_extras.pp_verification with
   | Some (`Ok msg) ->
       receipt_fields := !receipt_fields @ [("peer_pass_verification", `String msg)]
   | Some (`Missing m) ->
       receipt_fields := !receipt_fields @ [("peer_pass_verification", `String ("missing: " ^ m))]
   | Some (`Invalid m) ->
       receipt_fields := !receipt_fields @ [("peer_pass_verification", `String ("invalid: " ^ m))]
   | None -> ());
  if recipient_dnd then receipt_fields := !receipt_fields @ [("recipient_dnd", `Bool true)];
  (match recipient_compacting with
   | Some (dur, reason) ->
       let reason_str = match reason with Some r -> " (" ^ r ^ ")" | None -> "" in
       let warning = Printf.sprintf "recipient compacting for %.0fs%s" dur reason_str in
       receipt_fields := !receipt_fields @ [("compacting_warning", `String warning)]
   | None -> ());
  if deferrable then receipt_fields := !receipt_fields @ [("deferrable", `Bool true)];
  `Assoc !receipt_fields |> Yojson.Safe.to_string

let send ~broker ~session_id_override ~arguments =
      let to_alias = string_member_any [ "to_alias"; "alias" ] arguments in
      let content = string_member "content" arguments in
      (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
       | None ->
           Lwt.return (missing_sender_alias_result "send")
       | Some from_alias ->
           (match send_alias_impersonation_check ?session_id_override:session_id_override broker from_alias with
            | Some conflict ->
                Lwt.return
                  (tool_result
                     ~content:
                       (Printf.sprintf
                          "send rejected: from_alias '%s' is currently held by \
                           alive session '%s' — you cannot send as another agent. \
                           Options: (1) register your own alias first — call \
                           register with {\"alias\":\"<new-name>\"}, \
                           (2) call whoami to see your current identity."
                          from_alias conflict.session_id)
                     ~is_error:true)
              | None ->
                 if from_alias = to_alias then
                   Lwt.return (tool_err "error: cannot send a message to yourself")
                 else
                 let deferrable =
                   try match Yojson.Safe.Util.member "deferrable" arguments with
                     | `Bool b -> b | _ -> false
                   with _ -> false
                 in
                 let ephemeral =
                   try match Yojson.Safe.Util.member "ephemeral" arguments with
                     | `Bool b -> b | _ -> false
                   with _ -> false
                 in
                 (* #392: optional `tag` for fail/blocking/urgent body prefix. *)
                 let tag_arg =
                   try match Yojson.Safe.Util.member "tag" arguments with
                     | `String s -> Some s | _ -> None
                   with _ -> None
                 in
                 (match parse_send_tag tag_arg with
                   | Error msg ->
                     Lwt.return (tool_err (Printf.sprintf "send rejected: %s" msg))
                  | Ok tag_opt ->
                 let content = (tag_to_body_prefix tag_opt) ^ content in
let ts = Unix.gettimeofday () in
                  let effective_content =
                    encrypt_content_for_recipient
                      ~broker ~from_alias ~to_alias ~content ~ts
                  in
                 match effective_content with
                 | `Key_changed alias ->
                   let err = Printf.sprintf "send rejected: enc_status:key-changed — %s's x25519 key differs from known pin (possible relay tamper). Re-send after trust --repin %s." alias alias in
                   Lwt.return (tool_err err)
                  | `Plain s | `Encrypted s ->
                    (* #450 S9: peer-pass pipeline hoisted into [verify_peer_pass_dm].
                       [content] is the raw (pre-encryption) body; [s] is the
                       effective wire content (may be encrypted). *)
                    let pp_decision, pp_extras =
                      verify_peer_pass_dm ~broker ~from_alias ~to_alias ~content
                    in
                    (match pp_decision with
                    | `Reject msg ->
                        Lwt.return (tool_err msg)
                    | `Warn _ | `Allow ->
                        Broker.enqueue_message broker ~from_alias ~to_alias ~content:s ~deferrable ~ephemeral ();
                        (match session_id_override with
                         | Some sid -> Broker.touch_session broker ~session_id:sid
                         | None ->
                           (match current_session_id () with
                            | Some sid -> Broker.touch_session broker ~session_id:sid
                            | None -> ()));
                        let ts = Unix.gettimeofday () in
                        (* #432: case-insensitive alias match for sidebar
                           lookups; otherwise dnd / compacting status can be
                           read from a different row than the one
                           [enqueue_message] writes to. *)
                        let to_alias_cf = Broker.alias_casefold to_alias in
                        let recipient_dnd =
                          match Broker.list_registrations broker
                                |> List.find_opt (fun r -> Broker.alias_casefold r.alias = to_alias_cf) with
                          | Some r -> Broker.is_dnd broker ~session_id:r.session_id
                          | None -> false
                        in
                        let recipient_compacting =
                          match Broker.list_registrations broker
                                |> List.find_opt (fun r -> Broker.alias_casefold r.alias = to_alias_cf) with
                          | Some r ->
                              (match Broker.is_compacting broker ~session_id:r.session_id with
                               | Some c ->
                                   let dur = Unix.gettimeofday () -. c.started_at in
                                   Some (dur, c.reason)
                               | None -> None)
                          | None -> None
                        in
                        let receipt =
                          build_send_receipt
                            ~pp_extras
                            ~ts
                            ~from_alias
                            ~to_alias
                            ~recipient_dnd
                            ~recipient_compacting
                            ~deferrable
                        in
                        Lwt.return (tool_ok receipt)))))

(** #671 S1: per-recipient encrypted broadcast.  Replaces the old
    plaintext [Broker.send_all] fan-out with a loop that calls
    [encrypt_content_for_recipient] for each live recipient, then
    [Broker.enqueue_message] with the (possibly encrypted) content.
    Receipt is enriched: [encrypted], [plaintext], and [key_changed]
    arrays so the sender knows what protection each peer got. *)
let broadcast_to_all ~broker ~from_alias ~content ~exclude_aliases ~tag_arg
    : (Yojson.Safe.t, string) result =
  match parse_send_tag tag_arg with
  | Error msg -> Error (Printf.sprintf "send_all rejected: %s" msg)
  | Ok tag_opt ->
    let content = (tag_to_body_prefix tag_opt) ^ content in
    let regs = Broker.list_registrations broker in
    (* Deduplicate by case-folded alias — mirrors Broker.send_all. *)
    let seen : (string, unit) Hashtbl.t = Hashtbl.create 16 in
    let sent_encrypted = ref [] in
    let sent_plaintext = ref [] in
    let key_changed = ref [] in
    let skipped = ref [] in
    let from_cf = Broker.alias_casefold from_alias in
    List.iter (fun (reg : C2c_mcp_helpers.registration) ->
      let alias_cf = Broker.alias_casefold reg.alias in
      if Hashtbl.mem seen alias_cf then ()
      else begin
        Hashtbl.add seen alias_cf ();
        if alias_cf = from_cf then ()
        else if List.exists (fun ex -> Broker.alias_casefold ex = alias_cf) exclude_aliases then ()
        else
          let ts = Unix.gettimeofday () in
          match encrypt_content_for_recipient ~broker ~from_alias ~to_alias:reg.alias ~content ~ts with
          | `Key_changed alias ->
            key_changed := alias :: !key_changed
          | `Encrypted enc_content ->
            (try
               Broker.enqueue_message broker ~from_alias ~to_alias:reg.alias ~content:enc_content ();
               sent_encrypted := reg.alias :: !sent_encrypted
             with Invalid_argument _ ->
               skipped := (reg.alias, "not_alive") :: !skipped)
          | `Plain plain_content ->
            (try
               Broker.enqueue_message broker ~from_alias ~to_alias:reg.alias ~content:plain_content ();
               sent_plaintext := reg.alias :: !sent_plaintext
             with Invalid_argument _ ->
               skipped := (reg.alias, "not_alive") :: !skipped)
      end
    ) regs;
    let sent_encrypted = List.rev !sent_encrypted in
    let sent_plaintext = List.rev !sent_plaintext in
    let key_changed = List.rev !key_changed in
    let skipped = List.rev !skipped in
    let all_sent = sent_encrypted @ sent_plaintext in
    let result_json =
      `Assoc
        [ ( "sent_to",
            `List (List.map (fun alias -> `String alias) all_sent) )
        ; ( "encrypted",
            `List (List.map (fun alias -> `String alias) sent_encrypted) )
        ; ( "plaintext",
            `List (List.map (fun alias -> `String alias) sent_plaintext) )
        ; ( "key_changed",
            `List (List.map (fun alias -> `String alias) key_changed) )
        ; ( "skipped",
            `List
              (List.map
                 (fun (alias, reason) ->
                   `Assoc
                     [ ("alias", `String alias)
                     ; ("reason", `String reason)
                     ])
                 skipped) )
        ]
    in
    Ok result_json

let send_all ~broker ~session_id_override ~arguments =
      let content = string_member "content" arguments in
      (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
       | None -> Lwt.return (missing_sender_alias_result "send_all")
       | Some from_alias ->
           (match send_alias_impersonation_check ?session_id_override:session_id_override broker from_alias with
            | Some conflict ->
                Lwt.return
                  (tool_result
                     ~content:
                       (Printf.sprintf
                          "send_all rejected: from_alias '%s' is currently held by \
                           alive session '%s' — you cannot broadcast as another agent. \
                           Options: (1) register your own alias first — call \
                           register with {\"alias\":\"<new-name>\"}, \
                           (2) call whoami to see your current identity."
                          from_alias conflict.session_id)
                     ~is_error:true)
            | None ->
                let exclude_aliases =
                  let open Yojson.Safe.Util in
                  try
                    match arguments |> member "exclude_aliases" with
                    | `List items ->
                        List.filter_map
                          (fun item ->
                            match item with `String s -> Some s | _ -> None)
                          items
                    | _ -> []
                  with _ -> []
                in
                (* #392: optional `tag` for fail/blocking/urgent body prefix. *)
                let tag_arg =
                  try match Yojson.Safe.Util.member "tag" arguments with
                    | `String s -> Some s | _ -> None
                  with _ -> None
                in
                match broadcast_to_all ~broker ~from_alias ~content ~exclude_aliases ~tag_arg with
                | Error msg ->
                    Lwt.return (tool_err msg)
                | Ok result_json ->
                    (match session_id_override with Some sid -> Broker.touch_session broker ~session_id:sid | None -> (match current_session_id () with Some sid -> Broker.touch_session broker ~session_id:sid | None -> ()));
                    Lwt.return (tool_ok (Yojson.Safe.to_string result_json))))
