(* c2c_monitor_cmd — inotify-based inbox watcher subcommand.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open C2c_mcp
open C2c_cli_helpers

let ( // ) = Filename.concat

(* --- helper functions ---------------------------------------------------- *)

(* Read an inbox JSON file, returning the parsed message list. *)
let read_inbox_file path =
  try
    let ic = open_in path in
    let content = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let buf = Buffer.create 512 in
      (try while true do Buffer.add_channel buf ic 1 done with End_of_file -> ());
      Buffer.contents buf)
    in
    (match Yojson.Safe.from_string content with
     | `List msgs -> msgs
     | _ -> [])
  with _ -> []

(* Convert a broker [message] record to the same JSON shape the monitor's
   emit path consumes (used on the --drain inbox path, which returns records
   rather than raw JSON). Only the fields emit/dedup read are included. *)
let message_record_to_json (m : message) : Yojson.Safe.t =
  let base =
    [ ("from_alias", `String m.from_alias)
    ; ("to_alias", `String m.to_alias)
    ; ("content", `String m.content)
    ; ("ts", `Float m.ts)
    ]
  in
  match m.message_id with
  | Some mid -> `Assoc (base @ [("message_id", `String mid)])
  | None -> `Assoc base

(* Extract a string field from a JSON assoc or return a default. *)
let jstr fields key def =
  match List.assoc_opt key fields with Some (`String s) -> s | _ -> def

(* Current time as [HH:MM:SS] *)
let now_hms () =
  let t = Unix.localtime (Unix.gettimeofday ()) in
  Printf.sprintf "[%02d:%02d:%02d]" t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

(* Determine if a to_alias value is a room fanout (contains '#') *)
let parse_to_alias s =
  match String.split_on_char '#' s with
  | [_alias; room] -> `Room room
  | _ -> `Direct s

(* Short-window dedup for room fanouts. One room message lands in N peer
   archives; each archive append emits. Keyed on (from_alias, to_alias,
   content) — if we saw the exact same triple within the last 30s, skip.
   Max 1024 entries, oldest evicted on overflow. *)
let dedup_seen : (string * string * string, float) Hashtbl.t = Hashtbl.create 64
let dedup_window_s = 30.0

let dedup_check ~from ~to_raw ~content =
  let key = (from, to_raw, content) in
  let now = Unix.gettimeofday () in
  (* Opportunistic GC when table gets large *)
  if Hashtbl.length dedup_seen > 1024 then begin
    let stale = Hashtbl.fold (fun k ts acc ->
      if now -. ts > dedup_window_s then k :: acc else acc) dedup_seen [] in
    List.iter (Hashtbl.remove dedup_seen) stale
  end;
  match Hashtbl.find_opt dedup_seen key with
  | Some ts when now -. ts < dedup_window_s -> false
  | _ -> Hashtbl.replace dedup_seen key now; true

(* Emit notification lines per unique sender. In full-body mode (the
   default) every message in a burst is emitted whole — one line per
   message, untruncated (claude-full-delivery: the Monitor is a first-class
   full-delivery surface, so bodies must arrive complete). In --snippet
   mode bursts collapse to a count + preview (legacy). [source] tags the
   message origin ("local" or "relay") so a relay-surfaced cross-host DM is
   distinguishable from a local-broker one (B089). *)
let emit_messages ~my_alias ~all ~full_body ~source msgs =
  (* Group messages by from_alias *)
  let by_sender = Hashtbl.create 4 in
  List.iter (fun msg ->
    match msg with
    | `Assoc fields ->
        let from = jstr fields "from_alias" "?" in
        let existing = try Hashtbl.find by_sender from with Not_found -> [] in
        Hashtbl.replace by_sender from (existing @ [fields])
    | _ -> ()
  ) msgs;
  Hashtbl.iter (fun from sender_msgs ->
    (* Room-fanout dedup, per message (was per-burst on the first message
       only). Normalize room fanouts: each peer's archive tags to_alias
       with their own alias prefix (coder1#swarm-lounge vs
       planner1#swarm-lounge) so dedup sees them as distinct. Strip alias,
       keep just #<room>. *)
    let kept =
      List.filter (fun fields ->
        let to_raw = jstr fields "to_alias" "" in
        let body = jstr fields "content" "" in
        let dedup_to = match parse_to_alias to_raw with
          | `Room room -> "#" ^ room
          | `Direct d -> d
        in
        dedup_check ~from ~to_raw:dedup_to ~content:body)
        sender_msgs
    in
    match kept with
    | [] -> ()
    | first :: _ ->
        let to_raw = jstr first "to_alias" "" in
        let is_mine = match my_alias with
          | None -> true
          | Some me -> to_raw = me || String.length to_raw > String.length me + 1
                       && String.sub to_raw 0 (String.length me) = me
        in
        if all || is_mine then begin
          let icon = if is_mine then "📬" else "💬" in
          let dest = match parse_to_alias to_raw with
            | `Room room -> "@" ^ room
            | `Direct d -> if is_mine then "you" else d
          in
          (* B089: relay-sourced messages get a 🌐 origin marker so the
             operator can tell a cross-host DM (peeked from the relay inbox)
             from a local broker delivery. *)
          let origin = if source = "relay" then "🌐" else "" in
          let bodies = List.map (fun fields -> jstr fields "content" "") kept in
          List.iter
            (fun subject ->
              Printf.printf "%s %s%s  %s→%s  %s\n%!"
                (now_hms ()) origin icon from dest subject)
            (C2c_monitor_logic.burst_subjects ~full_body bodies)
        end
  ) by_sender

(* --- Cmdliner args -------------------------------------------------------- *)

(* --- monitor Cmdliner term ----------------------------------------------- *)

let monitor_cmd =
  let open Cmdliner in
  let open Cmdliner.Term in
  let broker_root_opt =
    Arg.(value & opt (some string) None & info ["broker-root";"root"] ~docv:"DIR"
           ~doc:"Broker root dir (default: auto-resolve via env/git).")
  in
  let alias_opt =
    Arg.(value & opt (some string) None & info ["alias";"a"] ~docv:"ALIAS"
           ~doc:"My alias. Only messages addressed to this alias are shown by \
                 default. When omitted the alias is resolved automatically: \
                 C2C_MCP_AUTO_REGISTER_ALIAS, then THIS session's own broker \
                 registration (session-id lookup — authoritative), then the \
                 machine-global $(b,~/.config/c2c/default-alias) file, then \
                 C2C_MCP_SESSION_ID, then a single alive registration.")
  in
  let drain_flag =
    Arg.(value & flag & info ["drain"]
           ~doc:"When watching the live inbox, DRAIN it (archive-append \
                 preserved) instead of peeking. Use when this monitor is the \
                 session's only inbox consumer. Default is non-draining (peek), \
                 so a separate hook/poll consumer still receives the messages.")
  in
  let all_flag =
    Arg.(value & flag & info ["all"]
           ~doc:"Also show messages addressed to other peers (situational awareness).")
  in
  let drains_flag =
    Arg.(value & flag & info ["drains"]
           ~doc:"Show drain events (when a peer polls their inbox to empty).")
  in
  let sweeps_flag =
    Arg.(value & flag & info ["sweeps"]
           ~doc:"Show sweep/delete events.")
  in
  let full_body_flag =
    Arg.(value & flag & info ["full-body";"body"]
           ~doc:"Emit full message content. This is now the default; use $(b,--snippet) for the old 80-char preview.")
  in
  let snippet_flag =
    Arg.(value & flag & info ["snippet"]
           ~doc:"Emit an 80-char subject snippet instead of the full body (legacy default).")
  in
  let from_opt =
    Arg.(value & opt (some string) None & info ["from"] ~docv:"ALIAS"
           ~doc:"Only show messages from this sender alias.")
  in
  let json_flag =
    Arg.(value & flag & info ["json"]
           ~doc:"Emit JSON objects instead of human-readable lines.")
  in
  let archive_flag =
    Arg.(value & flag & info ["archive"]
           ~doc:"Watch append-only archive (archive/*.jsonl). This is now the default; use $(b,--live) for the old inbox-watching mode.")
  in
  let live_flag =
    Arg.(value & flag & info ["live"]
           ~doc:"Watch live inboxes (*.inbox.json) instead of the archive. \
                 Subject to the race where the drain hook clears the inbox \
                 before the monitor reads it. Legacy behaviour.")
  in
  let include_self_flag =
    Arg.(value & flag & info ["include-self"]
           ~doc:"Include messages sent by you. Off by default — your own broadcasts \
                 and DMs echo back through archive/inbox events and are noise.")
  in
  let force_flag =
    Arg.(value & flag & info ["force"]
           ~doc:"Override the per-alias monitor lockfile guard (#354). By default \
                 a second $(b,c2c monitor --alias ALIAS) refuses to start if a live \
                 monitor for the same alias is already running, to prevent fork-bomb \
                 accumulation. Stale locks (holder pid dead) are taken over \
                 automatically; $(b,--force) is only needed to displace a \
                 still-alive holder.")
  in
  let cross_repo = cross_repo_flag in
  (* B089: relay-inbox watcher source flags. *)
  let no_relay =
    Arg.(value & flag & info ["no-relay"]
           ~doc:"Disable the relay-inbox watcher source. By default the monitor \
                 also peeks (NON-draining) the relay inbox for the resolved alias \
                 when a relay URL is configured, so cross-host DMs surface like \
                 local ones. Use this flag to watch the local broker only.")
  in
  let relay_interval =
    Arg.(value & opt float 5.0 & info ["relay-interval"] ~docv:"SECONDS"
           ~doc:"Interval between non-draining relay inbox peeks (default 5.0). \
                 Set to 0 to disable the relay watcher (same as --no-relay). The \
                 relay is peeked, never polled, so a separate relay consumer \
                 (connector / `relay dm poll`) still receives every message.")
  in
  let relay_node_id =
    Arg.(value & opt (some string) None & info ["relay-node-id"] ~docv:"ID"
           ~doc:"Relay node-id whose inbox to peek. Default is resolved \
                 automatically: the connector-managed node-id when a relay \
                 connector manages this alias (read from connector-state.json), \
                 else cli-<alias> matching `c2c relay register --alias <alias>`. \
                 Override here (or set C2C_RELAY_NODE_ID) only to force a \
                 different key.")
  in
  let relay_session_id =
    Arg.(value & opt (some string) None & info ["relay-session-id"] ~docv:"ID"
           ~doc:"Relay session-id whose inbox to peek (default: same as \
                 --relay-node-id). Override or set C2C_RELAY_SESSION_ID.")
  in
  const (fun broker_root_arg alias_arg all drains sweeps full_body snippet from_filter json archive live include_self force drain cross_repo no_relay relay_interval relay_node_id relay_session_id ->
    (* Resolve effective flags: --archive and --full-body are now defaults.
       --live reverts to inbox watching; --snippet reverts to 80-char preview. *)
    let full_body = full_body || not snippet in  (* full_body unless --snippet *)
    let archive = archive || not live in  (* archive unless --live *)
    let broker_root =
      (* #518: treat empty-string env/arg as "unset" — same shape as #496/#497.
         C2C_MCP_BROKER_ROOT='' should fall through to resolve_broker_root ()
         rather than being used as a bogus empty-string path. *)
      let resolved value_opt =
        match value_opt with
        | Some s when String.trim s <> "" -> Some (String.trim s)
        | _ -> None
      in
      match resolved broker_root_arg with
      | Some r -> r
      | None ->
          if cross_repo then C2c_repo_fp.resolve_sessions_broker_root ()
          else (match C2c_utils.trimmed_env_value "C2C_MCP_BROKER_ROOT" with
                | Some r -> r
                | None -> (try C2c_utils.resolve_broker_root () with _ ->
                    Printf.eprintf "c2c monitor: cannot resolve broker root \
                      (set C2C_MCP_BROKER_ROOT or run from inside the repo)\n%!";
                    exit 1))
    in
    (* Resolve the caller's session id via the standard chain
       (C2C_MCP_SESSION_ID → client-native keys e.g. CLAUDE_CODE_SESSION_ID →
       broker-root default-session statefile — see env_session_id). Used for
       both authoritative alias resolution (B069) and locating this session's
       live inbox file for inbox-watching (B070). *)
    let resolved_sid = try env_session_id () with _ -> None in
    (* One broker handle, reused for registration lookups. *)
    let lookup_regs () =
      try Broker.list_registrations (Broker.create ~root:broker_root)
      with _ -> []
    in
    (* This session's OWN registration alias — authoritative and immune to
       another agent's `c2c init` clobbering the shared default-alias file. *)
    let session_reg =
      match resolved_sid with
      | None -> None
      | Some sid ->
          (match List.find_opt
                   (fun (r : registration) -> r.session_id = sid)
                   (lookup_regs ()) with
           | Some r -> Some (r.alias, sid)
           | None -> None)
    in
    let default_alias_file =
      let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
      let path = home // ".config" // "c2c" // "default-alias" in
      let s = String.trim (C2c_io.read_file_opt path) in
      if s <> "" then Some s else None
    in
    let single_alive =
      match List.filter
              (fun (r : registration) ->
                Broker.registration_liveness_state r = Broker.Alive)
              (lookup_regs ()) with
      | [r] -> Some r.alias
      | _ -> None
    in
    (* B069: session registration outranks the machine-global default-alias
       file. Order + labels live in the pure, unit-tested C2c_monitor_logic. *)
    let my_alias0, alias_source0 =
      C2c_monitor_logic.resolve_alias
        ~flag:alias_arg
        ~auto_env:(C2c_utils.alias_from_env_only ())
        ~session_reg
        ~default_alias_file
        ~session_id_env:(Sys.getenv_opt "C2C_MCP_SESSION_ID")
        ~single_alive
        ()
    in
    (* B180: identity is mutable after startup so a rename can rebind without
       killing the process. --alias freezes identity (flag_bound). *)
    let my_alias_r = ref my_alias0 in
    let alias_source_r = ref alias_source0 in
    let flag_bound = match alias_arg with Some _ -> true | None -> false in
    (* Session whose live inbox we watch (B070). Prefer the resolved session id;
       otherwise map the resolved alias back to its registration's session id so
       inbox-watching still works when the alias came from a fallback source. *)
    let inbox_sid =
      match resolved_sid with
      | Some _ as s -> s
      | None ->
          (match !my_alias_r with
           | None -> None
           | Some a ->
               (match List.find_opt
                        (fun (r : registration) ->
                          Broker.alias_casefold r.alias = Broker.alias_casefold a)
                        (lookup_regs ()) with
                | Some r -> Some r.session_id
                | None -> None))
    in
    (* #354: per-alias monitor lockfile guard.
       Prevents fork-bomb accumulation when `c2c monitor --alias <a>` is launched
       in a loop (e.g. by a buggy supervisor). Lockfile location matches the
       `doctor monitor-leak` scanner: <broker_root>/.monitor-locks/<alias>.lock.
       Behaviour:
         - Try non-blocking POSIX advisory lock (Unix.lockf F_TLOCK).
         - If acquired: write our PID, install at_exit cleanup, proceed.
         - If conflict: read holder PID. If /proc/<pid> is gone (stale), take over
           by truncating + rewriting the lockfile and retrying. If holder is alive,
           refuse with a clear error unless --force is set; with --force we kill
           the holder (SIGTERM) and take over.
       Skip the guard when no alias is set (e.g. unscoped `c2c monitor --all`).
       B180: lock state is held in refs so a rename can migrate the lock to the
       new alias without restarting. *)
    let lock_dir = Filename.concat broker_root ".monitor-locks" in
    let pid_alive p =
      try Sys.is_directory (Printf.sprintf "/proc/%d" p)
      with _ -> false
    in
    let read_holder_pid fd =
      try
        ignore (Unix.lseek fd 0 Unix.SEEK_SET);
        let buf = Bytes.create 32 in
        let n = Unix.read fd buf 0 32 in
        if n <= 0 then None
        else int_of_string_opt (String.trim (Bytes.sub_string buf 0 n))
      with _ -> None
    in
    let write_pid fd =
      (try Unix.ftruncate fd 0 with _ -> ());
      ignore (Unix.lseek fd 0 Unix.SEEK_SET);
      let s = string_of_int (Unix.getpid ()) ^ "\n" in
      ignore (Unix.write_substring fd s 0 (String.length s))
    in
    let release_lock_pair fd path =
      (try Unix.ftruncate fd 0 with _ -> ());
      (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
      (try Unix.close fd with _ -> ());
      (try Unix.unlink path with _ -> ())
    in
    (* Current lock held by this process (if any). Migrated on B180 rebind. *)
    let monitor_lock_r : (Unix.file_descr * string) option ref = ref None in
    let acquire_monitor_lock ~alias ~force_displace : (Unix.file_descr * string) option =
      (try Unix.mkdir lock_dir 0o700
       with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
          | _ -> ());
      let lock_path = Filename.concat lock_dir (alias ^ ".lock") in
      let rec acquire ~retry =
        let fd =
          Unix.openfile lock_path [Unix.O_RDWR; Unix.O_CREAT] 0o644
        in
        match Unix.lockf fd Unix.F_TLOCK 0 with
        | () ->
            write_pid fd;
            Some (fd, lock_path)
        | exception Unix.Unix_error
            ((Unix.EAGAIN | Unix.EACCES | Unix.EWOULDBLOCK), _, _) ->
            let holder = read_holder_pid fd in
            Unix.close fd;
            (match holder with
             | Some p when pid_alive p && not force_displace ->
                 None
             | Some p when pid_alive p (* && force_displace *) ->
                 (try Unix.kill p Sys.sigterm with _ -> ());
                 let deadline = Unix.gettimeofday () +. 2.0 in
                 while pid_alive p && Unix.gettimeofday () < deadline do
                   Unix.sleepf 0.05
                 done;
                 if retry > 0 then acquire ~retry:(retry - 1) else None
             | _ ->
                 if retry > 0 then acquire ~retry:(retry - 1) else None)
        | exception _ ->
            (try Unix.close fd with _ -> ());
            None
      in
      acquire ~retry:3
    in
    let _monitor_lock_fd : Unix.file_descr option =
      match !my_alias_r with
      | None -> None
      | Some alias ->
          (match acquire_monitor_lock ~alias ~force_displace:force with
           | Some (fd, lock_path) ->
               monitor_lock_r := Some (fd, lock_path);
               at_exit (fun () ->
                 match !monitor_lock_r with
                 | Some (f, p) -> release_lock_pair f p; monitor_lock_r := None
                 | None -> ());
               Some fd
           | None ->
               (* Mirror the original hard-fail startup messages. *)
               let lock_path = Filename.concat lock_dir (alias ^ ".lock") in
               let holder =
                 try
                   let fd = Unix.openfile lock_path [Unix.O_RDONLY] 0o644 in
                   Fun.protect ~finally:(fun () -> Unix.close fd)
                     (fun () -> read_holder_pid fd)
                 with _ -> None
               in
               (match holder with
                | Some p when pid_alive p && not force ->
                    Printf.eprintf
                      "c2c monitor: alias '%s' already has a live monitor \
                       (pid %d). Refusing to start (#354 fork-bomb guard).\n\
                       \  Stop it first:  kill %d\n\
                       \  Or override:    c2c monitor --alias %s --force\n%!"
                      alias p p alias;
                    exit 1
                | Some p when pid_alive p ->
                    Printf.eprintf
                      "c2c monitor: failed to displace holder pid %d after \
                       --force; giving up.\n%!" p;
                    exit 1
                | _ ->
                    Printf.eprintf
                      "c2c monitor: stale lock for alias '%s'; takeover \
                       retries exhausted.\n%!" alias;
                    exit 1))
    in
    let registry_path = Filename.concat broker_root "registry.json" in
    (* Read aliases from registry.json — returns (alias, session_id) pairs. *)
    let read_registry_aliases () =
      try
        let ic = open_in registry_path in
        let content = really_input_string ic (in_channel_length ic) in
        close_in ic;
        match Yojson.Safe.from_string content with
        | `Assoc fields ->
            (match List.assoc_opt "registrations" fields with
             | Some (`List regs) ->
                 List.filter_map (fun r -> match r with
                   | `Assoc rfields ->
                       (match List.assoc_opt "alias" rfields,
                              List.assoc_opt "session_id" rfields with
                        | Some (`String a), Some (`String s) -> Some (a, s)
                        | _ -> None)
                   | _ -> None) regs
             | _ -> [])
        | _ -> []
      with _ -> []
    in
    (* Snapshot: alias → session_id. Used to diff registry changes. *)
    let known_peers : (string, string) Hashtbl.t = Hashtbl.create 16 in
    List.iter (fun (a, s) -> Hashtbl.replace known_peers a s) (read_registry_aliases ());
    (* Snapshot: room_id → alias set. Used to diff room membership changes. *)
    let known_room_members : (string, (string, unit) Hashtbl.t) Hashtbl.t =
      Hashtbl.create 4
    in
    let read_room_members room_id =
      let path = broker_root // "rooms" // room_id // "members.json" in
      try
        let ic = open_in path in
        let content = really_input_string ic (in_channel_length ic) in
        close_in ic;
        (match Yojson.Safe.from_string content with
         | `List members ->
             List.filter_map (fun m -> match m with
               | `Assoc fields -> (match List.assoc_opt "alias" fields with
                   | Some (`String a) -> Some a | _ -> None)
               | _ -> None) members
         | _ -> [])
      with _ -> []
    in
    (* #433: snapshot per-room invited_members for room.invite emission.
       Reads the [invited_members] field from rooms/<room>/meta.json. *)
    let known_room_invited : (string, (string, unit) Hashtbl.t) Hashtbl.t =
      Hashtbl.create 4
    in
    let read_room_invited room_id =
      let path = broker_root // "rooms" // room_id // "meta.json" in
      try
        let ic = open_in path in
        let content = really_input_string ic (in_channel_length ic) in
        close_in ic;
        (match Yojson.Safe.from_string content with
         | `Assoc fields ->
             (match List.assoc_opt "invited_members" fields with
              | Some (`List items) ->
                  List.filter_map
                    (function `String s -> Some s | _ -> None)
                    items
              | _ -> [])
         | _ -> [])
      with _ -> []
    in
    (try
       let rooms_dir = broker_root // "rooms" in
       if Sys.file_exists rooms_dir then
         Array.iter (fun room_id ->
           let tbl : (string, unit) Hashtbl.t = Hashtbl.create 4 in
           List.iter (fun a -> Hashtbl.replace tbl a ()) (read_room_members room_id);
           Hashtbl.replace known_room_members room_id tbl;
           let itbl : (string, unit) Hashtbl.t = Hashtbl.create 4 in
           List.iter (fun a -> Hashtbl.replace itbl a ()) (read_room_invited room_id);
           Hashtbl.replace known_room_invited room_id itbl
         ) (Sys.readdir rooms_dir)
     with _ -> ());
    (* Archive mode watches <broker_root>/archive/*.jsonl (append-only).
       Each drained message is a full JSON object on its own line. We track
       per-file read offsets so we only emit newly-appended lines. This avoids
       the race where the PostToolUse hook drains the live inbox before our
       inotify event fires on <root>/*.inbox.json. *)
    let watch_dir =
      if archive then Filename.concat broker_root "archive" else broker_root
    in
    if archive && not (Sys.file_exists watch_dir) then
      mkdir_p ~mode:0o700 watch_dir;
    (* B070: in the default (archive) mode, ALSO watch this session's live
       inbox file so a bare CLI session with no drainer still receives
       messages (the archive only echoes what some OTHER consumer drained).
       Live mode already watches inboxes, so this augments archive mode only. *)
    let inbox_filename =
      match inbox_sid with Some s -> Some (s ^ ".inbox.json") | None -> None
    in
    let do_inbox_watch = archive && inbox_filename <> None in
    (* B142: does the main thread run a local inbox/archive inotify watch? It
       ALWAYS does — archive mode watches the archive dir (plus this session's
       live inbox when resolved, [do_inbox_watch]); --live watches the broker
       root. There is no relay-only invocation, so this is deterministically
       true. Crucially it is NOT gated on runtime "inotify established yet"
       state: the first relay peek fires immediately at startup (last_tick in
       the past, see the relay thread below) — before inotifywait is armed — and
       the common terminal failures (not_found / unauthorized /
       timestamp_out_of_window) all surface on that first peek. Gating on a
       runtime flag would therefore re-introduce the B142 process teardown for
       startup terminal failures. The local watch is guaranteed by
       configuration, so the relay thread's exit-vs-log-only decision
       ([C2c_monitor_logic.should_exit_on_relay_terminal]) reads this constant;
       a future relay-only mode would set it false and inherit the correct
       supervisor-exit behaviour for free. *)
    let local_watch_active = true in
    (* Per-file read offsets for archive mode. Init to current size so we
       don't re-emit historical entries on startup. *)
    let archive_offsets : (string, int) Hashtbl.t = Hashtbl.create 16 in
    if archive && Sys.file_exists watch_dir then begin
      Array.iter (fun fname ->
        let n = String.length fname in
        if n > 6 && String.sub fname (n - 6) 6 = ".jsonl" then
          let path = Filename.concat watch_dir fname in
          try
            let st = Unix.stat path in
            Hashtbl.replace archive_offsets path st.Unix.st_size
          with _ -> ()
      ) (Sys.readdir watch_dir)
    end;
    let read_new_archive_entries path =
      let prev = try Hashtbl.find archive_offsets path with Not_found -> 0 in
      try
        let st = Unix.stat path in
        let sz = st.Unix.st_size in
        if sz <= prev then []
        else
          let fd = Unix.openfile path [Unix.O_RDONLY] 0 in
          Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
            let _ = Unix.lseek fd prev Unix.SEEK_SET in
            let buf = Bytes.create (sz - prev) in
            let rec read_all off rem =
              if rem <= 0 then () else
              let r = Unix.read fd buf off rem in
              if r = 0 then () else read_all (off + r) (rem - r)
            in
            read_all 0 (sz - prev);
            Hashtbl.replace archive_offsets path sz;
            let text = Bytes.unsafe_to_string buf in
            let lines = String.split_on_char '\n' text in
            List.filter_map (fun ln ->
              let ln = String.trim ln in
              if ln = "" then None
              else try Some (Yojson.Safe.from_string ln) with _ -> None
            ) lines)
      with _ -> []
    in
    (* B070: cross-path dedup between the inbox-watch (peek) path and the
       archive-echo path. When a live-inbox message is surfaced and later
       drained into the archive by any consumer, the archive event must not
       re-print it. Keyed on message identity (see C2c_monitor_logic.msg_key). *)
    let seen = C2c_monitor_logic.create_seen () in
    (* Apply --from + self filters, then drop messages already surfaced.
       B180: self-filter reads the live alias ref so post-rename echoes from
       the new name are suppressed and old-name self-echo is not. *)
    let apply_filters msgs =
      let msgs = match from_filter with
        | None -> msgs
        | Some f -> List.filter (fun m -> match m with
            | `Assoc fields -> jstr fields "from_alias" "" = f
            | _ -> false) msgs
      in
      let msgs =
        if include_self then msgs
        else match !my_alias_r with
          | None -> msgs
          | Some me -> List.filter (fun m -> match m with
              | `Assoc fields ->
                  (* Case-insensitive: rename may only change case. *)
                  not (C2c_monitor_logic.alias_eq
                         (jstr fields "from_alias" "") me)
              | _ -> true) msgs
      in
      C2c_monitor_logic.filter_unseen seen msgs
    in
    (* Emit an already-filtered message list (json objects or human lines).
       [source] tags origin ("local"/"relay") for both JSON and human output
       (B089). JSON message events are shaped to the canonical v1 schema via
       C2c_monitor_ndjson (J3) — legacy keys preserved additively — and
       written one compact object per line, flushed per event. *)
    let emit ~is_mine ~source msgs =
      match msgs with
      | [] -> ()
      | msgs ->
          if json then begin
            if all || is_mine then
              List.iter (fun m ->
                let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
                C2c_monitor_ndjson.emit_line stdout
                  (C2c_monitor_ndjson.message_event ~monitor_ts:ts ~source m))
                msgs
          end else
            emit_messages ~my_alias:(!my_alias_r) ~all ~full_body ~source msgs
    in
    (* B089: the local (inotify) path and the relay-peek thread both feed the
       shared [seen] dedup set and stdout. Serialize filter+emit under one mutex
       so (a) the two sources can't both pass [filter_unseen] for the same
       message and (b) output lines never interleave. Returns the filtered list
       so the inbox-watch path can distinguish "nothing new" (-> DRAIN event)
       from "surfaced messages". *)
    let emit_mutex = Mutex.create () in
    let emit_filtered ~is_mine ~source msgs =
      Mutex.lock emit_mutex;
      Fun.protect ~finally:(fun () -> Mutex.unlock emit_mutex) (fun () ->
        let filtered = apply_filters msgs in
        (match filtered with [] -> () | _ -> emit ~is_mine ~source filtered);
        filtered)
    in
    (* B089: relay-inbox watcher source. Periodically peeks (NON-draining) the
       resolved alias's relay inbox via POST /peek_inbox and surfaces newly-seen
       cross-host DMs through the same emit path as local messages. Peek never
       drains, so the real poll consumer (relay connector / `c2c relay dm poll`)
       still receives every message; dedup against the local archive echo is
       free because the connector preserves the relay message_id on local
       delivery (see C2c_monitor_logic). Gated on relay registration (alias
       resolved + relay URL configured). Runs in a background thread that
       mirrors the existing _err_thread pattern; a stop flag + at_exit keep it
       from outliving the monitor. *)
    let relay_stop = Atomic.make false in
    at_exit (fun () -> Atomic.set relay_stop true);
    let node_id_override =
      match relay_node_id with
      | Some _ -> relay_node_id
      | None ->
          (match Sys.getenv_opt "C2C_RELAY_NODE_ID" with
           | Some s when s <> "" -> Some s
           | _ -> None)
    in
    let session_id_override =
      match relay_session_id with
      | Some _ -> relay_session_id
      | None ->
          (match Sys.getenv_opt "C2C_RELAY_SESSION_ID" with
           | Some s when s <> "" -> Some s
           | _ -> None)
    in
    let relay_url_resolved = C2c_relay_cmd.resolve_relay_url None in
    let relay_token_resolved = C2c_relay_cmd.resolve_relay_token None in
    let identity = match Relay_identity.load () with Ok id -> Some id | Error _ -> None in
    (* H3: resolve the connector-managed relay peek key. When the relay CONNECTOR
       (`c2c relay connect`) manages this broker it registers each local session
       under the machine node-id with the session's OWN session-id — NOT the
       cli-<alias> convention. If connector-state.json lists our resolved alias,
       peek THAT inbox (machine node-id + our local session-id) by default so a
       bare `c2c monitor` on a connector-managed broker surfaces cross-host DMs
       without the operator hand-supplying --relay-node-id / --relay-session-id.
       Node-id preference: the connector's persisted node_id (honours a
       `relay connect --node-id` override), else the same host hash the connector
       derives by default (Host_id.compute_host_hash). B180: recomputed on
       identity rebind so a post-rename connector roster update is honoured. *)
    let resolve_connector_key (alias : string) : C2c_monitor_logic.relay_key option =
      match inbox_sid with
      | Some sid ->
          (match C2c_relay_connector.read_connector_state broker_root with
           | Some cs when
               List.exists
                 (fun a -> Broker.alias_casefold a = Broker.alias_casefold alias)
                 cs.C2c_relay_connector.cs_registered ->
               let node_id =
                 match cs.C2c_relay_connector.cs_node_id with
                 | Some n when n <> "" -> n
                 | _ -> (try Host_id.compute_host_hash () with _ -> "")
               in
               if node_id = "" then None
               else Some C2c_monitor_logic.{ node_id; session_id = sid }
           | _ -> None)
      | None -> None
    in
    let connector_key0 =
      match !my_alias_r with Some a -> resolve_connector_key a | None -> None
    in
    (* B180: live relay peek target. Updated in place on identity rebind so the
       background peek thread adopts cli-<new> (or connector key) without a
       process restart. None = relay watcher not armed. *)
    let relay_peek_r : C2c_monitor_logic.relay_key option ref = ref None in
    let relay_status_label, _relay_thread =
      if no_relay || relay_interval <= 0.0 then
        ("off (--no-relay / --relay-interval 0)", None)
      else if not archive then
        (* --live (legacy) mode emits through its own inline path that does
           not share the [seen] dedup set or [emit_mutex], so a relay-peeked
           DM reappearing in a local live inbox would double-surface and output
           could interleave. The relay watcher is gated to the default (archive)
           mode where the B070 dedup integration is wired. *)
        ("off (--live mode: relay watcher requires the default archive mode for dedup)",
         None)
      else
        let decision =
          C2c_monitor_logic.decide_relay_watch
            ~my_alias:(!my_alias_r) ~relay_url:relay_url_resolved ~identity
            ~node_id_override ~session_id_override ~connector_key:connector_key0 ()
        in
        match decision with
        | C2c_monitor_logic.Relay_watch_off reason ->
            (Printf.sprintf "off (%s)" reason, None)
        | C2c_monitor_logic.Relay_watch { node_id; session_id } ->
            relay_peek_r := Some C2c_monitor_logic.{ node_id; session_id };
            let url = Option.get relay_url_resolved in
            let client = Relay.Relay_client.make ?token:relay_token_resolved url in
            let peek_once () =
              (* Non-draining peek. B180: read node/session/alias from refs so a
                 mid-run rename rebinds the peek key + signing alias without
                 restarting this thread. *)
              match !relay_peek_r with
              | None ->
                  `Assoc [ ("ok", `Bool false)
                         ; ("error_code", `String "not_registered")
                         ; ("error", `String "relay peek target cleared") ]
              | Some { node_id; session_id } ->
                  let body_str = Yojson.Safe.to_string (`Assoc [
                    ("node_id", `String node_id);
                    ("session_id", `String session_id)]) in
                  let alias_str = Option.value !my_alias_r ~default:"" in
                  match identity with
                  | Some id ->
                      let auth =
                        Relay_signed_ops.sign_request id ~alias:alias_str
                          ~meth:"POST" ~path:"/peek_inbox" ~body_str ()
                      in
                      Lwt_main.run (Relay.Relay_client.peek_inbox_signed client
                                      ~node_id ~session_id ~auth_header:auth)
                  | None ->
                      Lwt_main.run (Relay.Relay_client.peek_inbox client
                                      ~node_id ~session_id)
            in
            (* H3 error honesty: distinguish transient (retry, may recover) from
               terminal (auth/identity — will not self-heal) relay failures.
               [err_streak] drives exponential backoff and reconnect reporting so
               a flapping relay does not hammer the endpoint and a recovery is
               announced. A terminal failure is reported clearly and then either
               exits a pure-relay monitor non-zero for its supervisor, or disables
               only relay watching while local receive continues. *)
            let err_streak = ref 0 in
            (* B142: log the terminal message ONCE (a terminal error repeats
               every peek cycle; without this guard the relay loop would spam
               stderr each interval). B180: reset when identity rebinds so a
               post-rename auth recovery is re-attempted honestly. *)
            let terminal_logged = ref false in
            let last_terminal_target = ref "" in
            let handle_terminal ~node_id ~session_id detail =
              let target = node_id ^ "/" ^ session_id in
              if !last_terminal_target <> target then begin
                terminal_logged := false;
                last_terminal_target := target
              end;
              if not !terminal_logged then begin
                terminal_logged := true;
                Printf.eprintf
                  "%s relay watch: TERMINAL failure peeking %s/%s: %s\n\
                   %s relay watch: this will not self-heal (auth / identity / \
                   config). Re-register (c2c relay register) or fix the key/clock, \
                   then restart the monitor.\n%!"
                  (now_hms ()) node_id session_id detail (now_hms ())
              end;
              if C2c_monitor_logic.should_exit_on_relay_terminal ~local_watch_active
              then
                (* Pure-relay monitor (no local watch): tear down so a supervisor
                   notices a dead relay stream. *)
                exit C2c_monitor_logic.exit_relay_terminal
              else begin
                (* B142: a local inbox/archive watch is active — a relay-side
                   problem must NOT tear down local receive. Disable ONLY the
                   relay loop; the main-thread inotify watch keeps running. Set
                   the stop flag so the loop returns on its next guard check. *)
                if not (Atomic.get relay_stop) then
                  Printf.eprintf
                    "%s relay watch: disabled — local inbox watch continues \
                     (relay failure does not stop local receive)\n%!"
                    (now_hms ());
                Atomic.set relay_stop true
              end
            in
            let rec relay_loop last_tick =
              if Atomic.get relay_stop || Unix.getppid () = 1 then ()
              else begin
                let now = Unix.gettimeofday () in
                (* Backoff: after consecutive transient errors wait longer before
                   the next peek, capped at 60s. Zero streak == normal interval. *)
                let effective_interval =
                  if !err_streak = 0 then relay_interval
                  else Float.min 60.0 (relay_interval *. float_of_int (!err_streak + 1))
                in
                if now -. last_tick >= effective_interval then begin
                  let peek_target = !relay_peek_r in
                  let outcome =
                    try C2c_monitor_logic.classify_relay_response (peek_once ())
                    with e -> C2c_monitor_logic.Peek_transient (Printexc.to_string e)
                  in
                  let node_id, session_id =
                    match peek_target with
                    | Some k -> k.node_id, k.session_id
                    | None -> "?", "?"
                  in
                  (match outcome with
                   | C2c_monitor_logic.Peek_ok msgs ->
                       if !err_streak > 0 then begin
                         Printf.eprintf
                           "%s relay watch: reconnected (recovered after %d \
                            transient error%s)\n%!"
                           (now_hms ()) !err_streak
                           (if !err_streak = 1 then "" else "s");
                         err_streak := 0
                       end;
                       ignore (emit_filtered ~is_mine:true ~source:"relay" msgs)
                   | C2c_monitor_logic.Peek_transient detail ->
                       incr err_streak;
                       Printf.eprintf
                         "%s relay watch: transient error peeking %s/%s: %s \
                          (attempt %d; backing off, will retry)\n%!"
                         (now_hms ()) node_id session_id detail !err_streak
                   | C2c_monitor_logic.Peek_terminal detail ->
                       handle_terminal ~node_id ~session_id detail);
                  relay_loop now
                end else begin
                  (* Short sleep so the stop flag / parent-death is noticed
                     within ~0.2s rather than waiting a full interval. *)
                  Thread.delay 0.2;
                  relay_loop last_tick
                end
              end
            in
            (* Start with last_tick in the past so the FIRST peek fires
               immediately — a terminal auth/identity failure surfaces at
               startup, not one interval late. *)
            let th =
              Thread.create
                (fun () -> relay_loop (Unix.gettimeofday () -. relay_interval -. 1.0)) ()
            in
            let id_tag = if identity = None then " (unsigned)" else "" in
            (Printf.sprintf "peek %s/%s every %.1fs%s"
               node_id session_id relay_interval id_tag,
             Some th)
    in
    (* B180: rebind identity after rename without process restart.
       Triggers: registry change, archive alias_renamed marker, periodic poll.
       Re-arms include-self filter (via my_alias_r), monitor lockfile, and
       relay peek key (cli-<new> / connector). --alias freezes identity. *)
    let rebind_mutex = Mutex.create () in
    let session_reg_alias_now () : string option =
      match resolved_sid with
      | None -> None
      | Some sid ->
          (match List.find_opt
                   (fun (r : registration) -> r.session_id = sid)
                   (lookup_regs ()) with
           | Some r -> Some r.alias
           | None -> None)
    in
    let emit_identity_changed ~old_alias ~new_alias ~reason ~relay_label () =
      (* Share emit_mutex with message emit so NDJSON lines never interleave
         with the relay/local emit paths (poll thread can rebind concurrently). *)
      Mutex.lock emit_mutex;
      Fun.protect ~finally:(fun () -> Mutex.unlock emit_mutex) (fun () ->
        if json then begin
          let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
          print_string (Yojson.Safe.to_string
            (`Assoc [ "event_type", `String "identity.changed"
                    ; "monitor_ts", `String ts
                    ; "old_alias", (match old_alias with Some a -> `String a | None -> `Null)
                    ; "new_alias", `String new_alias
                    ; "reason", `String reason
                    ; "alias_source", `String (C2c_monitor_logic.source_label !alias_source_r)
                    ; "relay_watch", `String relay_label ]));
          print_newline ()
        end else begin
          (match old_alias with
           | Some o ->
               Printf.printf "%s identity rebind: %s → %s (%s)\n%!"
                 (now_hms ()) o new_alias reason
           | None ->
               Printf.printf "%s identity rebind: monitoring as %s (%s)\n%!"
                 (now_hms ()) new_alias reason);
          Printf.printf "%s monitoring as %s (session %s)\n%!"
            (now_hms ()) new_alias
            (match resolved_sid with Some s -> s | None -> "?");
          Printf.printf "%s relay watch: %s\n%!" (now_hms ()) relay_label
        end)
    in
    let migrate_lock ~new_alias =
      match !monitor_lock_r with
      | Some (old_fd, old_path) ->
          let old_base = Filename.basename old_path in
          (* Only migrate when the held lock is for a different alias. *)
          if old_base <> (new_alias ^ ".lock") then
            (match acquire_monitor_lock ~alias:new_alias ~force_displace:false with
             | Some (fd, path) ->
                 release_lock_pair old_fd old_path;
                 monitor_lock_r := Some (fd, path)
             | None ->
                 (* Keep old lock; another monitor may already hold the new name. *)
                 Printf.eprintf
                   "%s identity rebind: could not acquire lock for '%s' \
                    (keeping previous lock)\n%!" (now_hms ()) new_alias)
      | None ->
          (match acquire_monitor_lock ~alias:new_alias ~force_displace:false with
           | Some (fd, path) -> monitor_lock_r := Some (fd, path)
           | None -> ())
    in
    let rearm_relay_for_alias new_alias =
      if no_relay || relay_interval <= 0.0 || not archive then
        match !relay_peek_r with
        | Some k ->
            Printf.sprintf "peek %s/%s every %.1fs (unchanged; relay re-arm gated)"
              k.node_id k.session_id relay_interval
        | None -> relay_status_label
      else
        let ck = resolve_connector_key new_alias in
        match
          C2c_monitor_logic.decide_relay_watch
            ~my_alias:(Some new_alias) ~relay_url:relay_url_resolved ~identity
            ~node_id_override ~session_id_override ~connector_key:ck ()
        with
        | C2c_monitor_logic.Relay_watch_off reason ->
            relay_peek_r := None;
            Printf.sprintf "off (%s)" reason
        | C2c_monitor_logic.Relay_watch { node_id; session_id } ->
            let prev = !relay_peek_r in
            relay_peek_r := Some C2c_monitor_logic.{ node_id; session_id };
            (* If the relay thread was previously stopped on a terminal error
               under the OLD key, do not auto-restart it here — B142 stop is
               sticky for the process. Only swap the peek target when the
               loop is still running. *)
            let id_tag = if identity = None then " (unsigned)" else "" in
            let label =
              Printf.sprintf "peek %s/%s every %.1fs%s"
                node_id session_id relay_interval id_tag
            in
            (match prev with
             | Some p when p.node_id = node_id && p.session_id = session_id -> ()
             | _ when not (Atomic.get relay_stop) ->
                 Printf.eprintf
                   "%s relay watch re-armed: %s\n%!" (now_hms ()) label
             | _ -> ());
            label
    in
    let try_rebind_identity ?hint () =
      if flag_bound then ()
      else begin
        Mutex.lock rebind_mutex;
        Fun.protect ~finally:(fun () -> Mutex.unlock rebind_mutex) (fun () ->
          let session_alias =
            match hint with
            | Some n when String.trim n <> "" -> Some (String.trim n)
            | _ -> session_reg_alias_now ()
          in
          (* Prefer live registration when available; hint only fills gaps
             (e.g. archive marker races ahead of registry re-read). *)
          let session_alias =
            match session_reg_alias_now () with
            | Some _ as s -> s
            | None -> session_alias
          in
          match
            C2c_monitor_logic.decide_identity_rebind
              ~flag_bound
              ~current_alias:(!my_alias_r)
              ~session_reg_alias:session_alias
              ()
          with
          | C2c_monitor_logic.No_rebind -> ()
          | C2c_monitor_logic.Rebind { old_alias; new_alias; reason } ->
              (* Migrate lock BEFORE swapping the alias ref so the expected
                 old lock name still matches the held lock path. *)
              migrate_lock ~new_alias;
              my_alias_r := Some new_alias;
              (match resolved_sid with
               | Some sid -> alias_source_r := C2c_monitor_logic.Session_reg sid
               | None -> ());
              let relay_label = rearm_relay_for_alias new_alias in
              emit_identity_changed ~old_alias ~new_alias ~reason ~relay_label ())
      end
    in
    (* Background poll: registry renames that arrive while the main thread is
       blocked on inotify still rebind within a few seconds. Cheap: one
       registry list read. Skipped when --alias froze identity. *)
    let _identity_poll_thread =
      if flag_bound then None
      else
        Some (Thread.create (fun () ->
          let rec loop () =
            if Unix.getppid () = 1 then ()
            else begin
              (try try_rebind_identity () with _ -> ());
              Thread.delay 2.0;
              loop ()
            end
          in
          loop ()) ())
    in
    (* Belt-and-braces startup orphan check: if the parent already died before
       we enter the inotify loop, exit immediately rather than loop forever. *)
    (if Unix.getppid () = 1 then exit 0);
    let cmd =
      if archive then
        (* Archive (default): watch the append-only archive dir; when a session
           inbox was resolved (B070) also watch the broker root for that
           session's live *.inbox.json. Unified tab-delimited full-path format
           so both watch roots parse identically; non-recursive (rooms/registry
           events are a live-mode concern). *)
        let paths =
          (Filename.quote watch_dir)
          ^ (if do_inbox_watch then " " ^ Filename.quote broker_root else "")
        in
        Printf.sprintf
          "inotifywait -m -e close_write,modify,delete,moved_to --format '%%e\t%%w%%f' %s"
          paths
      else
        (* Live: recursive so rooms/<id>/members.json is caught.
           Tab-delimited with %w%f = full path avoids space-in-path ambiguity.
           No -q: we read stderr to detect "Watches established." and emit a
           monitor.ready event so tests/callers don't need a fixed sleep. *)
        Printf.sprintf
          "inotifywait -m -r -e close_write,modify,delete,moved_to --format '%%e\t%%w%%f' %s"
          (Filename.quote watch_dir)
    in
    let (ic, _oc, err_ic) = Unix.open_process_full cmd (Unix.environment ()) in
    (* Drain inotifywait stderr in a background thread; set a flag once we see
       "Watches established." so the main thread knows inotifywait is armed.
       This replaces the fixed sleep in callers (tests, plugin) with a
       deterministic signal, preventing the race where events are triggered
       before inotifywait finishes setting up watches. *)
    let ready_flag = Atomic.make false in
    let str_contains haystack needle =
      let hl = String.length haystack and nl = String.length needle in
      if nl = 0 then true
      else if nl > hl then false
      else begin
        let found = ref false in
        let i = ref 0 in
        while !i <= hl - nl && not !found do
          if String.sub haystack !i nl = needle then found := true;
          incr i
        done;
        !found
      end
    in
    let _err_thread = Thread.create (fun () ->
      (try while true do
        let line = String.lowercase_ascii (input_line err_ic) in
        if str_contains line "watches established" then
          Atomic.set ready_flag true
      done with End_of_file | Sys_error _ -> ());
      (* Signal on EOF too so main thread never waits forever. *)
      Atomic.set ready_flag true
    ) () in
    (* Poll ready_flag up to 10s with 50ms sleeps — no timed Condition needed. *)
    let deadline = Unix.gettimeofday () +. 10.0 in
    while not (Atomic.get ready_flag) && Unix.gettimeofday () < deadline do
      Thread.delay 0.05
    done;
    (* B069: make the resolved identity VISIBLE — a misresolved alias (e.g. a
       stale default-alias file belonging to another agent) must never fail
       silently. This line is the monitor's first output, so in Claude Code's
       Monitor tool it becomes the first notification. *)
    let sid_str = match resolved_sid with Some s -> s | None -> "?" in
    if json then begin
      let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
      print_string (Yojson.Safe.to_string
        (`Assoc [ "event_type", `String "monitor.ready"
                ; "monitor_ts", `String ts
                ; "alias", (match !my_alias_r with Some a -> `String a | None -> `Null)
                ; "session_id", (match resolved_sid with Some s -> `String s | None -> `Null)
                ; "alias_source", `String (C2c_monitor_logic.source_label !alias_source_r)
                ; "inbox_watch", `Bool do_inbox_watch
                ; "relay_watch", `String relay_status_label ]));
      print_newline ()
    end else begin
      (match !my_alias_r with
       | Some a ->
           Printf.printf "%s monitoring as %s (session %s)%s\n%!"
             (now_hms ()) a sid_str
             (if C2c_monitor_logic.is_fallback_source !alias_source_r
              then Printf.sprintf " — resolved via %s"
                     (C2c_monitor_logic.source_label !alias_source_r)
              else "")
       | None ->
           Printf.printf "%s monitoring ALL peers — no alias resolved (%s)\n%!"
             (now_hms ()) (C2c_monitor_logic.source_label !alias_source_r));
      if do_inbox_watch then
        Printf.printf "%s watching live inbox (%s)\n%!"
          (now_hms ()) (if drain then "drain" else "peek");
      Printf.printf "%s relay watch: %s\n%!" (now_hms ()) relay_status_label
    end;
    (* B150: surface any mail ALREADY queued in this session's live inbox at
       startup. The inotify watch only fires on CHANGES, so messages sitting in
       the inbox when the monitor starts would otherwise stay invisible until
       the next inbox event. Runs after inotifywait is armed (the ready_flag
       wait above), so a message that lands during this read still produces an
       inotify event and is deduped against `seen` rather than lost.

       Scoped to the default archive+inbox-watch mode (B070): that path shares
       the `seen` set and emit_mutex with the live-inbox change handler, so a
       startup-surfaced message is not re-printed when the same inbox is later
       drained into the archive. --live (legacy) mode emits through a separate
       non-deduped path, so surfacing there could double-print on a later
       change; it is deliberately left out. Mirrors the inbox-change path:
       peek by default, drain with --drain. *)
    (if do_inbox_watch then
       match inbox_sid, inbox_filename with
       | Some sid, Some ifn ->
           let inbox_path = Filename.concat broker_root ifn in
           if Sys.file_exists inbox_path then begin
             let msgs =
               if drain then
                 (try
                    List.map message_record_to_json
                      (Broker.drain_inbox ~drained_by:"c2c-monitor"
                         (Broker.create ~root:broker_root) ~session_id:sid)
                  with _ -> read_inbox_file inbox_path)
               else read_inbox_file inbox_path
             in
             ignore (emit_filtered ~is_mine:true ~source:"local" msgs)
           end
       | _ -> ());
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_full (ic, _oc, err_ic))) (fun () ->
      try while true do
        (* If our parent died (reparented to init/PID 1), we are an orphan —
           exit rather than accumulate as a zombie monitor process. *)
        (if Unix.getppid () = 1 then exit 0);
        let line = input_line ic in
        (* Unified tab-delimited "EVENT\tFULL_PATH" format for both archive and
           live modes (see the inotifywait --format above). *)
        let parts = String.split_on_char '\t' (String.trim line) in
        (match parts with
         | event :: full_path :: _ when archive ->
             (* Archive mode routes two file kinds by suffix: append-only
                archive entries (.jsonl in watch_dir) and — when inbox-watch is
                on (B070) — this session's live inbox (.inbox.json in the
                broker root). Both are unambiguous by suffix. *)
             let filename = Filename.basename full_path in
             let n = String.length filename in
             let is_jsonl = n > 6 && String.sub filename (n - 6) 6 = ".jsonl" in
             if is_jsonl then begin
               let sid = String.sub filename 0 (n - 6) in
               (* Rebuild the path against watch_dir so it matches the offset
                  table keys initialised at startup. *)
               let path = Filename.concat watch_dir filename in
               let is_mine =
                 C2c_monitor_logic.archive_owner_is_mine ~archive_id:sid
                   ~my_alias:(!my_alias_r) ~my_session_id:inbox_sid ()
               in
               let entries = read_new_archive_entries path in
               (* B180: B140 rename appends an alias_renamed marker to THIS
                  session's archive. Detect it early and rebind before emit so
                  filters/relay already use the new alias. *)
               if is_mine then
                 List.iter
                   (fun m ->
                     match C2c_monitor_logic.parse_alias_renamed_marker m with
                     | Some (_old, new_a) -> try_rebind_identity ~hint:new_a ()
                     | None -> ())
                   entries;
               ignore (emit_filtered ~is_mine ~source:"local" entries)
             end else if filename = "registry.json" then begin
               (* B180: registry rewrite (rename/register) while archive mode
                  already watches the broker root for the live inbox. Re-resolve
                  this session's alias so monitor identity tracks rename. *)
               try_rebind_identity ()
             end else begin
               match inbox_filename with
               | Some ifn when filename = ifn ->
                   (* B070: this session's live inbox changed. Peek (default) or
                      drain (--drain) and surface newly-seen messages. Dedup
                      against the eventual archive echo via `seen`. *)
                   let event_up = String.uppercase_ascii event in
                   let is_delete = String.length event_up >= 6
                                   && String.sub event_up 0 6 = "DELETE" in
                   let label = match !my_alias_r with
                     | Some a -> a | None -> String.sub filename 0 (n - 11) in
                   if is_delete then begin
                     if sweeps then begin
                       if json then begin
                         let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
                         print_string (Yojson.Safe.to_string
                           (`Assoc [ "event_type", `String "sweep"
                                   ; "alias",      `String label
                                   ; "monitor_ts", `String ts ]));
                         print_newline ()
                       end else
                         Printf.printf "%s 🗑️  SWEEP  %s (inbox deleted)\n%!"
                           (now_hms ()) label
                     end
                   end else begin
                     let inbox_path = Filename.concat broker_root filename in
                     let msgs =
                       if drain then
                         (match inbox_sid with
                          | Some sid ->
                              (try
                                 List.map message_record_to_json
                                   (Broker.drain_inbox ~drained_by:"c2c-monitor"
                                      (Broker.create ~root:broker_root)
                                      ~session_id:sid)
                               with _ -> read_inbox_file inbox_path)
                          | None -> read_inbox_file inbox_path)
                       else read_inbox_file inbox_path
                     in
                     (match emit_filtered ~is_mine:true ~source:"local" msgs with
                      | [] ->
                          if drains then begin
                            if json then begin
                              let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
                              print_string (Yojson.Safe.to_string
                                (`Assoc [ "event_type", `String "drain"
                                        ; "alias",      `String label
                                        ; "monitor_ts", `String ts ]));
                              print_newline ()
                            end else
                              Printf.printf "%s 📤  DRAIN  %s (inbox cleared)\n%!"
                                (now_hms ()) label
                          end
                      | _ -> ())
                   end
               | _ -> ()
             end
         | event :: full_path :: _ ->
             (* In live mode filename is a full path; basename is used for routing. *)
             let filename = Filename.basename full_path in
             let n = String.length filename in
             let is_inbox = n > 11 && String.sub filename (n - 11) 11 = ".inbox.json" in
             let is_lock  = n >= 5  && String.sub filename (n - 5) 5 = ".lock" in
             if is_inbox && not is_lock then begin
               let alias = String.sub filename 0 (n - 11) in
               let event_up = String.uppercase_ascii event in
               let is_delete = String.length event_up >= 6
                               && String.sub event_up 0 6 = "DELETE" in
               if is_delete then begin
                 if sweeps then begin
                   if json then begin
                     let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
                     print_string (Yojson.Safe.to_string
                       (`Assoc [ "event_type", `String "sweep"
                               ; "alias",      `String alias
                               ; "monitor_ts", `String ts ]));
                     print_newline ()
                   end else
                     Printf.printf "%s 🗑️  SWEEP  %s (inbox deleted)\n%!" (now_hms ()) alias
                 end
               end else begin
                 let inbox_path = Filename.concat broker_root filename in
                 let msgs = read_inbox_file inbox_path in
                 (* Apply --from filter *)
                 let msgs = match from_filter with
                   | None -> msgs
                   | Some f -> List.filter (fun m -> match m with
                       | `Assoc fields -> jstr fields "from_alias" "" = f
                       | _ -> false) msgs
                 in
                 (* Drop self-sent unless --include-self *)
                 let msgs =
                   if include_self then msgs
                   else match !my_alias_r with
                     | None -> msgs
                     | Some me -> List.filter (fun m -> match m with
                         | `Assoc fields ->
                             not (C2c_monitor_logic.alias_eq
                                    (jstr fields "from_alias" "") me)
                         | _ -> true) msgs
                 in
                 (match msgs with
                  | [] ->
                      if drains then begin
                        if json then begin
                          let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
                          print_string (Yojson.Safe.to_string
                            (`Assoc [ "event_type", `String "drain"
                                    ; "alias",      `String alias
                                    ; "monitor_ts", `String ts ]));
                          print_newline ()
                        end else
                          Printf.printf "%s 📤  DRAIN  %s (inbox cleared)\n%!" (now_hms ()) alias
                      end
                  | msgs ->
                      if json then begin
                        let is_mine = match !my_alias_r with
                          | None -> true
                          | Some me -> C2c_monitor_logic.alias_eq alias me in
                        if all || is_mine then
                          (* J3: canonical v1 shape (legacy keys additive).
                             The live path is always local-sourced; pre-J3 it
                             omitted `source` — the v1 face now carries
                             source:"local" (additive). *)
                          List.iter (fun m ->
                            let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
                            C2c_monitor_ndjson.emit_line stdout
                              (C2c_monitor_ndjson.message_event
                                 ~monitor_ts:ts ~source:"local" m)
                          ) msgs
                      end else
                        emit_messages ~my_alias:(!my_alias_r) ~all ~full_body
                          ~source:"local" msgs)
               end
             end else if filename = "registry.json" && not archive then begin
               (* Registry changed — diff against snapshot and emit peer events.
                  B180: also rebind our own identity if this session renamed. *)
               try_rebind_identity ();
               let new_regs = read_registry_aliases () in
               let new_tbl : (string, string) Hashtbl.t = Hashtbl.create 16 in
               List.iter (fun (a, s) -> Hashtbl.replace new_tbl a s) new_regs;
               let ts () = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
               (* Emit peer.alive for any alias not previously known. *)
               List.iter (fun (a, _s) ->
                 if not (Hashtbl.mem known_peers a) then begin
                   if json then begin
                     print_string (Yojson.Safe.to_string
                       (`Assoc [ "event_type", `String "peer.alive"
                               ; "alias",      `String a
                               ; "monitor_ts", `String (ts ()) ]));
                     print_newline ()
                   end else
                     Printf.printf "%s 🟢  PEER   %s (registered)\n%!" (now_hms ()) a
                 end
               ) new_regs;
               (* Emit peer.dead for any alias no longer present. *)
               Hashtbl.iter (fun a _s ->
                 if not (Hashtbl.mem new_tbl a) then begin
                   if json then begin
                     print_string (Yojson.Safe.to_string
                       (`Assoc [ "event_type", `String "peer.dead"
                               ; "alias",      `String a
                               ; "monitor_ts", `String (ts ()) ]));
                     print_newline ()
                   end else
                     Printf.printf "%s 🔴  PEER   %s (deregistered)\n%!" (now_hms ()) a
                 end
               ) known_peers;
               (* Update snapshot. *)
               Hashtbl.reset known_peers;
               List.iter (fun (a, s) -> Hashtbl.replace known_peers a s) new_regs
             end else if filename = "members.json"
                      && Filename.basename (Filename.dirname (Filename.dirname full_path)) = "rooms"
             then begin
               (* Room membership changed — extract room_id, diff, emit events. *)
               let room_id = Filename.basename (Filename.dirname full_path) in
               let new_members = read_room_members room_id in
               let new_tbl : (string, unit) Hashtbl.t = Hashtbl.create 4 in
               List.iter (fun a -> Hashtbl.replace new_tbl a ()) new_members;
               let prev_tbl =
                 try Hashtbl.find known_room_members room_id
                 with Not_found ->
                   let t : (string, unit) Hashtbl.t = Hashtbl.create 4 in
                   Hashtbl.replace known_room_members room_id t; t
               in
               let ts () = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
               List.iter (fun a ->
                 if not (Hashtbl.mem prev_tbl a) then begin
                   if json then begin
                     print_string (Yojson.Safe.to_string
                       (`Assoc [ "event_type", `String "room.join"
                               ; "room_id",    `String room_id
                               ; "alias",      `String a
                               ; "monitor_ts", `String (ts ()) ]));
                     print_newline ()
                   end else
                     Printf.printf "%s 🚪  ROOM   %s joined %s\n%!" (now_hms ()) a room_id
                 end
               ) new_members;
               Hashtbl.iter (fun a () ->
                 if not (Hashtbl.mem new_tbl a) then begin
                   if json then begin
                     print_string (Yojson.Safe.to_string
                       (`Assoc [ "event_type", `String "room.leave"
                               ; "room_id",    `String room_id
                               ; "alias",      `String a
                               ; "monitor_ts", `String (ts ()) ]));
                     print_newline ()
                   end else
                     Printf.printf "%s 👋  ROOM   %s left %s\n%!" (now_hms ()) a room_id
                 end
               ) prev_tbl;
               Hashtbl.reset prev_tbl;
               List.iter (fun a -> Hashtbl.replace prev_tbl a ()) new_members
             end else if filename = "meta.json"
                      && Filename.basename (Filename.dirname (Filename.dirname full_path)) = "rooms"
             then begin
               (* #433: Room meta changed — diff invited_members and emit
                  room.invite for any newly-invited alias. The MCP
                  Broker.send_room_invite already auto-DMs the invitee;
                  this monitor event is the parallel observability surface
                  (parity with room.join / room.leave). *)
               let room_id = Filename.basename (Filename.dirname full_path) in
               let new_invited = read_room_invited room_id in
               let new_tbl : (string, unit) Hashtbl.t = Hashtbl.create 4 in
               List.iter (fun a -> Hashtbl.replace new_tbl a ()) new_invited;
               let prev_tbl =
                 try Hashtbl.find known_room_invited room_id
                 with Not_found ->
                   let t : (string, unit) Hashtbl.t = Hashtbl.create 4 in
                   Hashtbl.replace known_room_invited room_id t; t
               in
               let ts () = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
               List.iter (fun a ->
                 if not (Hashtbl.mem prev_tbl a) then begin
                   if json then begin
                     print_string (Yojson.Safe.to_string
                       (`Assoc [ "event_type", `String "room.invite"
                               ; "room_id",    `String room_id
                               ; "alias",      `String a
                               ; "monitor_ts", `String (ts ()) ]));
                     print_newline ()
                   end else
                     Printf.printf "%s ✉️  ROOM   %s invited to %s\n%!" (now_hms ()) a room_id
                 end
               ) new_invited;
               Hashtbl.reset prev_tbl;
               List.iter (fun a -> Hashtbl.replace prev_tbl a ()) new_invited
             end
         | _ -> ()
        )
      done with End_of_file -> ())
  ) $ broker_root_opt $ alias_opt $ all_flag $ drains_flag $ sweeps_flag
    $ full_body_flag $ snippet_flag $ from_opt $ json_flag $ archive_flag $ live_flag $ include_self_flag
    $ force_flag $ drain_flag $ cross_repo $ no_relay $ relay_interval $ relay_node_id $ relay_session_id

(* --- monitor Cmd ---------------------------------------------------------- *)

let monitor =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "monitor"
       ~doc:"Watch broker inboxes and emit formatted event notifications."
       ~man:[ `S "DESCRIPTION"
            ; `P "Watches the broker inbox directory with $(b,inotifywait) and emits \
                  one formatted line per new message (or event). Designed for Claude Code's \
                  Monitor tool — each output line becomes the notification summary."
            ; `P "Default behaviour: only show messages addressed to your alias. \
                  The alias is auto-resolved (no --alias needed): \
                  $(b,C2C_MCP_AUTO_REGISTER_ALIAS), then THIS session's own broker \
                  registration (authoritative — never shadowed by another agent's \
                  $(b,~/.config/c2c/default-alias)), then that file, then \
                  $(b,C2C_MCP_SESSION_ID), then a single alive registration. The \
                  resolved identity is printed as the first line so a misresolution \
                  is visible, not silent. After $(b,c2c rename) the monitor \
                  re-resolves this session's registration, re-arms the local \
                  identity filter and relay peek key ($(b,cli-<new>) when not \
                  connector-managed), and emits $(b,identity.changed) — no full \
                  process restart required (B180). Explicit $(b,--alias) freezes \
                  identity. New messages only — drains and sweeps suppressed \
                  unless $(b,--drains)/$(b,--sweeps) are set."
            ; `P "Receive without a drainer: in the default (archive) mode the \
                  monitor ALSO watches your session's live inbox, so a bare CLI \
                  session with no hook/poll consumer still sees incoming messages \
                  (peeked, not drained). Pass $(b,--drain) to make the monitor the \
                  inbox consumer (archive-append preserved)."
            ; `P "Full delivery by default: every message is emitted with its \
                  complete body, one line per message — a burst from one sender \
                  is NOT collapsed or truncated (each body arrives whole). Only \
                  legacy $(b,--snippet) mode collapses bursts to a count + \
                  truncated preview. Inbox-peek and archive-echo of the same \
                  message are deduped by message identity so it is not printed \
                  twice."
            ; `P "Relay-inbox watcher (B089): when a relay URL is configured \
                  ($(b,C2C_RELAY_URL) / $(b,c2c relay setup)) and an alias is resolved, \
                  the monitor ALSO peeks (non-draining) the relay inbox on an interval \
                  so cross-host DMs surface like local ones. The relay is peeked, never \
                  polled, so a separate consumer (relay connector / $(b,c2c relay dm poll)) \
                  still receives every message. Relay-sourced lines are tagged 🌐 (and \
                  carry \"source\":\"relay\" in --json). $(b,--no-relay) disables."
            ; `P "Peek-key resolution (H3): the default relay inbox to peek is resolved \
                  automatically. When the relay CONNECTOR ($(b,c2c relay connect)) manages \
                  this broker it registers your alias under the machine node-id with your \
                  LOCAL session-id (not the $(b,cli-<alias>) convention), so the monitor \
                  reads $(b,connector-state.json) and peeks that connector-managed inbox by \
                  default — no manual $(b,--relay-node-id)/$(b,--relay-session-id) needed. \
                  With no connector it falls back to $(b,cli-<alias>) (matching \
                  $(b,c2c relay register --alias)). Explicit $(b,--relay-node-id) / \
                  $(b,--relay-session-id) always override the resolved default."
            ; `P "Error honesty (H3): a relay error is never silently swallowed. An \
                  $(b,ok:false) response is surfaced on stderr. A TRANSIENT error \
                  (network blip, timeout, rate-limit) is retried with backoff and a \
                  $(b,reconnected) line is emitted on recovery. A TERMINAL error \
                  (auth / identity / signature / bad-request — will not self-heal) prints \
                  a clear message ONCE and DISABLES the relay watcher — the \
                  main-thread local inbox watch KEEPS RUNNING (B142), so a \
                  relay-side problem never tears down local receive. The monitor \
                  exits with a non-zero code on a terminal relay failure ONLY when \
                  relay-watch is the sole reason it started (no local watch active), \
                  so a supervisor still notices a dead pure-relay monitor."
            ; `S "EXIT STATUS"
            ; `P "0  clean exit (parent gone / stop; also after a terminal relay \
                  failure when a local inbox watch is active — the local watch keeps \
                  running and the process exits 0 only when it stops). \
                  1  usage or startup error (broker root unresolved, lockfile conflict). \
                  3  terminal relay failure (auth / identity / signature / bad request) \
                  when relay-watch is the sole source (no local watch active)."
            ; `S "OUTPUT FORMAT"
            ; `P "[HH:MM:SS] ICON  TYPE  from→to  \"subject…\""
            ; `P "ICON: 📬 = addressed to you, 💬 = peer traffic (--all), \
                  📤 = drain (--drains), 🗑️ = sweep (--sweeps), 🌐 = relay-sourced (B089)"
            ; `S "EXAMPLES"
            ; `P "$(b,c2c monitor)  — zero-flag form: auto-resolves alias + broker, watches archive with full body. Recommended."
            ; `P "$(b,c2c monitor --all)  — broad swarm monitor"
            ; `P "$(b,c2c monitor --all --drains --sweeps)  — everything"
            ; `P "$(b,c2c monitor --from coder1)  — only messages from coder1"
            ; `P "$(b,c2c monitor --drain)  — monitor is the inbox consumer (drains live inbox)"
            ; `P "$(b,c2c monitor --snippet)  — 80-char subject preview (legacy)"
            ; `P "$(b,c2c monitor --no-relay)  — local broker only (disable relay watcher)"
            ; `P "$(b,c2c monitor --relay-node-id machine-42)  — peek a relay inbox keyed machine-42/machine-42"
            ; `P "$(b,c2c monitor --relay-node-id host-1 --relay-session-id <sid>)  — connector-managed inbox (needs both)"
            ; `P "$(b,c2c monitor --live)  — watch live inboxes instead of archive (legacy)"
            ; `P "$(b,c2c monitor --json)  — NDJSON output for programmatic parsing \
                  (one object per line, flushed per event; message events carry the \
                  canonical message schema v1 fields plus the legacy \
                  from_alias/to_alias keys — see docs/monitor-json-schema.md)"
            ; `P "In Claude Code: Monitor({command: \"c2c monitor\", persistent: true})"
            ; `P "Per-alias lockfile prevents duplicate monitors; use $(b,--force) to displace a live holder."
            ])
    monitor_cmd
