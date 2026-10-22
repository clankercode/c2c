(** Shared signed DM dispatch. Contact selection is committed before invoking
    the HTTP adapter. An admission failure never falls through to /send. *)
open Lwt.Infix

let load_identity () =
  let path = match Sys.getenv_opt "C2C_RELAY_IDENTITY_PATH" with
    | Some p when p <> "" -> p
    | _ -> Relay_identity.default_path () in
  Relay_identity.load ~path ()

let sender_pk = function
  | None -> ""
  | Some id -> Relay_identity.b64url_encode id.Relay_identity.public_key

let new_message_id () =
  Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ())

let error code =
  `Assoc [ "ok", `Bool false; "error_code", `String "contact_send_held";
           "error", `String code ]

let prepare ?dir ~relay_url ~to_alias ~identity ~from_alias ~content
    ~message_id () =
  Relay_contact_store.prepare ?dir ~relay_url ~to_alias
    ~sender_pk:(sender_pk identity) ~from_alias ~content ~message_id
    ~now:(Unix.gettimeofday ()) ()

let dispatch ?dir ~relay_url ~identity ~from_alias ~sender_route ~to_alias
    ~content ~message_id ~request () =
  match prepare ?dir ~relay_url ~to_alias ~identity ~from_alias ~content
          ~message_id () with
  | Error code -> Lwt.return (error code)
  | Ok selection ->
    let path, body, allowed = match selection with
      | Relay_contact_store.Legacy ->
        "/send", `Assoc [ "from_alias", `String sender_route;
                          "to_alias", `String to_alias;
                          "content", `String content;
                          "message_id", `String message_id ], true
      | Relay_contact_store.Contact grant ->
        let secure = Uri.scheme (Uri.of_string relay_url) = Some "https" in
        let host = match String.split_on_char '@' to_alias with
          | [_; host] when C2c_name.is_opaque_host_id host ->
            [ "expected_recipient_host_id", `String host ]
          | _ -> [] in
        "/contact/v1/deliver",
        `Assoc ([ "protocol", `String "c2c-contact/1";
                  "grant_secret", `String grant.grant_secret;
                  "expected_recipient_pk", `String grant.recipient_pk;
                  "expected_delivery_alias", `String grant.delivery_alias;
                  "message_id", `String message_id;
                  "content", `String content ] @ host),
        (secure || (Uri.scheme (Uri.of_string relay_url) = Some "http"
                    && grant.allow_http)) in
    if not allowed then Lwt.return (error "contact_requires_https_or_explicit_http_opt_in")
    else if path = "/contact/v1/deliver" && identity = None then
      Lwt.return (error "contact_sender_identity_required")
    else
      let auth = Option.map (fun id ->
          Relay_signed_ops.sign_request id ~alias:from_alias ~meth:"POST"
            ~path ~body_str:(Yojson.Safe.to_string body) ()) identity in
      let contact_ready = if path <> "/contact/v1/deliver" then Lwt.return true
        else request ~meth:`GET ~path:"/health" ~body:None ~auth:None >|= fun health ->
          match health with
          | `Assoc fields -> List.assoc_opt "contact_protocol" fields = Some (`Int 1)
              && List.assoc_opt "contact_destination_binding" fields = Some (`Int 1)
          | _ -> false in
      contact_ready >>= fun ready ->
      (if ready then request ~meth:`POST ~path ~body:(Some body) ~auth
       else Lwt.return (error "relay_contact_destination_binding_unsupported_upgrade_relay"))
      >|= fun result ->
      (* Do not echo a hostile relay response containing reusable grant secrets
         into outbox diagnostics. Contact errors expose a fixed allowlist. *)
      let field key = try Yojson.Safe.Util.member key result with _ -> `Null in
      let safe = if path = "/contact/v1/deliver" && ready then
          `Assoc (List.filter_map (fun key ->
              match field key with
              | `Bool _ as v when key = "ok" || key = "duplicate" || key = "transport" -> Some (key,v)
              | (`Float _ | `Int _) as v when key = "ts" || key = "http_status" || key = "retry_after" -> Some (key,v)
              | `String code when key = "error_code" ->
                let code = if List.mem code [ "contact_unauthorised"; "rate_limit_exceeded";
                   "connection_error"; "incompatible_client"; "signature_invalid"; "contact_send_held" ]
                  then code else "contact_delivery_failed" in Some (key, `String code)
              | _ -> None) ["ok";"duplicate";"ts";"http_status";"transport";"retry_after";"error_code"])
        else result in
      match safe with
      | `Assoc fields -> `Assoc (("message_id", `String message_id) :: fields)
      | _ -> safe
