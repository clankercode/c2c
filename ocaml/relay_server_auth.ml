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

let auth_decision ~path ~include_dead ~token ~auth_header ~ed25519_verified =
  (* /list_rooms is a read-only public directory. /room_history is allowed
     through here because the handler applies per-room visibility: public and
     unlisted rooms remain open-read, while gated/private rooms require a
     verified Ed25519 member alias. *)
  let is_unauth =
    List.mem path ["/health"; "/"; "/list_rooms"; "/room_history"; "/device-login"]
  in
  let is_admin =
    path = "/gc"
    || path = "/dead_letter"
    || path = "/admin/unbind"
    || (path = "/list" && include_dead)
    || String.starts_with ~prefix:"/remote_inbox/" path
  in
  (* /register uses body-level Ed25519 proof (identity_pk + signature + nonce
     + timestamp in the JSON body). This is the bootstrap route — the alias
     doesn't exist yet so per-request header auth can't work. handle_register
     does its own crypto verification; auth_decision just allows it through.
     Room mutation routes (join_room, leave_room, send_room, set_room_visibility,
     invite/uninvite/knock/knock-decision) similarly carry body-level Ed25519 proof via verify_room_op_proof
     and also accept an unsigned legacy path. They do their own auth at the handler
     level; bypassing header auth here lets signed AND unsigned bodies through.
     B115: /poll_inbox and /peek_inbox are deliberately NOT in this set. They
     are ordinary peer routes: reading or draining an inbox requires a verified
     Ed25519 request whose bound alias owns the node/session (checked in the
     handlers). Only dev mode (no Bearer token configured) keeps the legacy
     unauthenticated path. Same rule as /send and /heartbeat. *)
  let is_self_auth =
    path = "/register"
    || path = "/join_room"
    || path = "/leave_room"
    || path = "/send_room"
    || path = "/set_room_visibility"
    || path = "/send_room_invite"
    || path = "/invite_room"
    || path = "/uninvite_room"
    || path = "/knock_room"
    || path = "/list_room_knocks"
    || path = "/approve_room_knock"
    || path = "/deny_room_knock"
    || path = "/mobile-pair/prepare"
    || path = "/mobile-pair"
    || path = "/forward"
    || path = "/ws/subscribe"
    || String.starts_with ~prefix:"/binding/" path
  in
  if is_unauth || is_self_auth then (true, None)
  else if is_admin then
    if header_has_ed25519 auth_header then
      (false, Some
        "admin routes require Bearer token; Ed25519 is for peer routes (spec §5.1)")
    else if check_auth token auth_header then (true, None)
    else (false, Some "admin route requires Bearer token")
  else if ed25519_verified then (true, None)
  else if header_has_bearer auth_header then
    (false, Some
      "peer routes require Ed25519 auth per spec §5.1; Bearer is admin-only")
  else if token = None then (true, None)  (* dev mode *)
  else (false, Some "peer route requires Ed25519 auth (spec §5.1)")
