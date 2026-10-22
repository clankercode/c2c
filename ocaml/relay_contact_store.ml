type selection =
  | Legacy
  | Contact of {
      grant_id : string;
      grant_secret : string;
      recipient_pk : string;
      delivery_alias : string;
      allow_http : bool;
    }

exception Invalid of string
let reject message = raise (Invalid message)
let require condition message = if not condition then reject message
let protect f =
  try Ok (f ()) with
  | Invalid message -> Error message
  | _ -> Error "contact store unavailable; delivery held"

let finite n = match classify_float n with FP_nan | FP_infinite -> false | _ -> true
let b64 s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s
let sha s = Digestif.SHA256.(to_raw_string (digest_string s))
let decode32 s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
  | Ok raw when String.length raw = 32 && b64 raw = s -> raw
  | _ -> reject "invalid contact key or verifier"
let valid_key s = ignore (decode32 s)

(* Only a relay origin is accepted. A path prefix would make the caller's
   signed request path ambiguous. Parsing explicitly also rejects URI parser
   repairs (backslashes, encoded authority and empty/invalid ports). *)
let url value =
  let bad () = reject "invalid relay URL" in
  let size = String.length value in
  require (size > 0 && size <= 2048) "invalid relay URL";
  String.iter (fun c -> if Char.code c <= 32 || Char.code c >= 127 then bad ()) value;
  let colon = match String.index_opt value ':' with Some i -> i | None -> bad () in
  let scheme = String.lowercase_ascii (String.sub value 0 colon) in
  require (scheme = "https" || scheme = "http") "invalid relay URL";
  require (size >= colon + 3 && String.sub value colon 3 = "://") "invalid relay URL";
  let rest = String.sub value (colon + 3) (size - colon - 3) in
  let authority =
    if String.ends_with ~suffix:"/" rest then String.sub rest 0 (String.length rest - 1)
    else rest in
  require (authority <> "") "invalid relay URL";
  String.iter (fun c -> if String.contains "/\\@?#%" c then bad ()) authority;
  let host, port_text =
    if authority.[0] = '[' then begin
      let stop = match String.index_opt authority ']' with Some i -> i | None -> bad () in
      let inner = String.sub authority 1 (stop - 1) in
      require (String.contains inner ':') "invalid relay URL";
      let normalized =
        try Unix.string_of_inet_addr (Unix.inet_addr_of_string inner)
        with _ -> bad () in
      let tail = String.sub authority (stop + 1) (String.length authority - stop - 1) in
      let port = if tail = "" then None else begin
        require (tail.[0] = ':') "invalid relay URL";
        Some (String.sub tail 1 (String.length tail - 1)) end in
      "[" ^ String.lowercase_ascii normalized ^ "]", port
    end else begin
      let parts = String.split_on_char ':' authority in
      let host, port = match parts with [h] -> h, None | [h; p] -> h, Some p | _ -> bad () in
      require (String.length host <= 253) "invalid relay URL";
      List.iter (fun label ->
        let n = String.length label in
        require (n > 0 && n <= 63 && label.[0] <> '-' && label.[n - 1] <> '-') "invalid relay URL";
        String.iter (fun c ->
          if not ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c = '-') then bad ()) label)
        (String.split_on_char '.' host);
      String.lowercase_ascii host, port
    end in
  let port = match port_text with
    | None -> ""
    | Some p ->
        require (p <> "" && String.length p <= 5) "invalid relay URL";
        String.iter (fun c -> if c < '0' || c > '9' then bad ()) p;
        let n = int_of_string p in
        require (n > 0 && n <= 65535) "invalid relay URL";
        if (scheme = "http" && n = 80) || (scheme = "https" && n = 443)
        then "" else ":" ^ string_of_int n in
  scheme ^ "://" ^ host ^ port
let canonical_url value = protect (fun () -> url value)
let route value =
  require (C2c_name.is_valid_with_opaque_host_id value) "invalid contact route";
  fst (C2c_name.split_opaque_host_id value)

(* Existing legacy relay forwarding also accepts named relay hosts. They are
   valid legacy intents, but never accepted as contact-grant route bindings. *)
let legacy_route value =
  match String.split_on_char '@' value with
  | [alias] when C2c_name.is_valid alias -> ()
  | [alias; host] when C2c_name.is_valid alias && C2c_name.is_valid host -> ()
  | _ -> reject "invalid relay route"

let default_dir () =
  let base = match Sys.getenv_opt "XDG_CONFIG_HOME" with
    | Some s when s <> "" -> s
    | _ ->
        (match Sys.getenv_opt "HOME" with
         | Some s when s <> "" -> Filename.concat s ".config"
         | _ -> reject "contact store home unavailable") in
  require (not (Filename.is_relative base)) "contact store home unavailable";
  Filename.concat base "c2c/contacts"

let absolute path =
  require (path <> "" && path <> "-") "invalid contact file path";
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
let stat_opt path =
  try Some (Unix.lstat path) with Unix.Unix_error (Unix.ENOENT, _, _) -> None
let same a b = a.Unix.st_dev = b.Unix.st_dev && a.Unix.st_ino = b.Unix.st_ino
let check_regular_with_modes modes st =
  require (st.Unix.st_kind = Unix.S_REG && st.Unix.st_uid = Unix.geteuid () &&
           List.mem st.Unix.st_perm modes && st.Unix.st_nlink = 1)
    "unsafe contact file; owner-only regular file required"
let check_regular = check_regular_with_modes [0o600]
let rec check_parents path =
  let parent = Filename.dirname path in
  if parent <> path then check_parents parent;
  let st = Unix.lstat path in
  require (st.Unix.st_kind = Unix.S_DIR) "unsafe contact directory"
let with_private_fd ?(check = check_regular) path flags f =
  check_parents (Filename.dirname path);
  let before = Unix.lstat path in
  check before;
  let fd = Unix.openfile path (Unix.O_CLOEXEC :: Unix.O_NONBLOCK :: flags) 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    let current = Unix.fstat fd in
    check current;
    require (same before current && same current (Unix.lstat path)) "contact file changed; delivery held";
    let result = f fd in
    let after = Unix.fstat fd in
    check after;
    require (same after (Unix.lstat path)) "contact file changed; delivery held";
    result)
let read_private path =
  let path = absolute path in
  with_private_fd ~check:(check_regular_with_modes [0o400; 0o600]) path [Unix.O_RDONLY] (fun fd ->
    let before = Unix.fstat fd in
    require (before.Unix.st_size <= 65536) "contact artifact too large";
    let buffer = Bytes.create (before.Unix.st_size + 1) in
    let rec read offset =
      if offset = Bytes.length buffer then reject "contact artifact changed";
      let count = Unix.read fd buffer offset (Bytes.length buffer - offset) in
      if count = 0 then offset else read (offset + count) in
    let count = read 0 in
    let after = Unix.fstat fd in
    require (count = before.Unix.st_size && before.Unix.st_size = after.Unix.st_size &&
             before.Unix.st_mtime = after.Unix.st_mtime && before.Unix.st_ctime = after.Unix.st_ctime)
      "contact artifact changed";
    try Yojson.Safe.from_string (Bytes.sub_string buffer 0 count)
    with _ -> reject "invalid contact artifact JSON")
let read_private_json path = protect (fun () -> read_private path)

let rec ensure_directory path =
  match stat_opt path with
  | Some st -> require (st.Unix.st_kind = Unix.S_DIR) "unsafe contact directory"
  | None ->
      let parent = Filename.dirname path in
      require (parent <> path) "unsafe contact directory";
      ensure_directory parent;
      (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      require ((Unix.lstat path).Unix.st_kind = Unix.S_DIR) "unsafe contact directory";
      C2c_io.fsync_path parent
let check_dir path =
  check_parents path;
  let st = Unix.lstat path in
  require (st.Unix.st_uid = Unix.geteuid () && st.Unix.st_perm = 0o700)
    "unsafe contact store directory; mode 0700 required";
  st
let create_private path =
  let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    check_regular (Unix.fstat fd);
    require (same (Unix.fstat fd) (Unix.lstat path)) "contact file changed; delivery held";
    Unix.fsync fd);
  C2c_io.fsync_path (Filename.dirname path)

let sql_ok rc = require (Sqlite3.Rc.is_success rc) "contact store transaction failed; delivery held"
let exec db sql = sql_ok (Sqlite3.exec db sql)
let rows db sql params =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    sql_ok (Sqlite3.bind_values stmt params);
    let rec loop acc = match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> loop (Array.init (Sqlite3.column_count stmt) (Sqlite3.column stmt) :: acc)
      | Sqlite3.Rc.DONE -> List.rev acc
      | _ -> reject "contact store transaction failed; delivery held" in
    loop [])
let write db sql params = ignore (rows db sql params)
let text s = Sqlite3.Data.TEXT s
let int n = Sqlite3.Data.INT (Int64.of_int n)
let string_data = function Sqlite3.Data.TEXT s -> s | _ -> reject "invalid contact store; delivery held"
let integer_data = function
  | Sqlite3.Data.INT n when n <= Int64.of_int max_int && n >= Int64.of_int min_int -> Int64.to_int n
  | _ -> reject "invalid contact store; delivery held"
let one = function [] -> None | [r] -> Some r | _ -> reject "invalid contact store; delivery held"
let schema = {|
CREATE TABLE store_version(version INTEGER NOT NULL CHECK(version=1));
INSERT INTO store_version VALUES(1);
CREATE TABLE grants(
 relay TEXT NOT NULL, route TEXT NOT NULL, grant_id TEXT NOT NULL,
 artifact TEXT NOT NULL, allow_http INTEGER NOT NULL CHECK(allow_http IN (0,1)),
 PRIMARY KEY(relay,route,grant_id), UNIQUE(relay,grant_id));
CREATE TABLE routes(
 relay TEXT NOT NULL, route TEXT NOT NULL, grant_id TEXT,
 disabled INTEGER NOT NULL CHECK(disabled IN (0,1)),
 PRIMARY KEY(relay,route));
CREATE TABLE pins(
 relay TEXT NOT NULL, route TEXT NOT NULL, message_id TEXT NOT NULL,
 sender_pk TEXT NOT NULL, payload_hash TEXT NOT NULL, grant_id TEXT,
 PRIMARY KEY(relay,route,message_id));
CREATE TRIGGER immutable_grants_update BEFORE UPDATE ON grants BEGIN SELECT RAISE(ABORT,'immutable'); END;
CREATE TRIGGER immutable_grants_delete BEFORE DELETE ON grants BEGIN SELECT RAISE(ABORT,'immutable'); END;
CREATE TRIGGER immutable_pins_update BEFORE UPDATE ON pins BEGIN SELECT RAISE(ABORT,'immutable'); END;
CREATE TRIGGER immutable_pins_delete BEFORE DELETE ON pins BEGIN SELECT RAISE(ABORT,'immutable'); END;
|}

(* The sentinel survives deletion of contacts.sqlite. Never recreate an empty
   database in an initialized store: doing so would lose protected tombstones.
   Interrupted initialization intentionally fails closed and needs recovery.
   The lock is an inode-stable owner-only file, not a SQLite database lock. *)
let with_store ?dir f =
  protect (fun () ->
    let dir = absolute (match dir with Some d -> d | None -> default_dir ()) in
    ensure_directory dir;
    let dir_stat = check_dir dir in
    let lock = Filename.concat dir "store.lock" in
    (try create_private lock with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    with_private_fd lock [Unix.O_RDWR] (fun lock_fd ->
      (try Unix.lockf lock_fd Unix.F_TLOCK 0
       with _ -> reject "contact store busy; retry with the same message ID");
      Fun.protect ~finally:(fun () -> Unix.lockf lock_fd Unix.F_ULOCK 0) (fun () ->
        let marker = Filename.concat dir "initialized-v1" in
        let path = Filename.concat dir "contacts.sqlite" in
        let fresh = match stat_opt marker, stat_opt path with
          | None, None -> create_private marker; create_private path; true
          | Some _, Some _ -> false
          | _ -> reject "contact store incomplete; restore authority and retry with the same message ID" in
        with_private_fd marker [Unix.O_RDONLY] (fun _ -> ());
        let check_sidecars () =
          List.iter (fun suffix -> match stat_opt (path ^ suffix) with
            | None -> () | Some st -> check_regular st) ["-journal"; "-wal"; "-shm"] in
        check_sidecars ();
        with_private_fd path [Unix.O_RDWR] (fun _ ->
          let db = Sqlite3.db_open ~mode:`NO_CREATE ~uri:false ~mutex:`FULL path in
          Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () ->
            require (same dir_stat (check_dir dir)) "contact directory changed; delivery held";
            check_sidecars ();
            Sqlite3.busy_timeout db 5000;
            (* DELETE journaling keeps all private material in this directory;
               FULL sync and the marker's directory fsync make pins durable. *)
            (match rows db "PRAGMA journal_mode=DELETE" [] with
             | [r] when String.lowercase_ascii (string_data r.(0)) = "delete" -> ()
             | _ -> reject "contact store journal unavailable; delivery held");
            exec db "PRAGMA synchronous=FULL";
            exec db "PRAGMA foreign_keys=ON";
            if fresh then begin
              exec db "BEGIN IMMEDIATE";
              (try exec db schema; exec db "COMMIT"
               with error -> (try exec db "ROLLBACK" with _ -> ()); raise error);
              C2c_io.fsync_path dir
            end;
            exec db "BEGIN IMMEDIATE";
            try
              (match rows db "SELECT version FROM store_version" [] with
               | [r] when integer_data r.(0) = 1 -> ()
               | _ -> reject "unsupported contact store; delivery held");
              let result = f db in
              require (same dir_stat (check_dir dir)) "contact directory changed; delivery held";
              check_sidecars ();
              exec db "COMMIT";
              C2c_io.fsync_path dir;
              result
            with error ->
              (try exec db "ROLLBACK" with _ -> ());
              raise error)))))

let assoc json = match json with
  | `Assoc fields ->
      let names = List.map fst fields in
      require (List.length names = List.length (List.sort_uniq String.compare names)) "duplicate contact artifact fields";
      fields
  | _ -> reject "invalid contact artifact"
let field fields key = match List.assoc_opt key fields with
  | Some value -> value | None -> reject "incomplete contact artifact"
let str fields key = match field fields key with
  | `String s -> s | _ -> reject "invalid contact artifact field"
let num fields key = match field fields key with
  | `Float n when finite n -> n
  | `Int n -> float_of_int n
  | _ -> reject "invalid contact artifact time"
let number fields key = match field fields key with
  | `Int n -> n | _ -> reject "invalid contact artifact generation"

type grant = {
  relay : string; route : string; delivery : string; sender : string;
  recipient : string; id : string; secret : string; expires : float;
  generation : int;
}
let parse_artifact json =
  let fields = assoc json in
  require (field fields "artifact_version" = `Int 1 &&
           str fields "protocol" = "c2c-contact/1" &&
           str fields "scope" = "dm-first-contact") "unsupported contact artifact";
  let relay = url (str fields "relay_url") in
  let route_value = str fields "recipient_route" in
  let bare = route route_value in
  let delivery = str fields "delivery_alias" in
  require (C2c_name.is_valid delivery && delivery = bare) "contact delivery route mismatch";
  let sender = str fields "sender_pk" and recipient = str fields "recipient_pk" in
  valid_key sender; valid_key recipient;
  let secret = str fields "grant_secret" and id = str fields "grant_id" in
  let raw = decode32 secret in
  ignore (decode32 id);
  require (id = b64 (sha raw)) "contact grant verifier mismatch";
  let expires = num fields "expires_at" and generation = number fields "generation" in
  require (finite expires && generation > 0) "invalid contact expiry or generation";
  {relay; route = route_value; delivery; sender; recipient; id; secret; expires; generation}
let artifact g : Yojson.Safe.t = `Assoc [
  "artifact_version", `Int 1; "protocol", `String "c2c-contact/1";
  "scope", `String "dm-first-contact"; "relay_url", `String g.relay;
  "recipient_route", `String g.route; "delivery_alias", `String g.delivery;
  "sender_pk", `String g.sender; "recipient_pk", `String g.recipient;
  "grant_id", `String g.id; "grant_secret", `String g.secret;
  "expires_at", `Float g.expires; "generation", `Int g.generation]
let lookup_route db relay route =
  one (rows db "SELECT grant_id,disabled FROM routes WHERE relay=? AND route=?" [text relay; text route])
let load_grant db relay route id =
  match one (rows db "SELECT artifact,allow_http FROM grants WHERE relay=? AND route=? AND grant_id=?"
               [text relay; text route; text id]) with
  | None -> reject "selected contact grant missing; delivery held"
  | Some row ->
      let g = parse_artifact (Yojson.Safe.from_string (string_data row.(0))) in
      require (g.relay = relay && g.route = route && g.id = id) "contact grant binding mismatch; delivery held";
      let consent = integer_data row.(1) in
      require (consent = 0 || consent = 1) "invalid contact store; delivery held";
      require (not (String.starts_with ~prefix:"http://" relay) || consent = 1)
        "contact HTTP requires explicit local consent";
      g, consent = 1
let enabled row = require (integer_data row.(1) = 0) "contact route disabled; delivery uncertain; retry held"
let require_unselected db relay route =
  require (rows db "SELECT 1 FROM grants WHERE relay=? AND route=? UNION ALL SELECT 1 FROM pins WHERE relay=? AND route=? AND grant_id IS NOT NULL LIMIT 1"
             [text relay; text route; text relay; text route] = [])
    "selected contact route missing; delivery held"
let current_id row = match row.(0) with
  | Sqlite3.Data.TEXT id -> id
  | _ -> reject "selected contact grant missing; delivery held"

let import_file ?dir ~relay_url ~to_alias ~sender_pk ~allow_http ~path ~now () =
  (* Parse and validate before opening the store, without exposing parse errors. *)
  match protect (fun () ->
    require (finite now) "invalid contact time";
    let relay = url relay_url in
    ignore (route to_alias); valid_key sender_pk;
    let g = parse_artifact (read_private path) in
    require (g.relay = relay && g.route = to_alias) "contact relay or route mismatch";
    require (g.sender = sender_pk) "contact sender mismatch";
    require (g.expires > now) "contact grant expired; delivery held";
    require (allow_http || not (String.starts_with ~prefix:"http://" relay)) "contact HTTP requires explicit local consent";
    g) with
  | Error e -> Error e
  | Ok g -> with_store ?dir (fun db ->
      (match lookup_route db g.relay g.route with
       | None -> require_unselected db g.relay g.route
       | Some row -> (match row.(0) with
           | Sqlite3.Data.NULL -> require (integer_data row.(1) = 1) "invalid contact store; delivery held"
           | _ ->
               let old, _ = load_grant db g.relay g.route (current_id row) in
               require (g.sender = old.sender && g.recipient = old.recipient && g.delivery = old.delivery)
                 "contact identity change refused; use a separately verified route";
               require (g.id = old.id || g.generation > old.generation) "contact generation rollback refused"));
      (match one (rows db "SELECT route FROM grants WHERE relay=? AND grant_id=?" [text g.relay; text g.id]) with
       | Some row ->
           require (string_data row.(0) = g.route) "contact grant route change refused";
           let old, old_http = load_grant db g.relay g.route g.id in
           require (artifact old = artifact g && old_http = allow_http) "immutable contact grant change refused"
       | None ->
           write db "INSERT INTO grants(relay,route,grant_id,artifact,allow_http) VALUES(?,?,?,?,?)"
             [text g.relay; text g.route; text g.id; text (Yojson.Safe.to_string (artifact g)); int (if allow_http then 1 else 0)]);
      write db "INSERT INTO routes(relay,route,grant_id,disabled) VALUES(?,?,?,0) ON CONFLICT(relay,route) DO UPDATE SET grant_id=excluded.grant_id,disabled=0"
        [text g.relay; text g.route; text g.id])

let prepare ?dir ~relay_url ~to_alias ~sender_pk ~from_alias ~content ~message_id ~now () =
  with_store ?dir (fun db ->
    require (finite now) "invalid contact time";
    let relay = url relay_url in
    legacy_route to_alias; legacy_route from_alias;
    if sender_pk <> "" then valid_key sender_pk;
    require (message_id <> "" && String.length message_id <= 1024) "invalid contact message ID";
    let selected = lookup_route db relay to_alias in
    (match selected with
     | None -> require_unselected db relay to_alias
     | Some row ->
      enabled row;
      let g, _ = load_grant db relay to_alias (current_id row) in
      require (g.sender = sender_pk) "contact sender mismatch; delivery held");
    let payload_hash = b64 (sha (Yojson.Safe.to_string (`List [
      `String sender_pk; `String from_alias; `String content]))) in
    let pinned = one (rows db "SELECT sender_pk,payload_hash,grant_id FROM pins WHERE relay=? AND route=? AND message_id=?"
                        [text relay; text to_alias; text message_id]) in
    let grant_id = match pinned with
      | Some row ->
          require (string_data row.(0) = sender_pk && string_data row.(1) = payload_hash)
            "message ID payload conflict; delivery held";
          (match row.(2), selected with
           | Sqlite3.Data.NULL, None -> None
           | Sqlite3.Data.NULL, Some _ -> reject "legacy message ID predates contact protection; delivery held"
           | Sqlite3.Data.TEXT _, None -> reject "selected contact route missing; delivery held"
           | Sqlite3.Data.TEXT id, Some _ -> Some id
           | _ -> reject "invalid contact pin; delivery held")
      | None ->
          let id = Option.map current_id selected in
          write db "INSERT INTO pins(relay,route,message_id,sender_pk,payload_hash,grant_id) VALUES(?,?,?,?,?,?)"
            [text relay; text to_alias; text message_id; text sender_pk; text payload_hash;
             (match id with None -> Sqlite3.Data.NULL | Some s -> text s)];
          id in
    match grant_id with
    | None -> Legacy
    | Some id ->
        let g, allow_http = load_grant db relay to_alias id in
        require (g.sender = sender_pk) "contact sender mismatch; delivery held";
        require (g.expires > now) "original contact grant expired; delivery uncertain; retry held";
        Contact {grant_id = g.id; grant_secret = g.secret; recipient_pk = g.recipient;
                 delivery_alias = g.delivery; allow_http})

let disable ?dir ~relay_url ~to_alias () =
  with_store ?dir (fun db ->
    let relay = url relay_url in
    ignore (route to_alias);
    write db "INSERT INTO routes(relay,route,grant_id,disabled) VALUES(?,?,NULL,1) ON CONFLICT(relay,route) DO UPDATE SET disabled=1"
      [text relay; text to_alias])

let list_metadata ?dir () =
  with_store ?dir (fun db ->
    `List (List.map (fun row ->
      let relay = string_data row.(0) and route_value = string_data row.(1) in
      require (url relay = relay) "invalid contact store; delivery held";
      ignore (route route_value);
      let disabled = integer_data row.(3) in
      require (disabled = 0 || disabled = 1) "invalid contact store; delivery held";
      let base = ["relay_url", `String relay; "recipient_route", `String route_value;
                  "disabled", `Bool (disabled = 1)] in
      match row.(2) with
      | Sqlite3.Data.NULL ->
          require (disabled = 1) "selected contact grant missing; delivery held";
          `Assoc base
      | Sqlite3.Data.TEXT id ->
          let g, allow_http = load_grant db relay route_value id in
          `Assoc (base @ ["grant_id", `String g.id; "delivery_alias", `String g.delivery;
             "sender_pk", `String g.sender; "recipient_pk", `String g.recipient;
             "expires_at", `Float g.expires; "generation", `Int g.generation;
             "allow_http", `Bool allow_http])
      | _ -> reject "invalid contact store; delivery held")
      (rows db "SELECT relay,route,grant_id,disabled FROM routes ORDER BY relay,route" [])))

let export_file ?dir ~relay_url ~to_alias ~path () =
  match with_store ?dir (fun db ->
    let relay = url relay_url in
    ignore (route to_alias);
    match lookup_route db relay to_alias with
    | None -> reject "contact route not selected"
    | Some row ->
        enabled row;
        let g, _ = load_grant db relay to_alias (current_id row) in
        Yojson.Safe.to_string (artifact g) ^ "\n") with
  | Error e -> Error e
  | Ok bytes -> protect (fun () ->
      let path = absolute path in
      check_parents (Filename.dirname path);
      let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC] 0o600 in
      (* Keep a partial output on an I/O failure: never unlink an inode that a
         concurrent same-uid actor may have replaced. It is never stdout. *)
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        check_regular (Unix.fstat fd);
        require (same (Unix.fstat fd) (Unix.lstat path)) "contact export changed";
        let rec write offset = if offset < String.length bytes then begin
          let n = Unix.write_substring fd bytes offset (String.length bytes - offset) in
          require (n > 0) "contact export failed";
          write (offset + n) end in
        write 0;
        Unix.fsync fd;
        require (same (Unix.fstat fd) (Unix.lstat path)) "contact export changed";
        check_regular (Unix.lstat path));
      C2c_io.fsync_path (Filename.dirname path))
