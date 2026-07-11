module P = Pow

let test_difficulty_zero_always_verifies () =
  let challenge =
    P.challenge_string ~ctx:P.ctx ~route:"send" ~actor_id:"actor-1" ~epoch:7
      ~server_nonce:"srv"
  in
  Alcotest.(check bool) "empty nonce verifies at D=0" true
    (P.verify ~challenge ~difficulty:0 ~pow_nonce:"");
  Alcotest.(check bool) "arbitrary nonce verifies at D=0" true
    (P.verify ~challenge ~difficulty:0 ~pow_nonce:"not-mined")

let test_minted_nonce_verifies_and_wrong_nonce_fails () =
  let challenge =
    P.challenge_string ~ctx:P.ctx ~route:"register" ~actor_id:"ed25519-pk"
      ~epoch:42 ~server_nonce:"server-nonce"
  in
  match P.mint ~challenge ~difficulty:8 with
  | None -> Alcotest.fail "expected mint to find a nonce at D=8"
  | Some pow_nonce ->
      Alcotest.(check bool) "minted nonce verifies" true
        (P.verify ~challenge ~difficulty:8 ~pow_nonce);
      Alcotest.(check bool) "wrong nonce fails" false
        (P.verify ~challenge ~difficulty:8 ~pow_nonce:"definitely-wrong")

let test_challenge_string_is_deterministic_and_binds_fields () =
  let base =
    P.challenge_string ~ctx:P.ctx ~route:"send" ~actor_id:"actor" ~epoch:11
      ~server_nonce:"nonce"
  in
  let same =
    P.challenge_string ~ctx:P.ctx ~route:"send" ~actor_id:"actor" ~epoch:11
      ~server_nonce:"nonce"
  in
  let changed_route =
    P.challenge_string ~ctx:P.ctx ~route:"register" ~actor_id:"actor" ~epoch:11
      ~server_nonce:"nonce"
  in
  let changed_actor =
    P.challenge_string ~ctx:P.ctx ~route:"send" ~actor_id:"other" ~epoch:11
      ~server_nonce:"nonce"
  in
  let changed_epoch =
    P.challenge_string ~ctx:P.ctx ~route:"send" ~actor_id:"actor" ~epoch:12
      ~server_nonce:"nonce"
  in
  let changed_server_nonce =
    P.challenge_string ~ctx:P.ctx ~route:"send" ~actor_id:"actor" ~epoch:11
      ~server_nonce:"other"
  in
  Alcotest.(check string) "deterministic" base same;
  Alcotest.(check string) "canonical bytes"
    "c2c/v1/pow\x1fsend\x1factor\x1f11\x1fnonce"
    base;
  Alcotest.(check bool) "route changes challenge" true (base <> changed_route);
  Alcotest.(check bool) "actor changes challenge" true (base <> changed_actor);
  Alcotest.(check bool) "epoch changes challenge" true (base <> changed_epoch);
  Alcotest.(check bool) "server nonce changes challenge" true
    (base <> changed_server_nonce)

let test_leading_zero_bits_counts_digest_prefix () =
  Alcotest.(check int) "empty digest" 0 (P.leading_zero_bits "");
  Alcotest.(check int) "zero byte plus 00001111" 12
    (P.leading_zero_bits "\x00\x0f");
  Alcotest.(check int) "stops at first one bit" 3
    (P.leading_zero_bits "\x10\x00")

(* Regression: dogfooding showed registration hard-failed with pow_mint_failed
   because the policy's d_max exceeded the client's mint-iteration budget. The
   mint cap MUST cover the maximum difficulty the policy can ever demand, or a
   legitimate throttled actor cannot mint and registration fails outright. *)
let test_mint_budget_covers_d_max () =
  Alcotest.(check bool)
    "max_mint_iterations >= 2^d_max" true
    (P.max_mint_iterations >= (1 lsl Pow_policy.d_max))

(* B014: PoW-difficulty metadata on delivered messages. The units helper turns
   a leading-zero-bit difficulty into an interpretable "expected hashes" weight
   (~2^bits), so a recipient agent can reason about a sender's PoW weight. *)
module RPC = Relay_pow_challenge

let test_expected_hashes_of_difficulty () =
  Alcotest.(check int) "D=0 -> 0 hashes" 0 (RPC.expected_hashes_of_difficulty 0);
  Alcotest.(check int) "negative -> 0 hashes" 0 (RPC.expected_hashes_of_difficulty (-1));
  Alcotest.(check int) "D=1 -> 2 hashes" 2 (RPC.expected_hashes_of_difficulty 1);
  Alcotest.(check int) "D=8 -> 256 hashes" 256 (RPC.expected_hashes_of_difficulty 8);
  Alcotest.(check int) "D=12 (d_max) -> 4096 hashes" 4096
    (RPC.expected_hashes_of_difficulty 12);
  (* Matches the primitive: expected work ~ 2^difficulty. *)
  Alcotest.(check int) "matches 2^d_max" (1 lsl Pow_policy.d_max)
    (RPC.expected_hashes_of_difficulty Pow_policy.d_max)

let test_pow_meta_json_is_self_describing () =
  let open Yojson.Safe.Util in
  let j = RPC.pow_meta_json ~difficulty:8 in
  Alcotest.(check int) "difficulty_bits" 8 (j |> member "difficulty_bits" |> to_int);
  Alcotest.(check int) "expected_hashes" 256 (j |> member "expected_hashes" |> to_int);
  Alcotest.(check string) "scheme = pow scheme id" Pow.scheme_id
    (j |> member "scheme" |> to_string)

let has_pow_key fields = List.mem_assoc "pow" fields

let test_with_pow_meta_gated_on_recorded () =
  (* Recorded (>= 0): appends a pow object. *)
  (match RPC.with_pow_meta ~difficulty:8 [ ("k", `String "v") ] with
   | fields ->
     Alcotest.(check bool) "recorded appends pow" true (has_pow_key fields);
     Alcotest.(check bool) "preserves prior fields" true (List.mem_assoc "k" fields));
  (* Unrecorded sentinel (-1): no pow object. *)
  Alcotest.(check bool) "unrecorded omits pow" false
    (has_pow_key (RPC.with_pow_meta ~difficulty:RPC.pow_difficulty_unrecorded [ ("k", `String "v") ]))

let () =
  Alcotest.run "pow"
    [
      ( "b014-metadata",
        [
          Alcotest.test_case "expected_hashes = 2^difficulty" `Quick
            test_expected_hashes_of_difficulty;
          Alcotest.test_case "pow_meta_json is self-describing" `Quick
            test_pow_meta_json_is_self_describing;
          Alcotest.test_case "with_pow_meta gated on recorded difficulty" `Quick
            test_with_pow_meta_gated_on_recorded;
        ] );
      ( "primitive",
        [
          Alcotest.test_case "mint budget covers d_max" `Quick
            test_mint_budget_covers_d_max;
          Alcotest.test_case "D=0 always verifies" `Quick
            test_difficulty_zero_always_verifies;
          Alcotest.test_case "minted nonce verifies; wrong nonce fails" `Quick
            test_minted_nonce_verifies_and_wrong_nonce_fails;
          Alcotest.test_case "challenge string is canonical" `Quick
            test_challenge_string_is_deterministic_and_binds_fields;
          Alcotest.test_case "leading zero bit count" `Quick
            test_leading_zero_bits_counts_digest_prefix;
        ] );
    ]
