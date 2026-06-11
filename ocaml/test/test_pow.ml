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

let () =
  Alcotest.run "pow"
    [
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
