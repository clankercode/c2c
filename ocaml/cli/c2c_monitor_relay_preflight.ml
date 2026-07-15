(* Secure relay-watch preflight shared by monitor startup and live alias
   rebind.  A local broker registration does not imply that the alias is
   bound to this machine's Ed25519 identity on the relay. *)

type registration_policy =
  | Registration_disabled
  | Registration_allowed
  | Registration_refused of string

type watch_context = Direct_cli | Connector_managed | Custom_key

type outcome =
  | Ready of { registered : bool }
  | Off of string

let register_alias_signed ~url ?token ~alias ~identity () =
  let client = Relay.Relay_client.make ?token url in
  let node_id = Printf.sprintf "cli-%s" alias in
  let p = Relay_signed_ops.sign_register identity ~alias ~relay_url:url in
  Relay.Relay_client.register_signed client
    ~node_id ~session_id:node_id ~alias ~client_type:"cli"
    ~identity_pk_b64:p.Relay_signed_ops.identity_pk_b64
    ~sig_b64:p.Relay_signed_ops.sig_b64
    ~nonce:p.Relay_signed_ops.nonce ~ts:p.Relay_signed_ops.ts ()

let registration_ok = function
  | `Assoc fields -> List.assoc_opt "ok" fields = Some (`Bool true)
  | _ -> false

let missing_binding_reason ~context ~alias =
  match context with
  | Connector_managed ->
      Printf.sprintf
        "connector-managed alias %S has no relay identity binding; repair/restart the machine relay connector"
        alias
  | Custom_key ->
      Printf.sprintf
        "alias %S has no relay identity binding for the custom relay key; register that key explicitly"
        alias
  | Direct_cli ->
      Printf.sprintf
        "alias %S is not registered on the relay; run `c2c relay register --alias %s` or restart with --register-relay-alias"
        alias alias

let check_lwt ~url ?token ~alias ~identity ~context ~registration_policy () =
  let open Lwt.Infix in
  match registration_policy with
  | Registration_refused reason ->
      Lwt.return (Off ("relay alias registration refused: " ^ reason))
  | Registration_disabled | Registration_allowed ->
      let client = Relay.Relay_client.make ?token ~timeout:2.0 url in
      let auth =
        Relay_signed_ops.sign_request identity ~alias ~meth:"GET" ~path:"/list"
          ~body_str:"" ()
      in
      Relay.Relay_client.list_peers_signed client ~auth_header:auth ()
      >>= fun response ->
      if not (Relay_client_hints.is_missing_identity_binding response) then
        Lwt.return (Ready { registered = false })
      else
        match registration_policy with
        | Registration_disabled ->
            Lwt.return (Off (missing_binding_reason ~context ~alias))
        | Registration_refused _ -> assert false
        | Registration_allowed ->
            register_alias_signed ~url ?token ~alias ~identity ()
            >|= fun result ->
            if registration_ok result then Ready { registered = true }
            else
              Off
                (Printf.sprintf "relay alias registration failed: %s"
                   (Yojson.Safe.to_string result))
