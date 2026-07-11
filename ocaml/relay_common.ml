(* Shared pure relay constants and helpers. Re-exported by Relay for API compatibility. *)

(* Error codes *)
let relay_err_unknown_alias = "unknown_alias"
let relay_err_alias_conflict = "alias_conflict"
let relay_err_alias_identity_mismatch = "alias_identity_mismatch"
let relay_err_recipient_dead = "recipient_dead"
let relay_err_signature_invalid = "signature_invalid"
let relay_err_timestamp_out_of_window = "timestamp_out_of_window"
let relay_err_nonce_replay = "nonce_replay"
let relay_err_missing_proof_field = "missing_proof_field"
(* B116: uniform denial for binding revocation — deliberately covers BOTH
   "binding does not exist" and "proof key does not own this binding" so a
   valid-signature probe cannot be used as a binding-existence oracle. *)
let relay_err_revoke_denied = "revoke_denied"
let relay_err_not_found = "not_found"

(* Signature windows (spec §4.3): 120s past / 30s future, 10 min nonce TTL *)
let register_ts_past_window = 120.0
let register_ts_future_window = 30.0
let register_nonce_ttl = 600.0

(* Per-request auth (spec §5.1): 30s past / 5s future, 2 min nonce TTL *)
let request_ts_past_window = 30.0
let request_ts_future_window = 5.0
let request_nonce_ttl = 120.0

(* Registration lease lifetime -- single canonical default, referenced
   everywhere a lease ttl default is needed. Bumped from 300s to 24h
   (2026-06-11) so agents don't have to re-register every few minutes.
   Lease lifetime is server policy: [handle_register] floors any
   client-supplied ttl up to [default_lease_ttl] (so already-deployed
   clients that still send 300 get 24h on the redeployed relay), and caps
   it at [max_lease_ttl] to bound abuse. *)
let default_lease_ttl = 86400.0   (* 24 hours, seconds *)
let max_lease_ttl = 604800.0      (* 7 days; hard cap on a client-requested ttl *)

let effective_lease_ttl ~client_ttl =
  if client_ttl <= default_lease_ttl then default_lease_ttl
  else if client_ttl > max_lease_ttl then max_lease_ttl
  else client_ttl

(* Alias ownership outlives active delivery leases. Delivery TTLs stay short so
   sends fail fast for offline agents, but an alias remains reserved for 12
   30-day months after the last heartbeat/register. After 3 months unseen, list
   responses include warning metadata with the eventual release timestamp. *)
let alias_month_s = 30.0 *. 86400.0
let alias_warning_after_s = 3.0 *. alias_month_s
let alias_release_after_s = 12.0 *. alias_month_s
let alias_release_at ~last_seen = last_seen +. alias_release_after_s
let alias_warning_since ~last_seen = last_seen +. alias_warning_after_s
let alias_released ~now ~last_seen = alias_release_at ~last_seen <= now

let alias_release_warning ~now ~last_seen =
  now >= alias_warning_since ~last_seen && not (alias_released ~now ~last_seen)

(* Layer 4 room ops (spec §4.1/§4.2): use the register ts window + nonce TTL. *)
let room_join_sign_ctx = "c2c/v1/room-join"
let room_leave_sign_ctx = "c2c/v1/room-leave"

(* Layer 4 envelope error codes (spec §9). *)
let relay_err_unsupported_enc = "unsupported_enc"
let relay_err_not_invited = "not_invited"
let relay_err_not_a_member = "not_a_member"
let relay_err_unsigned_room_op = "unsigned_room_op"
let relay_err_join_directly = "join_directly"
let relay_err_already_invited = "already_invited"
let relay_err_already_member = "already_member"
let relay_err_no_pending_knock = "no_pending_knock"

(* Strip any "@host" or "@host:port" suffix from an alias string.
   Returns bare alias for hashtbl/registration lookup. #686 *)
let bare_alias (s : string) : string =
  match String.index_opt s '@' with
  | None -> s
  | Some i -> String.sub s 0 i

(* Gate for Phase 2 migration: when C2C_REQUIRE_SIGNED_ROOM_OPS=1,
   room ops (join/leave/send/invite/uninvite/set_visibility) require
   body-level Ed25519 proof and reject unsigned requests.
   Default (unset or "0"): legacy behavior — accept unsigned.
   Migration path:
     Phase 1: server ships with gate off; OCaml CLI updated to sign.
     Phase 2: Python relay client updated to sign.
     Phase 3: gate defaults to "1" (require signed).
   Operators can set C2C_REQUIRE_SIGNED_ROOM_OPS=0 on the server to
   temporarily revert if needed during the transition. *)
let require_signed_room_ops () =
  match Sys.getenv_opt "C2C_REQUIRE_SIGNED_ROOM_OPS" with
  | Some "1" -> true
  | _ -> false

(* Layer 4 slice 5: signed invite / uninvite / set_visibility. *)
let room_invite_sign_ctx = "c2c/v1/room-invite"
let room_uninvite_sign_ctx = "c2c/v1/room-uninvite"
let room_set_visibility_sign_ctx = "c2c/v1/room-set-visibility"
let room_knock_sign_ctx = "c2c/v1/room-knock"
let room_list_knocks_sign_ctx = "c2c/v1/room-list-knocks"
let room_approve_knock_sign_ctx = "c2c/v1/room-approve-knock"
let room_deny_knock_sign_ctx = "c2c/v1/room-deny-knock"

type room_knock = {
  requester_alias : string;
  requester_pk : string;
  requested_at : float;
}

(* Room visibility — four levels (relay-canonical wire values), a 2x2 of
   listed-ness x join-gating:
     "public"   — listed in /list_rooms, open join, open read.
     "unlisted" — NOT listed, but anyone who knows the room id may join + read.
     "gated"    — listed in /list_rooms, but join requires the caller's
                  identity_pk to be on the room's invite list (ACL-gated);
                  read requires membership.
     "private"  — NOT listed, and join requires the caller's identity_pk to
                  be on the room's invite list (ACL-gated); read requires
                  membership.
   [canonical_visibility] normalizes operator/CLI input to one of these.
   Returns [None] for unrecognized input so callers can reject it. Only
   "public" and "gated" rooms are returned by list_rooms; "gated" and
   "private" rooms are join-gated. *)
let canonical_visibility v =
  match String.lowercase_ascii (String.trim v) with
  | "public" -> Some "public"
  | "unlisted" -> Some "unlisted"
  | "gated" -> Some "gated"
  | "private" -> Some "private"
  | _ -> None

let canonical_visibility_exn v =
  match canonical_visibility v with
  | Some v -> v
  | None -> invalid_arg (Printf.sprintf "invalid room visibility %S" v)

let canonical_visibility_or_raw v =
  match canonical_visibility v with
  | Some v -> v
  | None -> v

(* S5a: Mobile pair token signing context *)
let mobile_pair_token_sign_ctx = "c2c/v1/mobile-pair-token"

(* B116: Binding revocation proof signing context.
   Blob shape: binding_id || revoke_pk_b64 || ts || nonce, where revoke_pk
   must be the machine or phone Ed25519 key stored on the binding. ts is
   Unix epoch seconds (string, as signed). Freshness + replay reuse the
   signed-request pattern (request_ts_past/future_window +
   check_request_nonce), so no B116-specific window constant is needed. *)
let binding_revoke_sign_ctx = "c2c/v1/binding-revoke"

(* E2E S2: pubkey binding sign context.
   Blob shape: alias || ed_pubkey_b64 || x25519_b64 || signed_at_rfc3339.
   Diverges from Relay_signed_ops.register_sign_ctx (which includes nonce +
   relay-url binding) by design — this is a SELF-ATTESTATION of key ownership,
   not a relay-binding. No replay window enforced at S2; deferred to S3. *)
let pubkey_binding_sign_ctx = "c2c/v1/pubkey-binding"

(* Parse a header value like
     "Ed25519 alias=foo,ts=1776698000,nonce=AAA,sig=BBB"
   into the four fields. Leading "Ed25519 " prefix is stripped by the caller. *)
let parse_ed25519_auth_params s =
  let parts = String.split_on_char ',' s in
  let tbl = Hashtbl.create 4 in
  List.iter (fun p ->
    match String.index_opt p '=' with
    | None -> ()
    | Some i ->
      let k = String.sub p 0 i |> String.trim in
      let v = String.sub p (i + 1) (String.length p - i - 1) |> String.trim in
      Hashtbl.replace tbl k v
  ) parts;
  let field name =
    match Hashtbl.find_opt tbl name with
    | Some v when v <> "" -> Ok v
    | _ -> Error (Printf.sprintf "missing %s" name)
  in
  match field "alias", field "ts", field "nonce", field "sig" with
  | Ok a, Ok t, Ok n, Ok s -> Ok (a, t, n, s)
  | Error e, _, _, _
  | _, Error e, _, _
  | _, _, Error e, _
  | _, _, _, Error e -> Error e

(* Sort query params by key ascending, re-encode as k=v&k=v. Matches what
   a client would sign. Empty query → "". *)
let sorted_query_string uri =
  let params = Uri.query uri in
  let flat =
    List.concat_map (fun (k, vs) -> List.map (fun v -> (k, v)) vs) params
  in
  let sorted =
    List.sort (fun (a, _) (b, _) -> String.compare a b) flat
  in
  String.concat "&"
    (List.map (fun (k, v) ->
       Uri.pct_encode ~component:`Query_key k ^ "=" ^
       Uri.pct_encode ~component:`Query_value v) sorted)

let body_sha256_b64 body_str =
  if body_str = "" then ""
  else
    let digest = Digestif.SHA256.digest_string body_str in
    let raw = Digestif.SHA256.to_raw_string digest in
    Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet raw

let room_system_alias = "c2c-system"
let room_join_content alias room_id = alias ^ " joined room " ^ room_id
let room_leave_content alias room_id = alias ^ " left room " ^ room_id

let b64url_nopad_encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s
