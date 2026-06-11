let scheme_id = "sha256-leading-zeros-v1"
let ctx = "c2c/v1/pow"
let sep = "\x1f"
(* Must comfortably exceed 2^Pow_policy.d_max so a legitimate (throttled)
   actor can always mint at the maximum required difficulty rather than
   hard-failing with pow_mint_failed. ~16x margin over 2^20 (d_max=20). *)
let max_mint_iterations = 16_777_216

let challenge_string ~ctx ~route ~actor_id ~epoch ~server_nonce =
  (* Canonical v1 wire format: raw 0x1f separators, no escaping. *)
  String.concat sep [ ctx; route; actor_id; string_of_int epoch; server_nonce ]

let leading_zero_bits digest =
  let rec count_bytes idx total =
    if idx >= String.length digest then total
    else
      let byte = Char.code digest.[idx] in
      if byte = 0 then count_bytes (idx + 1) (total + 8)
      else
        let rec count_bits mask bits =
          if mask = 0 || byte land mask <> 0 then bits
          else count_bits (mask lsr 1) (bits + 1)
        in
        total + count_bits 0x80 0
  in
  count_bytes 0 0

let sha256_raw s =
  Digestif.SHA256.digest_string s |> Digestif.SHA256.to_raw_string

let verify ~challenge ~difficulty ~pow_nonce =
  difficulty <= 0
  ||
  let digest = sha256_raw (String.concat sep [ challenge; pow_nonce ]) in
  leading_zero_bits digest >= difficulty

let mint ~challenge ~difficulty =
  let rec loop counter =
    if counter >= max_mint_iterations then None
    else
      let pow_nonce = string_of_int counter in
      if verify ~challenge ~difficulty ~pow_nonce then Some pow_nonce
      else loop (counter + 1)
  in
  loop 0
