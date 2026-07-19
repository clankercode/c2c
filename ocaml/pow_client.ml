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

(* #11: the relay's difficulty is load-derived and moves while a request is in
   flight (a live relay was observed stepping 0 -> 8 -> 12 -> 8). A single
   minted retry loses that race: the proof is already stale on arrival, and we
   used to give up while HOLDING the corrected challenge the rejection carried.
   [post_with_retry] now re-reads the requirement from each rejection and mints
   again, bounded by [max_minted_attempts].

   Three, because each further attempt absorbs one more difficulty change
   landing between challenge and arrival; two consecutive changes inside one
   exchange is already well past anything observed, and an unsatisfiable or
   hostile relay must terminate rather than spin. Worst case is 1 + 3 requests.

   No sleep between attempts: the mint IS the backoff, and it costs
   2^difficulty — a relay that wants us to slow down raises difficulty and
   gets that for free, scaled to its own load signal. Adding wall-clock delay
   on top would only penalise the legitimate sender the relay just told how to
   comply. The cap needs no wall-clock component either: measured mint cost is
   2.5ms at [Pow_policy.d_max] = 12 (the protocol ceiling), so three attempts
   cost ~7.5ms; a failed mint exits immediately with pow_mint_failed rather
   than consuming an attempt, so [Pow.max_mint_iterations] exhaustion is still
   paid at most once, exactly as before. Since #71 that exhaustion costs 2^17
   hashes (~0.15-0.25s) rather than 2^24 (~20-32s), so the 3x amplification
   this cap introduces now applies to a ceiling that was itself re-derived. *)
let max_minted_attempts = 3

(* Re-minting against a challenge IDENTICAL to the one we just satisfied is
   provably futile: [Pow.mint] is deterministic in the challenge string, so it
   would produce the same nonce and earn the same rejection. Stopping there
   keeps a relay that simply repeats itself at ONE minted retry (no extra
   requests, no extra CPU) and means an adversary can only make us mint again
   by issuing genuinely fresh work — still capped by [max_minted_attempts]. *)
let same_requirement a b =
  a.difficulty = b.difficulty && a.epoch = b.epoch
  && a.server_nonce = b.server_nonce && a.ctx = b.ctx

let retry_still_required_error ~minted relay_response =
  client_error ~relay_response "pow_retry_failed"
    (Printf.sprintf "relay still required PoW after %d minted %s" minted
       (if minted = 1 then "retry" else "retries"))

(* B010: when a request succeeds only after we minted PoW, annotate the
   response with the difficulty we had to satisfy. The connector reads
   [pow_minted_difficulty] to surface a "difficulty increased" alert even
   though the retry itself succeeded (the relay's success body carries no
   difficulty otherwise). Harmless extra field for every other consumer. *)
let annotate_minted_difficulty response ~difficulty =
  match response with
  | `Assoc fields when not (List.mem_assoc "pow_minted_difficulty" fields) ->
      `Assoc (fields @ [ "pow_minted_difficulty", `Int difficulty ])
  | other -> other

let post_with_retry ~post ~route ~actor_id body =
  (* [minted] counts proofs already sent; [last] is the requirement the most
     recent proof satisfied — it supplies both the futility comparison and the
     difficulty a succeeded-after-mint response is annotated with (B010), so
     the connector's alert still names the difficulty that actually applied. *)
  let rec handle ~minted ~last response =
    match requirement_of_response response with
    | Error msg -> Lwt.return (client_error "pow_bad_required" msg)
    | Ok None -> (
        match last with
        | None -> Lwt.return response
        | Some requirement ->
            Lwt.return
              (annotate_minted_difficulty response
                 ~difficulty:requirement.difficulty))
    | Ok (Some requirement) ->
        let futile =
          match last with
          | Some previous -> same_requirement previous requirement
          | None -> false
        in
        if minted >= max_minted_attempts || futile then
          Lwt.return (retry_still_required_error ~minted response)
        else (
          match body_with_minted_pow ~route ~actor_id body requirement with
          | Error error_json -> Lwt.return error_json
          | Ok retry_body ->
              post retry_body >>= fun retry_response ->
              handle ~minted:(minted + 1) ~last:(Some requirement) retry_response
          )
  in
  post body >>= handle ~minted:0 ~last:None
