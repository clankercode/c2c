(* test_c2c_version.ml — B287 regression guard: `c2c --version` must report the
   BUILD time, not the wall clock at invocation.

   The bug: [version_string] used to embed [C2c_time.now_iso8601_utc ()], so the
   trailing timestamp changed on every invocation — a wall-clock echo dressed up
   as build metadata. The fix makes [Version.build_identity] the primary,
   parseable identity anchored to [Version.build_date], and confines any "now"
   clock to a secondary, visually-demarcated segment
   ([Version.display_with_clock]).

   These are pure-function assertions (fast, deterministic) plus one end-to-end
   smoke test that the compiled binary's `--version` is wired up the same way. *)

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else
    let rec loop i =
      i + nl <= hl && (String.sub haystack i nl = needle || loop (i + 1))
    in
    loop 0

(* An ISO-8601 UTC instant has an uppercase 'T' date/time separator and a
   trailing 'Z'. The primary build identity must contain NEITHER — its only
   timestamp is the [YYYY-MM-DD] build date. This is the discriminator that
   catches a re-introduced wall clock. *)
let has_iso_instant s = contains ~needle:"T" s || contains ~needle:"Z" s

let test_build_identity_uses_build_date () =
  let id = Version.build_identity () in
  Alcotest.(check bool)
    (Printf.sprintf "build identity %S must contain the build date %S" id
       Version.build_date)
    true
    (contains ~needle:Version.build_date id);
  Alcotest.(check bool)
    (Printf.sprintf "build identity %S must demarcate the build date with \"(built \"" id)
    true
    (contains ~needle:"(built " id)

let test_build_identity_has_no_wall_clock () =
  let id = Version.build_identity () in
  Alcotest.(check bool)
    (Printf.sprintf
       "build identity %S must NOT contain a wall-clock ISO instant (no 'T'/'Z')"
       id)
    false
    (has_iso_instant id)

let test_build_identity_is_deterministic () =
  (* A build-time constant does not change between calls; a wall clock would
     (eventually). Two calls must be byte-identical. *)
  let a = Version.build_identity () in
  let b = Version.build_identity () in
  Alcotest.(check string) "build identity is a stable compile-time constant" a b

let test_display_clock_is_secondary_and_demarcated () =
  let frozen = "2001-02-03T04:05:06Z" in
  let line = Version.display_with_clock ~now:frozen () in
  let id = Version.build_identity () in
  (* The primary identity leads the line (parseable prefix preserved). *)
  Alcotest.(check bool)
    (Printf.sprintf "display line %S must start with the build identity %S" line id)
    true
    (String.length line >= String.length id && String.sub line 0 (String.length id) = id);
  (* The now clock is present but clearly labelled / bracketed off to the side. *)
  Alcotest.(check bool)
    (Printf.sprintf "display line %S must demarcate the now clock with \"[now:\"" line)
    true
    (contains ~needle:"[now:" line);
  Alcotest.(check bool)
    (Printf.sprintf "display line %S must carry the injected now instant" line)
    true
    (contains ~needle:frozen line)

(* --- end-to-end: the compiled binary's `--version` is wired the same way --- *)

(* Dune may launch this test from the source root (via [dune exec]) or the
   build directory (via [dune runtest]); the sibling binary is reliable in
   both cases, unlike a cwd-relative ["./c2c.exe"]. *)
let c2c_binary = Filename.concat (Filename.dirname Sys.executable_name) "c2c.exe"

let read_all ic =
  let buf = Buffer.create 256 in
  (try
     while true do
       Buffer.add_channel buf ic 1
     done
   with End_of_file -> ());
  Buffer.contents buf

(* Run `c2c <args>` and capture full stdout (stderr discarded). *)
let run_version args =
  let ic =
    Unix.open_process_in
      (Filename.quote c2c_binary ^ " " ^ args ^ " 2>/dev/null")
  in
  Fun.protect
    ~finally:(fun () -> ignore (Unix.close_process_in ic))
    (fun () -> read_all ic)

(* Run `c2c <args>` with C2C_MCP_BROKER_ROOT pinned to a temp broker so the
   cache-only update-available lookup reads a fixture we control. *)
let run_version_env ~broker_root args =
  let cmd =
    Printf.sprintf "C2C_MCP_BROKER_ROOT=%s %s %s 2>/dev/null"
      (Filename.quote broker_root) (Filename.quote c2c_binary) args
  in
  let ic = Unix.open_process_in cmd in
  Fun.protect
    ~finally:(fun () -> ignore (Unix.close_process_in ic))
    (fun () -> read_all ic)

let first_line s = match String.index_opt s '\n' with
  | Some i -> String.sub s 0 i
  | None -> s

let read_first_line_of_version () = first_line (run_version "--version")

let test_binary_version_reports_build_date () =
  let line = read_first_line_of_version () in
  Alcotest.(check bool)
    (Printf.sprintf "`c2c --version` first line %S must contain build date %S" line
       Version.build_date)
    true
    (contains ~needle:Version.build_date line);
  Alcotest.(check bool)
    (Printf.sprintf "`c2c --version` first line %S must demarcate build date" line)
    true
    (contains ~needle:"(built " line);
  Alcotest.(check bool)
    (Printf.sprintf "`c2c --version` first line %S must label its optional now clock" line)
    true
    (contains ~needle:"[now:" line)

(* B289: `c2c version` is a real subcommand and must be at least as informative
   as bare `c2c --version`. The [now:] clock differs between two invocations, so
   we compare only the first line (build identity) for byte equality, and assert
   `c2c version` carries the same build-identity markers. *)
let strip_now_clock line =
  (* Drop the demarcated "[now:...]" segment so the stable build identity remains
     comparable across invocations at different wall-clock times. *)
  match String.index_opt line '[' with
  | Some i -> String.trim (String.sub line 0 i)
  | None -> String.trim line

let test_version_subcommand_first_line_matches_flag () =
  let flag = strip_now_clock (first_line (run_version "--version")) in
  let sub = strip_now_clock (first_line (run_version "version")) in
  Alcotest.(check string)
    "`c2c version` build identity must match `c2c --version`" flag sub

let test_version_subcommand_reports_build_date () =
  let line = first_line (run_version "version") in
  Alcotest.(check bool)
    (Printf.sprintf "`c2c version` first line %S must contain build date %S" line
       Version.build_date)
    true
    (contains ~needle:Version.build_date line);
  Alcotest.(check bool)
    (Printf.sprintf "`c2c version` first line %S must demarcate build date" line)
    true
    (contains ~needle:"(built " line);
  Alcotest.(check bool)
    (Printf.sprintf "`c2c version` first line %S must label its optional now clock"
       line)
    true
    (contains ~needle:"[now:" line)

let test_version_subcommand_is_superset () =
  (* Every non-clock line of `--version` (build identity, optional update line)
     must also appear in `c2c version` output — the subcommand is a superset. *)
  let lines s =
    String.split_on_char '\n' s
    |> List.map strip_now_clock
    |> List.filter (fun l -> l <> "")
  in
  let flag_lines = lines (run_version "--version") in
  let sub_out = run_version "version" in
  List.iter
    (fun l ->
      Alcotest.(check bool)
        (Printf.sprintf "`c2c version` must include `--version` line %S" l)
        true
        (contains ~needle:l sub_out))
    flag_lines

(* B289 P2: the optional cache-only "newer release" line must appear under BOTH
   `--version` and `version` when the local changelog cache advertises a newer
   version. Sentinel 99.0.0 is never embedded (see test_c2c_changelog.ml), so
   this exercises the remote-cache path rather than an embedded entry. *)
let test_version_update_line_parity () =
  let root = Filename.temp_file "c2c_version_broker" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let cdir = Filename.concat root "changelog" in
  Unix.mkdir cdir 0o700;
  let oc = open_out (Filename.concat cdir "remote.md") in
  output_string oc
    "## v99.0.0 — 2099-01-01\n\n### Future feature\nsummary: a future thing.\n";
  close_out oc;
  let needle = "newer release 99.0.0 available" in
  let flag_out = run_version_env ~broker_root:root "--version" in
  let sub_out = run_version_env ~broker_root:root "version" in
  Alcotest.(check bool)
    (Printf.sprintf "`c2c --version` must surface the cached newer release; got %S"
       flag_out)
    true
    (contains ~needle flag_out);
  Alcotest.(check bool)
    (Printf.sprintf "`c2c version` must surface the cached newer release; got %S"
       sub_out)
    true
    (contains ~needle sub_out)

let version_exit_code args =
  Sys.command
    (Printf.sprintf "%s %s >/dev/null 2>&1" (Filename.quote c2c_binary) args)

(* B289: the fast path must accept only the no-arg and `--version` shapes;
   unknown flags / stray positionals must still error via Cmdliner rather than
   silently succeed with version output. *)
let test_version_rejects_unknown_flag () =
  Alcotest.(check bool)
    "`c2c version --definitely-invalid` must NOT exit 0" false
    (version_exit_code "version --definitely-invalid" = 0);
  Alcotest.(check bool)
    "`c2c version bogus-positional` must NOT exit 0" false
    (version_exit_code "version bogus-positional" = 0)

let test_version_flag_form_ok () =
  Alcotest.(check int) "`c2c version` exits 0" 0 (version_exit_code "version");
  Alcotest.(check int) "`c2c version --version` exits 0" 0
    (version_exit_code "version --version")

let () =
  Alcotest.run "c2c_version"
    [ ( "build-time",
        [ Alcotest.test_case "build identity uses build date" `Quick
            test_build_identity_uses_build_date;
          Alcotest.test_case "build identity has no wall clock" `Quick
            test_build_identity_has_no_wall_clock;
          Alcotest.test_case "build identity is deterministic" `Quick
            test_build_identity_is_deterministic;
          Alcotest.test_case "now clock is secondary and demarcated" `Quick
            test_display_clock_is_secondary_and_demarcated ] );
      ( "binary",
        [ Alcotest.test_case "`c2c --version` reports build date" `Quick
            test_binary_version_reports_build_date ] );
      ( "subcommand",
        [ Alcotest.test_case "`c2c version` first line matches `--version`" `Quick
            test_version_subcommand_first_line_matches_flag;
          Alcotest.test_case "`c2c version` reports build date" `Quick
            test_version_subcommand_reports_build_date;
          Alcotest.test_case "`c2c version` is a superset of `--version`" `Quick
            test_version_subcommand_is_superset;
          Alcotest.test_case "update-available line parity (--version vs version)"
            `Quick test_version_update_line_parity;
          Alcotest.test_case "version accepts only no-arg / --version forms"
            `Quick test_version_flag_form_ok;
          Alcotest.test_case "version rejects unknown flags / positionals" `Quick
            test_version_rejects_unknown_flag ] )
    ]
