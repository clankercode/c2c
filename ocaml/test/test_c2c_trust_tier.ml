open Alcotest

let tier =
  testable
    (fun fmt t -> Format.pp_print_string fmt (C2c_trust_tier.to_string t))
    ( = )

let test_same_repo () =
  check tier "repo broker" C2c_trust_tier.Same_repo
    (C2c_trust_tier.classify ~origin:C2c_trust_tier.Repo_broker
       ~sender:"co-worker")

let test_same_host () =
  check tier "machine sessions broker" C2c_trust_tier.Same_host
    (C2c_trust_tier.classify ~origin:C2c_trust_tier.Host_broker
       ~sender:"other-repo-peer")

let test_relay () =
  check tier "relay transport" C2c_trust_tier.Relay
    (C2c_trust_tier.classify ~origin:C2c_trust_tier.Relay_transport
       ~sender:"remote-peer");
  check tier "address cannot be upgraded by stale local origin"
    C2c_trust_tier.Relay
    (C2c_trust_tier.classify ~origin:C2c_trust_tier.Repo_broker
       ~sender:"remote-peer@abcdef012345")

let test_unknown_and_headless () =
  check tier "missing provenance" C2c_trust_tier.Unknown
    (C2c_trust_tier.classify ~origin:C2c_trust_tier.Origin_unknown
       ~sender:"unclassified-peer");
  check bool "interactive uncertainty asks operator" true
    (C2c_trust_tier.uncertainty_action ~interactive:true
     = C2c_trust_tier.Ask_operator);
  check bool "headless uncertainty fails closed" true
    (C2c_trust_tier.uncertainty_action ~interactive:false
     = C2c_trust_tier.Fail_closed)

let () =
  run "c2c_trust_tier"
    [ ( "classification",
        [ test_case "same_repo" `Quick test_same_repo
        ; test_case "same_host" `Quick test_same_host
        ; test_case "relay" `Quick test_relay
        ; test_case "unknown_and_headless" `Quick test_unknown_and_headless
        ] )
    ]
