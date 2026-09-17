(* B316 regression: write_connector_state_error must be a read-modify-write
   that PRESERVES the ownership evidence (registered / node_id / sessions)
   exactly the way the B292 wedge fields are preserved.

   Pre-fix, one transient sync exception rebuilt connector-state.json with
   "registered": [] and no node_id/sessions keys:
   - connector_owns_alias (B294 register guard) lost its managed-alias
     evidence and returned None, reopening the alias-theft window;
   - connector_peek_key (B209/B231) lost the binding, so monitor/CLI peeks
     fell back to the cli-<alias> key and hit signature_invalid,
   until the next good pass rewrote the file. *)

module Conn = C2c_relay_connector

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
    (Printf.sprintf "c2c-b316-test-%d-%d"
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

let ok_result ?(registered = []) ?(sessions = []) () : Conn.sync_result =
  { registered; registered_sessions = sessions; heartbeated = [];
    outbox_forwarded = 0; outbox_failed = 0; outbox_dlqed = 0;
    inbound_delivered = 0; inbound_rejected = 0; inbound_rejected_note = None;
    alerts_emitted = 0; rate_limited = false; retry_after_s = None;
    last_error = None; errors = [] }

(* A good pass writes the full ownership record; the next pass raises (the
   writer's ~op/~detail path). Every ownership field must survive. *)
let test_error_write_preserves_ownership_fields () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  Conn.write_connector_state ~node_id:"node-b316" tmp
    (ok_result ~registered:["b316-alias"]
       ~sessions:[("b316-alias", "sess-b316")] ());
  let ok_before = Conn.read_connector_state tmp in
  Conn.write_connector_state_error tmp ~op:"sync" ~detail:"boom";
  match Conn.read_connector_state tmp with
  | None -> Alcotest.fail "error write deleted connector-state.json"
  | Some st ->
      Alcotest.(check (list string)) "registered aliases survive the error write"
        ["b316-alias"] st.Conn.cs_registered;
      Alcotest.(check (option string)) "node_id survives the error write"
        (Some "node-b316") st.Conn.cs_node_id;
      Alcotest.(check (list (pair string string)))
        "session bindings survive the error write"
        [("b316-alias", "sess-b316")] st.Conn.cs_sessions;
      Alcotest.(check bool) "the error itself is still recorded" true
        (st.Conn.cs_last_error_op = Some "sync"
         && st.Conn.cs_last_error_detail = Some "boom");
      (* The B292 wedge preservation contract already in place must not
         regress while we extend it. *)
      Alcotest.(check bool) "last_ok_ts still preserved for doctor staleness" true
        (match ok_before, Conn.read_connector_state tmp with
         | Some a, Some b -> a.Conn.cs_last_ok_ts = b.Conn.cs_last_ok_ts
         | _ -> false);
      (* The actual consumer consequence (B209/B231): the peek key for the
         managed alias still resolves to the connector's binding instead of
         the cli-<alias> convention. *)
      Alcotest.(check (option (pair string string)))
        "connector_peek_key keeps the binding after an error write"
        (Some ("node-b316", "sess-b316"))
        (Conn.connector_peek_key st ~alias:"b316-alias"
           ~fallback_node_id:"host-hash" ~fallback_session_id:"local-sid")

(* A root with NO prior state file keeps the minimal schema: registered []
   is still emitted (the doctor/typed reader expects the key), and no
   node_id/sessions keys appear. *)
let test_error_write_without_prior_state_keeps_schema () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  Conn.write_connector_state_error tmp ~op:"sync_watchdog" ~detail:"hang";
  match Conn.read_connector_state tmp with
  | None -> Alcotest.fail "error write produced no state file"
  | Some st ->
      Alcotest.(check (list string)) "registered defaults to empty" []
        st.Conn.cs_registered;
      Alcotest.(check (option string)) "no node_id recorded" None
        st.Conn.cs_node_id;
      Alcotest.(check (list (pair string string))) "no sessions recorded" []
        st.Conn.cs_sessions

(* The wedge fields keep their own preservation contract (B292): an error
   write landing while a root is parked in cooldown must not erase it. *)
let test_error_write_still_preserves_wedge_fields () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  Conn.write_connector_state ~node_id:"node-b316" tmp (ok_result ());
  let _since, count = Conn.mark_connector_wedged tmp ~reason:"staleness" in
  Alcotest.(check int) "wedge recorded" 1 count;
  Conn.write_connector_state_error tmp ~op:"sync" ~detail:"boom";
  match Conn.read_connector_state tmp with
  | None -> Alcotest.fail "error write deleted connector-state.json"
  | Some st ->
      Alcotest.(check bool) "wedged_since preserved" true
        (st.Conn.cs_wedged_since <> None);
      Alcotest.(check int) "wedge_count preserved" 1 st.Conn.cs_wedge_count;
      Alcotest.(check (option string)) "wedge_reason preserved"
        (Some "staleness") st.Conn.cs_wedge_reason

let () =
  Alcotest.run "B316 connector-state error write preserves ownership"
    [ ("ownership preservation",
       [ Alcotest.test_case "error write keeps registered/node_id/sessions" `Quick
           test_error_write_preserves_ownership_fields
       ; Alcotest.test_case "error write without prior state keeps schema" `Quick
           test_error_write_without_prior_state_keeps_schema
       ; Alcotest.test_case "error write still preserves wedge fields" `Quick
           test_error_write_still_preserves_wedge_fields
       ]) ]
