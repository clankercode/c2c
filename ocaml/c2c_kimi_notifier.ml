(* c2c_kimi_notifier.ml — push c2c broker DMs into a managed kimi instance via
   kimi-cli's file-based notification store. Replaces c2c-kimi-wire-bridge.

   See c2c_kimi_notifier.mli for the architecture overview, and
   .collab/research/2026-04-29T10-27-00Z-stanza-coder-kimi-notification-store-
   push-validated.md for the probe that grounds this design. *)

let home () =
  match Sys.getenv_opt "HOME" with
  | Some h -> h
  | None -> "/tmp"

let ( // ) = Filename.concat

(* ─── Constants + path helpers ───────────────────────────────────────────── *)

(* Kimi-cli's share-dir resolution mirrors share.py:
     get_share_dir = $KIMI_SHARE_DIR or ~/.kimi *)
let kimi_share_dir () =
  match Sys.getenv_opt "KIMI_SHARE_DIR" with
  | Some d when d <> "" -> d
  | _ -> home () // ".kimi"

let kimi_log_path () = kimi_share_dir () // "logs" // "kimi.log"
let kimi_sessions_root () = kimi_share_dir () // "sessions"

let pidfile_path alias =
  home () // ".local" // "share" // "c2c" // "kimi-notifiers" // (alias ^ ".pid")

let logfile_path alias =
  home () // ".local" // "share" // "c2c" // "kimi-notifiers" // (alias ^ ".log")

let ensure_state_dir () =
  let d = home () // ".local" // "share" // "c2c" // "kimi-notifiers" in
  (try Unix.mkdir (home () // ".local") 0o755 with Unix.Unix_error _ -> ());
  (try Unix.mkdir (home () // ".local" // "share") 0o755 with Unix.Unix_error _ -> ());
  (try Unix.mkdir (home () // ".local" // "share" // "c2c") 0o755 with Unix.Unix_error _ -> ());
  (try Unix.mkdir d 0o755 with Unix.Unix_error _ -> ());
  d

(* ─── Workspace-hash + session-id discovery ──────────────────────────────── *)

(* Mirrors kimi-cli/metadata.py:WorkDirMeta.sessions_dir —
     md5(self.path.encode("utf-8")).hexdigest()
   For non-local KAOS contexts kimi prefixes "<kaos>_<md5>" but c2c-managed
   sessions are always local, so the bare md5 is correct. *)
let workspace_hash_for_path path =
  Digest.to_hex (Digest.string path)

(* #158: read the pinned session UUID from c2c instance config instead of
   grepping kimi.log.  c2c pre-mints the UUID before exec and persists it in
   config.json, so the notifier never races the session-creation log line. *)
let instance_config_path alias =
  home () // ".local" // "share" // "c2c" // "instances" // alias // "config.json"

let read_session_id_from_config alias =
  let path = instance_config_path alias in
  if not (Sys.file_exists path) then None
  else
    try
      let json = Yojson.Safe.from_file path in
      match json with
      | `Assoc fields ->
          (match List.assoc_opt "resume_session_id" fields with
           | Some (`String sid) when String.trim sid <> "" -> Some sid
           | _ -> None)
      | _ -> None
    with _ -> None

(* Resolve the session-dir for a given session-id, anchored to cwd. *)
let session_dir_for ~cwd ~session_id =
  let wh = workspace_hash_for_path cwd in
  kimi_sessions_root () // wh // session_id

(* ─── Notification ID + writer ───────────────────────────────────────────── *)

(* Stable notification id: 12 lowercase-hex chars (within kimi's
   ^[a-z0-9]{2,20}$ validator) derived from the broker message identity.
   Same broker message → same id → kimi de-dupes via dedupe_key. *)
let notification_id_for_msg ~from_alias ~ts ~content =
  let key = Printf.sprintf "%s|%.6f|%s" from_alias ts content in
  let digest = Digest.to_hex (Digest.string key) in
  String.sub digest 0 12

let json_string s =
  (* Escape to a valid JSON string literal. We use yojson if available;
     fall back to a minimal escaper for the small set we emit. *)
  Yojson.Safe.to_string (`String s)

let now () = Unix.gettimeofday ()

(* prctl(PR_SET_NAME, ...) binding — rename the calling thread's "comm"
   field (visible in `ps`, `/proc/<pid>/comm`). Linux-only; no-op on
   other platforms. Implementation in [ocaml/c2c_posix_stubs.c]. *)
external set_proc_name : string -> unit = "caml_c2c_set_proc_name"

(* Atomic write: write to .tmp, fsync, close, then rename.
   The explicit fsync before rename ensures the temp-file's data
   blocks are durably on disk before the directory entry is updated;
   without it, on some filesystems a crash between rename + flush
   leaves a zero-length destination file. The [try/with] is for
   portability — some filesystems return EINVAL for fsync on small
   tmp files; the atomic-rename guarantee is preserved either way. *)
let atomic_write_string path content =
  let dir = Filename.dirname path in
  let tmp = Filename.temp_file ~temp_dir:dir "c2c-notif-" ".tmp" in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> try close_out oc with _ -> ())
    (fun () ->
      output_string oc content;
      flush oc;
      let fd = Unix.descr_of_out_channel oc in
      try Unix.fsync fd with _ -> ());
  Unix.rename tmp path

(* [mkdir_p] is canonical (#388): delegates to C2c_io.mkdir_p *)
let mkdir_p = C2c_io.mkdir_p

(* System events (peer-register, room-join broadcasts) are operator-
   visibility signals from c2c-system, NOT user-turn input. If we route
   them through the kimi notification-store llm sink, kimi reads them as
   if a user typed them — causing identity-confusion (e.g. "<alias>
   joined swarm-lounge" makes kimi think it just registered as <alias>).
   Filter at the writer so every entry path (run_once, future callers)
   gets the guard for free. See #475. *)
let is_system_event ~from_alias = from_alias = "c2c-system"

(* [#490 slice 5c] Approval-token DM filter.
   The legacy slice-1 verdict path was `c2c send <kimi> "<TOKEN> allow"`,
   which lands in kimi's broker inbox + gets drained by this notifier
   daemon. With the slice-5a verdict-file side-channel as the canonical
   reply path, those legacy DMs are noise: they don't drive the hook
   (await-reply reads the verdict file first), and pushing them as
   notification-store entries / chat-log lines clutters operator
   scrollback with structured-control-traffic.

   This predicate matches bodies of shape `^\s*ka_<id>\s+(allow|deny)\b`
   (case-insensitive on the verdict word). When true, the notifier
   skips chat-log + notification + wake. The message stays drained
   (broker-side inbox is consumed) which is fine — the hook is not
   waiting on inbox-DMs in the new architecture; it watches the
   verdict file. *)
let is_approval_verdict_body body =
  let s = String.trim body in
  let len = String.length s in
  if len < 5 then false
  else if not (String.length s >= 3 && String.sub s 0 3 = "ka_") then false
  else
    (* Walk past the token: alnum / underscore / dot / hyphen. *)
    let rec scan_tok i =
      if i >= len then i
      else
        match s.[i] with
        | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '.' | '-' -> scan_tok (i + 1)
        | _ -> i
    in
    let after_tok = scan_tok 0 in
    if after_tok = 0 || after_tok >= len then false
    else
      (* Require at least one whitespace separator. *)
      let rec skip_ws i =
        if i >= len then i
        else
          match s.[i] with
          | ' ' | '\t' -> skip_ws (i + 1)
          | _ -> i
      in
      let verdict_start = skip_ws after_tok in
      if verdict_start = after_tok then false
      else
        let remain = String.sub s verdict_start (len - verdict_start) in
        let lc = String.lowercase_ascii remain in
        let prefixed_with prefix =
          let pl = String.length prefix in
          String.length lc >= pl && String.sub lc 0 pl = prefix
        in
        prefixed_with "allow" || prefixed_with "deny"

(* ISO-8601 UTC timestamp for the sidecar log, e.g. 2026-04-29T12:34:56Z *)
let iso8601_utc () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

(* Append a human-readable entry to the session's c2c-chat-log.md.
   This is the operator scrollback — it logs EVERYTHING including system
   events, so a human inspecting tail -f sees the full swarm traffic.
   Idempotent on retry: duplicate appends are visible but harmless. *)
let write_chat_log ~session_dir ~from_alias ~body =
  let path = session_dir // "c2c-chat-log.md" in
  let ts = iso8601_utc () in
  (* Indent multi-line bodies so they read cleanly in tail -f. *)
  let indented_body =
    let lines = String.split_on_char '\n' body in
    match lines with
    | [] -> ""
    | [single] -> single
    | first :: rest ->
      first ^ "\n" ^ String.concat "\n" (List.map (fun l -> "    " ^ l) rest)
  in
  let entry = Printf.sprintf "[%s] FROM %s: %s\n\n" ts from_alias indented_body in
  let fd =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o644
  in
  Fun.protect ~finally:(fun () -> Unix.close fd)
    (fun () ->
       let (_ : int) = Unix.write_substring fd entry 0 (String.length entry) in
       ())

let write_notification
    ~session_dir
    ~notification_id
    ~from_alias
    ~body =
  if is_system_event ~from_alias then begin
    Printf.eprintf
      "[kimi-notifier] skip system event from %s (#475 identity-confusion guard): %s\n%!"
      from_alias
      (if String.length body > 60 then String.sub body 0 60 ^ "..." else body);
    ()
  end else
  let ndir = session_dir // "notifications" // notification_id in
  mkdir_p ndir;
  let event_path = ndir // "event.json" in
  let delivery_path = ndir // "delivery.json" in
  let ts = now () in
  let event_json =
    Printf.sprintf
      "{\"version\":1,\"id\":%s,\"category\":\"agent\",\
       \"type\":\"c2c-dm\",\"source_kind\":%s,\"source_id\":%s,\
       \"title\":%s,\"body\":%s,\"severity\":\"info\",\
       \"created_at\":%.6f,\"payload\":{},\
       \"targets\":[\"llm\",\"shell\"],\"dedupe_key\":%s}"
      (json_string notification_id)
      (json_string from_alias)
      (json_string from_alias)
      (json_string (Printf.sprintf "c2c DM from %s" from_alias))
      (json_string body)
      ts
      (json_string notification_id)
  in
  let delivery_json =
    "{\"sinks\":{\
       \"llm\":{\"status\":\"pending\",\"claimed_at\":null,\"acked_at\":null},\
       \"shell\":{\"status\":\"pending\",\"claimed_at\":null,\"acked_at\":null}\
     }}"
  in
  atomic_write_string event_path event_json;
  atomic_write_string delivery_path delivery_json

(* ─── Tmux idle detection + wake ─────────────────────────────────────────── *)

(* Capture last few lines of pane scrollback. Empty/None on failure. *)
let tmux_capture_tail ~pane =
  let cmd = Printf.sprintf "tmux capture-pane -t %s -p 2>/dev/null | tail -8"
              (Filename.quote pane) in
  try
    let ic = Unix.open_process_in cmd in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () ->
        let buf = Buffer.create 512 in
        (try
           while true do Buffer.add_string buf (input_line ic); Buffer.add_char buf '\n' done
         with End_of_file -> ());
        Buffer.contents buf)
  with _ -> ""

(* Heuristic: kimi at idle shows the "── input ──" divider + an empty input
   area + status line, NO "Thinking..." spinner, NO "Tool:" indicator.
   When the regex doesn't match cleanly we ASSUME idle (per coord
   guidance — better to fire one extra wake than to silently miss). *)
let tmux_pane_is_idle ~pane =
  let tail = tmux_capture_tail ~pane in
  if tail = "" then true  (* no info → assume idle, send wake *)
  else
    let busy_markers = [ "Thinking"; "Tool:"; "elapsed_steps="; "permission" ] in
    not (List.exists
           (fun marker ->
             try ignore (Str.search_forward (Str.regexp_string marker) tail 0); true
             with Not_found -> false)
           busy_markers)

let tmux_wake ~pane =
  let cmd = Printf.sprintf
    "tmux send-keys -t %s '[c2c] check inbox' Enter 2>/dev/null"
    (Filename.quote pane) in
  ignore (Sys.command cmd)

(* ─── Inbox write-back helpers (mirrors Broker.save_inbox locking) ──────────── *)

(* Inline message JSON serialization to avoid depending on un-exposed internals.
   Must match the schema Broker.save_inbox writes. *)
let message_to_json (msg : C2c_mcp.message) =
  let base =
    [ ("from_alias", `String msg.from_alias)
    ; ("to_alias", `String msg.to_alias)
    ; ("content", `String msg.content)
    ; ("ts", `Float msg.ts)
    ]
  in
  let with_deferrable = if msg.deferrable then base @ [("deferrable", `Bool true)] else base in
  let with_ephemeral = if msg.ephemeral then with_deferrable @ [("ephemeral", `Bool true)] else with_deferrable in
  let with_reply_via = match msg.reply_via with None -> with_ephemeral | Some rv -> with_ephemeral @ [("reply_via", `String rv)] in
  let with_msg_id = match msg.message_id with None -> with_reply_via | Some mid -> with_reply_via @ [("message_id", `String mid)] in
  match msg.enc_status with
  | None -> `Assoc with_msg_id
  | Some es -> `Assoc (with_msg_id @ [("enc_status", `String es)])

(* Replicate the broker's atomic-write-to-tmp+rename pattern for the inbox file.
   We write back only the messages we want to keep (skipped ones) without
   depending on un-exposed Broker internals. Lock path and file layout match
   what Broker uses: <broker_root>/<session_id>.inbox.json with
   <broker_root>/<session_id>.inbox.lock for the fcntl lock. *)
let write_inbox_file ~broker_root ~session_id messages =
  let path = Filename.concat broker_root (session_id ^ ".inbox.json") in
  let lock_path = Filename.concat broker_root (session_id ^ ".inbox.lock") in
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let fd =
    Unix.openfile lock_path [ Unix.O_RDWR; Unix.O_CREAT ] 0o644
  in
  Fun.protect
    ~finally:(fun () ->
      try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ();
      try Unix.close fd with _ -> ())
    (fun () ->
       Unix.lockf fd Unix.F_LOCK 0;
       let oc =
         open_out_gen
           [ Open_wronly; Open_creat; Open_trunc; Open_text ]
           0o600 tmp
       in
       Fun.protect
         ~finally:(fun () -> try close_out oc with _ -> ())
         (fun () ->
            let json = `List (List.map message_to_json messages) in
            Yojson.Safe.to_channel oc json);
       (* Atomic rename — same guarantee as Broker.write_json_file. *)
       Unix.rename tmp path)

(* ─── Drain + deliver loop ───────────────────────────────────────────────── *)

(* [#484 S1] Eliminate the inbox-drain race that was starving await-reply.
   Previously run_once called Broker.drain_inbox which REMOVED every message
   from the broker inbox before await-reply could see it — a race the notifier
   won every time, causing approval-verdict DMs to vanish.
   Fix:
   1. read_inbox (peek, no side effects)
   2. Partition: to_deliver (non-system), to_skip (system events)
   3. Deliver to_deliver to kimi; track which deliveries succeeded
   4. write_inbox_file: write back to_skip + any to_deliver that failed delivery
      This means approval verdicts stay in the broker inbox if kimi delivery
      failed or session dir is missing — await-reply can still find them.
   5. Return count of successful kimi deliveries (for logging). *)

let run_once ~broker_root ~alias ~session_id ~tmux_pane =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let drain_sid = if session_id = "" then alias else session_id in
  (* Peek: read messages without draining them from the broker inbox. *)
  let all_messages = C2c_mcp.Broker.read_inbox broker ~session_id:drain_sid in
  match all_messages with
  | [] -> 0
  | _ ->
    (* Resolve the kimi session-dir. *)
    let cwd = Sys.getcwd () in
    let session_dir_opt =
      match read_session_id_from_config alias with
      | Some sid -> Some (session_dir_for ~cwd ~session_id:sid)
      | None -> None
    in
    (* Partition: to_deliver = non-system (deliver to kimi), to_skip = system events. *)
    let to_deliver, to_skip =
      List.partition
        (fun (msg : C2c_mcp.message) -> not (is_system_event ~from_alias:msg.from_alias))
        all_messages
    in
    (* Log skipped system events to chat-log for operator scrollback. *)
    List.iter
      (fun (msg : C2c_mcp.message) ->
        (try
           match session_dir_opt with
           | Some sdir -> write_chat_log ~session_dir:sdir ~from_alias:msg.from_alias ~body:msg.content
           | None -> ()
         with exn ->
           Printf.eprintf "[kimi-notifier] chat-log write failed: %s\n%!"
             (Printexc.to_string exn)))
      to_skip;
    (* Attempt delivery of non-system messages. Track what actually landed. *)
    let delivered, undelivered = ref [], ref [] in
    List.iter
      (fun (msg : C2c_mcp.message) ->
        let from_alias = msg.from_alias in
        let body = msg.content in
        let ts = msg.ts in
        let nid = notification_id_for_msg ~from_alias ~ts ~content:body in
        match session_dir_opt with
        | Some sdir ->
          (* Sidecar chat-log for all messages. *)
          (try write_chat_log ~session_dir:sdir ~from_alias ~body
           with exn ->
             Printf.eprintf "[kimi-notifier] chat-log write failed: %s\n%!"
               (Printexc.to_string exn));
          (* JSON notification store: skip system events (#475 identity-confusion guard). *)
          (try write_notification ~session_dir:sdir ~notification_id:nid
                 ~from_alias ~body;
           delivered := msg :: !delivered
           with exn ->
             Printf.eprintf "[kimi-notifier] write failed: %s\n%!"
               (Printexc.to_string exn);
           undelivered := msg :: !undelivered)
        | None ->
          undelivered := msg :: !undelivered;
          Printf.eprintf
            "[kimi-notifier] no kimi session-id resolved; message archived but undelivered\n%!")
      to_deliver;
    (* Write back to_skip (system events) + any undelivered non-system messages.
       This keeps approval verdicts in the broker inbox if kimi delivery failed —
       await-reply will find them on the next poll. *)
    let to_keep = to_skip @ !undelivered in
    write_inbox_file ~broker_root ~session_id:drain_sid to_keep;
    let n = List.length !delivered in
    (* Wake pane if idle and something was delivered. *)
    (match tmux_pane with
     | Some pane when session_dir_opt <> None && n > 0 ->
       if tmux_pane_is_idle ~pane then tmux_wake ~pane
     | _ -> ());
    n

(* ─── Daemon shell (fork + setsid + loop) ────────────────────────────────── *)

let read_pid path =
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let line = String.trim (input_line ic) in
          Some (int_of_string line))
    with _ -> None

let pid_is_alive pid =
  try Unix.kill pid 0; true
  with Unix.Unix_error _ -> false

let already_running alias =
  match read_pid (pidfile_path alias) with
  | Some p when pid_is_alive p -> true
  | _ -> false

let start_daemon ~alias ~broker_root ~session_id ~tmux_pane ?(interval=2.0) () =
  if already_running alias then None
  else begin
    let _state_dir = ensure_state_dir () in
    let pidfile = pidfile_path alias in
    let logfile = logfile_path alias in
    match Unix.fork () with
    | 0 ->
      ignore (Unix.setsid ());
      (* Rename our "comm" field so `ps` / `/proc/<pid>/comm` distinguish
         the daemon from the c2c-start wrapper that forked it. PR_SET_NAME
         truncates to 16 bytes including NUL ("c2c-kimi-notifier" is 17
         chars but kernel will truncate safely). #469. *)
      (try set_proc_name "c2c-kimi-notif" with _ -> ());
      let log_fd =
        Unix.openfile logfile
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644
      in
      Unix.dup2 log_fd Unix.stdout;
      Unix.dup2 log_fd Unix.stderr;
      Unix.close log_fd;
      let pid = Unix.getpid () in
      let oc = open_out pidfile in
      Printf.fprintf oc "%d\n" pid; close_out oc;
      while true do
        (try
           let n = run_once ~broker_root ~alias ~session_id ~tmux_pane in
           if n > 0 then
             Printf.printf "[kimi-notifier] delivered %d message(s)\n%!" n
         with exn ->
           Printf.printf "[kimi-notifier] error: %s\n%!" (Printexc.to_string exn));
        Unix.sleepf interval
      done;
      exit 0
    | child_pid ->
      (* Brief wait for pidfile to appear, then return. *)
      let deadline = Unix.gettimeofday () +. 3.0 in
      let rec wait () =
        if Unix.gettimeofday () < deadline then begin
          if Sys.file_exists pidfile && read_pid pidfile <> None then ()
          else begin Unix.sleepf 0.05; wait () end
        end
      in
      wait ();
      ignore (Unix.waitpid [ Unix.WNOHANG ] child_pid);
      Some child_pid
  end

let stop_daemon ~alias =
  match read_pid (pidfile_path alias) with
  | None -> ()
  | Some pid ->
    if pid_is_alive pid then begin
      (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
      let deadline = Unix.gettimeofday () +. 3.0 in
      let rec wait () =
        if not (pid_is_alive pid) then ()
        else if Unix.gettimeofday () < deadline then begin
          Unix.sleepf 0.1; wait ()
        end else
          (try Unix.kill pid Sys.sigkill with _ -> ())
      in
      wait ()
    end;
    (try Sys.remove (pidfile_path alias) with _ -> ())
