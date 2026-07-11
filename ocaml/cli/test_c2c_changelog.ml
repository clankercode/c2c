(* Tests for C2c_changelog (B126): parser, version compare, entries_since,
   the per-client auto-show state machine, and the fixture-gated fetch.
   All network is disabled/fixture-gated — no live network. *)

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
   New changelog + onboarding.\n\
   \n\
   - `c2c changelog` shows what's new.\n\
   - Codex hooks: run `c2c install codex`.\n\
   \n\
   ## v0.9.0 — 2026-06-20\n\
   \n\
   Rooms + social layer.\n\
   \n\
   - N:N rooms via `c2c rooms join`.\n\
   \n\
   ## v0.8.0 — 2026-05-15\n\
   \n\
   Scheduling.\n\
   \n\
   - `c2c schedule set`.\n"

let versions entries = List.map (fun e -> e.C2c_changelog.version) entries

let test_parse () =
  let es = C2c_changelog.parse sample in
  check (list string) "versions parsed newest-first-as-written"
    [ "0.10.0"; "0.9.0"; "0.8.0" ] (versions es);
  let top = List.hd es in
  check (option string) "date parsed" (Some "2026-07-11") top.C2c_changelog.date;
  check (option string) "title is first prose line"
    (Some "New changelog + onboarding.") top.C2c_changelog.title;
  check bool "body contains a bullet" true
    (List.exists (fun l -> String.length l > 0 && l.[0] = '-') top.C2c_changelog.body)

let test_parse_ignores_non_version_headers () =
  (* "# c2c changelog" and stray prose must not become entries. *)
  let es = C2c_changelog.parse "# Title\n\nprose\n\n## Not a version\n\nx\n" in
  check int "no entries" 0 (List.length es)

let test_compare () =
  check bool "0.10.0 > 0.9.0" true (C2c_changelog.compare_version "0.10.0" "0.9.0" > 0);
  check bool "0.9.0 < 0.10.0" true (C2c_changelog.compare_version "0.9.0" "0.10.0" < 0);
  check int "equal" 0 (C2c_changelog.compare_version "1.2.3" "1.2.3");
  check bool "1.0.0 > 0.99.0" true (C2c_changelog.compare_version "1.0.0" "0.99.0" > 0)

let test_entries_since () =
  let es = C2c_changelog.parse sample in
  check (list string) "since 0.9.0 -> only 0.10.0" [ "0.10.0" ]
    (versions (C2c_changelog.entries_since ~version:"0.9.0" es));
  check int "since 0.10.0 -> none" 0
    (List.length (C2c_changelog.entries_since ~version:"0.10.0" es))

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
  (* current matches embedded top; first run must NOT show, just record. *)
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
  (* Simulate prior launch at 0.9.0, now upgraded to 0.10.0 (embedded). *)
  C2c_changelog.write_marker ~broker_root:root ~client:"claude" ~version:"0.9.0";
  let out =
    C2c_changelog.auto_show ~current:"0.10.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  (match out with
   | None -> fail "expected changelog block on upgrade"
   | Some block ->
       check bool "block mentions v0.10.0" true
         (contains block "v0.10.0");
       check bool "block does not include old 0.9.0" false
         (contains block "v0.9.0"));
  check (option string) "marker advanced to 0.10.0" (Some "0.10.0")
    (read_marker root "claude");
  (* Second launch at same version is silent. *)
  let out2 =
    C2c_changelog.auto_show ~current:"0.10.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  check (option string) "no re-show" None out2

let test_remote_only_waits_then_shows () =
  let root = tmp_broker () in
  (* Binary is 0.11.0 (not embedded); last shown 0.10.0. No remote cache yet
     -> nothing available locally -> None, marker NOT advanced. *)
  C2c_changelog.write_marker ~broker_root:root ~client:"claude" ~version:"0.10.0";
  let out1 =
    C2c_changelog.auto_show ~current:"0.11.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  check (option string) "waits: no output yet" None out1;
  check (option string) "marker NOT advanced" (Some "0.10.0")
    (read_marker root "claude");
  (* Simulate the background fetch landing a remote cache with 0.11.0. *)
  let dir = C2c_changelog.broker_changelog_dir ~broker_root:root in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let oc = open_out (C2c_changelog.remote_cache_path ~broker_root:root) in
  output_string oc "## v0.11.0 — 2026-08-01\n\nRemote-only feature.\n\n- new thing.\n";
  close_out oc;
  let out2 =
    C2c_changelog.auto_show ~current:"0.11.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  (match out2 with
   | None -> fail "expected 0.11.0 shown once cached"
   | Some block -> check bool "shows v0.11.0" true (contains block "v0.11.0"));
  check (option string) "marker advanced to 0.11.0" (Some "0.11.0")
    (read_marker root "claude")

let test_per_client_independent () =
  let root = tmp_broker () in
  C2c_changelog.write_marker ~broker_root:root ~client:"claude" ~version:"0.9.0";
  (* codex has never seen it: first run bootstraps silently at current. *)
  let codex_out =
    C2c_changelog.auto_show ~current:"0.10.0" ~broker_root:root ~client:"codex"
      ~now:0. ()
  in
  check (option string) "codex first-run silent" None codex_out;
  (* claude still gets the upgrade show. *)
  let claude_out =
    C2c_changelog.auto_show ~current:"0.10.0" ~broker_root:root ~client:"claude"
      ~now:0. ()
  in
  check bool "claude shows" true (Option.is_some claude_out)

let test_fetch_fixture_populates_cache () =
  let root = tmp_broker () in
  let fixture = Filename.temp_file "c2c_changelog_fixture" ".md" in
  let oc = open_out fixture in
  output_string oc "## v9.9.9 — 2099-01-01\n\nfrom fixture.\n";
  close_out oc;
  Unix.putenv "C2C_CHANGELOG_FETCH_FIXTURE" fixture;
  C2c_changelog.spawn_background_fetch ~broker_root:root;
  Unix.putenv "C2C_CHANGELOG_FETCH_FIXTURE" "";  (* clear *)
  let cache = C2c_changelog.remote_cache_path ~broker_root:root in
  check bool "cache exists" true (Sys.file_exists cache);
  let es = C2c_changelog.merged_entries ~broker_root:root in
  check bool "merged includes fixture version" true
    (List.exists (fun e -> e.C2c_changelog.version = "9.9.9") es)

let test_embedded_nonempty () =
  let es = Lazy.force C2c_changelog.embedded_entries in
  check bool "embedded changelog has entries" true (List.length es > 0)

let () =
  (* Never spawn real curl during tests: disable the network path outright.
     (The fetch-fixture test re-enables via C2C_CHANGELOG_FETCH_FIXTURE.) *)
  Unix.putenv "C2C_CHANGELOG_FETCH_DISABLE" "1";
  run "c2c_changelog"
    [ ( "parse",
        [ test_case "parse sections" `Quick test_parse
        ; test_case "ignore non-version headers" `Quick
            test_parse_ignores_non_version_headers ] )
    ; ( "compare",
        [ test_case "version ordering" `Quick test_compare
        ; test_case "entries_since" `Quick test_entries_since ] )
    ; ( "auto_show",
        [ test_case "first run bootstraps marker" `Quick
            test_first_run_bootstraps_marker_no_output
        ; test_case "same version silent" `Quick test_same_version_silent
        ; test_case "upgrade shows once" `Quick test_upgrade_shows_once
        ; test_case "remote-only waits then shows" `Quick
            test_remote_only_waits_then_shows
        ; test_case "per-client independent" `Quick test_per_client_independent ] )
    ; ( "fetch",
        [ test_case "fixture populates cache" `Quick
            test_fetch_fixture_populates_cache ] )
    ; ( "embedded",
        [ test_case "embedded non-empty" `Quick test_embedded_nonempty ] )
    ]
