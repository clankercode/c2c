(* B370 sender store contract. No relay, connector or network dependency. *)
module Store = Relay_contact_store

let b64 s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s
let key c = b64 (String.make 32 c)
let sender = key 's'
let recipient = key 'r'
let other = key 'o'
let relay = "https://relay.example"
let target = "receiver@0123456789ab"
let from = "sender@abcdef012345"
let now = 1000.
let id_of_secret secret = b64 Digestif.SHA256.(to_raw_string (digest_string secret))
let secret n = String.make 32 (Char.chr (64 + n))
let grant_id n = id_of_secret (secret n)
let artifact ?(relay_url = relay) ?(recipient_route = target)
    ?(delivery_alias = "receiver") ?(sender_pk = sender) ?(recipient_pk = recipient)
    ?(expires_at = 2000.) ?generation n : Yojson.Safe.t =
  `Assoc ["artifact_version", `Int 1; "protocol", `String "c2c-contact/1";
    "scope", `String "dm-first-contact"; "relay_url", `String relay_url;
    "recipient_route", `String recipient_route; "delivery_alias", `String delivery_alias;
    "sender_pk", `String sender_pk; "recipient_pk", `String recipient_pk;
    "grant_id", `String (grant_id n); "grant_secret", `String (b64 (secret n));
    "expires_at", `Float expires_at; "generation", `Int (Option.value generation ~default:n)]
let replace name value = function
  | `Assoc fields -> `Assoc ((name, value) :: List.remove_assoc name fields)
  | _ -> assert false
let ok = function Ok value -> value | Error e -> Alcotest.fail e
let error = function Error e -> e | Ok _ -> Alcotest.fail "expected error"
let denied result = ignore (error result)
let contains text needle =
  let n = String.length needle in
  let rec loop i = i + n <= String.length text &&
    (String.sub text i n = needle || loop (i + 1)) in
  loop 0
let no_literal text literal = Alcotest.(check bool) "redacted" false (contains text literal)
let rec cleanup path =
  match Unix.lstat path with
  | st when st.Unix.st_kind = Unix.S_DIR ->
      Array.iter (fun name -> cleanup (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
let with_temp f =
  let root = Filename.temp_file "c2c-sender-contact-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let dir = Filename.concat root "store" in
  Fun.protect ~finally:(fun () -> cleanup root) (fun () -> f root dir)
let write_text path text =
  let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let oc = Unix.out_channel_of_descr fd in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    Unix.fchmod fd 0o600;
    output_string oc text;
    flush oc)
let write_card root json =
  let path = Filename.concat root "card.json" in
  write_text path (Yojson.Safe.to_string ~std:false json);
  path
let import ?(relay_url = relay) ?(to_alias = target) ?(sender_pk = sender)
    ?(allow_http = false) ?(at = now) root dir card =
  Store.import_file ~dir ~relay_url ~to_alias ~sender_pk ~allow_http
    ~path:(write_card root card) ~now:at ()
let prepare ?(relay_url = relay) ?(to_alias = target) ?(sender_pk = sender)
    ?(from_alias = from) ?(content = "message-private-body") ?(message_id = "id-1")
    ?(at = now) dir () =
  Store.prepare ~dir ~relay_url ~to_alias ~sender_pk ~from_alias ~content ~message_id ~now:at ()
let contact n selection = match selection with
  | Store.Legacy -> Alcotest.fail "expected contact"
  | Store.Contact c ->
      Alcotest.(check string) "original grant ID" (grant_id n) c.grant_id;
      Alcotest.(check bool) "exact secret" true (c.grant_secret = b64 (secret n));
      Alcotest.(check string) "trusted recipient key" recipient c.recipient_pk;
      Alcotest.(check string) "bare delivery alias" "receiver" c.delivery_alias
let legacy = function Store.Legacy -> () | Store.Contact _ -> Alcotest.fail "expected legacy"
let database dir = Filename.concat dir "contacts.sqlite"
let mutate dir sql =
  let db = Sqlite3.db_open (database dir) in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () ->
    Alcotest.(check bool) "fixture mutation succeeds" true (Sqlite3.Rc.is_success (Sqlite3.exec db sql)))

let test_canonical_urls () =
  List.iter (fun (input, expected) ->
    Alcotest.(check string) "canonical origin" expected (ok (Store.canonical_url input)))
    ["HTTPS://Relay.Example:443/", relay;
     "http://C2C.LAN:80", "http://c2c.lan";
     "https://relay.example:0443", relay;
     "http://127.0.0.1:30435/", "http://127.0.0.1:30435";
     "https://[::1]:443/", "https://[::1]";
     "https://[0:0:0:0:0:0:0:1]/", "https://[::1]"];
  List.iter (fun input -> denied (Store.canonical_url input))
    [""; "relay.example"; "ftp://relay.example"; "https://u:p@relay.example";
     "https://relay.example/path"; "https://relay.example//";
     "https://relay.example/?token=secret"; "https://relay.example/#frag";
     "https://relay.example:"; "https://relay.example:0";
     "https://relay.example:65536"; "https://relay.example:abc";
     "https://relay.example\\evil"; "https://%72elay.example";
     "https://.example"; "https://bad_.example"; " https://relay.example"]

let test_import_and_restart () = with_temp (fun root dir ->
  ok (import root dir (artifact ~relay_url:"HTTPS://Relay.Example:443/" 1));
  contact 1 (ok (prepare dir ()));
  contact 1 (ok (prepare ~relay_url:"https://relay.example/" dir ()));
  (* API opens/closes its SQLite connection each time: these calls exercise
     durable state without sharing any in-process cache. *)
  contact 1 (ok (prepare dir ()));
  Alcotest.(check int) "directory 0700" 0o700 (Unix.stat dir).Unix.st_perm;
  Alcotest.(check int) "database 0600" 0o600 (Unix.stat (database dir)).Unix.st_perm)

let test_legacy_pins_and_import () = with_temp (fun root dir ->
  legacy (ok (prepare dir ()));
  legacy (ok (prepare dir ()));
  denied (prepare ~content:"changed" dir ());
  ok (import root dir (artifact 1));
  denied (prepare dir ());
  contact 1 (ok (prepare ~message_id:"new-id" dir ())))

let test_anonymous_legacy_only () = with_temp (fun root dir ->
  legacy (ok (prepare ~sender_pk:"" dir ()));
  ok (import root dir (artifact 1));
  denied (prepare ~sender_pk:"" ~message_id:"new" dir ());
  denied (prepare ~sender_pk:"garbage" ~message_id:"new" dir ()))

let test_rotation_and_namespaces () = with_temp (fun root dir ->
  ok (import root dir (artifact 1));
  contact 1 (ok (prepare dir ()));
  ok (import root dir (artifact 2));
  contact 1 (ok (prepare dir ()));
  contact 2 (ok (prepare ~message_id:"new-id" dir ()));
  (* The same ID is independent at another exact route or relay. *)
  legacy (ok (prepare ~to_alias:"other@0123456789ab" dir ()));
  legacy (ok (prepare ~relay_url:"https://other.example" dir ()));
  let out = Filename.concat root "rotation-export.json" in
  ok (Store.export_file ~dir ~relay_url:relay ~to_alias:target ~path:out ());
  let exported = ok (Store.read_private_json out) in
  Alcotest.(check string) "export selects current version" (grant_id 2)
    Yojson.Safe.Util.(to_string (member "grant_id" exported)))

let test_process_restart_pins () = with_temp (fun root dir ->
  let child f =
    match Unix.fork () with
    | 0 ->
        let status = try if f () then 0 else 1 with _ -> 2 in
        exit status
    | pid ->
        let _, status = Unix.waitpid [] pid in
        Alcotest.(check bool) "separate process persisted selection" true (status = Unix.WEXITED 0) in
  let is_contact n result = match result with
    | Ok (Store.Contact c) -> c.grant_id = grant_id n
    | _ -> false in
  ok (import root dir (artifact 1));
  child (fun () -> is_contact 1 (prepare dir ()));
  ok (import root dir (artifact 2));
  child (fun () -> is_contact 1 (prepare dir ()) &&
    is_contact 2 (prepare ~message_id:"new-process-id" dir ()));
  denied (prepare ~content:"changed-after-restart" dir ());
  contact 1 (ok (prepare dir ())))

let test_payload_id_conflicts () = with_temp (fun root dir ->
  ok (import root dir (artifact 1));
  contact 1 (ok (prepare dir ()));
  denied (prepare ~content:"different-body" dir ());
  denied (prepare ~from_alias:"sender2@abcdef012345" dir ());
  denied (prepare ~sender_pk:other dir ());
  contact 1 (ok (prepare dir ()));
  contact 1 (ok (prepare ~content:"different-body" ~message_id:"different-id" dir ())))

let test_sender_and_rotation_identity () = with_temp (fun root dir ->
  denied (import ~sender_pk:other root dir (artifact 1));
  ok (import root dir (artifact 1));
  denied (prepare ~sender_pk:other ~message_id:"other-sender" dir ());
  denied (import ~sender_pk:other root dir (artifact ~sender_pk:other 2));
  denied (import root dir (artifact ~recipient_pk:other 2));
  denied (import root dir (artifact ~generation:1 2));
  ok (import root dir (artifact 2));
  denied (import root dir (artifact 1));
  contact 2 (ok (prepare dir ())))

let test_immutable_grants () = with_temp (fun root dir ->
  ok (import root dir (artifact 1));
  ok (import root dir (artifact 1));
  denied (import root dir (artifact ~expires_at:3000. 1));
  denied (import ~allow_http:true root dir (artifact 1));
  contact 1 (ok (prepare dir ()));
  (* A verifier cannot silently bind a second route, even under the same key. *)
  denied (import ~to_alias:"receiver@abcdef012345" root dir
    (artifact ~recipient_route:"receiver@abcdef012345" 1)))

let test_expired_original () = with_temp (fun root dir ->
  denied (import root dir (artifact ~expires_at:now 1));
  ok (import root dir (artifact ~expires_at:1100. 1));
  contact 1 (ok (prepare dir ()));
  ok (import root dir (artifact 2));
  let message = error (prepare ~at:1100. dir ()) in
  Alcotest.(check bool) "uncertainty retained" true (contains message "uncertain");
  contact 2 (ok (prepare ~at:1100. ~message_id:"new-id" dir ()));
  denied (prepare ~at:2000. ~message_id:"expired-current" dir ()))

let test_disabled_and_reenabled () = with_temp (fun root dir ->
  ok (import root dir (artifact 1));
  contact 1 (ok (prepare dir ()));
  ok (Store.disable ~dir ~relay_url:relay ~to_alias:target ());
  denied (prepare dir ());
  denied (prepare ~message_id:"new-id" dir ());
  denied (Store.export_file ~dir ~relay_url:relay ~to_alias:target ~path:(Filename.concat root "out.json") ());
  ok (import root dir (artifact 2));
  contact 1 (ok (prepare dir ()));
  contact 2 (ok (prepare ~message_id:"new-id" dir ())))

let test_unknown_disabled_tombstone () = with_temp (fun root dir ->
  ok (Store.disable ~dir ~relay_url:relay ~to_alias:target ());
  denied (prepare dir ());
  denied (prepare ~message_id:"another-id" dir ());
  legacy (ok (prepare ~to_alias:"unselected" dir ()));
  ok (import root dir (artifact 1));
  contact 1 (ok (prepare dir ())))

let test_missing_current_grant () = with_temp (fun root dir ->
  ok (import root dir (artifact 1));
  contact 1 (ok (prepare dir ()));
  mutate dir "UPDATE routes SET grant_id='absent'";
  denied (prepare dir ());
  denied (prepare ~message_id:"new-id" dir ()))

let test_missing_route () = with_temp (fun root dir ->
  ok (import root dir (artifact 1));
  contact 1 (ok (prepare dir ()));
  mutate dir "DELETE FROM routes";
  denied (prepare dir ());
  denied (prepare ~message_id:"new-id" dir ());
  denied (import root dir (artifact 2)))

let test_missing_old_grant () = with_temp (fun root dir ->
  ok (import root dir (artifact 1));
  contact 1 (ok (prepare dir ()));
  ok (import root dir (artifact 2));
  mutate dir ("DROP TRIGGER immutable_grants_delete; DELETE FROM grants WHERE grant_id='" ^ grant_id 1 ^ "'");
  denied (prepare dir ());
  contact 2 (ok (prepare ~message_id:"new-id" dir ())))

let test_missing_database () = with_temp (fun root dir ->
  ok (import root dir (artifact 1));
  Unix.unlink (database dir);
  denied (prepare dir ());
  Alcotest.(check bool) "missing database not recreated" false (Sys.file_exists (database dir)))

let test_metadata_redacted () = with_temp (fun root dir ->
  let card = match artifact 1 with
    | `Assoc fields -> `Assoc (("display_hint", `String "display-body-secret") :: fields)
    | _ -> assert false in
  ok (import root dir card);
  contact 1 (ok (prepare dir ()));
  let json = ok (Store.list_metadata ~dir ()) in
  let serialized = Yojson.Safe.to_string json in
  List.iter (no_literal serialized) [b64 (secret 1); "grant_secret"; "content";
    "payload_hash"; "message-private-body"; "display-body-secret"];
  let allowed = ["relay_url"; "recipient_route"; "disabled"; "grant_id";
    "delivery_alias"; "sender_pk"; "recipient_pk"; "expires_at"; "generation"; "allow_http"] in
  (match json with
   | `List [`Assoc fields] ->
       List.iter (fun (name, _) -> Alcotest.(check bool) "allowlisted metadata key" true (List.mem name allowed)) fields
   | _ -> Alcotest.fail "one contact metadata row expected");
  ok (Store.disable ~dir ~relay_url:relay ~to_alias:target ());
  ignore (ok (Store.list_metadata ~dir ())))

let test_artifact_validation () = with_temp (fun root dir ->
  let cards = [
    artifact ~relay_url:"https://other.example" 1;
    artifact ~recipient_route:"receiver@abcdef012345" 1;
    artifact ~delivery_alias:"impostor" 1;
    artifact ~recipient_route:"receiver@BADHOST" 1;
    artifact ~recipient_route:"receiver#host" 1;
    artifact ~sender_pk:"bad" 1;
    artifact ~recipient_pk:(key 'r' ^ "=") 1;
    artifact ~recipient_pk:(b64 (String.make 31 'x')) 1;
    artifact ~generation:0 1;
    replace "expires_at" (`Intlit "1e999") (artifact 1);
    replace "grant_secret" (`String (key 'x')) (artifact 1);
    replace "grant_id" (`String "not-a-verifier") (artifact 1);
    replace "scope" (`String "room") (artifact 1);
    replace "protocol" (`String "c2c-contact/2") (artifact 1);
    replace "artifact_version" (`Int 2) (artifact 1);
    (match artifact 1 with `Assoc fields -> `Assoc (("sender_pk", `String sender) :: fields) | _ -> assert false)
  ] in
  List.iter (fun card -> denied (import root dir card)) cards;
  ok (import root dir (artifact 1));
  contact 1 (ok (prepare dir ())))

let test_routes_not_display_hints () = with_temp (fun root dir ->
  let card = replace "recipient_route" (`String "someone-else@0123456789ab") (artifact 1)
    |> replace "recipient_display_hint" (`String target) in
  denied (import root dir card);
  (* Bare aliases and host-qualified aliases are independent exact routes. *)
  ok (import root dir (artifact 1));
  legacy (ok (prepare ~to_alias:"receiver" dir ()));
  legacy (ok (prepare ~to_alias:"receiver@relay-a" dir ())))

let test_http_consent () = with_temp (fun root dir ->
  let http = "http://c2c.lan:30435" in
  let card = artifact ~relay_url:http 1 in
  denied (import ~relay_url:http root dir card);
  ok (import ~relay_url:http ~allow_http:true root dir card);
  let selected = ok (prepare ~relay_url:http dir ()) in
  contact 1 selected;
  (match selected with Store.Contact c -> Alcotest.(check bool) "explicit HTTP consent" true c.allow_http | _ -> assert false);
  let output = Filename.concat root "http-export.json" in
  ok (Store.export_file ~dir ~relay_url:http ~to_alias:target ~path:output ());
  let exported = ok (Store.read_private_json output) in
  Alcotest.(check bool) "consent does not transfer in artifact" true
    (Yojson.Safe.Util.member "allow_http" exported = `Null);
  let second_dir = Filename.concat root "second-store" in
  denied (Store.import_file ~dir:second_dir ~relay_url:http ~to_alias:target ~sender_pk:sender
    ~allow_http:false ~path:output ~now ()))

let test_private_file_reads () = with_temp (fun root _ ->
  let path = write_card root (artifact 1) in
  ignore (ok (Store.read_private_json path));
  Unix.chmod path 0o400;
  ignore (ok (Store.read_private_json path));
  Unix.chmod path 0o644;
  denied (Store.read_private_json path);
  Unix.chmod path 0o600;
  let link = Filename.concat root "linked.json" in
  Unix.symlink path link;
  denied (Store.read_private_json link);
  let hard = Filename.concat root "hard.json" in
  Unix.link path hard;
  denied (Store.read_private_json path);
  Unix.unlink hard;
  let parent_link = Filename.concat root "linked-dir" in
  Unix.symlink root parent_link;
  denied (Store.read_private_json (Filename.concat parent_link "card.json"));
  denied (Store.read_private_json root);
  write_text path "{not-json-secret-body";
  let message = error (Store.read_private_json path) in
  no_literal message "not-json-secret-body";
  no_literal message path;
  write_text path (String.make 65537 'x');
  denied (Store.read_private_json path);
  let fifo = Filename.concat root "pipe" in
  Unix.mkfifo fifo 0o600;
  denied (Store.read_private_json fifo))

let test_store_permission_and_symlinks () = with_temp (fun root dir ->
  Unix.mkdir dir 0o755;
  denied (prepare dir ());
  Unix.chmod dir 0o700;
  legacy (ok (prepare dir ()));
  Unix.chmod (database dir) 0o644;
  denied (prepare dir ());
  Unix.chmod (database dir) 0o600;
  let saved = Filename.concat root "saved.sqlite" in
  Unix.rename (database dir) saved;
  Unix.symlink saved (database dir);
  denied (prepare dir ());
  Unix.unlink (database dir);
  Unix.rename saved (database dir);
  let journal = database dir ^ "-journal" in
  Unix.symlink (Filename.concat root "does-not-exist") journal;
  denied (prepare dir ());
  Unix.unlink journal;
  let dir_link = Filename.concat root "store-link" in
  Unix.symlink dir dir_link;
  denied (prepare dir_link ());
  legacy (ok (prepare dir ())))

let test_corrupt_store_redacted () = with_temp (fun root dir ->
  ok (import root dir (artifact 1));
  write_text (database dir) "path-and-body-secret-corrupt-SQLite";
  let message = error (prepare dir ()) in
  List.iter (no_literal message) [dir; "path-and-body-secret"; b64 (secret 1)];
  denied (Store.list_metadata ~dir ()))

let test_exclusive_export () = with_temp (fun root dir ->
  ok (import root dir (artifact 1));
  let output = Filename.concat root "export.json" in
  ok (Store.export_file ~dir ~relay_url:relay ~to_alias:target ~path:output ());
  Alcotest.(check int) "export mode 0600" 0o600 (Unix.stat output).Unix.st_perm;
  let before = C2c_io.read_file output in
  denied (Store.export_file ~dir ~relay_url:relay ~to_alias:target ~path:output ());
  Alcotest.(check string) "existing file retained" before (C2c_io.read_file output);
  let linked = Filename.concat root "export-link" in
  Unix.symlink output linked;
  denied (Store.export_file ~dir ~relay_url:relay ~to_alias:target ~path:linked ());
  denied (Store.export_file ~dir ~relay_url:relay ~to_alias:target ~path:"-" ());
  let link_dir = Filename.concat root "export-dir-link" in
  Unix.symlink root link_dir;
  denied (Store.export_file ~dir ~relay_url:relay ~to_alias:target
    ~path:(Filename.concat link_dir "new.json") ()))

let test_failed_first_operation_recoverable () = with_temp (fun root dir ->
  denied (prepare ~from_alias:"invalid/from" dir ());
  ok (import root dir (artifact 1));
  contact 1 (ok (prepare dir ()));
  denied (prepare ~at:nan dir ());
  contact 1 (ok (prepare dir ())))

let tests = [
  "canonical origins", test_canonical_urls;
  "import and connection restart", test_import_and_restart;
  "legacy pin and later protection", test_legacy_pins_and_import;
  "anonymous legacy only", test_anonymous_legacy_only;
  "rotation and route/relay namespace", test_rotation_and_namespaces;
  "pins survive process restart", test_process_restart_pins;
  "payload, sender and from alias conflicts", test_payload_id_conflicts;
  "sender and recipient identity continuity", test_sender_and_rotation_identity;
  "immutable grant versions", test_immutable_grants;
  "expired original retains uncertainty", test_expired_original;
  "disable retains pins across reenable", test_disabled_and_reenabled;
  "unselected disable creates tombstone", test_unknown_disabled_tombstone;
  "missing current grant", test_missing_current_grant;
  "missing selected route", test_missing_route;
  "missing old pinned grant", test_missing_old_grant;
  "missing database fails closed", test_missing_database;
  "metadata is allowlisted and redacted", test_metadata_redacted;
  "artifact validation", test_artifact_validation;
  "exact route never display hint", test_routes_not_display_hints;
  "explicit HTTP consent does not transfer", test_http_consent;
  "private files and symlink refusal", test_private_file_reads;
  "store permissions and symlinks", test_store_permission_and_symlinks;
  "corrupt store errors redacted", test_corrupt_store_redacted;
  "exclusive private export", test_exclusive_export;
  "failed first operation preserves initialized store", test_failed_first_operation_recoverable;
]
let () = Alcotest.run "relay contact sender store"
  ["sender store", List.map (fun (name, f) -> Alcotest.test_case name `Quick f) tests]
