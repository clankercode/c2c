let check_auth token auth_header =
  match token with
  | None -> true
  | Some t ->
    match auth_header with
    | None -> false
    | Some h ->
      (match String.split_on_char ' ' h with
       | ["Bearer"; token'] -> token' = t
       | _ -> false)

let header_has_bearer = function
  | Some h ->
    (match String.split_on_char ' ' h with
     | "Bearer" :: _ -> true
     | _ -> false)
  | None -> false

let header_has_ed25519 = function
  | Some h ->
    let p = "Ed25519 " in
    String.length h >= String.length p
    && String.sub h 0 (String.length p) = p
  | None -> false

let err_unauthorized = "unauthorized"

(* B113: route classification is DATA, shared between auth_decision (the
   enforcement point) and the landing page (Relay_server_html), which
   generates its operational auth copy from these same lists. The
   test_relay_landing_auth_contract suite cross-checks both directions, so
   editing a list here updates the public copy, and hand-editing the copy
   out of sync fails CI. *)
type route_class =
  | Anonymous_read  (* no credentials; handler may apply per-resource rules *)
  | Self_auth       (* bypasses the outer header-auth gate; what follows is
                       route-specific handler policy — room mutation routes
                       and /register verify a body-level Ed25519 proof
                       (unsigned bodies rejected since B114 unless the
                       dev-only C2C_REQUIRE_SIGNED_ROOM_OPS=0 gate is active
                       on a token-less relay), and bare-ID /binding/* revoke
                       requires a signed machine/phone owner proof (B116) *)
  | Bearer_admin    (* operator Bearer token; Ed25519 rejected *)
  | Peer_ed25519    (* per-request Ed25519 signature from a bound identity *)

(* /list_rooms is a read-only directory of listed (public + gated) rooms.
   /room_history is allowed through here because the handler applies per-room
   visibility: public and unlisted rooms remain open-read, while gated/private
   rooms require a verified Ed25519 member alias. *)
let anonymous_read_routes =
  ["/"; "/health"; "/list_rooms"; "/room_history"; "/device-login"]

(* /register uses body-level Ed25519 proof (identity_pk + signature + nonce
   + timestamp in the JSON body). This is the bootstrap route — the alias
   doesn't exist yet so per-request header auth can't work. handle_register
   does its own crypto verification; auth_decision just allows it through.
   Room mutation routes (join_room, leave_room, send_room, set_room_visibility,
   invite/uninvite/knock/knock-decision) similarly carry body-level Ed25519 proof
   via verify_room_op_proof (send_room via verify_room_send_envelope) and since
   B114 REJECT unsigned bodies unless the dev-only unsigned gate is active
   (C2C_REQUIRE_SIGNED_ROOM_OPS=0 on a token-less relay). Handler policy is
   still route-specific rather than uniform: /binding/* revocation requires a
   signed machine/phone owner proof (B116) and discloses no binding existence.
   Bypassing header auth here hands the body to the handler's own policy.
   B115: /poll_inbox and /peek_inbox are deliberately NOT in this set — they
   are ordinary peer routes (Peer_ed25519). Reading or draining an inbox
   requires a verified Ed25519 request whose bound alias owns the
   node/session (checked in the handlers); the handlers additionally fail
   closed even on a tokenless relay unless the development-only env gate
   C2C_RELAY_ALLOW_UNSIGNED_INBOX=1 is set (see inbox_owner_required in
   relay.ml). Same route class as /send and /heartbeat. *)
let self_auth_exact_routes =
  [ "/register"; "/join_room"; "/leave_room"; "/send_room";
    "/set_room_visibility"; "/set_room_history_public";
    "/send_room_invite"; "/invite_room";
    "/uninvite_room"; "/knock_room"; "/list_room_knocks";
    "/approve_room_knock"; "/deny_room_knock"; "/mobile-pair/prepare";
    "/mobile-pair"; "/forward"; "/ws/subscribe" ]

let self_auth_prefix_routes = ["/binding/"]

(* Classifier-only compatibility entries: they pass the outer gate exactly
   like the rest of self_auth_exact_routes (removing one would flip it to
   the peer default and change auth_decision), but the HTTP router has no
   branch for them, so requests 404 after the gate. /send_room_invite is the
   MCP/broker tool name; the live relay endpoint is /invite_room. The
   landing page must not advertise these as active endpoints
   (test_relay_landing_auth_contract pins both directions). *)
let self_auth_classifier_only_routes = ["/send_room_invite"]

let admin_exact_routes = ["/gc"; "/dead_letter"; "/admin/unbind"]
let admin_prefix_routes = ["/remote_inbox/"]

let matches_prefix prefixes path =
  List.exists (fun p -> String.starts_with ~prefix:p path) prefixes

(* Precedence mirrors the original auth_decision ordering:
   anonymous/self-auth first, then admin, then the peer default. No path is
   in more than one list today; the ordering only matters if that changes. *)
let classify_route ~path ~include_dead =
  if List.mem path anonymous_read_routes then Anonymous_read
  else if List.mem path self_auth_exact_routes
          || matches_prefix self_auth_prefix_routes path
  then Self_auth
  else if List.mem path admin_exact_routes
          || (path = "/list" && include_dead)
          || matches_prefix admin_prefix_routes path
  then Bearer_admin
  else Peer_ed25519

let auth_decision ~path ~include_dead ~token ~auth_header ~ed25519_verified =
  match classify_route ~path ~include_dead with
  | Anonymous_read | Self_auth -> (true, None)
  | Bearer_admin ->
    if header_has_ed25519 auth_header then
      (false, Some
        "admin routes require Bearer token; Ed25519 is for peer routes (spec §5.1)")
    else if check_auth token auth_header then (true, None)
    else (false, Some "admin route requires Bearer token")
  | Peer_ed25519 ->
    if ed25519_verified then (true, None)
    else if header_has_bearer auth_header then
      (false, Some
        "peer routes require Ed25519 auth per spec §5.1; Bearer is admin-only")
    else if token = None then (true, None)  (* dev mode *)
    else (false, Some "peer route requires Ed25519 auth (spec §5.1)")
