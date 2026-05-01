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
              pty_inject ~master_fd msg.content;
              Printf.printf "[c2c-deliver-inbox] PTY: injected from %s: %s\n%!"
                msg.from_alias
                (String.sub msg.content 0
                   (min (String.length msg.content) 80)))
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