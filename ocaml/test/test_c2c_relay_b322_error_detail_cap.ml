(* B322 regression: last_error detail must be truncated AT CONSTRUCTION in
   [summarize_pass_errors], using the same B297 240-char helper the summary
   array and log lines already use.

   Pre-fix only the summary array entries (es_detail) and the printed lines
   truncated; last_error.err_detail carried the RAW pe_detail, so the full
   relay response JSON (which can embed PoW challenges) was written verbatim
   into connector-state.json ("last_error_detail") and rendered unclipped by
   doctor — the exact multi-KB-line symptom the B297 cap was meant to
   remove. *)

module Conn = C2c_relay_connector

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
    (Printf.sprintf "c2c-b322-test-%d-%d"
       (Unix.getpid ()) (Random.int 1_000_000)) in
  Unix.mkdir dir 0o755;
  dir

let rmrf path =
  let rec aux p =
    match (Unix.lstat p).st_kind with
    | Unix.S_DIR ->
        let entries = Sys.readdir p in
        Array.iter (fun e -> aux (Filename.concat p e)) entries;
        Unix.rmdir p
    | _ -> Unix.unlink p
    | exception _ -> ()
  in
  try aux path with _ -> ()

(* A >240-char relay error body: the single-line JSON a failing op records
   via Yojson.Safe.to_string, with an embedded PoW challenge. *)
let long_relay_body =
  Yojson.Safe.to_string
    (`Assoc
       [ ("ok", `Bool false)
       ; ("error_code", `String "other")
       ; ("error", `String "pow challenge")
       ; ("challenge",
          `String (String.init 500 (fun i -> Char.chr (65 + (i mod 26))))) ])

let pass_error detail : Conn.pass_error =
  { Conn.pe_op = "send"; pe_code = Some "other"; pe_alias = Some "b322-alias";
    pe_session_id = None; pe_detail = detail }

let result_with ~last_error ~errors : Conn.sync_result =
  { Conn.registered = []; registered_sessions = []; heartbeated = [];
    outbox_forwarded = 0; outbox_failed = 0; outbox_dlqed = 0;
    inbound_delivered = 0; inbound_rejected = 0; inbound_rejected_note = None;
    alerts_emitted = 0; rate_limited = false; retry_after_s = None;
    last_error; errors }

(* Construction-time cap: last_error.err_detail is truncated like the
   summary entry, not raw. *)
let test_summarize_caps_last_error_detail () =
  Alcotest.(check bool) "fixture exceeds the 240-char cap" true
    (String.length long_relay_body > Conn.error_detail_cap);
  let last_error, entries =
    Conn.summarize_pass_errors [ pass_error long_relay_body ]
  in
  (match last_error with
   | None -> Alcotest.fail "expected a last_error"
   | Some e ->
       Alcotest.(check bool) "last_error detail capped" true
         (String.length e.Conn.err_detail
          <= Conn.error_detail_cap + 3);
       Alcotest.(check bool) "cap actually bit (detail was truncated)" true
         (String.length e.Conn.err_detail < String.length long_relay_body);
       Alcotest.(check bool) "truncation marker present" true
         (String.ends_with ~suffix:"..." e.Conn.err_detail));
  Alcotest.(check bool) "summary entries stay capped too" true
    (List.for_all
       (fun (s : Conn.sync_error_summary) ->
          String.length s.Conn.es_detail <= Conn.error_detail_cap + 3)
       entries)

(* Storage cap: the value write_connector_state persists under
   "last_error_detail" (what doctor renders) is the capped one. *)
let test_state_file_carries_capped_detail () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let last_error, entries =
    Conn.summarize_pass_errors [ pass_error long_relay_body ]
  in
  Conn.write_connector_state tmp
    (result_with ~last_error ~errors:entries);
  match Conn.read_connector_state tmp with
  | None -> Alcotest.fail "no state file written"
  | Some st ->
      Alcotest.(check bool) "stored last_error_detail capped" true
        (match st.Conn.cs_last_error_detail with
         | Some d -> String.length d <= Conn.error_detail_cap + 3
         | None -> false)

(* A short detail is preserved verbatim — the cap must not eat useful
   short errors. *)
let test_short_detail_untouched () =
  let short = "connection_error" in
  let last_error, _ = Conn.summarize_pass_errors [ pass_error short ] in
  match last_error with
  | None -> Alcotest.fail "expected a last_error"
  | Some e ->
      Alcotest.(check string) "short detail verbatim" short e.Conn.err_detail

let () =
  Alcotest.run "B322 last_error detail truncated at construction"
    [ ("detail cap",
       [ Alcotest.test_case "summarize caps last_error detail" `Quick
           test_summarize_caps_last_error_detail
       ; Alcotest.test_case "state file carries capped detail" `Quick
           test_state_file_carries_capped_detail
       ; Alcotest.test_case "short detail untouched" `Quick
           test_short_detail_untouched
       ]) ]
