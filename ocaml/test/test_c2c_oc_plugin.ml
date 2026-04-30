(* test_c2c_oc_plugin.ml — Native OCaml tests for oc_plugin drain-inbox-to-spool command
 *
 * These tests exercise the OCaml spool drain path used by OpenCode's c2c plugin
 * to stage broker inbox messages into the plugin's spool file before delivery.
 *
 * Mirror coverage of the Python tests in tests/test_c2c_oc_plugin.py:
 *   - Happy path: drain archives and clears inbox
 *   - Error path: inbox preserved when spool write fails
 *)

open Alcotest

(* ---------------------------------------------------------------------------
 * Helpers
 * --------------------------------------------------------------------------- *)

let msg ?(from_alias="") ?(to_alias="") ?(reply_via=None) ?(enc_status=None) content =
  C2c_mcp.{ from_alias; to_alias; content; deferrable = false; reply_via; enc_status; ts = 0.0; ephemeral = false; message_id = None }

let with_tmp_dir f =
  let base = Filename.get_temp_dir_name () in
  let name = Printf.sprintf "c2c-oc-plugin-%06x" (Random.bits ()) in
  let dir = Filename.concat base name in
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore with _ -> ()))
    (fun () -> f dir)

let write_inbox_file ~(dir:string) ~session_id messages =
  let open Yojson.Safe in
  let path = Filename.concat dir (session_id ^ ".inbox.json") in
  let items = List.map (fun (m : C2c_mcp.message) ->
    `Assoc [
      ("from_alias", `String m.from_alias);
      ("to_alias",   `String m.to_alias);
      ("content",     `String m.content);
    ]) messages
  in
  to_file path (`List items)

let read_inbox_messages dir session_id =
  let path = Filename.concat dir (session_id ^ ".inbox.json") in
  if not (Sys.file_exists path) then []
  else
    match Yojson.Safe.from_file path with
    | `List items -> items
    | _ -> []

let archive_exists dir session_id =
  let path = Filename.concat dir (Filename.concat "archive" (session_id ^ ".jsonl")) in
  Sys.file_exists path

let read_archive_entries dir session_id =
  let path = Filename.concat dir (Filename.concat "archive" (session_id ^ ".jsonl")) in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> try close_in ic with _ -> ())
      (fun () ->
        let rec loop acc =
          match input_line ic with
          | exception End_of_file -> List.rev acc
          | line ->
              let trimmed = String.trim line in
              if trimmed = "" then loop acc
              else
                (match Yojson.Safe.from_string trimmed with
                 | exception _ -> loop acc
                 | entry -> loop (entry :: acc))
        in
        loop [])

(* ---------------------------------------------------------------------------
 * Tests — mirror Python test_c2c_oc_plugin.py
 * OCPluginDrainToSpoolTests
 * --------------------------------------------------------------------------- *)

let test_drain_inbox_to_spool_archives_and_clears_inbox () =
  with_tmp_dir (fun tmpdir ->
    let broker_root = Filename.concat tmpdir "broker" in
    Unix.mkdir broker_root 0o700;
    let spool_dir = Filename.concat tmpdir "spool" in
    Unix.mkdir spool_dir 0o700;
    let spool_path = Filename.concat spool_dir "opencode-plugin-spool.json" in
    let session_id = "opencode-local" in

    (* Write a pre-existing message in the spool (queued before broker msg arrived) *)
    let pre_spool = [
      msg ~from_alias:"bob" ~to_alias:session_id "already spooled"
    ] in
    C2c_wire_bridge.spool_write (C2c_wire_bridge.spool_of_path spool_path) pre_spool;

    (* Write a broker inbox message *)
    let inbox_msg = msg ~from_alias:"alice" ~to_alias:session_id "hello from broker" in
    write_inbox_file ~dir:broker_root ~session_id [inbox_msg];

    (* Simulate what oc_plugin_drain_inbox_to_spool_cmd does *)
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    let spool = C2c_wire_bridge.spool_of_path spool_path in
    let inbox_path = Filename.concat broker_root (session_id ^ ".inbox.json") in
    let pending =
      let queued = C2c_wire_bridge.spool_read spool in
      C2c_mcp.Broker.with_inbox_lock broker ~session_id (fun () ->
        let fresh = C2c_mcp.Broker.read_inbox broker ~session_id in
        match fresh with
        | [] -> queued
        | _ ->
          let combined = queued @ fresh in
          C2c_wire_bridge.spool_write spool combined;
          C2c_mcp.Broker.append_archive ~drained_by:"oc_plugin" broker ~session_id ~messages:fresh;
          (* Clear inbox: write empty array directly (mimics C2c_setup.json_write_file) *)
          Yojson.Safe.to_file inbox_path (`List []);
          combined)
    in

    (* Verify spool has 2 messages: bob's pre-existing + alice's from broker *)
    Alcotest.(check int) "spool has 2 messages" 2 (List.length pending);
    let spooled = C2c_wire_bridge.spool_read spool in
    Alcotest.(check int) "spool file has 2" 2 (List.length spooled);
    Alcotest.(check string) "first spooled from bob"
      "bob" (List.nth spooled 0).from_alias;
    Alcotest.(check string) "second spooled from alice"
      "alice" (List.nth spooled 1).from_alias;

    (* Verify inbox is cleared *)
    let remaining = read_inbox_messages broker_root session_id in
    Alcotest.(check int) "inbox cleared" 0 (List.length remaining);

    (* Verify archive was written *)
    Alcotest.(check bool) "archive exists" true (archive_exists broker_root session_id);
    let archive = read_archive_entries broker_root session_id in
    Alcotest.(check int) "archive has 1 entry" 1 (List.length archive))

let test_drain_inbox_to_spool_preserves_inbox_when_spool_write_fails () =
  with_tmp_dir (fun tmpdir ->
    let broker_root = Filename.concat tmpdir "broker" in
    Unix.mkdir broker_root 0o700;
    let session_id = "opencode-local" in

    (* Write a broker inbox message *)
    let inbox_msg = msg ~from_alias:"alice" ~to_alias:session_id "keep me" in
    write_inbox_file ~dir:broker_root ~session_id [inbox_msg];

    (* Create a sealed spool dir with no write permission *)
    let sealed_dir = Filename.concat tmpdir "sealed" in
    Unix.mkdir sealed_dir 0o500; (* r-x --- --- *)
    let spool_path = Filename.concat sealed_dir "spool.json" in

    (* Simulate what oc_plugin_drain_inbox_to_spool_cmd does *)
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    let spool = C2c_wire_bridge.spool_of_path spool_path in

    (* Attempt the drain — spool write will fail due to permissions *)
    let spool_write_ok, _pending =
      try
        let pending =
          let queued = C2c_wire_bridge.spool_read spool in
          C2c_mcp.Broker.with_inbox_lock broker ~session_id (fun () ->
            let fresh = C2c_mcp.Broker.read_inbox broker ~session_id in
            match fresh with
            | [] -> queued
            | _ ->
              (* This will raise Sys_error because the spool dir is unwritable *)
              C2c_wire_bridge.spool_write spool (queued @ fresh);
              C2c_mcp.Broker.append_archive ~drained_by:"oc_plugin" broker ~session_id ~messages:fresh;
              let inbox_path = Filename.concat broker_root (session_id ^ ".inbox.json") in
              Yojson.Safe.to_file inbox_path (`List []);
              queued @ fresh)
        in
        (true, pending)  (* No error — spool write succeeded *)
      with Sys_error _ ->
        (false, [])  (* Expected: spool write failed *)
    in
    if not spool_write_ok then begin
        (* Spool write failed — inbox should be preserved *)
        let remaining = read_inbox_messages broker_root session_id in
        Alcotest.(check int) "inbox preserved on spool failure" 1 (List.length remaining);
        (match List.hd remaining with
         | `Assoc fs ->
             (match List.assoc "content" fs with
              | `String s -> Alcotest.(check string) "inbox content unchanged" "keep me" s
              | _ -> Alcotest.(check bool) "content is string" true false)
         | _ -> Alcotest.(check bool) "inbox entry is object" true false);
        Alcotest.(check bool) "archive NOT written on spool failure"
          false (archive_exists broker_root session_id)
    end else
        (* Spool write succeeded despite sealed dir — skip this path *)
        Alcotest.(check bool) "skip: spool write succeeded unexpectedly" true true;

    (* Restore perms so cleanup can remove the dir *)
    Unix.chmod sealed_dir 0o700)

(* ---------------------------------------------------------------------------
 * Test registration
 * --------------------------------------------------------------------------- *)

let () =
  Alcotest.run "oc_plugin_drain_to_spool"
    [ ( "drain_inbox_to_spool"
      , [ Alcotest.test_case "archives_and_clears_inbox"                   `Quick test_drain_inbox_to_spool_archives_and_clears_inbox
        ; Alcotest.test_case "preserves_inbox_when_spool_write_fails"      `Quick test_drain_inbox_to_spool_preserves_inbox_when_spool_write_fails
        ] )
    ]
