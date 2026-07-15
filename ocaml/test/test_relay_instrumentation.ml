(* B216 + B219 relay instrumentation unit tests.

   B216: [Relay.resolve_git_hash] precedence — RAILWAY_GIT_COMMIT_SHA (7-char
   prefix) > git fallback > "unknown".
   B219: [Relay.format_heartbeat_line] shape. *)

(* local substring check (avoid extra deps) *)
let contains ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

(* --- B216: git_hash precedence --- *)

let git_ok () = Some "abc1234"
let git_none () = None

let t_railway_wins () =
  Alcotest.(check string) "railway sha truncated to 7 chars" "deadbee"
    (Relay.resolve_git_hash ~railway_sha:(Some "deadbeef0123") ~git_fallback:git_none)

let t_railway_exactly_7 () =
  Alcotest.(check string) "railway sha of exactly 7 chars kept" "abcdef0"
    (Relay.resolve_git_hash ~railway_sha:(Some "abcdef0") ~git_fallback:git_none)

let t_railway_too_short_falls_back_to_git () =
  Alcotest.(check string) "short railway sha falls through to git" "abc1234"
    (Relay.resolve_git_hash ~railway_sha:(Some "abc12") ~git_fallback:git_ok)

let t_no_railway_uses_git () =
  Alcotest.(check string) "no railway sha uses git fallback" "abc1234"
    (Relay.resolve_git_hash ~railway_sha:None ~git_fallback:git_ok)

let t_no_railway_no_git_unknown () =
  Alcotest.(check string) "no railway + git failure yields unknown" "unknown"
    (Relay.resolve_git_hash ~railway_sha:None ~git_fallback:git_none)

let t_short_railway_no_git_unknown () =
  Alcotest.(check string) "short railway + git failure yields unknown" "unknown"
    (Relay.resolve_git_hash ~railway_sha:(Some "short") ~git_fallback:git_none)

(* memoized value is a valid hash-or-unknown string (does not crash / fork) *)
let t_memo_forces () =
  let h = Lazy.force Relay.git_hash_memo in
  Alcotest.(check bool) "memoized git hash is non-empty" true (String.length h > 0)

(* --- B219: heartbeat line formatting --- *)

let t_heartbeat_line_with_rss () =
  let line =
    Relay.format_heartbeat_line ~uptime_s:123.7 ~peer_count:5
      ~heap_words:131072 ~rss_kb:(Some 28000)
  in
  Alcotest.(check bool) "has heartbeat tag" true
    (contains ~sub:"[relay] heartbeat" line);
  Alcotest.(check bool) "uptime rounded" true (contains ~sub:"uptime=124s" line);
  Alcotest.(check bool) "peers present" true (contains ~sub:"peers=5" line);
  Alcotest.(check bool) "heap words present" true
    (contains ~sub:"gc_heap_words=131072" line);
  Alcotest.(check bool) "rss present" true (contains ~sub:"rss_kb=28000" line)

let t_heartbeat_line_no_rss () =
  let line =
    Relay.format_heartbeat_line ~uptime_s:0. ~peer_count:0
      ~heap_words:0 ~rss_kb:None
  in
  Alcotest.(check bool) "rss unknown shown as ?" true (contains ~sub:"rss_kb=?" line)

let () =
  Alcotest.run "relay_instrumentation" [
    "git_hash_precedence", [
      Alcotest.test_case "railway sha wins (truncated)" `Quick t_railway_wins;
      Alcotest.test_case "railway sha exactly 7" `Quick t_railway_exactly_7;
      Alcotest.test_case "short railway -> git" `Quick t_railway_too_short_falls_back_to_git;
      Alcotest.test_case "no railway -> git" `Quick t_no_railway_uses_git;
      Alcotest.test_case "no railway + no git -> unknown" `Quick t_no_railway_no_git_unknown;
      Alcotest.test_case "short railway + no git -> unknown" `Quick t_short_railway_no_git_unknown;
      Alcotest.test_case "memo forces without crash" `Quick t_memo_forces;
    ];
    "heartbeat_line", [
      Alcotest.test_case "line with rss" `Quick t_heartbeat_line_with_rss;
      Alcotest.test_case "line without rss" `Quick t_heartbeat_line_no_rss;
    ];
  ]
