(* B179: post-rename relay identity rebind — see relay_rename_rebind.mli. *)

let next_step_command ~new_alias =
  Printf.sprintf "c2c relay register --alias=%s" new_alias

let relay_config_path () =
  match Sys.getenv_opt "C2C_RELAY_CONFIG" with
  | Some p when p <> "" -> p
  | _ ->
      (match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
       | Some d when String.trim d <> "" ->
           Filename.concat (String.trim d) "relay.json"
       | _ ->
           let home = try Sys.getenv "HOME" with Not_found -> "." in
           Filename.concat home ".config/c2c/relay.json")

let load_relay_config () =
  let path = relay_config_path () in
  if not (Sys.file_exists path) then `Assoc []
  else
    try Yojson.Safe.from_file path with _ -> `Assoc []

let relay_config_string_field key =
  match load_relay_config () with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String v) when v <> "" -> Some v
       | _ -> None)
  | _ -> None

let resolve_relay_url () =
  match Sys.getenv_opt "C2C_RELAY_URL" with
  | Some v when v <> "" -> Some v
  | _ -> relay_config_string_field "url"

let resolve_relay_token () =
  match Sys.getenv_opt "C2C_RELAY_TOKEN" with
  | Some v when v <> "" -> Some v
  | _ -> relay_config_string_field "token"

(* Same identity path resolution as c2c relay register (B114):
   C2C_RELAY_IDENTITY_PATH override, else default identity.json. Create if
   absent so a first-time rename after local-only use can still bind. *)
let load_or_create_client_identity ~alias_hint =
  let path =
    match Sys.getenv_opt "C2C_RELAY_IDENTITY_PATH" with
    | Some p when p <> "" -> p
    | _ -> Relay_identity.default_path ()
  in
  Relay_identity.load_or_create_at ~path ~alias_hint

let json_ok_field = function
  | `Assoc fields ->
      (match List.assoc_opt "ok" fields with
       | Some (`Bool true) -> true
       | _ -> false)
  | _ -> false

let json_error_message = function
  | `Assoc fields ->
      (match List.assoc_opt "error" fields with
       | Some (`String s) when String.trim s <> "" -> s
       | _ ->
           (match List.assoc_opt "error_code" fields with
            | Some (`String s) -> s
            | _ -> "relay register returned non-ok"))
  | _ -> "relay register returned non-ok"

let skipped_json ~reason ~new_alias =
  `Assoc
    [ ("status", `String "skipped")
    ; ("reason", `String reason)
    ; ("new_alias", `String new_alias)
    ]

let error_json ~new_alias ?relay_url ~error () =
  let fields =
    [ ("status", `String "error")
    ; ("new_alias", `String new_alias)
    ; ("error", `String error)
    ; ("next_step", `String (next_step_command ~new_alias))
    ; ( "old_alias_lease"
      , `String "unchanged_dual_bind_until_ttl" )
    ]
  in
  let fields =
    match relay_url with
    | Some u -> ("relay_url", `String u) :: fields
    | None -> fields
  in
  `Assoc fields

let ok_json ~old_alias ~new_alias ~relay_url =
  `Assoc
    [ ("status", `String "ok")
    ; ("old_alias", `String old_alias)
    ; ("new_alias", `String new_alias)
    ; ("relay_url", `String relay_url)
    ; ( "old_alias_lease"
      , `String "dual_bind_until_ttl" )
    ; ( "note"
      , `String
          "new alias bound with the same identity key; prior alias lease \
           remains until TTL expiry (dual-bind window)" )
    ]

let rebind_lwt ?relay_url ?token ~old_alias ~new_alias () =
  let new_alias = String.trim new_alias in
  let old_alias = String.trim old_alias in
  if new_alias = "" then
    Lwt.return
      (error_json ~new_alias ~error:"empty new_alias" ())
  else if String.equal old_alias new_alias then
    Lwt.return
      (skipped_json ~reason:"noop rename — relay identity already matches"
         ~new_alias)
  else
    match
      match relay_url with
      | Some u when String.trim u <> "" -> Some (String.trim u)
      | _ -> resolve_relay_url ()
    with
    | None ->
        Lwt.return
          (skipped_json ~reason:"no relay URL configured" ~new_alias)
    | Some url ->
        let token =
          match token with
          | Some t when t <> "" -> Some t
          | _ -> resolve_relay_token ()
        in
        (* Short timeout: rename must stay snappy when the relay is down. *)
        let client = Relay.Relay_client.make ?token ~timeout:5.0 url in
        match
          try Ok (load_or_create_client_identity ~alias_hint:new_alias)
          with e -> Error (Printexc.to_string e)
        with
        | Error err ->
            Lwt.return
              (error_json ~new_alias ~relay_url:url
                 ~error:("identity load/create failed: " ^ err) ())
        | Ok id ->
            let node_id = Printf.sprintf "cli-%s" new_alias in
            let session_id = node_id in
            let p =
              Relay_signed_ops.sign_register id ~alias:new_alias
                ~relay_url:url
            in
            Lwt.catch
              (fun () ->
                Relay.Relay_client.register_signed client ~node_id
                  ~session_id ~alias:new_alias ~client_type:"cli"
                  ~identity_pk_b64:p.Relay_signed_ops.identity_pk_b64
                  ~sig_b64:p.Relay_signed_ops.sig_b64
                  ~nonce:p.Relay_signed_ops.nonce ~ts:p.Relay_signed_ops.ts
                  ()
                |> Lwt.map (fun result ->
                       if json_ok_field result then
                         ok_json ~old_alias ~new_alias ~relay_url:url
                       else
                         error_json ~new_alias ~relay_url:url
                           ~error:(json_error_message result) ()))
              (fun exn ->
                Lwt.return
                  (error_json ~new_alias ~relay_url:url
                     ~error:(Printexc.to_string exn) ()))

let rebind_sync ?relay_url ?token ~old_alias ~new_alias () =
  try
    Lwt_main.run (rebind_lwt ?relay_url ?token ~old_alias ~new_alias ())
  with exn ->
    error_json ~new_alias
      ?relay_url:
        (match relay_url with
         | Some u when String.trim u <> "" -> Some (String.trim u)
         | _ -> resolve_relay_url ())
      ~error:(Printexc.to_string exn) ()

let merge_into_rename_result ~rename_json ~rebind_json =
  match rename_json with
  | `Assoc fields ->
      `Assoc
        (("relay_rebind", rebind_json)
        :: List.filter (fun (k, _) -> k <> "relay_rebind") fields)
  | other -> other
