(* Tests for C2c_changelog (B126): parser, version compare, entries_since,
   client/audience filters, the per-client auto-show state machine, and the
   fixture-gated fetch. All network is disabled/fixture-gated — no live network. *)

open Alcotest

(* Local substring test (avoid pulling in Str/Astring for the test). *)
let contains (haystack : string) (needle : string) : bool =
  let n = String.length haystack and m = String.length needle in
  if m = 0 then true
  else
    let rec go i =
      if i + m > n then false
      else if String.sub haystack i m = needle then true
      else go (i + 1)
    in
    go 0

let sample =
  "# c2c changelog\n\
   \n\
   Intro paragraph that must be ignored.\n\
   \n\
   ## v0.10.0 — 2026-07-11\n\
   \n\
   ### Agent-facing changelog\n\
   summary: You can now see what's new.\n\
   It spans two lines.\n\
   setup: c2c changelog\n\
   \n\
   ### Codex hook delivery\n\
   summary: Codex gets messages via hooks.\n\
   setup: c2c install codex\n\
   clients: codex\n\
   \n\
   ## v0.9.0 — 2026-06-20\n\
   \n\
   ### Rooms\n\
   summary: Join shared rooms.\n\
   setup: c2c rooms join swarm-lounge\n\
   audience: autonomous\n"

let versions entries = List.map (fun e -> e.C2c_changelog.version) entries
let titles entries = List.map (fun e -> e.C2c_changelog.title) entries

let test_parse () =
  let es = C2c_changelog.parse sample in
  check int "three feature entries across two versions" 3 (List.length es);
  check (list string) "versions" [ "0.10.0"; "0.10.0"; "0.9.0" ] (versions es);
  check (list string) "titles"
    [ "Agent-facing changelog"; "Codex hook delivery"; "Rooms" ] (titles es);
  let e0 = List.hd es in
  check (option string) "date" (Some "2026-07-11") e0.C2c_changelog.date;
  check string "summary multi-line joined"
    "You can now see what's new.\nIt spans two lines." e0.C2c_changelog.summary;
  check (option string) "setup verbatim" (Some "c2c changelog") e0.C2c_changelog.setup;
  check (list string) "no clients = all" [] e0.C2c_changelog.clients;
  check string "audience default all" "all" e0.C2c_changelog.audience;
  let e1 = List.nth es 1 in
  check (list string) "codex clients" [ "codex" ] e1.C2c_changelog.clients;
  let e2 = List.nth es 2 in
  check string "audience autonomous" "autonomous" e2.C2c_changelog.audience

let test_parse_ignores_non_version_headers () =
  let es = C2c_changelog.parse "# Title\n\nprose\n\n## Not a version\n\nx\n" in
  check int "no entries" 0 (List.length es)

let test_compare () =
  check bool "0.10.0 > 0.9.0" true (C2c_changelog.compare_version "0.10.0" "0.9.0" > 0);
  check bool "0.9.0 < 0.10.0" true (C2c_changelog.compare_version "0.9.0" "0.10.0" < 0);
  check int "equal" 0 (C2c_changelog.compare_version "1.2.3" "1.2.3");
  check bool "1.0.0 > 0.99.0" true (C2c_changelog.compare_version "1.0.0" "0.99.0" > 0)

let test_entries_since () =
  let es = C2c_changelog.parse sample in
  check (list string) "since 0.9.0 -> only 0.10.0 features" [ "0.10.0"; "0.10.0" ]
    (versions (C2c_changelog.entries_since ~version:"0.9.0" es));
  check int "since 0.10.0 -> none" 0
    (List.length (C2c_changelog.entries_since ~version:"0.10.0" es))

let test_filters () =
  let es = C2c_changelog.parse sample in
  let v10 = C2c_changelog.entries_since ~version:"0.9.0" es in
  (* claude: keeps the no-clients entry, drops the codex-only one. *)
  check (list string) "client=claude"
    [ "Agent-facing changelog" ]
    (titles (C2c_changelog.filter_client ~client:"claude" v10));
  check (list string) "client=codex keeps both (all + codex)"
    [ "Agent-facing changelog"; "Codex hook delivery" ]
    (titles (C2c_changelog.filter_client ~client:"codex" v10));
  (* audience: the 0.9.0 Rooms entry is autonomous-only. *)
  check (list string) "audience=interactive drops autonomous-only"
    [ "Agent-facing changelog"; "Codex hook delivery" ]
    (titles (C2c_changelog.filter_audience ~audience:"interactive" es));
  check (list string) "audience=autonomous keeps all + autonomous"
    [ "Agent-facing changelog"; "Codex hook delivery"; "Rooms" ]
    (titles (C2c_changelog.filter_audience ~audience:"autonomous" es))

(* ---- state machine helpers ---- *)

let tmp_broker () =
  let d = Filename.temp_file "c2c_changelog_test" "" in
  Sys.remove d;
  Unix.mkdir d 0o700;
  d

let read_marker root client =
  C2c_changelog.read_marker ~broker_root:root ~client

let test_first_run_bootstraps_marker_no_output () =
  let root = tmp_broker () in
  let out =
    C2c_changelog.auto_show ~current:"0.10.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  check (option string) "first run: no output" None out;
  check (option string) "marker recorded to current" (Some "0.10.0")
    (read_marker root "claude")

let test_same_version_silent () =
  let root = tmp_broker () in
  C2c_changelog.write_marker ~broker_root:root ~client:"claude" ~version:"0.10.0";
  let out =
    C2c_changelog.auto_show ~current:"0.10.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  check (option string) "same version: silent" None out

let test_upgrade_shows_once () =
  let root = tmp_broker () in
  C2c_changelog.write_marker ~broker_root:root ~client:"claude" ~version:"0.9.0";
  let out =
    C2c_changelog.auto_show ~current:"0.10.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  (match out with
   | None -> fail "expected changelog block on upgrade"
   | Some block ->
       check bool "block mentions a v0.10.0 title" true
         (contains block "Agent-facing changelog");
       check bool "block offers a setup command" true
         (contains block "offer to run: c2c changelog"));
  check (option string) "marker advanced to 0.10.0" (Some "0.10.0")
    (read_marker root "claude");
  let out2 =
    C2c_changelog.auto_show ~current:"0.10.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  check (option string) "no re-show" None out2

let test_downgrade_no_regress () =
  let root = tmp_broker () in
  C2c_changelog.write_marker ~broker_root:root ~client:"claude" ~version:"0.10.0";
  let out =
    C2c_changelog.auto_show ~current:"0.9.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  check (option string) "downgrade: no output" None out;
  check (option string) "marker NOT regressed" (Some "0.10.0")
    (read_marker root "claude")

let test_remote_only_waits_then_shows () =
  let root = tmp_broker () in
  (* Binary 0.11.0 (not embedded), last shown 0.10.0. No cache -> not covered
     -> None, marker untouched. *)
  C2c_changelog.write_marker ~broker_root:root ~client:"claude" ~version:"0.10.0";
  let out1 =
    C2c_changelog.auto_show ~current:"0.11.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  check (option string) "waits: no output yet" None out1;
  check (option string) "marker NOT advanced" (Some "0.10.0")
    (read_marker root "claude");
  (* Background fetch lands a remote cache with a 0.11.0 feature. *)
  let dir = C2c_changelog.broker_changelog_dir ~broker_root:root in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let oc = open_out (C2c_changelog.remote_cache_path ~broker_root:root) in
  output_string oc
    "## v0.11.0 — 2026-08-01\n\n### Remote feature\nsummary: A remote-only thing.\n";
  close_out oc;
  let out2 =
    C2c_changelog.auto_show ~current:"0.11.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  (match out2 with
   | None -> fail "expected 0.11.0 shown once cached"
   | Some block -> check bool "shows remote feature" true (contains block "Remote feature"));
  check (option string) "marker advanced to 0.11.0" (Some "0.11.0")
    (read_marker root "claude")

let test_client_filter_in_autoshow () =
  let root = tmp_broker () in
  (* Only a codex-scoped entry is new; a claude session must not be shown it,
     and (per contract) the marker must NOT advance on a no-emit. *)
  let dir = C2c_changelog.broker_changelog_dir ~broker_root:root in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let oc = open_out (C2c_changelog.remote_cache_path ~broker_root:root) in
  output_string oc
    "## v0.12.0 — 2026-09-01\n\n### Codex only\nsummary: codex thing.\nclients: codex\n";
  close_out oc;
  C2c_changelog.write_marker ~broker_root:root ~client:"claude" ~version:"0.11.0";
  let out =
    C2c_changelog.auto_show ~current:"0.12.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  check (option string) "claude not shown codex-only entry" None out;
  check (option string) "marker not advanced (no emit)" (Some "0.11.0")
    (read_marker root "claude");
  (* codex IS shown it. *)
  C2c_changelog.write_marker ~broker_root:root ~client:"codex" ~version:"0.11.0";
  let cout =
    C2c_changelog.auto_show ~current:"0.12.0" ~broker_root:root ~client:"codex"
      ~now:0. ()
  in
  check bool "codex shown" true (Option.is_some cout)

let test_per_client_independent () =
  let root = tmp_broker () in
  C2c_changelog.write_marker ~broker_root:root ~client:"claude" ~version:"0.9.0";
  let codex_out =
    C2c_changelog.auto_show ~current:"0.10.0" ~broker_root:root ~client:"codex"
      ~now:0. ()
  in
  check (option string) "codex first-run silent" None codex_out;
  let claude_out =
    C2c_changelog.auto_show ~current:"0.10.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  check bool "claude shows" true (Option.is_some claude_out)

let test_fetch_fixture_populates_cache () =
  let root = tmp_broker () in
  let fixture = Filename.temp_file "c2c_changelog_fixture" ".md" in
  let oc = open_out fixture in
  output_string oc "## v9.9.9 — 2099-01-01\n\n### From fixture\nsummary: hi.\n";
  close_out oc;
  Unix.putenv "C2C_CHANGELOG_FETCH_FIXTURE" fixture;
  C2c_changelog.spawn_background_fetch ~broker_root:root;
  Unix.putenv "C2C_CHANGELOG_FETCH_FIXTURE" "";
  let cache = C2c_changelog.remote_cache_path ~broker_root:root in
  check bool "cache exists" true (Sys.file_exists cache);
  let es = C2c_changelog.merged_entries ~broker_root:root in
  check bool "merged includes fixture version" true
    (List.exists (fun e -> e.C2c_changelog.version = "9.9.9") es)

let test_sync_fetch_fixture () =
  let root = tmp_broker () in
  let fixture = Filename.temp_file "c2c_changelog_syncfix" ".md" in
  let oc = open_out fixture in
  output_string oc "## v8.8.8 — 2098-01-01\n\n### Sync fixture\nsummary: hi.\n";
  close_out oc;
  Unix.putenv "C2C_CHANGELOG_FETCH_FIXTURE" fixture;
  let ok = C2c_changelog.fetch_remote_sync ~broker_root:root in
  Unix.putenv "C2C_CHANGELOG_FETCH_FIXTURE" "";
  check bool "sync fetch reports success" true ok;
  check bool "cache exists after sync fetch" true
    (Sys.file_exists (C2c_changelog.remote_cache_path ~broker_root:root))

let test_sync_fetch_disabled_reports_absence () =
  (* DISABLE=1 (set in main): no cache -> fetch_remote_sync must return false
     without touching the network. *)
  let root = tmp_broker () in
  let ok = C2c_changelog.fetch_remote_sync ~broker_root:root in
  check bool "disabled + no cache -> false" false ok

let test_marker_lock_serialised_autoshow () =
  (* Sanity: with_marker_lock does not deadlock sequential nesting-free use,
     and auto_show (which takes the lock internally) still shows on upgrade. *)
  let root = tmp_broker () in
  C2c_changelog.write_marker ~broker_root:root ~client:"claude" ~version:"0.9.0";
  let r1 =
    C2c_changelog.with_marker_lock ~broker_root:root ~client:"claude"
      (fun () -> C2c_changelog.read_marker ~broker_root:root ~client:"claude")
  in
  check (option string) "locked read sees marker" (Some "0.9.0") r1;
  let out =
    C2c_changelog.auto_show ~current:"0.10.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  check bool "auto_show under lock still shows" true (Option.is_some out)

let test_embedded_nonempty () =
  let es = Lazy.force C2c_changelog.embedded_entries in
  check bool "embedded changelog has entries" true (List.length es > 0);
  (* setup commands must survive verbatim through the embed+parse. *)
  check bool "an embedded entry offers `c2c install codex` verbatim" true
    (List.exists (fun e -> e.C2c_changelog.setup = Some "c2c install codex") es)

let () =
  Unix.putenv "C2C_CHANGELOG_FETCH_DISABLE" "1";
  run "c2c_changelog"
    [ ( "parse",
        [ test_case "parse features" `Quick test_parse
        ; test_case "ignore non-version headers" `Quick
            test_parse_ignores_non_version_headers ] )
    ; ( "compare",
        [ test_case "version ordering" `Quick test_compare
        ; test_case "entries_since" `Quick test_entries_since
        ; test_case "client/audience filters" `Quick test_filters ] )
    ; ( "auto_show",
        [ test_case "first run bootstraps marker" `Quick
            test_first_run_bootstraps_marker_no_output
        ; test_case "same version silent" `Quick test_same_version_silent
        ; test_case "upgrade shows once" `Quick test_upgrade_shows_once
        ; test_case "downgrade never regresses" `Quick test_downgrade_no_regress
        ; test_case "remote-only waits then shows" `Quick
            test_remote_only_waits_then_shows
        ; test_case "client filter gates emit + marker" `Quick
            test_client_filter_in_autoshow
        ; test_case "per-client independent" `Quick test_per_client_independent ] )
    ; ( "fetch",
        [ test_case "fixture populates cache" `Quick
            test_fetch_fixture_populates_cache
        ; test_case "sync fetch via fixture" `Quick test_sync_fetch_fixture
        ; test_case "sync fetch disabled -> false" `Quick
            test_sync_fetch_disabled_reports_absence ] )
    ; ( "locking",
        [ test_case "marker lock + auto_show" `Quick
            test_marker_lock_serialised_autoshow ] )
    ; ( "embedded",
        [ test_case "embedded non-empty + verbatim setup" `Quick
            test_embedded_nonempty ] )
    ]
