(* c2c_kimi_notifier.ml — push c2c broker DMs into a managed kimi instance via
   Kimi Code's local REST prompt endpoint. Replaces both the legacy file-based
   notification store and c2c-kimi-wire-bridge.

   See c2c_kimi_notifier.mli for the architecture overview. *)

let home () =
  match Sys.getenv_opt "HOME" with
  | Some h -> h
  | None -> "/tmp"

let ( // ) = Filename.concat

open Lwt.Infix

(* ─── Constants + path helpers ───────────────────────────────────────────── *)

(* Kimi Code's share-dir resolution mirrors share.py:
     get_share_dir = $KIMI_SHARE_DIR or ~/.kimi-code *)
let kimi_share_dir () =
  match Sys.getenv_opt "KIMI_SHARE_DIR" with
  | Some d when d <> "" -> d
  | _ -> home () // ".kimi-code"

let kimi_log_path () = kimi_share_dir () // "logs" // "kimi.log"

let pidfile_path alias =
  home () // ".local" // "share" // "c2c" // "kimi-notifiers" // (alias ^ ".pid")

let logfile_path alias =
  home () // ".local" // "share" // "c2c" // "kimi-notifiers" // (alias ^ ".log")

(* #9 B: the session_id a running notifier is BOUND to. Notifier state is
   alias-keyed (every lifecycle caller — SessionEnd, `c2c stop`, the managed
   supervisor — knows only the alias) while broker inboxes are session-id
   keyed. That asymmetry is why a daemon could sit on the wrong inbox: the
   alias-keyed pidfile made ensure_daemon dedup a mis-keyed daemon as "ours".
   Recording the binding next to the pidfile makes the mismatch detectable so
   ensure_daemon can re-key it, rather than fragmenting the state key. *)
let session_file_path alias =
  home () // ".local" // "share" // "c2c" // "kimi-notifiers" // (alias ^ ".sid")

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

(* Resolve the session-dir for a given session-id by looking it up in
   ~/.kimi-code/session_index.jsonl.  This is more reliable than recomputing
   Kimi Code's workspace-hash scheme, which uses a `wd_<name>_<hash>` prefix
   rather than the raw md5 of the path. *)
let session_dir_for ~cwd ~session_id =
  ignore cwd;
  C2c_kimi_deliver.session_dir_for_session_id ~session_id

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

(* ISO-8601 UTC timestamp for the sidecar log, e.g. 2026-04-29T12:34:56Z *)
let iso8601_utc () = C2c_time.iso8601_utc (Unix.gettimeofday ())

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
    ~to_alias
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
  let is_room = C2c_mcp.is_room_recipient ~to_alias in
  (* kimi renders [title] as raw XML text inside <notification>, whereas it
     applies escapeXmlAttr to source_kind/source_id itself. Escape only title
     interpolations here (pre-escaping the attribute fields would double
     escape them). Keep the peer-authored body byte-for-byte unchanged. *)
  let xml_text = C2c_mcp.xml_escape in
  let recipient = to_alias |> C2c_mcp.recipient_identity |> xml_text in
  let safe_from = xml_text from_alias in
  let event_type, title =
    if is_room then
      let room_id =
        match String.index_opt to_alias '#' with
        | Some i -> String.sub to_alias (i + 1) (String.length to_alias - i - 1)
        | None -> "<room id>"
      in
      ( "c2c-room",
        Printf.sprintf
          "c2c: your alias is %s; room message from %s; reply via c2c_send_room(room_id=\"%s\")"
          recipient safe_from (xml_text room_id) )
    else
      ( "c2c-dm",
        Printf.sprintf
          "c2c: your alias is %s; direct message from %s; reply via c2c_send(to_alias=\"%s\")"
          recipient safe_from safe_from )
  in
  let event_json =
    Printf.sprintf
      "{\"version\":1,\"id\":%s,\"category\":\"agent\",\
       \"type\":%s,\"source_kind\":%s,\"source_id\":%s,\
       \"title\":%s,\"body\":%s,\"severity\":\"info\",\
       \"created_at\":%.6f,\"payload\":{},\
       \"targets\":[\"llm\",\"shell\"],\"dedupe_key\":%s}"
      (json_string notification_id)
      (json_string event_type)
      (json_string from_alias)
      (json_string from_alias)
      (json_string title)
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

(* Check whether the Kimi server is reachable on its discovered base URL. *)
let kimi_server_is_responding () =
  match C2c_kimi_deliver.server_base_url () with
  | None -> false
  | Some base ->
      let url = base ^ "/api/v1/healthz" in
      let uri = Uri.of_string url in
      (match C2c_kimi_deliver.read_server_token () with
       | None -> false
       | Some token ->
           let headers =
             Cohttp.Header.of_list [ "Authorization", "Bearer " ^ token ]
           in
           try
             Lwt_main.run (
               Cohttp_lwt_unix.Client.get ~headers uri
               >>= fun (resp, _body) ->
               let code =
                 Cohttp.Code.code_of_status (Cohttp.Response.status resp)
               in
               Lwt.return (code = 200))
           with _ -> false)

(* #39: consecutive failed start attempts, and the earliest time we are willing
   to try `kimi server run` again. Before #39 this path re-spawned + waited 10s
   on every poll (~every 2s) against an address it had never validated, so a
   stale-port resolution produced an identical ECONNREFUSED line forever with
   no actionable signal. *)
let ensure_failures = ref 0
let next_start_attempt = ref 0.0

(* Escalating backoff so a persistently unreachable server costs one attempt
   per 10s → 20s → … → 5min instead of one per poll. *)
let start_backoff_s n =
  let base = 10.0 *. (2.0 ** float_of_int (max 0 (n - 1))) in
  if base > 300.0 then 300.0 else base

(* Threshold at which the log line changes from "transient" to "actionable" —
   past this, retrying is not going to fix it and the operator needs to know
   WHICH address we are failing against. *)
let ensure_failures_actionable = 3

(* Start the Kimi server if it is not already running.  The command is
   idempotent: if a server is already bound it prints the existing URL and
   exits.  We only start a real server outside of fixture/test mode.

   Non-fatal by construction: on any failure we simply return, delivery reports
   an error, and the message stays in the broker inbox for the next poll. Each
   call re-resolves the base URL via [C2c_kimi_deliver.server_base_url] rather
   than reusing a cached address, so a server that moved ports is picked up on
   the next attempt (#39). *)
let ensure_kimi_server_running () =
  if C2c_kimi_deliver.fixture_enabled () then ()
  else if kimi_server_is_responding () then begin
    if !ensure_failures > 0 then
      Printf.eprintf "[kimi-notifier] Kimi server reachable again at %s\n%!"
        (Option.value ~default:"(unknown)" (C2c_kimi_deliver.server_base_url ()));
    ensure_failures := 0;
    next_start_attempt := 0.0
  end
  else begin
    let now = Unix.gettimeofday () in
    if now < !next_start_attempt then
      (* Backing off: do not spawn another server, do not block the poll loop.
         Delivery will fail cleanly and the message stays queued. *)
      ()
    else begin
      let base =
        Option.value ~default:"(unresolved)" (C2c_kimi_deliver.server_base_url ())
      in
      Printf.eprintf
        "[kimi-notifier] Kimi server not responding at %s; starting it...\n%!" base;
      let cmd = "kimi server run --keep-alive >/dev/null 2>&1" in
      ignore (Unix.system cmd);
      let deadline = Unix.gettimeofday () +. 10.0 in
      let rec wait () =
        if kimi_server_is_responding () then true
        else if Unix.gettimeofday () > deadline then false
        else (
          Unix.sleepf 0.2;
          wait ())
      in
      if wait () then begin
        ensure_failures := 0;
        next_start_attempt := 0.0
      end
      else begin
        incr ensure_failures;
        let n = !ensure_failures in
        let backoff = start_backoff_s n in
        next_start_attempt := Unix.gettimeofday () +. backoff;
        if n >= ensure_failures_actionable then
          Printf.eprintf
            "[kimi-notifier] Kimi server still unreachable at %s after %d \
             attempts. c2c resolved that address from kimi's server lock \
             (%s), $C2C_KIMI_SERVER_PORT, or the server.log record. Check the \
             real port with `ss -ltnp | grep kimi` and export \
             C2C_KIMI_SERVER_PORT=<port> if it disagrees. Mail stays queued; \
             retrying in %.0fs.\n%!"
            base n (C2c_kimi_deliver.server_lock_path ()) backoff
        else
          Printf.eprintf
            "[kimi-notifier] timed out waiting for Kimi server at %s \
             (attempt %d); retrying in %.0fs\n%!"
            base n backoff
      end
    end
  end

(* ─── #41: authoritative kimi-session record ─────────────────────────────── *)

(* THE #41 BUG. [session_id_for_workdir] answers "newest entry in
   ~/.kimi-code/session_index.jsonl for this workdir". kimi-code appends the
   NEW session's line only AFTER its SessionStart hooks have run, so every
   resolver that fires at or near session start reads an index in which the
   newest entry is the PREVIOUS session. Measured live (#41): TUI session
   275f8dcb resolved to f4fac83d; TUI 0baa88d1 resolved to 275f8dcb. The
   notifier then POSTs the session's mail into a DEAD sibling session.

   The index cannot be made to answer this — it is a lagging log. But kimi
   itself names the session in the SessionStart hook payload, which is
   authoritative and arrives at exactly the moment the index is still stale.
   So the kimi SessionStart hook records it here, keyed by WORKSPACE (not
   alias) because REST delivery is workdir-keyed (#36): one machine-wide
   watcher serves many sessions and must look the sid up per workdir.

   Deliberately NOT the same thing as [session_file_path] (<alias>.sid): that
   records which BROKER INBOX the daemon drains (since #40 the instance name),
   whereas this records the REAL kimi session id used as the REST path
   component. Conflating them is what #40's notes warn against. *)
let kimi_session_record_path ~workdir =
  home () // ".local" // "share" // "c2c" // "kimi-sessions"
  // (workspace_hash_for_path workdir ^ ".json")

let ensure_kimi_session_record_dir () =
  let d = home () // ".local" // "share" // "c2c" // "kimi-sessions" in
  (try Unix.mkdir (home () // ".local") 0o755 with Unix.Unix_error _ -> ());
  (try Unix.mkdir (home () // ".local" // "share") 0o755 with Unix.Unix_error _ -> ());
  (try Unix.mkdir (home () // ".local" // "share" // "c2c") 0o755 with Unix.Unix_error _ -> ());
  (try Unix.mkdir d 0o755 with Unix.Unix_error _ -> ());
  d

(* Best-effort: a failed record simply falls back to index resolution. *)
let record_kimi_session_id ~workdir ~session_id =
  if String.trim workdir = "" || String.trim session_id = "" then ()
  else
    try
      ignore (ensure_kimi_session_record_dir ());
      let json =
        `Assoc
          [ ("session_id", `String session_id)
          ; ("workdir", `String workdir)
          ; ("ts", `Float (Unix.gettimeofday ())) ]
      in
      atomic_write_string (kimi_session_record_path ~workdir)
        (Yojson.Safe.to_string json)
    with _ -> ()

let read_kimi_session_record ~workdir =
  let path = kimi_session_record_path ~workdir in
  if not (Sys.file_exists path) then None
  else
    try
      let json = Yojson.Safe.from_file path in
      let open Yojson.Safe.Util in
      match
        (json |> member "session_id" |> to_string_option,
         json |> member "workdir" |> to_string_option)
      with
      | Some sid, Some wd when String.trim sid <> "" && wd = workdir -> Some sid
      | _ -> None
    with _ -> None

(* Only clear the record if it still names [session_id] — a SessionEnd for an
   older session must never delete the live session's binding. *)
let clear_kimi_session_record ~workdir ~session_id =
  match read_kimi_session_record ~workdir with
  | Some sid when sid = session_id ->
      (try Sys.remove (kimi_session_record_path ~workdir) with _ -> ())
  | _ -> ()

(* Pure decision, exposed for unit tests.

   [index_matches] is [session_ids_for_workdir] output: file-append order, so
   the last element is the newest session kimi has recorded for the workspace.

   - No record → the index's newest match (pre-#41 behaviour).
   - Record present and ABSENT from the index → trust it. This is the #41 case:
     the hook has told us the sid before kimi appended its line.
   - Record present and IS the newest index match → trust it (same answer).
   - Record present but SUPERSEDED (present in the index with a newer sibling
     after it) → the record is stale, e.g. a session that ended without its
     SessionEnd hook firing. The index has moved on; follow it. This is what
     stops the fix from turning a lagging binding into a sticky wrong one. *)
let decide_kimi_session_id ~recorded ~index_matches =
  let newest = match List.rev index_matches with x :: _ -> Some x | [] -> None in
  match recorded with
  | None -> newest
  | Some sid ->
      if List.mem sid index_matches && newest <> Some sid then newest
      else Some sid

(* #41 direction 3, process-wide. The per-alias notifier daemon arms at (or
   just before) its session's start, so its own start time is the best
   available "this session began no earlier than" bound — anything already in
   session_index.jsonl with an older sessionDir belongs to a PREVIOUS session.

   A ref rather than a parameter because the value belongs to the PROCESS, not
   the call: the only thing that can name it is the daemon's own entry point,
   and it would otherwise have to be threaded through run_once /
   poll_once_global / deliver_via_rest purely as pass-through. 0.0 = unset,
   which is correct for every other caller — notably the machine-wide watcher
   (c2c-deliver-inbox), which serves many sessions of many ages and has no
   single session start to speak of. *)
let session_freshness_floor = ref 0.0

let set_session_freshness_floor t = session_freshness_floor := t

(* Resolve the Kimi session id for [cwd]. Prefers the sid kimi itself reported
   through its SessionStart hook (#41 direction 1); falls back to the
   session_index.

   [?not_before] applies the index freshness guard (#41 direction 3) as a
   PREFERENCE, not a hard reject: if it eliminates every candidate we retry
   unfiltered. Failing closed here would park mail indefinitely for any session
   whose sessionDir mtime cannot be corroborated (a `--rearm` onto a
   long-running session, an exotic KIMI_SHARE_DIR layout), and a wedged inbox
   is a worse failure than the wrong-session delivery the authoritative record
   already prevents. *)
let resolve_kimi_session_id ?not_before ~cwd () =
  let not_before =
    match not_before with
    | Some _ as t -> t
    | None -> if !session_freshness_floor > 0.0 then Some !session_freshness_floor else None
  in
  let index_matches =
    match not_before with
    | None -> C2c_kimi_deliver.session_ids_for_workdir ~workdir:cwd ()
    | Some t -> (
        match C2c_kimi_deliver.session_ids_for_workdir ~workdir:cwd ~not_before:t () with
        | [] -> C2c_kimi_deliver.session_ids_for_workdir ~workdir:cwd ()
        | fresh -> fresh)
  in
  decide_kimi_session_id
    ~recorded:(read_kimi_session_record ~workdir:cwd)
    ~index_matches

(* REST prompt delivery seam.  Discovers the Kimi session id for [workdir],
   ensures the local server is running, and POSTs the message as a user
   prompt.  Messages stay in the broker inbox if delivery fails so the next
   poll can retry.

   [workdir] is the Kimi *workspace* directory of the target session — the key
   used to resolve the session id from ~/.kimi-code/session_index.jsonl.  It is
   an explicit parameter (never [Sys.getcwd ()] read from inside, #36) so a
   single machine-wide watcher process, which has exactly one cwd and may
   [chdir "/"], can deliver to many sessions. *)
let deliver_via_rest ~alias ~msg ~workdir () =
  ensure_kimi_server_running ();
  match resolve_kimi_session_id ~cwd:workdir () with
  | None ->
      Error (Printf.sprintf "no Kimi session for workdir %s" workdir)
  | Some session_id -> C2c_kimi_deliver.deliver_message ~session_id ~msg

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

(* Statefile-based idle detection (#590).
   Kimi-cli writes <session_dir>/wire.jsonl on every TurnBegin/Step/Tool/Done
   event. If the mtime is older than threshold_s, the agent loop is quiescent.
   Falls "idle" when no wire file exists yet (fresh session, never busy). *)
let kimi_session_is_idle ~session_dir ~now ~threshold_s =
  let wire = Filename.concat session_dir "wire.jsonl" in
  match (try Some (Unix.stat wire).Unix.st_mtime with _ -> None) with
  | None -> true  (* no wire file → not actively writing → idle *)
  | Some mtime -> now -. mtime > threshold_s

(* Detect whether our previous wake-text is still sitting in the input box,
   not yet submitted. If so, firing another wake just stacks more text on
   top — visible footgun lumi-test/tyyni-test hit 2026-05-01.
   Greps for "[c2c] check inbox" in the bottom 4 lines of the captured pane
   tail (where the kimi input box lives, after the "── input ──" divider). *)
let tmux_pane_has_pending_wake ~pane =
  let tail = tmux_capture_tail ~pane in
  if tail = "" then false
  else
    (* Pull the bottom 4 lines (input-box region) out of the captured tail. *)
    let lines = String.split_on_char '\n' tail in
    let n = List.length lines in
    let bottom =
      if n <= 4 then lines
      else
        let rec drop k = function
          | _ :: rest when k > 0 -> drop (k - 1) rest
          | xs -> xs
        in
        drop (n - 4) lines
    in
    let region = String.concat "\n" bottom in
    try ignore (Str.search_forward (Str.regexp_string "[c2c] check inbox") region 0); true
    with Not_found -> false

(* Combined idle check: (a) busy-marker absence on the captured tail,
   (b) wire.jsonl mtime older than threshold (default 2s), and
   (c) no pending [c2c] check inbox text already in the input box.
   All three must pass to fire a wake. Logs skip reasons to stderr so
   notifier.log shows when wakes were correctly suppressed.
   Falls "idle" if no session_dir is supplied (no statefile to consult)
   and falls back to the legacy busy-marker heuristic. *)
let tmux_pane_is_idle ~pane ?session_dir ?(now = Unix.gettimeofday ()) () =
  let tail = tmux_capture_tail ~pane in
  let busy_markers = [ "Thinking"; "Tool:"; "elapsed_steps="; "permission" ] in
  let busy_marker_present =
    if tail = "" then false
    else
      List.exists
        (fun marker ->
          try ignore (Str.search_forward (Str.regexp_string marker) tail 0); true
          with Not_found -> false)
        busy_markers
  in
  if busy_marker_present then begin
    Printf.eprintf "[kimi-notifier] skipping wake — busy marker on tail\n%!";
    false
  end else if tmux_pane_has_pending_wake ~pane then begin
    Printf.eprintf
      "[kimi-notifier] skipping wake — prior [c2c] check inbox still in input box\n%!";
    false
  end else
    match session_dir with
    | None -> true  (* no statefile → trust the marker check *)
    | Some sd ->
      if kimi_session_is_idle ~session_dir:sd ~now ~threshold_s:2.0 then true
      else begin
        Printf.eprintf
          "[kimi-notifier] skipping wake — wire.jsonl mtime < 2s ago (busy)\n%!";
        false
      end

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

(* [#484 S1] Peek before delivery so failed deliveries remain retryable.
   This originally also avoided a race with the now-removed inbox-DM approval
   fallback. Current approval resolution is host-local and file-only; retained
   peer messages are advisory data. Flow:
   1. read_inbox (peek, no side effects)
   2. Partition: to_deliver (non-system), to_skip (system events)
   3. Deliver to_deliver to kimi via REST prompt injection; track which
      deliveries succeeded.
   4. write_inbox_file: write back to_skip + any to_deliver that failed delivery
      This means undelivered advisory messages stay in the broker inbox if kimi
      delivery failed or the session dir is missing.
   5. Return count of successful kimi deliveries (for logging). *)

let run_once ~broker_root ~alias ~session_id ~tmux_pane ~workdir =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let drain_sid = if session_id = "" then alias else session_id in
  (* Peek: read messages without draining them from the broker inbox. *)
  let all_messages = C2c_mcp.Broker.read_inbox broker ~session_id:drain_sid in
  match all_messages with
  | [] -> 0
  | _ ->
    (* Resolve the kimi session-dir from the caller-supplied workdir (#36) —
       never from the process cwd, so a shared watcher can serve many sessions. *)
    let session_dir_opt =
      match resolve_kimi_session_id ~cwd:workdir () with
      | Some sid -> session_dir_for ~cwd:workdir ~session_id:sid
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
        (* Sidecar chat-log for all messages. *)
        (try
           match session_dir_opt with
           | Some sdir -> write_chat_log ~session_dir:sdir ~from_alias ~body
           | None -> ()
         with exn ->
           Printf.eprintf "[kimi-notifier] chat-log write failed: %s\n%!"
             (Printexc.to_string exn));
        (* REST prompt injection. System events are already partitioned out. *)
        try
          match deliver_via_rest ~alias ~msg ~workdir () with
          | Ok () -> delivered := msg :: !delivered
          | Error reason ->
              Printf.eprintf "[kimi-notifier] REST delivery failed: %s\n%!" reason;
              undelivered := msg :: !undelivered
        with exn ->
          Printf.eprintf "[kimi-notifier] delivery exception: %s\n%!"
            (Printexc.to_string exn);
          undelivered := msg :: !undelivered)
      to_deliver;
    (* Write back to_skip (system events) + any undelivered non-system messages
       so delivery can retry. await-reply never reads this inbox. *)
    let to_keep = to_skip @ !undelivered in
    write_inbox_file ~broker_root ~session_id:drain_sid to_keep;
    let n = List.length !delivered in
    (* Wake pane if idle and something was delivered.  The wake fires even
       when we have no session_dir (managed Kimi sessions have no predictable
       session id) because tmux_pane_is_idle falls back to the captured-pane
       heuristic when session_dir is absent. *)
    (match tmux_pane with
     | Some pane when n > 0 ->
       if tmux_pane_is_idle ~pane ?session_dir:session_dir_opt () then
         tmux_wake ~pane
     | _ -> ());
     n

(* ─── P4: global sessions broker drain ─────────────────────────────────────── *)

(* Check if a global session inbox exists for the given session_id. *)
let global_inbox_exists ~root ~session_id =
  Sys.file_exists (Filename.concat root (session_id ^ ".inbox.json"))

(* [#P4] Drain messages from the global sessions broker (C2C_SESSIONS_BROKER_ROOT)
   and deliver them via the Kimi REST prompt endpoint. This enables cross-client
   delivery: `c2c send --session <kimi-session-id>` reaches kimi sessions.

   Uses drain_inbox (destructive) since the global broker is separate from the
   per-repo broker — no risk of double-delivery.
   System events are logged to chat-log but not delivered to kimi. *)

let poll_once_global ~session_id ~alias ~tmux_pane ~workdir =
  if not (C2c_name.is_valid session_id) then 0
  else
  let sessions_root = C2c_repo_fp.resolve_sessions_broker_root () in
  if not (global_inbox_exists ~root:sessions_root ~session_id) then
    0
  else
    let broker = C2c_mcp.Broker.create ~root:sessions_root in
    let all_messages = C2c_mcp.Broker.drain_inbox ~drained_by:"kimi-notifier-global" broker ~session_id in
    match all_messages with
    | [] -> 0
    | _ ->
      (* Resolve the kimi session-dir for notification delivery, from the
         caller-supplied workdir (#36) rather than the process cwd. *)
      let session_dir_opt =
        match resolve_kimi_session_id ~cwd:workdir () with
        | Some sid -> session_dir_for ~cwd:workdir ~session_id:sid
        | None -> None
      in
      (* Partition: to_deliver = non-system, to_skip = system events. *)
      let to_deliver, to_skip =
        List.partition
          (fun (msg : C2c_mcp.message) -> not (is_system_event ~from_alias:msg.from_alias))
          all_messages
      in
      (* Log skipped system events to chat-log. *)
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
      (* Attempt delivery of non-system messages. *)
      let delivered, undelivered = ref [], ref [] in
      List.iter
        (fun (msg : C2c_mcp.message) ->
          let from_alias = msg.from_alias in
          let body = msg.content in
          (* Sidecar chat-log for all messages. *)
          (try
             match session_dir_opt with
             | Some sdir -> write_chat_log ~session_dir:sdir ~from_alias ~body
             | None -> ()
           with exn ->
             Printf.eprintf "[kimi-notifier] chat-log write failed: %s\n%!"
               (Printexc.to_string exn));
          (* REST prompt injection. System events are already partitioned out. *)
          try
            match deliver_via_rest ~alias ~msg ~workdir () with
            | Ok () -> delivered := msg :: !delivered
            | Error reason ->
                Printf.eprintf "[kimi-notifier] REST delivery failed: %s\n%!" reason;
                undelivered := msg :: !undelivered
          with exn ->
            Printf.eprintf "[kimi-notifier] delivery exception: %s\n%!"
              (Printexc.to_string exn);
            undelivered := msg :: !undelivered)
        to_deliver;
      (* Global broker drain is destructive — no write-back since the global broker
         is separate from the per-repo broker. Undleivered messages are logged but
         not recoverable without sender re-send. *)
      let n = List.length !delivered in
      (match tmux_pane with
       | Some pane when n > 0 ->
         if tmux_pane_is_idle ~pane ?session_dir:session_dir_opt () then
           tmux_wake ~pane
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

(* The daemon's "comm" as set by [start_daemon] via [set_proc_name]. This
   14-char string is under the kernel's TASK_COMM_LEN-1 (15-char) limit, so it
   is stored VERBATIM in [/proc/<pid>/comm] (the kernel appends a trailing
   newline that we trim). MUST stay byte-identical to the [set_proc_name]
   argument below — this is the identity token we match on to avoid signalling
   an unrelated same-UID process after PID reuse. *)
let notifier_comm = "c2c-kimi-notif"

(* Trimmed contents of [/proc/<pid>/comm], or [None] if unreadable. *)
let proc_comm pid =
  let path = Printf.sprintf "/proc/%d/comm" pid in
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> try close_in ic with _ -> ())
      (fun () -> Some (String.trim (input_line ic)))
  with _ -> None

(* Identity check (B145 PID-reuse guard): [pid] is *our* notifier only if it is
   alive AND its comm matches [notifier_comm]. Fail-CLOSED: an unreadable /proc
   or any mismatch → [false]. A stale pidfile whose pid was reused by an
   unrelated process must NEVER be treated as ours (else we'd SIGTERM/SIGKILL
   that process). Liveness alone is not identity. *)
let pid_is_our_notifier pid =
  pid_is_alive pid &&
  (match proc_comm pid with Some c -> c = notifier_comm | None -> false)

(* "our notifier is running" — liveness AND identity, not liveness alone. *)
let already_running alias =
  match read_pid (pidfile_path alias) with
  | Some p -> pid_is_our_notifier p
  | None -> false

let start_daemon ~alias ~broker_root ~session_id ~tmux_pane ?(interval=2.0) () =
  if already_running alias then None
  else begin
    (* Legacy workdir default (#36): the per-alias daemon is forked from the
       session's own process, so its inherited cwd IS that session's Kimi
       workspace dir. Snapshot it in the PARENT, before the fork, and pass it
       explicitly to [run_once] — the daemon then never re-reads the ambient
       cwd. A future machine-wide watcher supplies a per-session workdir
       instead of relying on inheritance. *)
    let workdir = try Sys.getcwd () with _ -> "." in
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
      (* #9 B: record the session binding BEFORE the pidfile, so any reader
         that observes a pidfile also observes the sid it is bound to. *)
      (try
         let soc = open_out (session_file_path alias) in
         Fun.protect ~finally:(fun () -> close_out soc)
           (fun () -> output_string soc (session_id ^ "\n"))
       with _ -> ());
      let oc = open_out pidfile in
      Printf.fprintf oc "%d\n" pid; close_out oc;
      let inbox_path = Filename.concat broker_root (session_id ^ ".inbox.json") in
      Printf.printf "[kimi-notifier] starting alias=%s session_id=%s broker_root=%s inbox=%s\n%!"
        alias session_id broker_root inbox_path;
      (* #41: the daemon arms at (or just before) session start, so its own
         start time is the best available "this session began no earlier than"
         bound for rejecting a PREVIOUS session's session_index entry. *)
      set_session_freshness_floor (Unix.gettimeofday ());
      while true do
        (try
           let n = run_once ~broker_root ~alias ~session_id ~tmux_pane ~workdir in
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
  (* Signal ONLY if the pidfile pid is confirmed to be our notifier (identity,
     not just liveness) — defense-in-depth so a stale-pidfile PID-reuse case
     never has us SIGTERM/SIGKILL an unrelated same-UID process. Either way the
     (now-stale) pidfile is removed. *)
  (match read_pid (pidfile_path alias) with
   | None -> ()
   | Some pid ->
     if pid_is_our_notifier pid then begin
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
     end);
  (try Sys.remove (pidfile_path alias) with _ -> ());
  (* #9 B: drop the session binding with the pidfile so a later ensure_daemon
     never compares against a dead daemon's sid. *)
  (try Sys.remove (session_file_path alias) with _ -> ())

(* ─── B145: upgrade-correctness (stale-binary detect + ensure_daemon) ──────

   The notifier is spawned fork+setsid DETACHED with its own pidfile and is
   deduped on startup via [already_running]. Before B145 this meant a notifier
   that outlived a [c2c restart] (its pid was untracked by the supervisor) kept
   running the OLD binary image indefinitely after [just install-all] — a
   fresh [c2c start] saw [already_running]=true and left the stale daemon be.

   Two-layer fix:
   1. The supervisor now tracks the notifier pid and tears it down on
      stop/restart (see c2c_start.ml) — so a clean restart cycles it onto the
      new binary.
   2. Belt-and-braces here: [ensure_daemon] compares the RUNNING notifier's
      binary SHA against the installed binary SHA and kills+respawns a stale
      one even on a bare [c2c start] with no clean stop. *)

type notifier_start_decision =
  | Start_fresh    (* nothing running → start a new daemon *)
  | Skip_current   (* running on the installed binary (or SHA undeterminable) → leave it *)
  | Respawn_stale  (* running on a DIFFERENT binary SHA → kill + respawn on the new binary *)

(* Pure decision function (unit-tested). Fail-SAFE: when either SHA cannot be
   determined we do NOT kill a working notifier — we [Skip_current], preserving
   pre-B145 behavior rather than risking a needless delivery gap. Only a
   confidently-observed SHA mismatch triggers a respawn. *)
let decide_notifier_start ~running ~running_sha ~installed_sha =
  if not running then Start_fresh
  else
    match running_sha, installed_sha with
    | Some r, Some i when r <> i -> Respawn_stale
    | _ -> Skip_current

(* Read the running notifier's binary SHA via [/proc/<pid>/exe]. Opening that
   magic symlink reads the ORIGINAL executable inode even after the on-disk
   file has been replaced by an upgrade (the inode outlives the path), which is
   exactly what we need to detect a stale-code daemon. Returns [None] when the
   process is gone or /proc is unreadable / SHA cannot be computed. *)
let running_binary_sha pid =
  let path = Printf.sprintf "/proc/%d/exe" pid in
  match C2c_mcp_helpers.best_effort_file_sha256 path with
  | "unknown" -> None
  | sha -> Some sha

(* SHA of the binary THIS process is running — i.e. the just-installed image a
   fresh notifier fork would execute. Read [/proc/self/exe] DIRECTLY (the magic
   symlink resolves to the running inode; robust even if the readlink path would
   carry a " (deleted)" suffix after an in-place replace). Falls back to the
   readlink'd path, then [None]. *)
let installed_binary_sha () =
  match C2c_mcp_helpers.best_effort_file_sha256 "/proc/self/exe" with
  | "unknown" ->
    (match
       C2c_mcp_helpers.best_effort_file_sha256
         (C2c_mcp_helpers.best_effort_server_executable ())
     with
     | "unknown" -> None
     | sha -> Some sha)
  | sha -> Some sha

(* Fixture hook (repo convention: external effects gated by env vars). When set,
   these override the SHA sources so tests can drive [ensure_daemon] through the
   Respawn_stale / Skip_current branches deterministically without a real
   upgrade. Unset in production. *)
let fixture_sha which =
  match Sys.getenv_opt ("C2C_KIMI_NOTIFIER_FIXTURE_" ^ which ^ "_SHA") with
  | Some s when String.trim s <> "" -> Some (String.trim s)
  | _ -> None

(* #9 B: the session_id the running notifier for [alias] is bound to, or
   [None] when unrecorded (a daemon started by a pre-#9 binary). *)
let running_session_id alias =
  let path = session_file_path alias in
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          match String.trim (input_line ic) with
          | "" -> None
          | s -> Some s)
    with _ -> None

(* #9 B: should ensure_daemon respawn a live notifier purely to re-key it onto
   a different session_id?

   The managed launcher (`c2c start kimi`) arms at t≈0, when NOTHING can yet
   name the real Kimi session id: the alias→real-sid broker registration is
   written later by the SessionStart hook running INSIDE the just-forked kimi
   process, and the session_index entry for the cwd does not exist yet. So it
   necessarily arms with the alias as a PLACEHOLDER sid. The hook then calls
   ensure_daemon with the REAL sid — which used to be a no-op (alias-keyed
   pidfile + matching binary SHA → Skip_current), stranding the daemon on an
   empty <alias>.inbox.json while mail piled up in <real-sid>.inbox.json.

   Rule: re-key iff the request names a sid that differs from what is running
   AND is not the alias placeholder. Refusing to "downgrade" back to the
   placeholder is what stops a later placeholder arm (e.g. a supervisor
   relaunch) from flapping a correctly-bound daemon back onto the alias.
   [running = None] is a pre-#9 daemon of unknown binding: bind it as soon as
   we have a real sid to bind. Pure; exposed for unit tests.

   [authoritative] (#40) breaks the "sid == alias means placeholder" overload.
   Since #40 the managed launcher registers session_id = the instance name and
   arms the notifier on it, so in the DEFAULT managed case
   (alias == name == session_id) the *authoritative* binding is byte-identical
   to what this function used to treat as a placeholder. Without the flag a
   leftover live notifier for the same alias bound to some other sid — after a
   SIGKILLed outer loop or a failed `c2c restart` teardown — would never
   converge onto <name>: it falls through to the stale-binary branch and
   Skip_current's on an unchanged binary, leaving the session deaf while
   `c2c send` reports success (i.e. #40's own symptom, re-introduced).
   Callers that KNOW the sid is a real binding rather than a t≈0 guess pass
   [~authoritative:true]; the placeholder guard is then skipped and only the
   "differs from what is running" test applies. Default [false] preserves the
   pre-#40 behaviour for every other caller. *)
let decide_notifier_rekey ~alias ~requested_sid ?(authoritative = false)
    ~running_sid () =
  (* Placeholder compare is case-insensitive, matching how aliases are
     compared everywhere else (alias comparisons are case-insensitive per
     B112, and pick_live_registration_sid matches the same way). *)
  if
    (not authoritative)
    && String.lowercase_ascii requested_sid = String.lowercase_ascii alias
  then false
  else match running_sid with
    | None -> true
    | Some cur -> cur <> requested_sid

let ensure_daemon ~alias ~broker_root ~session_id ?(authoritative = false)
    ~tmux_pane ?(interval = 2.0) () =
  let pidfile = pidfile_path alias in
  (* Identity gate FIRST (B145 PID-reuse guard). Treat the pidfile pid as the
     running notifier ONLY if it is alive AND comm-matches. A dead pid OR a
     live-but-reused (not-ours) pid means the pidfile is STALE: drop it (so
     start_daemon won't dedup against it) and take Start_fresh. We only ever
     read /proc/<pid>/exe or run Respawn_stale/stop_daemon on a CONFIRMED-ours
     pid — so we can never signal an unrelated process, and Skip_current can
     never hand a bogus/reused pid back up to the supervisor. *)
  let ours =
    match read_pid pidfile with
    | Some p when pid_is_our_notifier p -> Some p
    | Some _ -> (try Sys.remove pidfile with _ -> ()); None
    | None -> None
  in
  match ours with
  | None ->
    (* nothing of ours running (incl. a just-cleaned stale pidfile) → fresh *)
    start_daemon ~alias ~broker_root ~session_id ~tmux_pane ~interval ()
  | Some pid when
      decide_notifier_rekey ~alias ~requested_sid:session_id ~authoritative
        ~running_sid:(running_session_id alias) () ->
    (* #9 B: live daemon of ours, but bound to the WRONG session_id — it is
       draining an inbox no mail lands in. Re-key by cycling it onto the
       requested sid. [pid] is a CONFIRMED-ours notifier (identity-gated
       above), so stop_daemon can never signal an unrelated process. *)
    Printf.eprintf
      "[kimi-notifier] running daemon (pid %d) is bound to session %s; \
       re-keying onto %s\n%!"
      pid
      (match running_session_id alias with Some s -> s | None -> "<unknown>")
      session_id;
    stop_daemon ~alias;
    start_daemon ~alias ~broker_root ~session_id ~tmux_pane ~interval ()
  | Some pid ->
    let running_sha =
      match fixture_sha "RUNNING" with
      | Some _ as s -> s
      | None -> running_binary_sha pid
    in
    let installed_sha =
      match fixture_sha "INSTALLED" with
      | Some _ as s -> s
      | None -> installed_binary_sha ()
    in
    (match decide_notifier_start ~running:true ~running_sha ~installed_sha with
     | Skip_current | Start_fresh -> Some pid  (* running:true never yields Start_fresh *)
     | Respawn_stale ->
       let short s = match s with
         | Some x -> String.sub x 0 (min 12 (String.length x))
         | None -> "?" in
       Printf.eprintf
         "[kimi-notifier] running daemon (pid %d) is on a stale binary \
          (running=%s installed=%s); cycling onto the new binary\n%!"
         pid (short running_sha) (short installed_sha);
       stop_daemon ~alias;
       start_daemon ~alias ~broker_root ~session_id ~tmux_pane ~interval ())

(* B146: reap EVERY kimi notifier on this host, regardless of alias. Used by the
   temporary-disable path (`c2c start/new kimi`): a notifier left over from a
   pre-disable session would otherwise keep running against a now-unsupported
   client. Scans the notifier state dir for [<alias>.pid] files and calls the
   identity-gated [stop_daemon] on each (so a stale/reused pid is never
   signalled — only a confirmed [c2c-kimi-notif] process). Returns the number of
   aliases whose pidfile we processed. Best-effort: unreadable dir → 0. *)
let stop_all_daemons () =
  let dir = home () // ".local" // "share" // "c2c" // "kimi-notifiers" in
  match (try Sys.readdir dir with _ -> [||]) with
  | [||] -> 0
  | entries ->
    Array.fold_left
      (fun n entry ->
         if Filename.check_suffix entry ".pid" then begin
           let alias = Filename.chop_suffix entry ".pid" in
           (try stop_daemon ~alias with _ -> ());
           n + 1
         end else n)
      0 entries
