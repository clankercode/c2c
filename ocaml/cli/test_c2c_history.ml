(* test_c2c_history.ml — unit tests for the `c2c history` formatter (#353).

   The CLI dispatch is exercised manually; here we lock down the
   structural contract of [C2c_history.format_human]: per-message
   headers ON by default, opt-out flag, empty input, and that the
   header carries from -> to + a timestamp. *)

open Alcotest

let mk_entry ~ts ~from_a ~to_a ~content : C2c_mcp.Broker.archive_entry =
  { ae_drained_at = ts
  ; ae_from_alias = from_a
  ; ae_to_alias = to_a
  ; ae_content = content
  ; ae_deferrable = false
  }

let entries_fixture =
  [ mk_entry ~ts:1714291842.0 ~from_a:"coordinator1" ~to_a:"stanza-coder"
      ~content:"first body"
  ; mk_entry ~ts:1714291875.0 ~from_a:"stanza-coder" ~to_a:"coordinator1"
      ~content:"second body"
  ]

let test_empty () =
  let lines = C2c_history.format_human [] in
  check (list string) "empty -> single (no history) line"
    [ "(no history)" ] lines

let test_headers_default () =
  let lines = C2c_history.format_human entries_fixture in
  (* 2 entries * (header + body) + 1 separator = 5 lines *)
  check int "line count with headers" 5 (List.length lines);
  let joined = String.concat "\n" lines in
  let contains s sub =
    let nl = String.length s and nu = String.length sub in
    let rec loop i = i + nu <= nl && (String.sub s i nu = sub || loop (i + 1)) in
    nu = 0 || loop 0
  in
  check bool "first body present" true (contains joined "first body");
  check bool "second body present" true (contains joined "second body");
  check bool "header has from -> to (coord1 -> stanza)" true
    (contains joined "coordinator1 -> stanza-coder");
  check bool "header has reverse direction" true
    (contains joined "stanza-coder -> coordinator1");
  (* Timestamp is local-time so we don't assert exact wall-clock chars,
     but every entry header MUST start with '[' and contain ':' from
     HH:MM:SS. *)
  let header1 = List.nth lines 0 in
  check bool "header1 starts with [" true
    (String.length header1 > 0 && header1.[0] = '[');
  check bool "header1 has ':' (HH:MM:SS)" true
    (String.contains header1 ':');
  (* Body lines come immediately after header. *)
  check string "header1 body" "first body" (List.nth lines 1);
  check string "blank separator" "" (List.nth lines 2);
  check string "header2 body" "second body" (List.nth lines 4)

let test_no_headers () =
  let lines = C2c_history.format_human ~headers:false entries_fixture in
  check (list string) "bare bodies only, no separator"
    [ "first body"; "second body" ] lines

let test_format_timestamp_shape () =
  let s = C2c_history.format_timestamp 1714291842.0 in
  (* Shape: YYYY-MM-DD HH:MM:SS = 19 chars. *)
  check int "timestamp is 19 chars" 19 (String.length s);
  check char "year-month dash" '-' s.[4];
  check char "month-day dash" '-' s.[7];
  check char "date-time space" ' ' s.[10];
  check char "hour-min colon" ':' s.[13];
  check char "min-sec colon" ':' s.[16]

let tests =
  [ "empty input",        `Quick, test_empty
  ; "default headers on", `Quick, test_headers_default
  ; "--no-headers",       `Quick, test_no_headers
  ; "timestamp shape",    `Quick, test_format_timestamp_shape
  ]

let () = Alcotest.run "c2c_history" [ "format_human", tests ]
