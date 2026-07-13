(* c2c_pty_inject — PTY injection for claude/codex/opencode delivery.

   Extracts the PTY injection logic from c2c_start.ml so it can be linked by
   both c2c_start (PTY-loop delivery) and c2c_deliver_inbox (standalone daemon
   with --pty-master-fd).

   The pty_inject function writes to an already-open PTY master fd using
   bracketed paste mode (ESC[200~ ... ESC[201~) so the terminal treats the
   content as a paste rather than typing.

   Note: the legacy Python wire-bridge path (c2c-kimi-wire-bridge.py) used a
   subprocess binary at a hardcoded meta-agent path. This OCaml implementation
   replaces that path entirely. The binary-based approach is deprecated. *)

(* Write a message to the PTY master fd using bracketed paste mode.
   Bracketed paste mode: ESC[200~ ... ESC[201~ tells the terminal to treat
   the content as a paste, not as individual keystrokes. This prevents
   interpretation of special characters (Ctrl-C, etc.) in the message body.

   master_fd: the PTY master file descriptor (obtained from forkpty in the parent)
   content: the message text to inject *)
let pty_inject ~(master_fd : Unix.file_descr) (content : string) : unit =
  let oc = Unix.out_channel_of_descr master_fd in
  (* Bracketed paste mode: ESC [ 200 ~ ... ESC [ 201 ~ *)
  let esc = "\027" in  (* 0x1b = ESC, xterm C1 control *)
  let paste_start = esc ^ "[200~" in
  let paste_end = esc ^ "[201~" in
  output_string oc paste_start;
  output_string oc content;
  output_string oc paste_end;
  flush oc;
  (* Brief delay to let the application process the paste before we send Enter *)
  ignore (Unix.select [] [] [] 0.01);
  (* Send Enter to submit *)
  output_char oc '\n';
  flush oc

(* pid_is_alive: true if the process with given pid is running.
   Unix.kill pid 0: ESRCH if no such process, EPERM if process exists but we
   don't have permission (treat as alive). Guard pid <= 0 to avoid signals
   to process group 0. *)
let pid_is_alive pid =
  if pid <= 0 then false
  else
    try Unix.kill pid 0; true
    with Unix.Unix_error (Unix.ESRCH, _, _) -> false
    | Unix.Unix_error (Unix.EPERM, _, _) -> true

(* ---------------------------------------------------------------------------
 * B013: delivery-mode selection
 *
 * Pure decision over which delivery loop the c2c-deliver-inbox daemon should
 * run, given the fds/flags it was launched with. Kept here (library code, no
 * .mli to maintain, co-located with the loops it selects between) so the
 * dispatch *precedence* is unit-testable and documented.
 *
 * The precedence that matters:
 *
 *   XML sideband delivery (xml_output_fd) takes precedence over --inotify.
 *
 * Historically codex's managed delivery contract was the XML fd (the codex
 * fork read frames via --xml-input-fd; that flag was removed upstream and
 * interactive codex now uses config.toml hooks). The XML sideband survives
 * for the codex-headless bridge, which reads the same frame format from a
 * broker-owned fifo. When inotifywait is present on PATH, start_deliver_daemon
 * (c2c_start.ml) auto-adds --inotify, so an XML deliver daemon can receive BOTH
 * an XML output AND --inotify. The old dispatch checked use_inotify first and
 * routed non-generic clients to the log-only inotify path (which printed a
 * preview to stdout = /dev/null in the daemon and NEVER wrote XML to the fd) —
 * so codex silently went dark. Checking xml_output_fd before use_inotify fixes
 * that without disturbing the generic/opencode inotify-drain path.
 * --------------------------------------------------------------------------- *)

type delivery_mode =
  | Mode_pty of int            (* PTY master fd (S4) *)
  | Mode_xml_fd of int         (* XML sideband to fd — codex-headless bridge path *)
  | Mode_inotify_drain         (* generic client: event-driven destructive drain *)
  | Mode_inotify_print         (* non-generic, non-xml, --inotify: log-only (manual/debug) *)
  | Mode_wake_inject           (* codex: tmux/herdr wake-nudge watcher — never drains;
                                  codex hooks deliver bodies on the injected turn *)
  | Mode_poll                  (* generic/kimi polling loop *)
  | Mode_agy_inject            (* agy: agentapi delivery watcher *)

let select_delivery_mode
    ~(pty_master_fd : int option)
    ~(xml_output_fd : int option)
    ~(use_inotify : bool)
    ~(client : string) : delivery_mode =
  match pty_master_fd with
  | Some fd -> Mode_pty fd
  | None ->
      (match xml_output_fd with
       | Some fd -> Mode_xml_fd fd        (* precedence over --inotify *)
       | None ->
           (* codex-wake-inject: interactive codex delivery is owned by the
              config.toml hooks; the sidecar daemon's only job is to WAKE an
              idle session (tmux/herdr nudge) when the inbox grows. The old
              routing sent codex to the log-only Mode_inotify_print, which
              did nothing useful post-xmlfd-removal. C2c_wake_inject handles
              its own inotify/poll fallback, so use_inotify is irrelevant
              here. codex-headless is NOT affected (matches "codex" only). *)
           if client = "codex" then Mode_wake_inject
           else if client = "agy" then Mode_agy_inject
           else if use_inotify then
             if client = "generic" then Mode_inotify_drain
             else Mode_inotify_print
           else Mode_poll)

(* pty_deliver_loop_daemon: daemon-mode PTY delivery loop.
   Polls the broker inbox every poll_interval seconds and injects messages
   via pty_inject on the given master_fd. Runs until watched_pid exits
   (if provided) or max_iterations reached.

   Unlike pty_deliver_loop in c2c_start.ml (which waits for child_pid exit
   as its termination condition), this variant is designed for daemon mode where
   the daemon runs independently of any child process. *)
let pty_deliver_loop_daemon
    ~(master_fd : Unix.file_descr)
    ~(broker_root : string)
    ~(session_id : string)
    ~(watched_pid : int option)
    ~(poll_interval : float)
    ~(max_iterations : int option)
    : unit =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let iterations = ref 0 in
  let total_delivered = ref 0 in
  let rec loop () =
    match max_iterations with
    | Some m when !iterations >= m ->
      Printf.printf "[c2c-deliver-inbox] PTY: max iterations (%d) reached, stopping\n%!" m;
      flush stdout
    | _ ->
      (match watched_pid with
       | Some wp when not (pid_is_alive wp) ->
         Printf.printf "[c2c-deliver-inbox] PTY: watched pid %d exited, stopping\n%!" wp;
         flush stdout;
         ()
       | _ ->
         incr iterations;
         let messages =
           C2c_mcp.Broker.drain_inbox ~drained_by:"pty" broker ~session_id
         in
           List.iter
             (fun (msg : C2c_mcp.message) ->
                (* Race 3 fix (#623): per-message error isolation — one failed
                   pty_inject must not abort remaining messages in the batch.
                   Log and continue so subsequent messages are still delivered. *)
                (try
                  pty_inject ~master_fd msg.content;
                  Printf.printf "[c2c-deliver-inbox] PTY: injected from %s: %s\n%!"
                    msg.from_alias
                    (String.sub msg.content 0
                       (min (String.length msg.content) 80))
                with e ->
                  let id = Option.value msg.message_id ~default:msg.from_alias in
                  Printf.eprintf "[c2c-deliver-inbox] warning: pty_inject failed for message %s: %s\n%!"
                    id (Printexc.to_string e)))
             messages;
         total_delivered := !total_delivered + List.length messages;
         (if List.length messages > 0 then
            Printf.printf "[c2c-deliver-inbox] PTY: iteration %d: %d message(s)\n%!"
              !iterations (List.length messages)
          else
            Printf.printf "[c2c-deliver-inbox] PTY: iteration %d: no messages\n%!"
              !iterations);
         flush stdout;
         ignore (Unix.select [] [] [] poll_interval);
         loop ())
  in
  loop ();
  Printf.printf "[c2c-deliver-inbox] PTY: finished, %d total delivered\n%!"
    !total_delivered;
  flush stdout

(* xml_deliver_loop_daemon: daemon-mode XML sideband delivery loop.
   Polls the broker inbox every poll_interval seconds and writes XML sideband
   frames to the given output fd. The codex-headless bridge reads these from
   its broker-owned stdin fifo (the interactive-codex --xml-input-fd consumer
   was removed upstream).

   The XML frame format (per Codex client spec) is:
     <message type="user" queue="AfterAnyItem"><c2c event="message" from="..." to="...">...</c2c></message>

   queue="AfterAnyItem" holds the message until a tool call completes,
   preventing mid-turn validation errors in Codex's active turn controller.

   Runs until watched_pid exits (if provided) or max_iterations reached. *)
let xml_deliver_loop_daemon
    ~(out_fd : Unix.file_descr)
    ~(broker_root : string)
    ~(session_id : string)
    ~(watched_pid : int option)
    ~(poll_interval : float)
    ~(max_iterations : int option)
    : unit =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let oc = Unix.out_channel_of_descr out_fd in
  let iterations = ref 0 in
  let total_delivered = ref 0 in
  let rec loop () =
    match max_iterations with
    | Some m when !iterations >= m ->
      Printf.printf "[c2c-deliver-inbox] XML: max iterations (%d) reached, stopping\n%!" m;
      flush stdout
    | _ ->
      (match watched_pid with
       | Some wp when not (pid_is_alive wp) ->
         Printf.printf "[c2c-deliver-inbox] XML: watched pid %d exited, stopping\n%!" wp;
         flush stdout;
         ()
       | _ ->
         incr iterations;
         let messages =
          C2c_mcp.Broker.drain_inbox ~drained_by:"xml" broker ~session_id
         in
          List.iter
            (fun (msg : C2c_mcp.message) ->
               let tag = C2c_mcp.extract_tag_from_content msg.content in
               let envelope =
                 C2c_mcp.format_c2c_envelope
                   ~from_alias:msg.from_alias
                   ~to_alias:msg.to_alias
                   ?tag
                   ?reply_via:msg.reply_via
                   ~with_reply_hint:true
                   ~escape_content_for_xml:true
                   ~content:msg.content
                   ()
               in
               let xml_frame =
                 Printf.sprintf
                   "<message type=\"user\" queue=\"AfterAnyItem\">%s</message>\n"
                   envelope
               in
               (* G-5 fix: 3-retry exponential backoff for EPIPE, dead-letter on
                  persistent failure. Transient EPIPE (reader closed temporarily) is
                  retried; permanent failure (reader gone for good) drops to log. *)
               let max_retries = 3 in
               let rec retry attempt =
                 try
                   output_string oc xml_frame;
                   flush oc;
                   Printf.printf "[c2c-deliver-inbox] XML: delivered from %s: %s\n%!"
                     msg.from_alias
                     (String.sub msg.content 0
                        (min (String.length msg.content) 80))
                 with
                 | Unix.Unix_error (Unix.EPIPE, _, _) when attempt < max_retries ->
                   let backoff = 0.1 *. (2.0 ** float_of_int attempt) in
                   Printf.eprintf "[c2c-deliver-inbox] XML: EPIPE on attempt %d, retrying in %.1fs...\n%!"
                     attempt backoff;
                   ignore (Unix.select [] [] [] backoff);
                   retry (attempt + 1)
                 | Unix.Unix_error (Unix.EPIPE, _, _) ->
                   (* Permanent EPIPE after all retries — dead-letter *)
                   let dl_path = Filename.concat broker_root "xml-dead-letter.jsonl" in
                   let dl_entry = Yojson.Safe.pretty_to_string (
                     `Assoc [
                       "ts", `Float (Unix.gettimeofday ());
                       "session_id", `String session_id;
                       "message_id", (match msg.message_id with Some id -> `String id | None -> `Null);
                       "from_alias", `String msg.from_alias;
                       "to_alias", `String session_id;
                       "content", `String msg.content;
                       "reason", `String "EPIPE after 3 retries"
                     ])
                   in
                   (try
                      let dl_fd = Unix.openfile dl_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o644 in
                      Fun.protect ~finally:(fun () -> Unix.close dl_fd)
                        (fun () ->
                          let oc = Unix.out_channel_of_descr dl_fd in
                          output_string oc dl_entry;
                          output_char oc '\n';
                          flush oc);
                      Printf.eprintf "[c2c-deliver-inbox] XML: dead-lettered message from %s after EPIPE\n%!"
                        msg.from_alias
                    with _ ->
                      Printf.eprintf "[c2c-deliver-inbox] XML: dead-letter write failed for %s\n%!"
                        msg.from_alias)
                 | exn ->
                   Printf.eprintf "[c2c-deliver-inbox] XML: write failed (non-EPIPE): %s\n%!"
                     (Printexc.to_string exn)
               in
               retry 0)
           messages;
         total_delivered := !total_delivered + List.length messages;
         (if List.length messages > 0 then
            Printf.printf "[c2c-deliver-inbox] XML: iteration %d: %d message(s)\n%!"
              !iterations (List.length messages)
          else
            Printf.printf "[c2c-deliver-inbox] XML: iteration %d: no messages\n%!"
              !iterations);
         flush stdout;
         ignore (Unix.select [] [] [] poll_interval);
         loop ())
  in
  loop ();
  Printf.printf "[c2c-deliver-inbox] XML: finished, %d total delivered\n%!"
    !total_delivered;
  flush stdout
