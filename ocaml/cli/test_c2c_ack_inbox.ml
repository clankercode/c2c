(* B374: exercise the real CLI and broker against disposable native queues.
   No installed binaries, host services, relay, or operator state are used. *)
open Alcotest
module B = C2c_mcp.Broker

let binary = Filename.concat (Filename.dirname Sys.executable_name) "c2c.exe"
let sid = "hermes-ack-test"
let inbox_path broker ~session_id = Filename.concat (B.root broker) (session_id ^ ".inbox.json")

let read path = C2c_io.read_file path
let write path value =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc value)

let rec remove path =
  if Sys.is_directory path then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let fixture f =
  let home = Filename.temp_file "c2c-ack-" "" in
  Sys.remove home;
  Unix.mkdir home 0o700;
  Fun.protect ~finally:(fun () -> C2c_io.set_fsync_for_test None; remove home) (fun () ->
    let root = Filename.concat home "broker" in
    let broker = B.create ~root in
    B.register broker ~session_id:sid ~alias:"hermes-ack" ~pid:None ~pid_start_time:None
      ~from_auto_gen:true ();
    f home broker)

let message ?(ephemeral = false) ?(idless = false) id : C2c_mcp.message =
  { from_alias = "peer"; to_alias = "hermes-ack"; content = "body-" ^ id;
    ts = 1.; deferrable = false; ephemeral; message_id = (if idless then None else Some id);
    reply_via = None; enc_status = None; pow_difficulty = None; source = C2c_mcp.Local }

let ids broker =
  B.read_inbox ~strict:true broker ~session_id:sid
  |> List.filter_map (fun (m : C2c_mcp.message) -> m.message_id)

let archive_ids broker =
  B.read_archive broker ~session_id:sid ~limit:100
  |> List.filter_map (fun (e : B.archive_entry) -> e.ae_message_id)
  |> List.rev

let check_ids label expected actual = check (list string) label expected actual

let env ~home ~broker ~session_id extra =
  (* Build a fresh environment rather than inheriting the orchestrator's
     host binding, fallback session, relay activation, or client identity. *)
  let base = [ "PATH", Sys.getenv "PATH"; "HOME", home;
    "XDG_CONFIG_HOME", Filename.concat home ".config";
    "XDG_STATE_HOME", Filename.concat home "state";
    "C2C_MCP_BROKER_ROOT", B.root broker;
    "C2C_MCP_SESSION_ID", session_id;
    "C2C_CLI_FORCE", "1"; "C2C_DETECT_ANCESTOR_COMMS", "test-runner-neutral" ] in
  let keys = List.map fst extra in
  Array.of_list (List.map (fun (k, v) -> k ^ "=" ^ v)
    (List.filter (fun (k, _) -> not (List.mem k keys)) base @ extra))

let start_cli ?(session_id = sid) ?(extra = []) ~home ~broker args =
  let output = Filename.temp_file ~temp_dir:home "out-" "" in
  let errors = Filename.temp_file ~temp_dir:home "err-" "" in
  let out_fd = Unix.openfile output [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let err_fd = Unix.openfile errors [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let pid = Fun.protect ~finally:(fun () -> Unix.close out_fd; Unix.close err_fd) (fun () ->
    Unix.create_process_env binary (Array.of_list (binary :: args))
      (env ~home ~broker ~session_id extra) Unix.stdin out_fd err_fd) in
  (pid, output, errors)

let finish_cli (pid, output, errors) =
  let _, status = Unix.waitpid [] pid in
  let rc = match status with Unix.WEXITED n -> n | _ -> -1 in
  (rc, read output, read errors)

let cli ?session_id ?extra ~home ~broker args =
  finish_cli (start_cli ?session_id ?extra ~home ~broker args)

let ack_args ids = "ack-inbox" :: "--json" ::
  List.concat_map (fun id -> [ "--message-id"; id ]) ids

let success (rc, out, err) acknowledged missing =
  check int ("CLI exit: " ^ err ^ out) 0 rc;
  let expected = `Assoc [ "ok", `Bool true;
    "acknowledged", `List (List.map (fun id -> `String id) acknowledged);
    "missing", `List (List.map (fun id -> `String id) missing) ] in
  check string "complete success JSON" (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string (Yojson.Safe.from_string out))

let refused (rc, _, _) = check bool "refused" true (rc <> 0)

let ack broker message_ids = match B.ack_inbox broker ~session_id:sid ~message_ids with
  | Ok result -> result | Error reason -> fail reason

let test_selected_idempotent () = fixture (fun home broker ->
  B.save_inbox broker ~session_id:sid
    [ message "a"; message ~ephemeral:true "secret"; message "b"; message ~idless:true "old" ];
  success (cli ~home ~broker (ack_args [ "b"; "absent"; "a"; "b" ])) [ "b"; "a" ] [ "absent" ];
  check_ids "unrelated IDs" [ "secret" ] (ids broker);
  check int "ID-less legacy message retained" 2 (List.length (B.read_inbox broker ~session_id:sid));
  check_ids "selected persistent archive" [ "a"; "b" ] (archive_ids broker);
  success (cli ~home ~broker (ack_args [ "a"; "b" ])) [] [ "a"; "b" ];
  check_ids "no duplicate archive on successful retry" [ "a"; "b" ] (archive_ids broker))

let test_ephemeral () = fixture (fun home broker ->
  B.save_inbox broker ~session_id:sid [ message ~ephemeral:true "secret"; message "keep" ];
  success (cli ~home ~broker (ack_args [ "secret" ])) [ "secret" ] [];
  check_ids "persistent unrelated survives" [ "keep" ] (ids broker);
  check bool "ephemeral never creates archive" false
    (Sys.file_exists (B.archive_path broker ~session_id:sid));
  B.save_inbox broker ~session_id:sid [ message "public"; message ~ephemeral:true "secret2" ];
  success (cli ~home ~broker (ack_args [ "public"; "secret2" ])) [ "public"; "secret2" ] [];
  check_ids "mixed ACK archives persistent only" [ "public" ] (archive_ids broker))

let test_foreign_session () = fixture (fun home broker ->
  B.register broker ~session_id:"foreign" ~alias:"hermes-foreign" ~pid:None ~pid_start_time:None
    ~from_auto_gen:true ();
  B.save_inbox broker ~session_id:"foreign" [ message "foreign-id" ];
  B.save_inbox broker ~session_id:sid [ message "own-id" ];
  success (cli ~home ~broker (ack_args [ "foreign-id" ])) [] [ "foreign-id" ];
  let original = read (inbox_path broker ~session_id:"foreign") in
  refused (cli ~home ~broker (ack_args [ "foreign-id" ] @ [ "--session-id"; "foreign" ]));
  refused (cli ~home ~broker (ack_args [ "foreign-id" ] @ [ "--alias"; "hermes-foreign" ]));
  refused (cli ~home ~broker ~session_id:"stale"
    ~extra:[ "C2C_MCP_AUTO_REGISTER_ALIAS", "hermes-foreign" ] (ack_args [ "foreign-id" ]));
  refused (cli ~home ~broker ~session_id:""
    ~extra:[ "C2C_MCP_AUTO_REGISTER_ALIAS", "hermes-foreign"; "CODEX_THREAD_ID", "foreign" ]
    (ack_args [ "foreign-id" ]));
  check string "foreign queue byte-identical" original (read (inbox_path broker ~session_id:"foreign"));
  check_ids "own queue unchanged" [ "own-id" ] (ids broker))

let test_host_owned () = fixture (fun home broker ->
  B.save_inbox broker ~session_id:sid [ message "a" ];
  List.iter (fun variable ->
    refused (cli ~home ~broker ~extra:[ variable, "1" ] (ack_args [ "a" ])))
    [ "C2C_HOST_OWNED_MAILBOX"; "C2C_MCP_DISABLED"; "C2C_NO_AUTO_REGISTER" ];
  B.register broker ~session_id:sid ~alias:"hermes-ack" ~pid:None ~pid_start_time:None
    ~client_type:(Some "t3") ~registered_by:(Some C2c_broker.t3_service_registered_by)
    ~from_auto_gen:true ();
  refused (cli ~home ~broker (ack_args [ "a" ]));
  check bool "broker independently refuses service-owned row" true
    (match B.ack_inbox broker ~session_id:sid ~message_ids:[ "a" ] with Error _ -> true | _ -> false);
  check_ids "protected mail remains" [ "a" ] (ids broker);
  check_ids "no protected archive" [] (archive_ids broker))

let test_arguments () = fixture (fun home broker ->
  B.save_inbox broker ~session_id:sid [ message "a" ];
  refused (cli ~home ~broker [ "ack-inbox"; "--json" ]);
  refused (cli ~home ~broker [ "ack-inbox"; "--json"; "--message-id" ]);
  refused (cli ~home ~broker (ack_args [ "a"; " " ]));
  check_ids "bad args never partially ACK" [ "a" ] (ids broker))

let test_late_arrival () = fixture (fun home broker ->
  B.save_inbox broker ~session_id:sid [ message "peeked" ];
  check_ids "initial peek" [ "peeked" ] (ids broker);
  B.enqueue_message_with_result ~message_id:"late" broker ~from_alias:"peer"
    ~to_alias:"hermes-ack" ~content:"arrived after peek" () |> ignore;
  let late_ids = List.filter (( <> ) "peeked") (ids broker) in
  check int "one late message was enqueued" 1 (List.length late_ids);
  success (cli ~home ~broker (ack_args [ "peeked" ])) [ "peeked" ] [];
  check_ids "late mail stays pending for injection" late_ids (ids broker);
  let reopened = B.create ~root:(B.root broker) in
  check_ids "late mail survives reopen" late_ids (ids reopened))

let test_ack_race () = fixture (fun home broker ->
  B.save_inbox broker ~session_id:sid [ message "a" ];
  let first, second = B.with_inbox_lock broker ~session_id:sid (fun () ->
    let first = start_cli ~home ~broker (ack_args [ "a" ]) in
    let second = start_cli ~home ~broker (ack_args [ "a" ]) in
    (* Both ACKs must observe this arrival after acquiring the inbox lock,
       regardless of scheduler order; neither may rewrite a stale peek. *)
    B.save_inbox broker ~session_id:sid [ message "a"; message "late" ];
    (first, second)) in
  let results = List.map finish_cli [ first; second ] in
  let acknowledged = List.map (fun (rc, out, err) ->
    check int ("racing CLI exit: " ^ err) 0 rc;
    Yojson.Safe.Util.(Yojson.Safe.from_string out |> member "acknowledged" |> to_list |> List.map to_string)) results in
  check (list (list string)) "one winner and one idempotent retry" [ []; [ "a" ] ] (List.sort compare acknowledged);
  check_ids "racing ACK preserves late arrival" [ "late" ] (ids broker);
  check_ids "racing ACK archives exactly once" [ "a" ] (archive_ids broker))

let test_archive_failure () = fixture (fun home broker ->
  B.save_inbox broker ~session_id:sid [ message "a"; message "keep" ];
  let archive = B.archive_path broker ~session_id:sid in
  C2c_io.mkdir_p (Filename.dirname archive);
  Unix.mkdir archive 0o700;
  refused (cli ~home ~broker (ack_args [ "a" ]));
  check_ids "archive failure retains all mail" [ "a"; "keep" ] (ids broker);
  Unix.rmdir archive;
  success (cli ~home ~broker (ack_args [ "a" ])) [ "a" ] [];
  check_ids "retry after repair preserves unrelated" [ "keep" ] (ids broker))

let test_fsync_failure () = fixture (fun _ broker ->
  B.save_inbox broker ~session_id:sid [ message "a"; message "keep" ];
  let path = B.archive_path broker ~session_id:sid in
  C2c_io.set_fsync_for_test (Some (fun target fd ->
    if target = path then raise (Unix.Unix_error (Unix.EIO, "fsync", target));
    Unix.fsync fd));
  let failed = try ignore (ack broker [ "a" ]); false with Unix.Unix_error _ -> true in
  check bool "archive durability failure propagates" true failed;
  C2c_io.set_fsync_for_test None;
  check_ids "failed sync leaves queue retryable" [ "a"; "keep" ] (ids broker);
  let reopened = B.create ~root:(B.root broker) in
  let acknowledged, missing = ack reopened [ "a" ] in
  check_ids "reopened retry ACK" [ "a" ] acknowledged;
  check_ids "retry missing" [] missing;
  check_ids "reopened retry keeps unrelated" [ "keep" ] (ids reopened))

let test_durability_order () = fixture (fun _ broker ->
  B.save_inbox broker ~session_id:sid [ message "a"; message "keep" ];
  let archive = B.archive_path broker ~session_id:sid in
  let inbox = inbox_path broker ~session_id:sid in
  let events = ref [] in
  C2c_io.set_fsync_for_test (Some (fun path fd ->
    events := !events @ [ path ];
    if path = archive then check_ids "archive synced before removal" [ "a"; "keep" ] (ids broker);
    if path = inbox then check_ids "replacement synced after selection" [ "keep" ] (ids broker);
    Unix.fsync fd));
  ignore (ack broker [ "a" ]);
  C2c_io.set_fsync_for_test None;
  check_ids "strict file and directory sync sequence"
    [ archive; Filename.dirname archive; B.root broker;
      inbox ^ ".tmp." ^ string_of_int (Unix.getpid ()); inbox; B.root broker ] !events)

let test_untrusted_inbox () = fixture (fun home broker ->
  let path = inbox_path broker ~session_id:sid in
  List.iter (fun raw ->
    write path raw;
    refused (cli ~home ~broker (ack_args [ "a" ]));
    check string "untrusted queue byte-identical" raw (read path))
    [ "{broken"; "{}"; "[{}]";
      Yojson.Safe.to_string (`List (List.map C2c_broker.message_to_json [ message "a"; message "a" ])) ];
  check_ids "untrusted queue never archived" [] (archive_ids broker))

let test_error_redaction () = fixture (fun home broker ->
  let path = inbox_path broker ~session_id:sid in
  let secret = "PRIVATE_EPHEMERAL_BODY_B374" in
  let raw = "[" ^ secret ^ "]" in
  write path raw;
  let rc, out, err = cli ~home ~broker (ack_args [ "a" ]) in
  refused (rc, out, err);
  check string "redacted failure JSON"
    "{\"ok\":false,\"error\":\"unable to acknowledge inbox: queue read or durable update failed\"}"
    (Yojson.Safe.to_string (Yojson.Safe.from_string out));
  check string "no parser payload on stderr" "" err;
  check string "secret-bearing corrupt queue preserved" raw (read path))

let host_bind home broker owner_id =
  C2c_host_mailbox.bind ~environment_id:"ack-test" ~thread_id:"host-thread"
    ~workspace:home ~broker_root:(B.root broker) ~owner_id ~owner_pid:(Unix.getpid ()) ()

let host_sid = fst (C2c_host_mailbox.identity ~environment_id:"ack-test" ~thread_id:"host-thread")

let test_native_host () = fixture (fun home broker ->
  ignore (host_bind home broker "first");
  B.save_inbox broker ~session_id:host_sid [ message "host-mail" ];
  let original = read (inbox_path broker ~session_id:host_sid) in
  refused (cli ~home ~broker ~session_id:host_sid (ack_args [ "host-mail" ]));
  ignore (host_bind home broker "new-generation");
  refused (cli ~home ~broker ~session_id:host_sid (ack_args [ "host-mail" ]));
  check bool "broker refuses native host without env flags" true
    (match B.ack_inbox broker ~session_id:host_sid ~message_ids:[ "host-mail" ] with
     | Error _ -> true | Ok _ -> false);
  check string "host mail byte-identical through rebind" original (read (inbox_path broker ~session_id:host_sid));
  check int "no unauthorized archive" 0 (List.length (B.read_archive broker ~session_id:host_sid ~limit:100)))

let test_host_publication_race rebind = fixture (fun home broker ->
  if rebind then ignore (host_bind home broker "first");
  B.save_inbox broker ~session_id:host_sid [ message "host-mail" ];
  let original = read (inbox_path broker ~session_id:host_sid) in
  let ready_r, ready_w = Unix.pipe ~cloexec:true () in
  let release_r, release_w = Unix.pipe ~cloexec:true () in
  let child = Unix.fork () in
  if child = 0 then begin
    Unix.close ready_r; Unix.close release_w;
    C2c_host_mailbox.set_after_state_write_for_test (Some (fun () ->
      ignore (Unix.write_substring ready_w "r" 0 1);
      let byte = Bytes.create 1 in
      if Unix.read release_r byte 0 1 <> 1 then Unix._exit 79));
    (try ignore (host_bind home broker "next"); Unix._exit 0
     with _ -> Unix._exit 80)
  end;
  Unix.close ready_w; Unix.close release_r;
  let waited = ref false in
  Fun.protect ~finally:(fun () ->
    Unix.close ready_r; Unix.close release_w;
    if not !waited then begin
      (try Unix.kill child Sys.sigkill with _ -> ());
      ignore (Unix.waitpid [] child)
    end) (fun () ->
    let readable, _, _ = Unix.select [ ready_r ] [] [] 10. in
    check bool "publication reached registry-locked barrier" true (readable <> []);
    let byte = Bytes.create 1 in
    check int "publisher ready" 1 (Unix.read ready_r byte 0 1);
    let attempt = start_cli ~home ~broker ~session_id:host_sid (ack_args [ "host-mail" ]) in
    ignore (Unix.write_substring release_w "g" 0 1);
    let _, result = Unix.waitpid [] child in
    waited := true;
    check bool "publication completed" true (result = Unix.WEXITED 0);
    refused (finish_cli attempt);
    check string "publication/ACK race preserves host mail" original (read (inbox_path broker ~session_id:host_sid))))

let test_buffered_archive_failure () = fixture (fun _ broker ->
  B.save_inbox broker ~session_id:sid [ message "a"; message "keep" ];
  let archive = B.archive_path broker ~session_id:sid in
  C2c_io.mkdir_p (Filename.dirname archive);
  Unix.symlink "/dev/full" archive;
  (* A short archive record fits in the output-channel buffer. /dev/full
     rejects its flush at close. Simulate successful downstream fsync to
     prove it cannot disguise the earlier buffered write error. *)
  C2c_io.set_fsync_for_test (Some (fun _ _ -> ()));
  let failed = try ignore (ack broker [ "a" ]); false with Sys_error _ -> true in
  C2c_io.set_fsync_for_test None;
  check bool "buffered archive failure propagated" true failed;
  check_ids "buffered failure preserves entire queue" [ "a"; "keep" ] (ids broker);
  Unix.unlink archive;
  ignore (ack broker [ "a" ]);
  check_ids "repaired archive is retryable" [ "keep" ] (ids broker))

let test_post_rename_recovery ephemeral = fixture (fun _ broker ->
  B.save_inbox broker ~session_id:sid [ message ~ephemeral "a"; message "keep" ];
  let inbox = inbox_path broker ~session_id:sid in
  let child = Unix.fork () in
  if child = 0 then begin
    C2c_io.set_fsync_for_test (Some (fun path fd ->
      (* Terminate the writer at the first sync after the atomic rename. *)
      if path = inbox then Unix._exit 77 else Unix.fsync fd));
    ignore (ack broker [ "a" ]);
    Unix._exit 78
  end;
  let _, status = Unix.waitpid [] child in
  check bool "writer exited between rename and sync" true (status = Unix.WEXITED 77);
  let reopened = B.create ~root:(B.root broker) in
  check_ids "rename is visible to new process" [ "keep" ] (ids reopened);
  C2c_io.set_fsync_for_test (Some (fun path fd ->
    if path = inbox then raise (Unix.Unix_error (Unix.EIO, "fsync", path));
    Unix.fsync fd));
  let failed = try ignore (ack reopened [ "a" ]); false with Unix.Unix_error _ -> true in
  C2c_io.set_fsync_for_test None;
  check bool "missing-ID retry still rejects failed durability" true failed;
  let synced = ref [] in
  C2c_io.set_fsync_for_test (Some (fun path fd -> synced := path :: !synced; Unix.fsync fd));
  let acknowledged, missing = ack reopened [ "a" ] in
  C2c_io.set_fsync_for_test None;
  check_ids "retry has no duplicate removal" [] acknowledged;
  check_ids "retry reports missing ID" [ "a" ] missing;
  check_ids "successful retry completes file and parent sync" [ inbox; B.root broker ] (List.rev !synced);
  check_ids "surviving mail retained" [ "keep" ] (ids reopened);
  check_ids "archive respects privacy through process recovery" (if ephemeral then [] else [ "a" ]) (archive_ids reopened))

let test_archive_tail_recovery () = fixture (fun _ broker ->
  B.append_archive broker ~session_id:sid ~messages:[ message "old" ];
  B.save_inbox broker ~session_id:sid [ message "retry"; message "keep" ];
  let archive = B.archive_path broker ~session_id:sid in
  let child = Unix.fork () in
  if child = 0 then begin
    let fd = Unix.openfile archive [ Unix.O_WRONLY; Unix.O_APPEND ] 0 in
    let partial = "{\"message_id\":\"retry\",\"content\":\"interrupted body" in
    ignore (Unix.write_substring fd partial 0 (String.length partial));
    Unix.fsync fd;
    Unix._exit 77
  end;
  check bool "writer exited with partial archive record" true
    (snd (Unix.waitpid [] child) = Unix.WEXITED 77);
  ignore (ack broker [ "retry" ]);
  check_ids "complete retry readable after interrupted append" [ "old"; "retry" ] (archive_ids broker);
  check_ids "unrelated queued mail preserved" [ "keep" ] (ids broker);
  (* A complete JSON record missing only its newline must also survive. *)
  let contents = read archive in
  write archive (String.sub contents 0 (String.length contents - 1));
  ignore (ack broker [ "keep" ]);
  check_ids "unterminated complete record retained" [ "old"; "retry"; "keep" ] (archive_ids broker))

let test_pre_rename_sync_failure () =
  List.iter (fun error -> fixture (fun _ broker ->
    B.save_inbox broker ~session_id:sid [ message "a"; message "keep" ];
    let inbox = inbox_path broker ~session_id:sid in
    let tmp = inbox ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
    let before = read inbox in
    C2c_io.set_fsync_for_test (Some (fun path fd ->
      if path = tmp then raise (Unix.Unix_error (error, "fsync", path));
      Unix.fsync fd));
    let failed = try ignore (ack broker [ "a" ]); false with Unix.Unix_error _ -> true in
    C2c_io.set_fsync_for_test None;
    check bool "temporary inbox sync error propagates" true failed;
    check string "failed temp sync never replaces live inbox" before (read inbox);
    check bool "failed replacement temp cleaned" false (Sys.file_exists tmp);
    ignore (ack broker [ "a" ]);
    check_ids "retry retains unrelated message" [ "keep" ] (ids broker)))
    [ Unix.EIO; Unix.ENOSPC ]

let () = run "selected inbox ACK" [ "native", [
  test_case "selected, ordered, unique and idempotent" `Quick test_selected_idempotent;
  test_case "ephemeral archive privacy" `Quick test_ephemeral;
  test_case "bound caller only, no foreign overrides or alias fallback" `Quick test_foreign_session;
  test_case "host ownership environment and registry fence" `Quick test_host_owned;
  test_case "required nonempty IDs" `Quick test_arguments;
  test_case "late arrival survives ACK and reopen" `Quick test_late_arrival;
  test_case "concurrent ACKs serialize and preserve arrivals" `Quick test_ack_race;
  test_case "archive failure preserves queue and permits retry" `Quick test_archive_failure;
  test_case "archive sync failure preserves restart-safe retry" `Quick test_fsync_failure;
  test_case "durability ordering" `Quick test_durability_order;
  test_case "malformed or duplicate inbox fails closed" `Quick test_untrusted_inbox;
  test_case "queue errors never echo message contents" `Quick test_error_redaction;
  test_case "native host bindings refuse raw ACK" `Quick test_native_host;
  test_case "host publication and ACK serialize" `Quick (fun () -> test_host_publication_race false);
  test_case "host rebinding and ACK serialize" `Quick (fun () -> test_host_publication_race true);
  test_case "buffered archive flush failure preserves inbox" `Quick test_buffered_archive_failure;
  test_case "process exit after rename and missing-ID durability retry" `Quick (fun () -> test_post_rename_recovery false);
  test_case "ephemeral process recovery preserves privacy" `Quick (fun () -> test_post_rename_recovery true);
  test_case "interrupted archive append cannot poison retry" `Quick test_archive_tail_recovery;
  test_case "temp inbox sync errors prevent rename" `Quick test_pre_rename_sync_failure;
] ]
