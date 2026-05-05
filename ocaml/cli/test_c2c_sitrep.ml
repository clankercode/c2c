(* test_c2c_sitrep.ml — e2e tests for c2c_sitrep time functions.

    Tests local_tz_label: computes UTC offset from localtime+gmtime,
    handles DST wrap-around correctly. This is the one site that uses
    BOTH Unix.localtime AND Unix.gmtime — no other code in the tree does
    this. The DST correction logic is non-trivial and was implemented
    without test coverage at the time of the time-iso8601 migration (#501).
 *)

open Alcotest

(** Check a string matches the UTC offset label format: UTC, UTC+N, or UTC-N.
    e.g. "UTC", "UTC+10", "UTC-5". *)
let is_valid_tz_label s =
  let len = String.length s in
  len >= 3
  && String.sub s 0 3 = "UTC"
  && (len = 3 || (
    let sign = s.[3] in
    (sign = '+' || sign = '-') && len >= 5
    && String.for_all (fun c -> c >= '0' && c <= '9') (String.sub s 4 (len - 4))
  ))

let test_local_tz_label_format () =
  let got = C2c_sitrep.local_tz_label () in
  Alcotest.(check bool) "valid UTC offset format" true (is_valid_tz_label got)

let test_local_tz_label_known_offset_shape () =
  let got = C2c_sitrep.local_tz_label () in
  Alcotest.(check bool) "matches UTC offset regex"
    true (Str.string_match (Str.regexp "^UTC\\([+-][0-9]+\\)?$") got 0)

let test_local_tz_label_no_crash_repeated () =
  for _ = 1 to 10 do
    let got = C2c_sitrep.local_tz_label () in
    Alcotest.(check bool) "no empty string" true (String.length got > 0);
    Alcotest.(check bool) "starts with UTC" true (String.sub got 0 3 = "UTC")
  done

let test_utc_now_path_returns_tuple_shape () =
  let (rel, abs, year, month, day, hour) =
    C2c_sitrep.utc_now_path ~repo_root:"/repo"
  in
  Alcotest.(check bool) "relative path starts with .sitreps"
    true (String.length rel > 8 && String.sub rel 0 8 = ".sitreps");
  Alcotest.(check bool) "absolute path starts with /repo"
    true (String.length abs > 5 && String.sub abs 0 5 = "/repo");
  Alcotest.(check bool) "year is reasonable" true (year >= 2024 && year <= 2030);
  Alcotest.(check bool) "month in range" true (month >= 1 && month <= 12);
  Alcotest.(check bool) "day in range" true (day >= 1 && day <= 31);
  Alcotest.(check bool) "hour in range" true (hour >= 0 && hour <= 23)

let () =
  run "c2c_sitrep"
    [ ( "local_tz_label",
        [ test_case "output format valid" `Quick test_local_tz_label_format
        ; test_case "known offset shape" `Quick test_local_tz_label_known_offset_shape
        ; test_case "no crash on repeated calls" `Quick test_local_tz_label_no_crash_repeated
        ] )
    ; ( "utc_now_path",
        [ test_case "returns correct tuple shape" `Quick test_utc_now_path_returns_tuple_shape
        ] )
    ]
