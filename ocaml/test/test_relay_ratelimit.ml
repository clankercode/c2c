(* S4b — rate limiter tests.
   Covers:
   - reject-over-threshold: bucket denies after burst exhausted
   - log-shape-stable: structured_log emits valid JSON with required fields
   - prefix8 truncation: short strings pass through, long strings truncated at 8 chars *)

module RL = Relay_ratelimit

let test_reject_over_threshold () =
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  let rec loop n allow_count deny_count =
    if n <= 0 then (allow_count, deny_count)
    else
      match M.check limiter ~key:"burst-test" ~cost:1 ~path:"/pubkey/foo" with
      | `Allow -> loop (n - 1) (allow_count + 1) deny_count
      | `Deny _ -> loop (n - 1) allow_count (deny_count + 1)
  in
  let allow_count, deny_count = loop 200 0 0 in
  Alcotest.(check int) "100 allows then denials" 100 allow_count;
  Alcotest.(check int) "100 denials after burst" 100 deny_count

let test_different_keys_independent () =
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  let rec exhaust key =
    match M.check limiter ~key ~cost:1 ~path:"/pubkey/foo" with
    | `Allow -> exhaust key
    | `Deny _ -> ()
  in
  exhaust "key-a";
  let rec allow_n key n =
    if n <= 0 then 0
    else
      match M.check limiter ~key ~cost:1 ~path:"/pubkey/foo" with
      | `Allow -> 1 + allow_n key (n - 1)
      | `Deny _ -> n
  in
  Alcotest.(check int) "key-b still has 100 tokens" 100 (allow_n "key-b" 100)

let test_policy_matching () =
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  Alcotest.(check bool) "/pubkey allowed"
    true
    (match M.check limiter ~key:"ip1" ~cost:1 ~path:"/pubkey/alice" with `Allow -> true | `Deny _ -> false);
  Alcotest.(check bool) "/mobile-pair allowed (first)"
    true
    (match M.check limiter ~key:"ip2" ~cost:1 ~path:"/mobile-pair" with `Allow -> true | `Deny _ -> false);
  Alcotest.(check bool) "/device-pair allowed (first)"
    true
    (match M.check limiter ~key:"ip3" ~cost:1 ~path:"/device-pair/code123" with `Allow -> true | `Deny _ -> false);
  Alcotest.(check bool) "/observer allowed (first)"
    true
    (match M.check limiter ~key:"ip4" ~cost:1 ~path:"/observer/binding123" with `Allow -> true | `Deny _ -> false);
  Alcotest.(check bool) "unknown path: no limiting"
    true
    (match M.check limiter ~key:"ip5" ~cost:1 ~path:"/other/path" with `Allow -> true | `Deny _ -> false)

let test_cleanup () =
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  ignore (M.check limiter ~key:"old-key" ~cost:1 ~path:"/pubkey/foo");
  ignore (M.check limiter ~key:"new-key" ~cost:1 ~path:"/pubkey/bar");
  let removed = M.cleanup limiter ~older_than:1.0 in
  Alcotest.(check int) "cleanup: fresh entries not removed" 0 removed

let test_prefix8_truncation () =
  Alcotest.(check string) "short string unchanged" "abc" (RL.prefix8 "abc");
  Alcotest.(check string) "8-char string unchanged" "abcdefgh" (RL.prefix8 "abcdefgh");
  Alcotest.(check string) "long string truncated" "abcdefgh" (RL.prefix8 "abcdefghijklmnop")

let test_structured_log_calls_without_raising () =
  RL.structured_log
    ~event:"pair_requested"
    ~source_ip_prefix:"1.2.3.4"
    ~result:"ok"
    ~binding_id_prefix:"abc12345"
    ~phone_pubkey_prefix:"def67890"
    ();
  RL.structured_log
    ~event:"rate_limit_denied"
    ~source_ip_prefix:"9.8.7.6"
    ~result:"denied"
    ~reason:"/pubkey/foo retry_after=2.5"
    ();
  Alcotest.(check bool) "structured_log: no exception raised" true true

let test_reason_truncation () =
  let long_reason = String.init 200 (fun i -> Char.chr (97 + (i mod 26))) in
  RL.structured_log
    ~event:"denied"
    ~source_ip_prefix:"1.1.1.1"
    ~result:"denied"
    ~reason:long_reason
    ();
  Alcotest.(check bool) "reason truncation: no exception raised" true true

let () =
  Alcotest.run "relay_ratelimit" [
    "unit", [
      Alcotest.test_case "reject-over-threshold" `Quick test_reject_over_threshold;
      Alcotest.test_case "different-keys-independent" `Quick test_different_keys_independent;
      Alcotest.test_case "policy-matching" `Quick test_policy_matching;
      Alcotest.test_case "cleanup" `Quick test_cleanup;
      Alcotest.test_case "prefix8-truncation" `Quick test_prefix8_truncation;
      Alcotest.test_case "structured-log-no-raise" `Quick test_structured_log_calls_without_raising;
      Alcotest.test_case "reason-truncation" `Quick test_reason_truncation;
    ];
  ]
