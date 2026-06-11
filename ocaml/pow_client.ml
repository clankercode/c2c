type requirement = {
  difficulty : int;
  epoch : int;
  server_nonce : string;
  ctx : string;
}

let (>>=) = Lwt.Infix.(>>=)

let json_member name = function
  | `Assoc fields -> List.assoc_opt name fields |> Option.value ~default:`Null
  | _ -> `Null

let json_string_opt name json =
  match json_member name json with
  | `String s -> Some s
  | _ -> None

let json_int_opt name json =
  match json_member name json with
  | `Int n -> Some n
  | `Float f -> Some (int_of_float f)
  | _ -> None

let is_pow_required json =
  json_string_opt "error_code" json = Some "pow_required"

let requirement_of_response json =
  if not (is_pow_required json) then
    Ok None
  else
    let required = json_member "required" json in
    match
      ( json_int_opt "difficulty" required,
        json_int_opt "epoch" required,
        json_string_opt "server_nonce" required,
        json_string_opt "ctx" required )
    with
    | Some difficulty, Some epoch, Some server_nonce, Some ctx ->
        Ok (Some { difficulty; epoch; server_nonce; ctx })
    | _ -> Error "pow_required response is missing required challenge fields"

let client_error ?relay_response error_code error =
  let fields = [
    "ok", `Bool false;
    "error_code", `String error_code;
    "error", `String error;
  ] in
  let fields =
    match relay_response with
    | None -> fields
    | Some json -> fields @ [ "relay_response", json ]
  in
  `Assoc fields

let with_pow_fields body ~pow_nonce ~pow_epoch ~pow_server_nonce =
  match body with
  | `Assoc fields ->
      let pow_keys = [ "pow_nonce"; "pow_epoch"; "pow_server_nonce" ] in
      let fields =
        List.filter (fun (k, _) -> not (List.mem k pow_keys)) fields
      in
      Ok (`Assoc (fields @ [
        "pow_nonce", `String pow_nonce;
        "pow_epoch", `Int pow_epoch;
        "pow_server_nonce", `String pow_server_nonce;
      ]))
  | _ -> Error (client_error "pow_bad_request_body" "PoW retry requires a JSON object request body")

let body_with_minted_pow ~route ~actor_id body requirement =
  if actor_id = "" then
    Error (client_error "pow_actor_id_missing" "PoW retry requires a client identity public key")
  else if requirement.ctx <> Pow.ctx then
    Error (client_error "pow_unsupported_ctx"
      (Printf.sprintf "unsupported PoW ctx %S" requirement.ctx))
  else
    let challenge =
      Pow.challenge_string ~ctx:requirement.ctx ~route ~actor_id
        ~epoch:requirement.epoch ~server_nonce:requirement.server_nonce
    in
    match Pow.mint ~challenge ~difficulty:requirement.difficulty with
    | None ->
        Error (client_error "pow_mint_failed"
          (Printf.sprintf "failed to mint PoW nonce at difficulty %d"
             requirement.difficulty))
    | Some pow_nonce ->
        with_pow_fields body ~pow_nonce ~pow_epoch:requirement.epoch
          ~pow_server_nonce:requirement.server_nonce

let retry_still_required_error relay_response =
  client_error ~relay_response "pow_retry_failed"
    "relay still required PoW after one minted retry"

let post_with_retry ~post ~route ~actor_id body =
  post body >>= fun response ->
  match requirement_of_response response with
  | Error msg ->
      Lwt.return (client_error "pow_bad_required" msg)
  | Ok None -> Lwt.return response
  | Ok (Some requirement) ->
      match body_with_minted_pow ~route ~actor_id body requirement with
      | Error error_json -> Lwt.return error_json
      | Ok retry_body ->
          post retry_body >>= fun retry_response ->
          if is_pow_required retry_response then
            Lwt.return (retry_still_required_error retry_response)
          else
            Lwt.return retry_response
