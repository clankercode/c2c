(* test_c2c_time.ml — unit tests for C2c_time *)

let fail_fmt fmt = Printf.ksprintf (fun s -> failwith s) fmt

(* ---- Fixed-timestamp tests ---- *)

let test_iso8601_utc_epoch () =
  let got = C2c_time.iso8601_utc 0.0 in
  if got <> "1970-01-01T00:00:00Z" then
    fail_fmt "iso8601_utc 0.0: expected %s, got %s" "1970-01-01T00:00:00Z" got

let test_iso8601_utc_ms_epoch () =
  let got = C2c_time.iso8601_utc_ms 0.0 in
  if got <> "1970-01-01T00:00:00.000Z" then
    fail_fmt "iso8601_utc_ms 0.0: expected %s, got %s" "1970-01-01T00:00:00.000Z" got

let test_iso8601_utc_ms_fractional () =
  let got = C2c_time.iso8601_utc_ms 1234567890.0 in
  if got <> "2009-02-13T23:31:30.000Z" then
    fail_fmt "iso8601_utc_ms 1234567890.0: expected %s, got %s" "2009-02-13T23:31:30.000Z" got

let test_hhmm_epoch () =
  let got = C2c_time.hhmm 0.0 in
  if got <> "00:00" then
    fail_fmt "hhmm 0.0: expected %s, got %s" "00:00" got

let test_hms_epoch () =
  let got = C2c_time.hms 0.0 in
  if got <> "00:00:00" then
    fail_fmt "hms 0.0: expected %s, got %s" "00:00:00" got

let test_ymd_epoch () =
  let got = C2c_time.ymd 0.0 in
  if got <> "1970-01-01" then
    fail_fmt "ymd 0.0: expected %s, got %s" "1970-01-01" got

let test_human_utc_epoch () =
  let got = C2c_time.human_utc 0.0 in
  if got <> "1970-01-01 00:00:00 UTC" then
    fail_fmt "human_utc 0.0: expected %s, got %s" "1970-01-01 00:00:00 UTC" got

let test_compact_iso8601_epoch () =
  let got = C2c_time.compact_iso8601 0.0 in
  if got <> "19700101T000000" then
    fail_fmt "compact_iso8601 0.0: expected %s, got %s" "19700101T000000" got

let test_ymd_hour_path_epoch () =
  let got = C2c_time.ymd_hour_path 0.0 in
  if got <> "1970/01/01/00" then
    fail_fmt "ymd_hour_path 0.0: expected %s, got %s" "1970/01/01/00" got

(* ---- now_iso8601_utc regex test ---- *)

let test_now_iso8601_utc_format () =
  let got = C2c_time.now_iso8601_utc () in
  let expected_pat = Str.regexp "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$" in
  if not (Str.string_match expected_pat got 0) then
    fail_fmt "now_iso8601_utc (): %s does not match YYYY-MM-DDTHH:MM:SSZ" got

(* ---- iso8601_utc_ms includes .mmmZ suffix ---- *)

let test_iso8601_utc_ms_has_dot_mmm_Z () =
  let got = C2c_time.iso8601_utc_ms 0.0 in
  let dot_mmm_Z_pat = Str.regexp ".*\\.[0-9][0-9][0-9]Z$" in
  if not (Str.string_match dot_mmm_Z_pat got 0) then
    fail_fmt "iso8601_utc_ms 0.0: %s missing .mmmZ suffix" got

(* ---- Character-class and length checks ---- *)

let test_hhmm_length_and_chars () =
  let got = C2c_time.hhmm 0.0 in
  if String.length got <> 5 then
    fail_fmt "hhmm length: expected 5, got %d" (String.length got);
  let char_pat = Str.regexp "^[0-9][0-9]:[0-9][0-9]$" in
  if not (Str.string_match char_pat got 0) then
    fail_fmt "hhmm 0.0: %s does not match [0-9][0-9]:[0-9][0-9]" got

let test_hms_length_and_chars () =
  let got = C2c_time.hms 0.0 in
  if String.length got <> 8 then
    fail_fmt "hms length: expected 8, got %d" (String.length got);
  let char_pat = Str.regexp "^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$" in
  if not (Str.string_match char_pat got 0) then
    fail_fmt "hms 0.0: %s does not match [0-9][0-9]:[0-9][0-9]:[0-9][0-9]" got

let test_ymd_length_and_chars () =
  let got = C2c_time.ymd 0.0 in
  if String.length got <> 10 then
    fail_fmt "ymd length: expected 10, got %d" (String.length got);
  let char_pat = Str.regexp "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$" in
  if not (Str.string_match char_pat got 0) then
    fail_fmt "ymd 0.0: %s does not match YYYY-MM-DD pattern" got

(* ---- Run tests ---- *)

let tests = [
  "iso8601_utc epoch", test_iso8601_utc_epoch;
  "iso8601_utc_ms epoch", test_iso8601_utc_ms_epoch;
  "iso8601_utc_ms fractional", test_iso8601_utc_ms_fractional;
  "hhmm epoch", test_hhmm_epoch;
  "hms epoch", test_hms_epoch;
  "ymd epoch", test_ymd_epoch;
  "human_utc epoch", test_human_utc_epoch;
  "compact_iso8601 epoch", test_compact_iso8601_epoch;
  "ymd_hour_path epoch", test_ymd_hour_path_epoch;
  "now_iso8601_utc format", test_now_iso8601_utc_format;
  "iso8601_utc_ms has .mmmZ", test_iso8601_utc_ms_has_dot_mmm_Z;
  "hhmm length+chars", test_hhmm_length_and_chars;
  "hms length+chars", test_hms_length_and_chars;
  "ymd length+chars", test_ymd_length_and_chars;
]

let () =
  let passed = ref 0 in
  let failed = ref 0 in
  List.iter (fun (name, test) ->
    try
      test ();
      Printf.printf "[PASS] %s\n%!" name;
      incr passed
    with e ->
      Printf.printf "[FAIL] %s: %s\n%!" name (Printexc.to_string e);
      incr failed
  ) tests;
  Printf.printf "\n%d passed, %d failed\n%!" !passed !failed;
  if !failed > 0 then exit 1
