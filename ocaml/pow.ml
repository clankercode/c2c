let scheme_id = "sha256-leading-zeros-v1"
let ctx = "c2c/v1/pow"
let sep = "\x1f"
(* SECURITY BUDGET — re-derive this, do not inherit it (#71).

   Two jobs, pulling opposite ways:

   1. It must comfortably exceed 2^[Pow_policy.d_max] so a legitimate
      (throttled) actor can always mint at the maximum required difficulty
      rather than hard-failing with pow_mint_failed.
   2. It is the ONLY bound on how much CPU an UNTRUSTED relay can make this
      client burn. [mint] scans up to this many hashes whatever difficulty
      the relay states, so a relay claiming difficulty 40 costs no more than
      one claiming 12 — but it costs this whole budget.

   Job 2 is why the number is not free slack. It was previously sized as
   "~16x margin over 2^20 (d_max=20)"; d_max later dropped to 12 and the
   constant was never re-derived, so it carried ~4096x more than job 1 needs
   and pinned the hostile ceiling at ~2^24 hashes (20-32s at a measured
   1.2-1.9 us/hash).

   Sizing: nonce trials are independent Bernoulli(2^-d), so the number of
   iterations to a hit is GEOMETRIC with mean 2^d. A budget of only the mean
   would fail 1/e ~ 37% of honest mints — the margin is load-bearing, not
   padding. With margin k, P(no nonce in k*2^d trials) ~= e^-k. At 32x over
   2^12 that is e^-32 ~ 1.3e-14 per mint: unreachable next to every other
   failure mode on the /register path.

   32x = 2^17 hashes ~ 0.15-0.25s, so a hostile relay's ceiling drops ~128x.
   It also degrades gracefully if a relay legitimately raises its own d_max
   without a client update: d=13 still succeeds at e^-16, d=14 at e^-8. Past
   that the client fails FAST and honestly with pow_mint_failed instead of
   burning 20s+ of CPU, which is the correct outcome for a demand this
   client's policy never sanctions. Bounds pinned both ways in test_pow.ml. *)
let max_mint_iterations = 131_072

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
