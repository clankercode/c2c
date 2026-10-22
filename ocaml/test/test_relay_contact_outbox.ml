(* B369/B370: isolated intents, strict decoding and crash-safe legacy import.
   Filesystem and injected HTTP adapter only; no live relay or operator store. *)
module Conn = C2c_relay_connector
module Store = Relay_contact_store

let relay = "https://relay.example"
let other_relay = "https://other.example"
let target = "receiver@0123456789ab"

let rec cleanup path =
  match Unix.lstat path with
  | st when st.Unix.st_kind = Unix.S_DIR ->
      Array.iter (fun name -> cleanup (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_temp f =
  let root = Filename.temp_file "c2c-contact-outbox-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> cleanup root) (fun () -> f root)

let write path bytes =
  let oc = open_out_gen [Open_creat; Open_trunc; Open_wronly] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc bytes)

let read = C2c_io.read_file
let json_line json = Yojson.Safe.to_string json ^ "\n"
let replace key value fields = (key, value) :: List.remove_assoc key fields
let ok = function Ok value -> value | Error _ -> Alcotest.fail "fixture operation failed"

let entry ?(id = "stable-id") ?(url = Some relay) () : Conn.outbox_entry = {
  ob_from = "sender"; ob_to = target; ob_content = "private payload";
  ob_msg_id = Some id; ob_relay_url = url; ob_attempts = 1;
  ob_enqueued_at = 1717200000.; ob_last_error = None;
}

let legacy_fields = [ "from_alias", `String "sender";
                      "to_alias", `String target;
                      "content", `String "legacy payload" ]
let legacy_bytes = json_line (`Assoc legacy_fields)
let migrate ?(url = relay) root =
  Conn.with_outbox_lock root (fun () ->
    Conn.migrate_legacy_outbox_locked root ~relay_url:url)

let expect_preserved_error f =
  let message =
    try f (); Alcotest.fail "expected refusal"
    with Failure message -> message in
  Alcotest.(check bool) "fixed, redacted refusal" true
    (List.mem message [ "outbox_invalid_entry_preserved";
                        "outbox_migration_conflict_preserved" ])

let test_legacy_migration () = with_temp (fun root ->
  let old = Conn.legacy_outbox_path root in
  let explicit = `Assoc (legacy_fields @ [ "message_id", `String "original-id";
      "relay_url", `String other_relay; "attempts", `Int 3;
      "enqueued_at", `Int 1717200000; "last_error", `String "connection_error" ]) in
  write old (legacy_bytes ^ json_line explicit ^ legacy_bytes);
  Alcotest.(check int) "v2 reader never exposes old file" 0
    (List.length (Conn.read_outbox root));
  Alcotest.(check bool) "legacy root is work" false (Conn.machine_root_sync_is_noop root);
  let rows = migrate root in
  Alcotest.(check int) "all three pending intents retained" 3 (List.length rows);
  let a = List.nth rows 0 and b = List.nth rows 1 and c = List.nth rows 2 in
  Alcotest.(check bool) "identical no-ID rows stay distinct" true (a.ob_msg_id <> c.ob_msg_id);
  Alcotest.(check (option string)) "legacy ID preserved" (Some "original-id") b.ob_msg_id;
  Alcotest.(check (option string)) "explicit destination preserved" (Some other_relay) b.ob_relay_url;
  Alcotest.(check (option string)) "omitted destination pinned" (Some relay) a.ob_relay_url;
  Alcotest.(check int) "legacy retry counter preserved" 3 b.ob_attempts;
  Alcotest.(check int) "omitted retry counter defaults" 0 a.ob_attempts;
  Alcotest.(check bool) "omitted enqueue time defaults to now" true (a.ob_enqueued_at > 1_000_000_000.);
  Alcotest.(check bool) "legacy file removed only after copy" false (Sys.file_exists old);
  Alcotest.(check bool) "durable roundtrip" true (rows = Conn.read_outbox root);
  Alcotest.(check bool) "repeated import unchanged" true (rows = migrate root))

(* Interrupt at the exact durability boundary: the copied file and directory
   have actually been fsynced, but legacy unlink has not executed. *)
let crash_after_copy root =
  let v2 = Conn.outbox_path root in
  C2c_io.set_fsync_for_test (Some (fun path fd ->
      Unix.fsync fd;
      if path = root && Sys.file_exists v2 then raise Exit));
  Fun.protect ~finally:(fun () -> C2c_io.set_fsync_for_test None) (fun () ->
    try ignore (migrate root); Alcotest.fail "expected copy-boundary crash"
    with Exit -> ())

let test_copy_crash_replay () = with_temp (fun root ->
  let old = Conn.legacy_outbox_path root in
  write old (legacy_bytes ^ legacy_bytes);
  crash_after_copy root;
  Alcotest.(check bool) "legacy source survives crash" true (Sys.file_exists old);
  let copied = Conn.read_outbox root in
  Alcotest.(check int) "both copied before unlink" 2 (List.length copied);
  Alcotest.(check bool) "original IDs already committed in source" true
    (List.map snd (Conn.read_outbox_rows ~legacy:true old) = copied);
  (* A retry against a new configuration must retain the original destination. *)
  (* An unsupported old client can still append after the crashed pass releases
     the lock. Existing no-ID rows must keep their IDs when the tail changes. *)
  let added = json_line (`Assoc (replace "content" (`String "later old-client append") legacy_fields)) in
  let oc = open_out_gen [Open_append; Open_wronly] 0o600 old in
  output_string oc added;
  close_out oc;
  let replayed = migrate ~url:other_relay root in
  Alcotest.(check int) "only new tail imported after replay" 3 (List.length replayed);
  Alcotest.(check bool) "same IDs, payloads and original URLs; no duplicate copy" true
    (copied = [List.nth replayed 0; List.nth replayed 1]);
  let id = (List.hd replayed).Conn.ob_msg_id in
  (* A lost response leaves the row pending; later retries keep the same ID. *)
  Conn.with_outbox_lock root (fun () -> Conn.write_outbox root replayed);
  Alcotest.(check (option string)) "restart/lost-response identity stable" id
    (List.hd (migrate ~url:other_relay root)).Conn.ob_msg_id;
  Alcotest.(check bool) "old filename retired" false (Sys.file_exists old))

let test_source_crash_replay () = with_temp (fun root ->
  let old = Conn.legacy_outbox_path root and v2 = Conn.outbox_path root in
  write old legacy_bytes;
  C2c_io.set_fsync_for_test (Some (fun path fd ->
      Unix.fsync fd;
      if path = root && not (Sys.file_exists v2) then raise Exit));
  Fun.protect ~finally:(fun () -> C2c_io.set_fsync_for_test None) (fun () ->
    try ignore (migrate root); Alcotest.fail "expected source-boundary crash"
    with Exit -> ());
  Alcotest.(check bool) "v2 has not been copied yet" false (Sys.file_exists v2);
  let staged = List.map snd (Conn.read_outbox_rows ~legacy:true old) in
  let oc = open_out_gen [Open_append; Open_wronly] 0o600 old in
  output_string oc legacy_bytes;
  close_out oc;
  let rows = migrate ~url:other_relay root in
  Alcotest.(check int) "both old-client enqueues retained" 2 (List.length rows);
  Alcotest.(check bool) "source-committed ID and URL survive metadata change" true
    (List.hd staged = List.hd rows);
  Alcotest.(check bool) "identical later append gets a distinct ID" true
    ((List.hd rows).Conn.ob_msg_id <> (List.nth rows 1).Conn.ob_msg_id))

let test_new_legacy_batch () = with_temp (fun root ->
  let old = Conn.legacy_outbox_path root in
  write old legacy_bytes;
  let first = List.hd (migrate root) in
  (* A separate enqueue has a fresh source identity, even if the filesystem
     immediately reuses the just-unlinked inode. *)
  write old legacy_bytes;
  let rows = migrate root in
  Alcotest.(check int) "identical fresh legacy enqueue retained" 2 (List.length rows);
  Alcotest.(check bool) "new source gets a distinct ID" true
    (first.Conn.ob_msg_id <> (List.nth rows 1).Conn.ob_msg_id))

let test_exact_copy_and_conflicts () = with_temp (fun root ->
  let old = Conn.legacy_outbox_path root in
  let original = `Assoc (legacy_fields @ ["message_id", `String "original-id"]) in
  write old (json_line original);
  crash_after_copy root;
  let copied = Conn.read_outbox root in
  Alcotest.(check int) "explicit ID exact copy deduped" 1 (List.length (migrate root));
  (* An old client reintroducing the same ID with changed payload is visible,
     and neither the v2 copy nor the conflicting legacy bytes are rewritten. *)
  let conflict = json_line (`Assoc (replace "content" (`String "different")
      (legacy_fields @ ["message_id", `String "original-id"]))) in
  write old conflict;
  let v2_before = read (Conn.outbox_path root) in
  expect_preserved_error (fun () -> ignore (migrate root));
  Alcotest.(check string) "conflicting legacy preserved" conflict (read old);
  Alcotest.(check string) "v2 conflict preserved" v2_before (read (Conn.outbox_path root));
  let sender_conflict = json_line (`Assoc (replace "from_alias" (`String "other-sender")
      (legacy_fields @ ["message_id", `String "original-id"]))) in
  write old sender_conflict;
  expect_preserved_error (fun () -> ignore (migrate root));
  Alcotest.(check string) "conflicting sender preserved" sender_conflict (read old);
  Alcotest.(check string) "original intent not rewritten" v2_before (read (Conn.outbox_path root));
  Alcotest.(check bool) "original intent still pending" true (copied = Conn.read_outbox root))

let test_destination_namespaces () = with_temp (fun root ->
  let original = entry () in
  let other_route = {original with Conn.ob_to = "other@0123456789ab"} in
  let other_host = {original with Conn.ob_to = "receiver@abcdef012345"} in
  let other_url = {original with Conn.ob_relay_url = Some other_relay} in
  Conn.write_outbox root [original; other_route; other_host; other_url];
  (* An exact replay finds its own copy even when all destinations reuse the
     ID. Equivalent URL spelling belongs to that same destination namespace. *)
  let equivalent = {original with Conn.ob_relay_url = Some (relay ^ "/")} in
  write (Conn.legacy_outbox_path root)
    (String.concat "" (List.map (fun row -> json_line (Conn.outbox_entry_json row))
       [equivalent; other_route; other_host; other_url]));
  let rows = migrate root in
  Alcotest.(check bool) "replays matched within each destination" true
    (rows = [original; other_route; other_host; other_url]);
  let fresh = {original with Conn.ob_to = "third@0123456789ab"} in
  write (Conn.legacy_outbox_path root) (json_line (Conn.outbox_entry_json fresh));
  Alcotest.(check bool) "independent destination with same ID retained" true
    (migrate root = rows @ [fresh]);
  let fresh_url = {fresh with Conn.ob_relay_url = Some other_relay} in
  write (Conn.legacy_outbox_path root) (json_line (Conn.outbox_entry_json fresh_url));
  Alcotest.(check bool) "independent relay with same ID retained" true
    (migrate root = rows @ [fresh; fresh_url]))

let bad_rows ~legacy =
  let base = if legacy then legacy_fields else
      match Conn.outbox_entry_json (entry ()) with `Assoc fields -> fields | _ -> assert false in
  let cases = [
    "ID null", "message_id", `Null;
    "ID integer", "message_id", `Int 7;
    "ID empty", "message_id", `String "";
    "ID blank", "message_id", `String " ";
    "URL null", "relay_url", `Null;
    "URL integer", "relay_url", `Int 7;
    "URL empty", "relay_url", `String "";
    "URL invalid", "relay_url", `String "https://relay.example/other";
    "URL credentials", "relay_url", `String "https://secret@relay.example";
    "content null", "content", `Null;
    "content integer", "content", `Int 7;
    "content empty", "content", `String "";
    "sender null", "from_alias", `Null;
    "target invalid", "to_alias", `String "bad/route";
    "attempts null", "attempts", `Null;
    "attempts negative", "attempts", `Int (-1);
    "time null", "enqueued_at", `Null;
    "time negative", "enqueued_at", `Int (-1);
    "time infinite", "enqueued_at", `Intlit "1e999";
    "error null", "last_error", `Null;
    "unknown version", "version", `Int 99;
    "version null", "version", `Null;
    "unknown field", "future_schema", `Bool true;
  ] in
  let changed = List.map (fun (name, key, value) ->
      name, json_line (`Assoc (replace key value base))) cases in
  let duplicated = List.map (fun key ->
      let fields = if List.mem_assoc key base then base
        else (key, `String "first-value") :: base in
      "duplicate " ^ key,
      json_line (`Assoc ((key, `String "ambiguous") :: fields)))
      (if legacy then ["from_alias"; "to_alias"; "content"; "message_id"; "relay_url"]
       else ["from_alias"; "message_id"; "relay_url"; "version"]) in
  let missing = List.map (fun key ->
      "missing " ^ key, json_line (`Assoc (List.remove_assoc key base)))
      (if legacy then ["content"; "from_alias"; "to_alias"]
       else ["version"; "message_id"; "relay_url"; "attempts"; "enqueued_at"]) in
  changed @ duplicated @ missing @ ["truncated JSON", "{\"content\":\"unfinished\n"]

let malformed_case ~legacy (name, bad) =
  Alcotest.test_case name `Quick (fun () -> with_temp (fun root ->
    let old = Conn.legacy_outbox_path root and v2 = Conn.outbox_path root in
    Conn.write_outbox root [entry ()];
    write old legacy_bytes;
    (* Prepend valid mail: validation must preserve the whole original file,
       even when the corruption is discovered only at its tail. *)
    let damaged = if legacy then old else v2 in
    write damaged (read damaged ^ bad);
    let old_before = read old and v2_before = read v2 in
    expect_preserved_error (fun () -> ignore (migrate root));
    Alcotest.(check string) "all legacy bytes preserved" old_before (read old);
    Alcotest.(check string) "all v2 bytes preserved" v2_before (read v2)))

let test_invalid_new_writes () = with_temp (fun root ->
  let good = entry () in
  Conn.write_outbox root [good];
  let before = read (Conn.outbox_path root) in
  List.iter (fun bad ->
    expect_preserved_error (fun () -> Conn.write_outbox root [good; bad]);
    Alcotest.(check string) "invalid batch cannot rewrite original" before
      (read (Conn.outbox_path root))) [
    {good with ob_msg_id = None}; {good with ob_msg_id = Some ""};
    {good with ob_msg_id = Some (String.make 1025 'x')};
    {good with ob_relay_url = Some "invalid"};
    {good with ob_content = ""}; {good with ob_content = String.make (256 * 1024 + 1) 'x'};
    {good with ob_from = "bad/alias"}; {good with ob_to = "bad@host@extra"};
    {good with ob_attempts = -1}; {good with ob_attempts = max_int};
    {good with ob_enqueued_at = nan}; {good with ob_last_error = Some ""};
  ];
  expect_preserved_error (fun () -> Conn.append_outbox_entry root
      ~from_alias:"sender" ~to_alias:target ~content:"hi" ~message_id:"" ());
  Alcotest.(check string) "invalid append preserves original" before (read (Conn.outbox_path root)))

let test_offline_marker () = with_temp (fun root ->
  let pending = entry ~url:None () in
  Conn.write_outbox root [pending];
  Alcotest.(check bool) "explicit offline intent survives read" true
    (Conn.read_outbox root = [pending]);
  let rows = migrate root in
  Alcotest.(check (option string)) "first sync pins destination" (Some relay)
    (List.hd rows).Conn.ob_relay_url;
  Alcotest.(check (option string)) "later config does not repin" (Some relay)
    (List.hd (migrate ~url:other_relay root)).Conn.ob_relay_url)

let with_contact root f =
  let env = [ "XDG_CONFIG_HOME", root;
              "C2C_RELAY_URL", relay;
              "C2C_RELAY_CONFIG", Filename.concat root "relay.json";
              "C2C_RELAY_IDENTITY_PATH", Filename.concat root "identity.json" ] in
  let saved = List.map (fun (key, _) -> key, Sys.getenv_opt key) env in
  Fun.protect ~finally:(fun () -> List.iter (fun (key, value) ->
      Unix.putenv key (Option.value value ~default:"")) saved) (fun () ->
    List.iter (fun (key, value) -> Unix.putenv key value) env;
    let identity = Relay_identity.generate () in
    ignore (ok (Relay_identity.save ~path:(Filename.concat root "identity.json") identity));
    let b64 = Relay_identity.b64url_encode in
    let secret = String.make 32 's' in
    let artifact = `Assoc [ "artifact_version", `Int 1;
      "protocol", `String "c2c-contact/1"; "scope", `String "dm-first-contact";
      "relay_url", `String relay; "recipient_route", `String target;
      "delivery_alias", `String "receiver";
      "sender_pk", `String (b64 identity.public_key);
      "recipient_pk", `String (b64 (String.make 32 'r'));
      "grant_id", `String (b64 Digestif.SHA256.(to_raw_string (digest_string secret)));
      "grant_secret", `String (b64 secret);
      "expires_at", `Float (Unix.gettimeofday () +. 3600.); "generation", `Int 1 ] in
    let path = Filename.concat root "grant.json" in
    write path (Yojson.Safe.to_string artifact);
    ignore (ok (Store.import_file ~relay_url:relay ~to_alias:target
        ~sender_pk:(b64 identity.public_key) ~allow_http:false ~path
        ~now:(Unix.gettimeofday ()) ()));
    f identity)

let test_protected_append_and_retry () = with_temp (fun root -> with_contact root (fun identity ->
  (* The old reader only knows this pathname and ignores fields it does not
     understand. It must see exactly the old row, never the protected intent. *)
  let old = Conn.legacy_outbox_path root in
  write old legacy_bytes;
  Conn.append_outbox_entry root ~from_alias:"sender" ~to_alias:target
    ~content:"protected payload" ~message_id:"protected-id" ();
  Alcotest.(check string) "old reader sees only old mail" legacy_bytes (read old);
  let pending = Conn.read_outbox root in
  Alcotest.(check int) "new intent isolated" 1 (List.length pending);
  let paths = ref [] and ids = ref [] and attempts = ref 0 in
  let request ~meth:_ ~path ~body ~auth:_ =
    paths := path :: !paths;
    if path = "/health" then Lwt.return (`Assoc ["contact_protocol", `Int 1;
        "contact_destination_binding", `Int 1])
    else begin
      incr attempts;
      let json = Option.get body in
      ids := Yojson.Safe.Util.member "message_id" json :: !ids;
      Lwt.return (if !attempts = 1 then
          `Assoc ["ok", `Bool false; "error_code", `String "connection_error"]
        else `Assoc ["ok", `Bool true; "duplicate", `Bool true])
    end in
  let send row = Lwt_main.run (Relay_contact_send.dispatch ~relay_url:relay
      ~identity:(Some identity) ~from_alias:row.Conn.ob_from ~sender_route:"sender"
      ~to_alias:row.ob_to ~content:row.ob_content
      ~message_id:(Option.get row.ob_msg_id) ~request ()) in
  ignore (send (List.hd pending));
  Conn.with_outbox_lock root (fun () -> Conn.write_outbox root pending);
  ignore (send (List.hd (Conn.read_outbox root)));
  Alcotest.(check (list string)) "response-loss retry uses original ID twice"
    ["protected-id"; "protected-id"]
    (List.map Yojson.Safe.Util.to_string !ids);
  Alcotest.(check bool) "never falls back to /send" false (List.mem "/send" !paths);
  ignore (ok (Store.disable ~relay_url:relay ~to_alias:target ()));
  let before = List.length !paths in
  let held = send (List.hd pending) in
  Alcotest.(check string) "hold classification preserved" "contact_send_held"
    Yojson.Safe.Util.(held |> member "error_code" |> to_string);
  Alcotest.(check int) "disabled route makes no HTTP request" before (List.length !paths);
  Alcotest.(check bool) "pending protected intent retained" true (pending = Conn.read_outbox root)))

let test_append_delimiter () = with_temp (fun root -> with_contact root (fun _ ->
  let original = entry () in
  let serialized = Yojson.Safe.to_string (Conn.outbox_entry_json original) in
  List.iter (fun suffix ->
    write (Conn.outbox_path root) (serialized ^ suffix);
    Conn.append_outbox_entry root ~from_alias:"sender" ~to_alias:target
      ~content:"next protected payload" ~message_id:"next-id" ();
    let rows = Conn.read_outbox root in
    Alcotest.(check int) "both complete records remain readable" 2 (List.length rows);
    Alcotest.(check bool) "existing record retained" true (List.hd rows = original);
    Alcotest.(check (option string)) "new message accepted once" (Some "next-id")
      (List.nth rows 1).Conn.ob_msg_id)
    [""; "\n"; "  "];
  write (Conn.outbox_path root) "";
  Conn.append_outbox_entry root ~from_alias:"sender" ~to_alias:target
    ~content:"empty queue append" ~message_id:"empty-id" ();
  Alcotest.(check int) "empty queue append readable" 1 (List.length (Conn.read_outbox root));
  let damaged = serialized ^ "\n{\"version\":" in
  write (Conn.outbox_path root) damaged;
  expect_preserved_error (fun () -> Conn.append_outbox_entry root ~from_alias:"sender"
      ~to_alias:target ~content:"must remain refused" ~message_id:"refused-id" ());
  Alcotest.(check string) "incomplete record remains untouched" damaged
    (read (Conn.outbox_path root))))

let () =
  Alcotest.run "relay-contact-outbox" [
    "migration", [
      Alcotest.test_case "legacy omissions and explicit intent survive" `Quick test_legacy_migration;
      Alcotest.test_case "copy-before-unlink crash replay retains IDs and URL" `Quick test_copy_crash_replay;
      Alcotest.test_case "source-normalization crash survives legacy append" `Quick test_source_crash_replay;
      Alcotest.test_case "identical fresh legacy batch is separate mail" `Quick test_new_legacy_batch;
      Alcotest.test_case "exact copy deduped; conflicting copy preserved" `Quick test_exact_copy_and_conflicts;
      Alcotest.test_case "message IDs are scoped to relay and recipient" `Quick test_destination_namespaces;
      Alcotest.test_case "offline marker pins once" `Quick test_offline_marker ];
    "malformed legacy", List.map (malformed_case ~legacy:true) (bad_rows ~legacy:true);
    "malformed v2", List.map (malformed_case ~legacy:false) (bad_rows ~legacy:false);
    "new intents", [
      Alcotest.test_case "invalid writes preserve original bytes" `Quick test_invalid_new_writes;
      Alcotest.test_case "append repairs only a complete row delimiter" `Quick test_append_delimiter;
      Alcotest.test_case "old reader isolation, lost response, disable" `Quick test_protected_append_and_retry ];
  ]
