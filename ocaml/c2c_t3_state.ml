(* C2c_t3_state: durable routing state for the T3 connector. See the .mli. *)

type kind = Inbound | Recovery

type tombstone = { tombstoned_at : float; reason : string }

type mapping = {
  thread_id : string;
  alias : string;
  created_at : float;
  tombstone : tombstone option;
}

type entry = {
  seq : int;
  kind : kind;
  key : string;
  at : float;
  payload : Yojson.Safe.t;
}

type acked_entry = {
  kind : kind;
  key : string;
  result : Yojson.Safe.t option;
}

type append_result = Appended of entry | Duplicate

type open_error =
  | Already_running
  | Unsafe of string
  | Corrupt of string
  | Migration_required of string
  | Environment_mismatch of string
  | Io of string

let open_error_to_string = function
  | Already_running -> "T3 state is held by another live process"
  | Unsafe m -> "unsafe T3 state: " ^ m
  | Corrupt m -> "corrupt T3 state: " ^ m
  | Migration_required m -> "T3 state migration required: " ^ m
  | Environment_mismatch m -> "T3 state environment mismatch: " ^ m
  | Io m -> "T3 state I/O error: " ^ m

let default_max_journal = 1024
let default_max_payload_bytes = 64 * 1024
let default_max_tombstones = 4096
let default_max_acked = 4096

type t = {
  dir : string;
  path : string;
  environment_id : string;
  fsync : string -> unit;
  migrate_legacy : bool;
  clock : unit -> float;
  max_journal : int;
  max_payload_bytes : int;
  max_tombstones : int;
  max_acked : int;
  mutable lock : Unix.file_descr option;
  mutable maps : mapping list;  (* oldest first *)
  mutable journal : entry list; (* oldest first *)
  mutable acked : acked_entry list; (* oldest first *)
  mutable dispatch_at : float option;
  mutable next_seq : int;
  mutable needs_migration_write : bool;
}

(* POSIX lockf locks are per-process: a second [lockf] on the same file from
   this process would succeed. Track dirs held in-process so a second open
   reports [Already_running] as a cross-process one would. *)
let held_dirs : (string, unit) Hashtbl.t = Hashtbl.create 4

let dir t = t.dir
let state_path t = t.path
let environment_id t = t.environment_id

let alias_of_thread_id thread_id =
  let hex = Digestif.SHA256.(to_hex (digest_string thread_id)) in
  "t3-" ^ String.sub hex 0 12

let alias_of_environment_thread ~environment_id ~thread_id =
  let frame s = string_of_int (String.length s) ^ ":" ^ s in
  let seed = frame environment_id ^ frame thread_id in
  let hex = Digestif.SHA256.(to_hex (digest_string seed)) in
  (* 128 bits gives a practical collision margin while staying well below
     C2c_name's 64-byte alias limit. *)
  "t3-" ^ String.sub hex 0 32

(* ---- ownership checks ---- *)

let check_private_dir dir =
  match Unix.lstat dir with
  | exception Unix.Unix_error (e, _, _) -> Error (Io (Unix.error_message e))
  | st ->
    if st.Unix.st_kind <> Unix.S_DIR then
      Error (Unsafe (dir ^ " is not a directory (symlinks are refused)"))
    else if st.Unix.st_uid <> Unix.geteuid () then
      Error (Unsafe (dir ^ " is not owned by the current user"))
    else if st.Unix.st_perm land 0o077 <> 0 then
      Error
        (Unsafe
           (Printf.sprintf "%s has mode %04o; expected 0700" dir
              (st.Unix.st_perm land 0o7777)))
    else Ok ()

let check_private_file path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | exception Unix.Unix_error (e, _, _) -> Error (Io (Unix.error_message e))
  | st ->
    if st.Unix.st_kind <> Unix.S_REG then
      Error (Unsafe (path ^ " is not a regular file (symlinks are refused)"))
    else if st.Unix.st_uid <> Unix.geteuid () then
      Error (Unsafe (path ^ " is not owned by the current user"))
    else if st.Unix.st_perm land 0o077 <> 0 then
      Error
        (Unsafe
           (Printf.sprintf "%s has mode %04o; expected 0600" path
              (st.Unix.st_perm land 0o7777)))
    else Ok true

(* ---- JSON ---- *)

let kind_to_string = function Inbound -> "inbound" | Recovery -> "recovery"
let kind_of_string = function
  | "inbound" -> Some Inbound
  | "recovery" -> Some Recovery
  | _ -> None

let mapping_to_json m =
  `Assoc
    ([ ("thread_id", `String m.thread_id);
       ("alias", `String m.alias);
       ("created_at", `Float m.created_at) ]
     @ match m.tombstone with
       | None -> []
       | Some tb ->
         [ ("tombstone",
            `Assoc [ ("at", `Float tb.tombstoned_at); ("reason", `String tb.reason) ]) ])

let entry_to_json e =
  `Assoc
    [ ("seq", `Int e.seq);
      ("kind", `String (kind_to_string e.kind));
      ("key", `String e.key);
      ("at", `Float e.at);
      ("payload", e.payload) ]

let to_json t =
  `Assoc
    [ ("version", `Int 2);
      ("environment_id", `String t.environment_id);
      ("next_seq", `Int t.next_seq);
      ("mappings", `List (List.map mapping_to_json t.maps));
      ("journal", `List (List.map entry_to_json t.journal));
      ("acked",
       `List
         (List.map
            (fun entry ->
              `Assoc
                ([ ("kind", `String (kind_to_string entry.kind));
                   ("key", `String entry.key) ]
                 @ match entry.result with
                   | None -> []
                   | Some result -> [ ("result", result) ]))
            t.acked));
      ("dispatch_at", match t.dispatch_at with None -> `Null | Some at -> `Float at) ]

exception Bad of string
exception Needs_migration of string
exception Environment_mismatch_exn of string

let bad fmt = Printf.ksprintf (fun s -> raise (Bad s)) fmt

let member k = function
  | `Assoc l -> (try List.assoc k l with Not_found -> `Null)
  | _ -> `Null

let to_str what = function `String s -> s | _ -> bad "%s: expected string" what
let to_num what = function
  | `Float f -> f
  | `Int i -> float_of_int i
  | _ -> bad "%s: expected number" what
let to_int what = function `Int i -> i | _ -> bad "%s: expected int" what
let to_list what = function `List l -> l | `Null -> [] | _ -> bad "%s: expected list" what

let mapping_of_json j =
  let tombstone =
    match member "tombstone" j with
    | `Null -> None
    | tb ->
      Some
        { tombstoned_at = to_num "tombstone.at" (member "at" tb);
          reason = to_str "tombstone.reason" (member "reason" tb) }
  in
  { thread_id = to_str "thread_id" (member "thread_id" j);
    alias = to_str "alias" (member "alias" j);
    created_at = to_num "created_at" (member "created_at" j);
    tombstone }

let kind_of_json j =
  let s = to_str "kind" j in
  match kind_of_string s with Some k -> k | None -> bad "unknown kind %S" s

let entry_of_json j =
  { seq = to_int "seq" (member "seq" j);
    kind = kind_of_json (member "kind" j);
    key = to_str "key" (member "key" j);
    at = to_num "at" (member "at" j);
    payload = member "payload" j }

let load_into t =
  match C2c_io.read_file t.path with
  | exception e -> Error (Io (Printexc.to_string e))
  | s -> (
    match Yojson.Safe.from_string s with
    | exception e -> Error (Corrupt (Printexc.to_string e))
    | j -> (
      try
        (match member "version" j with
         | `Int 2 ->
             let persisted = to_str "environment_id" (member "environment_id" j) in
             if persisted <> t.environment_id then
               raise
                 (Environment_mismatch_exn
                    (Printf.sprintf "state belongs to %S, requested %S" persisted
                       t.environment_id))
         | `Int 1 when t.migrate_legacy -> t.needs_migration_write <- true
         | `Int 1 ->
             raise
               (Needs_migration
                  "state.json predates environment binding; run the explicit migration path"
               )
         | _ -> bad "unsupported or missing version");
        t.maps <- List.map mapping_of_json (to_list "mappings" (member "mappings" j));
        t.journal <- List.map entry_of_json (to_list "journal" (member "journal" j));
        t.acked <-
          List.map
            (fun a ->
              { kind = kind_of_json (member "kind" a);
                key = to_str "key" (member "key" a);
                result = (match member "result" a with `Null -> None | value -> Some value) })
            (to_list "acked" (member "acked" j));
        t.dispatch_at <-
          (match member "dispatch_at" j with
           | `Null -> None
           | (`Int _ | `Float _) as value -> Some (to_num "dispatch_at" value)
           | _ -> bad "dispatch_at: expected number or null");
        let max_seq = List.fold_left (fun m e -> max m e.seq) 0 t.journal in
        t.next_seq <- max (to_int "next_seq" (member "next_seq" j)) (max_seq + 1);
        Ok ()
      with
      | Bad m -> Error (Corrupt m)
      | Needs_migration m -> Error (Migration_required m)
      | Environment_mismatch_exn m -> Error (Environment_mismatch m)))

(* ---- persistence ---- *)

let rec drop n l = if n <= 0 then l else match l with [] -> [] | _ :: r -> drop (n - 1) r

(* [durable_write] writes and fsyncs the temporary file before rename, then
   fsyncs the containing directory. This is deliberately local to T3 state:
   a journal append or ACK must never be reported successful until both the
   bytes and the directory entry have reached the filesystem's durability
   boundary. The [fsync] callback is injectable so failure paths are tested
   without depending on a particular filesystem or power-loss behavior. *)
let durable_write t content =
  let tmp = t.path ^ ".tmp" in
  let cleanup () = try Unix.unlink tmp with _ -> () in
  match
    open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o600 tmp
  with
  | exception e -> Error (Printexc.to_string e)
  | oc ->
      (try
         output_string oc content;
         flush oc;
         t.fsync tmp;
         close_out oc;
         Unix.chmod tmp 0o600;
         Unix.rename tmp t.path;
         t.fsync t.dir;
         Ok ()
       with e ->
         (try close_out_noerr oc with _ -> ());
         cleanup ();
         Error (Printexc.to_string e))

(* Apply [f] to a copy of the state's mutable fields, persist, and only then
   commit. A failed write leaves [t] untouched. *)
let transact t f =
  let saved = (t.maps, t.journal, t.acked, t.dispatch_at, t.next_seq) in
  match f () with
  | Error _ as e ->
    let m, j, a, d, n = saved in
    t.maps <- m; t.journal <- j; t.acked <- a; t.dispatch_at <- d; t.next_seq <- n;
    e
  | Ok v -> (
    match durable_write t (Yojson.Safe.to_string (to_json t) ^ "\n") with
    | Ok () -> Ok v
    | Error msg ->
      let m, j, a, d, n = saved in
      t.maps <- m; t.journal <- j; t.acked <- a; t.dispatch_at <- d; t.next_seq <- n;
      Error ("T3 state write failed: " ^ msg))

(* ---- open / close ---- *)

let close t =
  match t.lock with
  | None -> ()
  | Some fd ->
    t.lock <- None;
    Hashtbl.remove held_dirs t.dir;
    C2c_singleton_lock.release fd

let open_state ?(clock = Unix.gettimeofday) ?(max_journal = default_max_journal)
    ?(max_payload_bytes = default_max_payload_bytes)
    ?(max_tombstones = default_max_tombstones) ?(max_acked = default_max_acked)
    ?(fsync = fun path ->
      let fd = Unix.openfile path [Unix.O_RDONLY] 0 in
      Fun.protect ~finally:(fun () -> try Unix.close fd with _ -> ()) (fun () ->
        Unix.fsync fd))
    ?(migrate_legacy = false) ~environment_id ~dir () =
  let ( let* ) = Result.bind in
  let dir = if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir else dir in
  let* () =
    match Unix.lstat dir with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> (
      try C2c_io.mkdir_p ~mode:0o700 dir; Ok ()
      with e -> Error (Io (Printexc.to_string e)))
    | _ -> Ok ()
  in
  let* () = check_private_dir dir in
  if Hashtbl.mem held_dirs dir then Error Already_running
  else
    let lock_base = Filename.concat dir "t3-state" in
    let* lock_fd =
      match C2c_singleton_lock.try_acquire ~path:lock_base with
      | exception Unix.Unix_error (e, _, _) -> Error (Io (Unix.error_message e))
      | C2c_singleton_lock.Already_running -> Error Already_running
      | C2c_singleton_lock.Acquired fd -> Ok fd
    in
    let fail e = C2c_singleton_lock.release lock_fd; Error e in
    (* The lock file is created 0644 by C2c_singleton_lock; tighten it now
       that we own it, after checking it really is ours. *)
    match Unix.fstat lock_fd with
    | exception Unix.Unix_error (e, _, _) -> fail (Io (Unix.error_message e))
    | st when st.Unix.st_uid <> Unix.geteuid () ->
      fail (Unsafe (C2c_singleton_lock.lockfile_path ~path:lock_base ^ " is not owned by the current user"))
    | _ -> (
      (try Unix.fchmod lock_fd 0o600 with _ -> ());
      if String.trim environment_id = "" then
        fail (Unsafe "environment_id must be non-empty")
      else
      let t =
        { dir; path = Filename.concat dir "state.json"; environment_id; fsync;
          migrate_legacy; clock; max_journal;
          max_payload_bytes; max_tombstones; max_acked; lock = Some lock_fd;
          maps = []; journal = []; acked = []; dispatch_at = None; next_seq = 1;
          needs_migration_write = false }
      in
      match check_private_file t.path with
      | Error e -> fail e
      | Ok false ->
          (match durable_write t (Yojson.Safe.to_string (to_json t) ^ "\n") with
           | Error msg -> fail (Io ("T3 state initialization write failed: " ^ msg))
           | Ok () -> Hashtbl.replace held_dirs dir (); Ok t)
      | Ok true -> (
        match load_into t with
        | Error e -> fail e
        | Ok () ->
            if t.needs_migration_write then
              match durable_write t (Yojson.Safe.to_string (to_json t) ^ "\n") with
              | Error msg -> fail (Io ("T3 state migration write failed: " ^ msg))
              | Ok () ->
                  t.needs_migration_write <- false;
                  Hashtbl.replace held_dirs dir ();
                  Ok t
            else (Hashtbl.replace held_dirs dir (); Ok t)))

(* ---- mapping ---- *)

let find_by_thread t ~thread_id = List.find_opt (fun m -> m.thread_id = thread_id) t.maps
let find_by_alias t ~alias = List.find_opt (fun m -> m.alias = alias) t.maps
let mappings t = t.maps

let ensure_mapping_with_alias t ~thread_id ~alias =
  if thread_id = "" then Error "empty T3 thread id"
  else if alias = "" then Error "empty T3 alias"
  else
    match find_by_thread t ~thread_id with
    | Some { tombstone = Some tb; _ } ->
      Error (Printf.sprintf "T3 thread %s is tombstoned (%s)" thread_id tb.reason)
    | Some m ->
      if m.alias <> alias then
        Error
          (Printf.sprintf "T3 thread %s already owns alias %s (requested %s)"
             thread_id m.alias alias)
      else Ok m
    | None ->
      (match find_by_alias t ~alias with
       | Some other ->
         Error
           (Printf.sprintf "alias %s for thread %s collides with thread %s" alias
              thread_id other.thread_id)
       | None ->
         transact t (fun () ->
           let m = { thread_id; alias; created_at = t.clock (); tombstone = None } in
           t.maps <- t.maps @ [ m ];
           Ok m))

let ensure_mapping t ~thread_id =
  ensure_mapping_with_alias t ~thread_id ~alias:(alias_of_thread_id thread_id)

let revive_mapping t ~thread_id =
  match find_by_thread t ~thread_id with
  | None -> Error ("unknown T3 thread " ^ thread_id)
  | Some m -> (
      match m.tombstone with
      | None -> Ok m
      | Some _ ->
          transact t (fun () ->
            let updated = { m with tombstone = None } in
            t.maps <-
              List.map
                (fun existing ->
                  if existing.thread_id = thread_id then updated else existing)
                t.maps;
            Ok updated))

let tombstone t ~thread_id ~reason =
  match find_by_thread t ~thread_id with
  | None -> Error ("unknown T3 thread " ^ thread_id)
  | Some { tombstone = Some _; _ } -> Ok ()
  | Some _ ->
    transact t (fun () ->
      t.maps <-
        List.map
          (fun m ->
            if m.thread_id = thread_id then
              { m with tombstone = Some { tombstoned_at = t.clock (); reason } }
            else m)
          t.maps;
      (* Bound tombstones: evict the oldest-tombstoned beyond the cap. *)
      let dead = List.filter (fun m -> m.tombstone <> None) t.maps in
      let excess = List.length dead - t.max_tombstones in
      if excess > 0 then begin
        let by_age =
          List.sort
            (fun a b ->
              compare
                (Option.map (fun x -> x.tombstoned_at) a.tombstone)
                (Option.map (fun x -> x.tombstoned_at) b.tombstone))
            dead
        in
        let evict = List.filteri (fun i _ -> i < excess) by_age in
        t.maps <- List.filter (fun m -> not (List.memq m evict)) t.maps
      end;
      Ok ())

(* ---- journal ---- *)

let journal_pending ?kind t =
  match kind with
  | None -> t.journal
  | Some k -> List.filter (fun (e : entry) -> e.kind = k) t.journal

let journal_acked ?kind t =
  match kind with
  | None -> t.acked
  | Some k -> List.filter (fun (e : acked_entry) -> e.kind = k) t.acked

let journal_append t ~kind ~key ~payload =
  if key = "" then Error "empty journal key"
  else if
    List.exists (fun (e : entry) -> e.kind = kind && e.key = key) t.journal
    || List.exists (fun (e : acked_entry) -> e.kind = kind && e.key = key) t.acked
  then Ok Duplicate
  else if String.length (Yojson.Safe.to_string payload) > t.max_payload_bytes then
    Error
      (Printf.sprintf "journal payload exceeds %d bytes" t.max_payload_bytes)
  else if List.length t.journal >= t.max_journal then
    Error
      (Printf.sprintf "T3 journal full (%d pending); refusing to drop unacknowledged entries"
         t.max_journal)
  else
    transact t (fun () ->
      let e = { seq = t.next_seq; kind; key; at = t.clock (); payload } in
      t.next_seq <- t.next_seq + 1;
      t.journal <- t.journal @ [ e ];
      Ok (Appended e))

let journal_ack_result t ~seq ~result =
  match List.find_opt (fun e -> e.seq = seq) t.journal with
  | None -> Ok false
  | Some e ->
    transact t (fun () ->
      t.journal <- List.filter (fun x -> x.seq <> seq) t.journal;
      let acked = t.acked @ [ { kind = e.kind; key = e.key; result } ] in
      t.acked <- drop (List.length acked - t.max_acked) acked;
      Ok true)

let journal_ack t ~seq = journal_ack_result t ~seq ~result:None

let journal_ack_with_result t ~seq ~result =
  journal_ack_result t ~seq ~result:(Some result)

let journal_update t ~seq ~payload =
  if String.length (Yojson.Safe.to_string payload) > t.max_payload_bytes then
    Error
      (Printf.sprintf "journal payload exceeds %d bytes" t.max_payload_bytes)
  else
    match List.find_opt (fun e -> e.seq = seq) t.journal with
    | None -> Ok false
    | Some _ ->
        transact t (fun () ->
          t.journal <-
            List.map
              (fun e -> if e.seq = seq then { e with payload } else e)
              t.journal;
          Ok true)

let last_dispatch_at t = t.dispatch_at

let record_dispatch_at t at =
  transact t (fun () ->
    t.dispatch_at <- Some at;
    Ok ())
