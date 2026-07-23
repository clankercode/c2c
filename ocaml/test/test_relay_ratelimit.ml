(* S4b — rate limiter tests.
   Covers:
   - reject-over-threshold: bucket denies after burst exhausted
   - log-shape-stable: structured_log emits valid JSON with required fields
   - prefix8 truncation: short strings pass through, long strings truncated at 8 chars
   - B243: per-(key, endpoint-class) buckets so first-touch path cannot freeze
     sibling endpoints onto the wrong capacity/refill *)

module RL = Relay_ratelimit

let is_allow = function `Allow -> true | `Deny _ -> false
let is_deny = function `Deny _ -> true | `Allow -> false

(* [check] is a partial application of Make.check limiter. *)
let rec exhaust_bucket check ~key ~path =
  match check ~key ~cost:1 ~path with
  | `Allow -> exhaust_bucket check ~key ~path
  | `Deny _ -> ()

let count_allows check ~key ~path ~n =
  let rec loop i acc =
    if i <= 0 then acc
    else
      match check ~key ~cost:1 ~path with
      | `Allow -> loop (i - 1) (acc + 1)
      | `Deny _ -> acc
  in
  loop n 0

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
  let check = M.check limiter in
  exhaust_bucket check ~key:"key-a" ~path:"/pubkey/foo";
  Alcotest.(check int) "key-b still has 100 tokens"
    100 (count_allows check ~key:"key-b" ~path:"/pubkey/foo" ~n:100)

let test_policy_matching () =
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  Alcotest.(check bool) "/pubkey allowed"
    true
    (is_allow (M.check limiter ~key:"ip1" ~cost:1 ~path:"/pubkey/alice"));
  Alcotest.(check bool) "/mobile-pair allowed (first)"
    true
    (is_allow (M.check limiter ~key:"ip2" ~cost:1 ~path:"/mobile-pair"));
  Alcotest.(check bool) "/device-pair allowed (first)"
    true
    (is_allow (M.check limiter ~key:"ip3" ~cost:1 ~path:"/device-pair/code123"));
  Alcotest.(check bool) "/observer allowed (first)"
    true
    (is_allow (M.check limiter ~key:"ip4" ~cost:1 ~path:"/observer/binding123"));
  Alcotest.(check bool) "/ws/subscribe allowed (first)"
    true
    (is_allow (M.check limiter ~key:"ip6" ~cost:1 ~path:"/ws/subscribe"));
  Alcotest.(check bool) "unknown path: no limiting"
    true
    (is_allow (M.check limiter ~key:"ip5" ~cost:1 ~path:"/other/path"))

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
  Alcotest.(check string) "long string truncated" "abcdefgh" (RL.prefix8 "abcdefghijklmnop");
  Alcotest.(check int) "8-char max" 8 (String.length (RL.prefix8 "abcdefghij"))

let test_structured_log_json_fields () =
  let captured_buf = Buffer.create 256 in
  let fmt = Format.formatter_of_buffer captured_buf in
  let reporter = Logs.format_reporter ~app:fmt ~dst:fmt () in
  let old_level = Logs.level () in
  Logs.set_reporter reporter;
  Logs.set_level (Some Logs.Info);
  RL.structured_log
    ~event:"pair_requested"
    ~source_ip_prefix:"1.2.3.4"
    ~result:"ok"
    ~binding_id_prefix:"abc12345"
    ~phone_pubkey_prefix:"def67890"
    ();
  Logs.set_level old_level;
  let captured = Buffer.contents captured_buf in
  let trimmed = String.trim captured in
  Alcotest.(check bool) "structured_log emits non-empty output"
    true (String.length trimmed > 0);
  let json_start = try String.index trimmed '{' with Not_found -> -1 in
  Alcotest.(check bool) "structured_log contains JSON object"
    true (json_start >= 0);
  if json_start >= 0 then
    let json_str = String.sub trimmed json_start (String.length trimmed - json_start) in
    match Yojson.Safe.from_string json_str with
    | exception Yojson.Json_error _ ->
        Alcotest.failf "structured_log output is not valid JSON: %s" trimmed
    | parsed ->
        let present_str name =
          match Yojson.Safe.Util.member name parsed with
          | `Null -> Alcotest.failf "missing field: %s" name
          | v -> Yojson.Safe.Util.to_string v
        in
        let present_any name =
          match Yojson.Safe.Util.member name parsed with
          | `Null -> Alcotest.failf "missing field: %s" name
          | v -> v
        in
        let event_v = present_str "event" in
        Alcotest.(check string) "event field" "pair_requested" event_v;
        let ts_v = present_any "ts" in
        Alcotest.(check bool) "ts field present" true
          (ts_v <> `Null);
        let src_ip = present_str "source_ip_prefix" in
        Alcotest.(check string) "source_ip_prefix <= 8 chars" "1.2.3.4" src_ip;
        let bid = present_str "binding_id_prefix" in
        Alcotest.(check int) "binding_id_prefix <= 8 chars" 8 (String.length bid);
        let ppub = present_str "phone_pubkey_prefix" in
        Alcotest.(check int) "phone_pubkey_prefix <= 8 chars" 8 (String.length ppub);
        let result_v = present_str "result" in
        Alcotest.(check string) "result field" "ok" result_v

let test_reason_truncation () =
  let long_reason = String.init 200 (fun i -> Char.chr (97 + (i mod 26))) in
  let captured_buf = Buffer.create 512 in
  let fmt = Format.formatter_of_buffer captured_buf in
  let reporter = Logs.format_reporter ~app:fmt ~dst:fmt () in
  let old_level = Logs.level () in
  Logs.set_reporter reporter;
  Logs.set_level (Some Logs.Info);
  RL.structured_log
    ~event:"denied"
    ~source_ip_prefix:"1.1.1.1"
    ~result:"denied"
    ~reason:long_reason
    ();
  Logs.set_level old_level;
  let captured = Buffer.contents captured_buf in
  let trimmed = String.trim captured in
  let json_start = try String.index trimmed '{' with Not_found -> -1 in
  if json_start >= 0 then
    let json_str = String.sub trimmed json_start (String.length trimmed - json_start) in
    match Yojson.Safe.from_string json_str with
    | exception Yojson.Json_error _ ->
        Alcotest.failf "reason truncation produced invalid JSON: %s" trimmed
    | parsed ->
        match Yojson.Safe.Util.member "reason" parsed with
        | `Null -> Alcotest.fail "reason field missing when expected"
        | v ->
            let reason_str = Yojson.Safe.to_string v in
            let reason_len = String.length reason_str - 2 in
            Alcotest.(check int) "reason truncated to 120 chars" 120 reason_len
  else
    Alcotest.failf "reason truncation: no JSON captured"

(* --- B243: endpoint-class isolation -------------------------------------- *)

let test_endpoint_class_of_path () =
  Alcotest.(check (option string)) "pubkey"
    (Some "pubkey") (RL.endpoint_class_of_path "/pubkey/alice");
  Alcotest.(check (option string)) "send"
    (Some "send") (RL.endpoint_class_of_path "/send");
  Alcotest.(check (option string)) "send_all before send"
    (Some "send_all") (RL.endpoint_class_of_path "/send_all");
  Alcotest.(check (option string)) "send_room before send"
    (Some "send_room") (RL.endpoint_class_of_path "/send_room");
  Alcotest.(check (option string)) "peek_inbox"
    (Some "peek_inbox") (RL.endpoint_class_of_path "/peek_inbox");
  Alcotest.(check (option string)) "poll_inbox"
    (Some "poll_inbox") (RL.endpoint_class_of_path "/poll_inbox");
  Alcotest.(check (option string)) "ws_subscribe"
    (Some "ws_subscribe") (RL.endpoint_class_of_path "/ws/subscribe");
  Alcotest.(check (option string)) "unmetered"
    None (RL.endpoint_class_of_path "/health")

let test_b243_classes_independent_same_ip () =
  (* Repro of prod bug: IP first touches /send (cap 20, refill 1/s), then
     /pubkey must still get its own generous bucket (cap 100, refill 10/s) —
     not inherit the send-family freeze. *)
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  let check = M.check limiter in
  let ip = "203.0.113.50" in
  exhaust_bucket check ~key:ip ~path:"/send";
  Alcotest.(check bool) "send exhausted"
    true (is_deny (check ~key:ip ~cost:1 ~path:"/send"));
  (* /pubkey must still allow a full 100-burst for the same IP *)
  Alcotest.(check int) "pubkey still has independent 100-token burst"
    100 (count_allows check ~key:ip ~path:"/pubkey/probe" ~n:100);
  Alcotest.(check bool) "pubkey then denies at capacity"
    true (is_deny (check ~key:ip ~cost:1 ~path:"/pubkey/probe"));
  (* /peek_inbox is a third class — independent of both *)
  Alcotest.(check int) "peek_inbox independent 30-token burst"
    30 (count_allows check ~key:ip ~path:"/peek_inbox" ~n:30);
  Alcotest.(check bool) "peek_inbox then denies"
    true (is_deny (check ~key:ip ~cost:1 ~path:"/peek_inbox"));
  (* Three classes → three buckets for one IP *)
  Alcotest.(check int) "three endpoint-class buckets for one IP"
    3 (M.bucket_count limiter)

let test_b243_first_touch_does_not_poison_sibling () =
  (* Reverse order of first-touch: generous /pubkey first, then strict /send
     must still only get capacity 20 — not ride the pubkey bucket. *)
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  let check = M.check limiter in
  let ip = "198.51.100.9" in
  ignore (check ~key:ip ~cost:1 ~path:"/pubkey/x");
  Alcotest.(check int) "send has its own 20-token capacity after pubkey touch"
    20 (count_allows check ~key:ip ~path:"/send" ~n:30);
  Alcotest.(check bool) "send denies after 20"
    true (is_deny (check ~key:ip ~cost:1 ~path:"/send"));
  (* pubkey still has remaining tokens from the single earlier allow *)
  Alcotest.(check int) "pubkey residual after one earlier allow"
    99 (count_allows check ~key:ip ~path:"/pubkey/y" ~n:99)

let test_b243_same_class_shares_bucket () =
  (* Two paths in the same class (/pubkey/a and /pubkey/b) share one bucket. *)
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  let check = M.check limiter in
  let ip = "192.0.2.1" in
  Alcotest.(check int) "drain 60 via /pubkey/a"
    60 (count_allows check ~key:ip ~path:"/pubkey/a" ~n:60);
  Alcotest.(check int) "remaining 40 via /pubkey/b"
    40 (count_allows check ~key:ip ~path:"/pubkey/b" ~n:40);
  Alcotest.(check bool) "shared class exhausted"
    true (is_deny (check ~key:ip ~cost:1 ~path:"/pubkey/c"));
  Alcotest.(check int) "one bucket for the class"
    1 (M.bucket_count limiter)

let test_b243_bucket_params_match_policy () =
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  let ip = "192.0.2.77" in
  ignore (M.check limiter ~key:ip ~cost:1 ~path:"/send");
  ignore (M.check limiter ~key:ip ~cost:1 ~path:"/pubkey/z");
  ignore (M.check limiter ~key:ip ~cost:1 ~path:"/peek_inbox");
  let expect path ~cap ~rate =
    match M.find_bucket limiter ~key:ip ~path with
    | None -> Alcotest.failf "missing bucket for %s" path
    | Some b ->
        Alcotest.(check (float 1e-9)) (path ^ " capacity")
          cap (RL.TokenBucket.capacity b);
        Alcotest.(check (float 1e-9)) (path ^ " refill_rate")
          rate (RL.TokenBucket.refill_rate b)
  in
  expect "/send" ~cap:20.0 ~rate:1.0;
  expect "/pubkey/z" ~cap:100.0 ~rate:10.0;
  expect "/peek_inbox" ~cap:30.0 ~rate:2.0

let test_b243_send_family_classes_are_distinct () =
  (* /send, /send_all, /send_room are separate classes (same numeric policy
     each) so exhausting one does not silence the others. *)
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  let check = M.check limiter in
  let ip = "192.0.2.88" in
  exhaust_bucket check ~key:ip ~path:"/send";
  Alcotest.(check int) "send_all independent after send exhaust"
    20 (count_allows check ~key:ip ~path:"/send_all" ~n:20);
  Alcotest.(check int) "send_room independent after send exhaust"
    20 (count_allows check ~key:ip ~path:"/send_room" ~n:20);
  Alcotest.(check int) "three send-family buckets"
    3 (M.bucket_count limiter)

let test_b243_deny_retry_after_uses_class_refill () =
  (* Prod symptom: /pubkey 429'd with ~1s retry_after because the IP bucket
     was created by /send (refill 1/s). After B243, exhausted /pubkey must
     report ~0.1s (refill 10/s) while exhausted /send still reports ~1s. *)
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  let check = M.check limiter in
  let ip = "192.0.2.99" in
  exhaust_bucket check ~key:ip ~path:"/send";
  exhaust_bucket check ~key:ip ~path:"/pubkey/p";
  let deny_secs path =
    match check ~key:ip ~cost:1 ~path with
    | `Allow -> Alcotest.failf "expected deny for %s" path
    | `Deny s -> s
  in
  let send_wait = deny_secs "/send" in
  let pubkey_wait = deny_secs "/pubkey/p" in
  (* Allow generous slack for wall-clock refill during the test itself. *)
  Alcotest.(check bool) "send retry_after near 1/refill(1/s)"
    true (send_wait > 0.5 && send_wait <= 1.05);
  Alcotest.(check bool) "pubkey retry_after near 1/refill(10/s)"
    true (pubkey_wait > 0.0 && pubkey_wait <= 0.15);
  Alcotest.(check bool) "pubkey refills faster than send (independent rates)"
    true (pubkey_wait < send_wait *. 0.5)

(* --- B276: /ws/subscribe is metered (was unmetered) ---------------------- *)

let contains_sub ~sub s =
  let n = String.length s and m = String.length sub in
  let rec loop i =
    if i + m > n then false
    else if String.sub s i m = sub then true
    else loop (i + 1)
  in
  loop 0

let test_b276_ws_subscribe_class_and_params () =
  (* Class label + frozen capacity/refill: 10 burst, 10/min ≈ 0.167/s. *)
  Alcotest.(check (option string)) "class label"
    (Some "ws_subscribe") (RL.endpoint_class_of_path "/ws/subscribe");
  Alcotest.(check (option string)) "prefix match"
    (Some "ws_subscribe") (RL.endpoint_class_of_path "/ws/subscribe/extra");
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  let ip = "192.0.2.176" in
  ignore (M.check limiter ~key:ip ~cost:1 ~path:"/ws/subscribe");
  match M.find_bucket limiter ~key:ip ~path:"/ws/subscribe" with
  | None -> Alcotest.fail "missing ws_subscribe bucket"
  | Some b ->
      Alcotest.(check (float 1e-9)) "capacity 10"
        10.0 (RL.TokenBucket.capacity b);
      Alcotest.(check (float 1e-9)) "refill 0.167/s"
        0.167 (RL.TokenBucket.refill_rate b)

let test_b276_ws_subscribe_burst_then_deny () =
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  let check = M.check limiter in
  let ip = "192.0.2.177" in
  Alcotest.(check int) "10-token burst"
    10 (count_allows check ~key:ip ~path:"/ws/subscribe" ~n:10);
  Alcotest.(check bool) "11th denied"
    true (is_deny (check ~key:ip ~cost:1 ~path:"/ws/subscribe"));
  match check ~key:ip ~cost:1 ~path:"/ws/subscribe" with
  | `Allow -> Alcotest.fail "expected deny with retry_after"
  | `Deny retry_after ->
      (* 1/0.167 ≈ 6s; allow wall-clock refill slack. *)
      Alcotest.(check bool) "retry_after near 1/refill(0.167/s)"
        true (retry_after > 3.0 && retry_after <= 6.5)

let test_b276_ws_subscribe_independent_of_observer () =
  (* Exhaust /observer must not starve /ws/subscribe (B243 class isolation). *)
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  let check = M.check limiter in
  let ip = "192.0.2.178" in
  exhaust_bucket check ~key:ip ~path:"/observer/binding-x";
  Alcotest.(check bool) "observer exhausted"
    true (is_deny (check ~key:ip ~cost:1 ~path:"/observer/binding-x"));
  Alcotest.(check int) "ws_subscribe still has full 10-token burst"
    10 (count_allows check ~key:ip ~path:"/ws/subscribe" ~n:10);
  Alcotest.(check bool) "ws_subscribe then denies at capacity"
    true (is_deny (check ~key:ip ~cost:1 ~path:"/ws/subscribe"));
  Alcotest.(check int) "two independent buckets"
    2 (M.bucket_count limiter)

let test_b276_ws_subscribe_stricter_than_observer () =
  (* Policy intent: burst 10 < observer 20, refill 10/min < observer 20/min. *)
  let module M = RL.Make() in
  let limiter = M.create ~gc_interval:300.0 () in
  let check = M.check limiter in
  let ip = "192.0.2.179" in
  Alcotest.(check int) "ws_subscribe burst is 10 not 20"
    10 (count_allows check ~key:ip ~path:"/ws/subscribe" ~n:30);
  let ip2 = "192.0.2.180" in
  Alcotest.(check int) "observer burst remains 20"
    20 (count_allows check ~key:ip2 ~path:"/observer/b" ~n:30)

let test_b276_ws_subscribe_structured_log_on_deny () =
  (* Request-path style: deny log uses event=ws_subscribe, result=rate_limit_denied
     (mirrors relay.ml rate-limit deny arm for /ws/subscribe). *)
  let captured_buf = Buffer.create 256 in
  let fmt = Format.formatter_of_buffer captured_buf in
  let reporter = Logs.format_reporter ~app:fmt ~dst:fmt () in
  let old_level = Logs.level () in
  Logs.set_reporter reporter;
  Logs.set_level (Some Logs.Info);
  RL.structured_log
    ~event:"ws_subscribe"
    ~source_ip_prefix:"203.0.11"
    ~result:"rate_limit_denied"
    ~reason:"/ws/subscribe retry_after=5.988"
    ();
  Logs.set_level old_level;
  let captured = Buffer.contents captured_buf in
  let trimmed = String.trim captured in
  let json_start = try String.index trimmed '{' with Not_found -> -1 in
  Alcotest.(check bool) "emits JSON" true (json_start >= 0);
  if json_start >= 0 then
    let json_str =
      String.sub trimmed json_start (String.length trimmed - json_start)
    in
    match Yojson.Safe.from_string json_str with
    | exception Yojson.Json_error _ ->
        Alcotest.failf "invalid JSON: %s" trimmed
    | parsed ->
        let str name =
          match Yojson.Safe.Util.member name parsed with
          | `Null -> Alcotest.failf "missing %s" name
          | v -> Yojson.Safe.Util.to_string v
        in
        Alcotest.(check string) "event" "ws_subscribe" (str "event");
        Alcotest.(check string) "result" "rate_limit_denied" (str "result");
        Alcotest.(check bool) "reason mentions path" true
          (contains_sub ~sub:"/ws/subscribe" (str "reason"));
        Alcotest.(check bool) "reason mentions retry_after" true
          (contains_sub ~sub:"retry_after" (str "reason"))

let () =
  Alcotest.run "relay_ratelimit" [
    "unit", [
      Alcotest.test_case "reject-over-threshold" `Quick test_reject_over_threshold;
      Alcotest.test_case "different-keys-independent" `Quick test_different_keys_independent;
      Alcotest.test_case "policy-matching" `Quick test_policy_matching;
      Alcotest.test_case "cleanup" `Quick test_cleanup;
      Alcotest.test_case "prefix8-truncation" `Quick test_prefix8_truncation;
      Alcotest.test_case "structured-log-json-fields" `Slow test_structured_log_json_fields;
      Alcotest.test_case "reason-truncation" `Slow test_reason_truncation;
      Alcotest.test_case "endpoint-class-of-path" `Quick test_endpoint_class_of_path;
      Alcotest.test_case "b243-classes-independent-same-ip" `Quick
        test_b243_classes_independent_same_ip;
      Alcotest.test_case "b243-first-touch-does-not-poison-sibling" `Quick
        test_b243_first_touch_does_not_poison_sibling;
      Alcotest.test_case "b243-same-class-shares-bucket" `Quick
        test_b243_same_class_shares_bucket;
      Alcotest.test_case "b243-bucket-params-match-policy" `Quick
        test_b243_bucket_params_match_policy;
      Alcotest.test_case "b243-send-family-classes-are-distinct" `Quick
        test_b243_send_family_classes_are_distinct;
      Alcotest.test_case "b243-deny-retry-after-uses-class-refill" `Quick
        test_b243_deny_retry_after_uses_class_refill;
      Alcotest.test_case "b276-ws-subscribe-class-and-params" `Quick
        test_b276_ws_subscribe_class_and_params;
      Alcotest.test_case "b276-ws-subscribe-burst-then-deny" `Quick
        test_b276_ws_subscribe_burst_then_deny;
      Alcotest.test_case "b276-ws-subscribe-independent-of-observer" `Quick
        test_b276_ws_subscribe_independent_of_observer;
      Alcotest.test_case "b276-ws-subscribe-stricter-than-observer" `Quick
        test_b276_ws_subscribe_stricter_than_observer;
      Alcotest.test_case "b276-ws-subscribe-structured-log-on-deny" `Slow
        test_b276_ws_subscribe_structured_log_on_deny;
    ];
  ]
