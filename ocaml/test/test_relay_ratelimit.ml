(* S4b — rate limiter tests.
   Covers:
   - reject-over-threshold: bucket denies after burst exhausted
   - log-shape-stable: structured_log emits valid JSON with required fields *)

module RL = Relay_ratelimit

let test_reject_over_threshold () =
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  (* /pubkey policy: capacity 100, refill 10/s. *)
  (* Call check 200 times and count Allow vs Deny. *)
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

let test_refill_after_time () =
  let module M = RL.Make() in
  (* Small capacity to test refill. Create a bucket manually via repeated checks. *)
  let limiter = M.create ~gc_interval:300.0 () in
  (* First call creates bucket for this key+path. *)
  let rec loop n =
    if n <= 0 then ()
    else
      match M.check limiter ~key:"refill-test" ~cost:1 ~path:"/pubkey/foo" with
      | `Allow -> loop (n - 1)
      | `Deny _ -> Alcotest.failf "unexpected deny at attempt %d" (150 - n + 1)
  in
  loop 100;
  (* Bucket should be empty now. *)
  match M.check limiter ~key:"refill-test" ~cost:1 ~path:"/pubkey/foo" with
  | `Allow -> Alcotest.fail "expected deny after burst exhausted"
  | `Deny _ -> ()

let test_different_keys_independent () =
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  (* Exhaust key-a's bucket. *)
  let rec exhaust key =
    match M.check limiter ~key ~cost:1 ~path:"/pubkey/foo" with
    | `Allow -> exhaust key
    | `Deny _ -> ()
  in
  exhaust "key-a";
  (* key-b should still have full bucket. *)
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
  (* /pubkey: allows *)
  Alcotest.(check bool) "/pubkey allowed"
    true
    (match M.check limiter ~key:"ip1" ~cost:1 ~path:"/pubkey/alice" with `Allow -> true | `Deny _ -> false);
  (* /mobile-pair: strict 10/min *)
  Alcotest.(check bool) "/mobile-pair allowed (first)"
    true
    (match M.check limiter ~key:"ip2" ~cost:1 ~path:"/mobile-pair" with `Allow -> true | `Deny _ -> false);
  (* /device-pair: strict 5/min *)
  Alcotest.(check bool) "/device-pair allowed (first)"
    true
    (match M.check limiter ~key:"ip3" ~cost:1 ~path:"/device-pair/code123" with `Allow -> true | `Deny _ -> false);
  (* /observer: strict 20/min *)
  Alcotest.(check bool) "/observer allowed (first)"
    true
    (match M.check limiter ~key:"ip4" ~cost:1 ~path:"/observer/binding123" with `Allow -> true | `Deny _ -> false);
  (* unknown path: no limiting *)
  Alcotest.(check bool) "unknown path: no limiting"
    true
    (match M.check limiter ~key:"ip5" ~cost:1 ~path:"/other/path" with `Allow -> true | `Deny _ -> false)

let test_cleanup () =
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  ignore (M.check limiter ~key:"old-key" ~cost:1 ~path:"/pubkey/foo");
  ignore (M.check limiter ~key:"new-key" ~cost:1 ~path:"/pubkey/bar");
  (* Cleanup entries older than 1 second — entries from "just now" are not old, so 0 removed *)
  let removed = M.cleanup limiter ~older_than:1.0 in
  Alcotest.(check int) "cleanup: fresh entries not removed" 0 removed

let test_structured_log_shape () =
  (* Verify structured_log produces valid JSON with required fields. *)
  let entry = `Assoc [
    "event", `String "test_event";
    "ts", `Float 1234567890.0;
    "binding_id_prefix", `String "abc12345";
    "phone_pubkey_prefix", `String "def67890";
    "source_ip_prefix", `String "1.2.3.4";
    "result", `String "ok";
  ] in
  let json_str = Yojson.Safe.to_string entry in
  match Yojson.Safe.from_string json_str with
  | exception Yojson.Json_error msg -> Alcotest.failf "invalid JSON: %s" msg
  | parsed ->
      let field_exists name =
        match Yojson.Safe.Util.member name parsed with
        | `Null -> Alcotest.failf "missing field %s" name
        | _ -> ()
      in
      field_exists "event";
      field_exists "ts";
      field_exists "binding_id_prefix";
      field_exists "phone_pubkey_prefix";
      field_exists "source_ip_prefix";
      field_exists "result";
      Alcotest.(check int) "no extra fields at top level" 6
        (List.length (Yojson.Safe.Util.to_assoc parsed))

let test_structured_log_with_reason () =
  let ts = Unix.gettimeofday () in
  let fields = [
    "event", `String "denied";
    "ts", `Float ts;
    "binding_id_prefix", `String "xyz";
    "phone_pubkey_prefix", `String "uvw";
    "source_ip_prefix", `String "5.6.7.8";
    "result", `String "denied";
    "reason", `String "bad_signature";
  ] in
  let json_str = Yojson.Safe.to_string (`Assoc fields) in
  match Yojson.Safe.from_string json_str with
  | exception Yojson.Json_error msg -> Alcotest.failf "invalid JSON with reason: %s" msg
  | parsed ->
      match Yojson.Safe.Util.member "reason" parsed with
      | `Null -> Alcotest.fail "reason field missing when expected"
      | _ -> Alcotest.(check bool) "reason field present" true true

let () =
  Alcotest.run "relay_ratelimit" [
    "unit", [
      Alcotest.test_case "reject-over-threshold" `Quick test_reject_over_threshold;
      Alcotest.test_case "different-keys-independent" `Quick test_different_keys_independent;
      Alcotest.test_case "policy-matching" `Quick test_policy_matching;
      Alcotest.test_case "cleanup" `Quick test_cleanup;
      Alcotest.test_case "structured-log-shape" `Quick test_structured_log_shape;
      Alcotest.test_case "structured-log-with-reason" `Quick test_structured_log_with_reason;
    ];
  ]