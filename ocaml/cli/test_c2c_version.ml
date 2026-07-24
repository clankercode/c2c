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

let read_first_line_of_version () =
  let ic =
    Unix.open_process_in (Filename.quote c2c_binary ^ " --version 2>/dev/null")
  in
  Fun.protect
    ~finally:(fun () -> ignore (Unix.close_process_in ic))
    (fun () -> try input_line ic with End_of_file -> "")

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
            test_binary_version_reports_build_date ] )
    ]
