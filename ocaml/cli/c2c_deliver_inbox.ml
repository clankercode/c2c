(* c2c_deliver_inbox — OCaml deliver-inbox daemon
   Replaces c2c_deliver_inbox.py (Python).
   S1: CLI parsing, daemon fork+setsid+pgrp, pidfile, log redirection.
   S2: inbox polling loop via c2c_mcp library.
   S3a: kimi notification-store delivery via C2c_kimi_notifier.

   Single-file executable: all logic in this file, `let () =` is the
   OCaml program body. *)

let ( // ) = Filename.concat

(* ---------------------------------------------------------------------------
 * Types
 * --------------------------------------------------------------------------- *)

type daemon_start_result = [
  | `Already_running of int
  | `Started of int
  | `Failed of string
]

type cli_args = {
  session_id : string option;
  terminal_pid : int option;
  pts : string option;
  broker_root : string;
  alias : string option;
  cross_repo : bool;
  register_self : bool;
  client : string;
  loop : bool;
  interval : float;
  max_iterations : int option;
  pidfile : string option;
  daemon : bool;
  daemon_log : string option;
  daemon_timeout : float;
  notify_debounce : float;
  xml_output_fd : int option;
  xml_output_path : string option;
  file_fallback : bool;
  timeout : float;
  dry_run : bool;
  json : bool;
  full_body : bool;
  pty_master_fd : int option;  (* S4: PTY master fd for PTY-based delivery *)
  use_inotify : bool;          (* H3: inotifywait-based watcher *)
}

(* ---------------------------------------------------------------------------
 * Utility: pidfile
 * --------------------------------------------------------------------------- *)

let read_pidfile path =
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let line = String.trim (input_line ic) in
          Some (int_of_string line))
    with _ -> None

let write_pidfile path pid =
  let dir = Filename.dirname path in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> try close_out oc with _ -> ())
    (fun () -> Printf.fprintf oc "%d\n" pid)

let pid_is_alive pid =
  if pid <= 0 then false
  else
    try Unix.kill pid 0; true
    with Unix.Unix_error (Unix.ESRCH, _, _) -> false
    | Unix.Unix_error (Unix.EPERM, _, _) -> true

let already_running pidfile =
  match read_pidfile pidfile with
  | Some p when pid_is_alive p -> true
  | _ -> false

(* ---------------------------------------------------------------------------
 * H3: Inotify-based inbox watcher
 * Uses `inotifywait -m` subprocess to watch the broker inbox file for
 * changes, then reads + delivers new messages. Position-based dedup (tracks
 * List.length of messages seen) prevents re-delivery after crash/restart
 * via atomic checkpoint sidecar.
 * --------------------------------------------------------------------------- *)

(* Atomic checkpoint: write to temp file then rename. *)
let read_checkpoint (path : string) : int =
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> try close_in ic with _ -> ())
      (fun () -> int_of_string (String.trim (input_line ic)))
  with _ -> 0

let write_checkpoint (path : string) (count : int) =
  let tmp = path ^ ".tmp" in
  try
    let oc = open_out tmp in
    Fun.protect ~finally:(fun () -> try close_out oc with _ -> ())
      (fun () -> Printf.fprintf oc "%d\n" count);
    Unix.rename tmp path
  with _ -> ()

(* Read the inbox JSON file and return parsed messages.
   Returns empty list if file missing or unparseable. *)
let read_inbox_json (path : string) : Yojson.Safe.t list =
  if not (Sys.file_exists path) then []
  else
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let buf = Buffer.create 512 in
          (try while true do Buffer.add_channel buf ic 1 done with End_of_file -> ());
          match Buffer.contents buf |> String.trim with
          | "" | "null" -> []
          | s -> (match Yojson.Safe.from_string s with
                  | `List msgs -> msgs
                  | _ -> []))
    with _ -> []

(* Drop first n elements from a list *)
let rec list_drop (n : int) (lst : 'a list) : 'a list =
  if n <= 0 then lst else match lst with [] -> [] | _ :: t -> list_drop (n - 1) t

(* Deliver new messages from inbox since last_seen_count.
   Uses read_inbox (non-destructive) so messages remain for poll_inbox callers.
   Position-based dedup: tracks List.length. Returns new count after delivery. *)
let deliver_new_messages
    ~(broker : C2c_mcp.Broker.t)
    ~(session_id : string)
    ~(last_seen_count : int ref)
    ~(inbox_path : string)
    ~(checkpoint_path : string)
    ~(client : string)
    ~(broker_root : string)
    : int =
  let messages = read_inbox_json inbox_path in
  let new_count = List.length messages in
  if new_count > !last_seen_count then begin
    let to_deliver_count = new_count - !last_seen_count in
    if to_deliver_count > 0 then begin
      let new_msgs_json = list_drop !last_seen_count messages in
      List.iter (fun (j : Yojson.Safe.t) ->
        match j with
        | `Assoc fields ->
            (try
              let from_alias = List.assoc "from_alias" fields |> function
                | `String s -> s | _ -> raise Exit
              and content = List.assoc "content" fields |> function
                | `String s -> s | _ -> raise Exit
              in
              Printf.printf "[c2c-deliver-inbox] inotify deliver from=%s: %s\n%!"
                from_alias
                (String.sub content 0 (min (String.length content) 80));
              flush stdout
            with Exit | Not_found -> ())
        | _ -> ())
        new_msgs_json;
      C2c_deliver_inbox_log.log_drain
        ~broker_root ~session_id ~client
        ~count:to_deliver_count
        ~drained_by_pid:(Unix.getpid ())
    end;
    last_seen_count := new_count;
    write_checkpoint checkpoint_path new_count;
    new_count
  end else
    !last_seen_count

(* ---------------------------------------------------------------------------
 * B156: inotifywait child lifecycle. `inotifywait -m` never exits on its own,
 * so if the daemon is killed (SIGTERM) or a loop returns without explicitly
 * killing the watcher, the inotifywait process orphans — and Unix.close_process_*
 * can then block forever waiting for it (the intermittent test hang). We
 * therefore (a) exec inotifywait directly so the tracked pid IS the watcher
 * (not a wrapping sh whose grandchild we could not reach), (b) explicitly kill
 * the watcher on loop teardown, and (c) install a SIGTERM/SIGINT handler that
 * kills any live watcher and exits promptly so a killed daemon never wedges a
 * `wait` in the caller.
 * ------------------------------------------------------------------------- *)

let inotify_children : int list ref = ref []

let track_inotify_child pid = inotify_children := pid :: !inotify_children

let forget_inotify_child pid =
  inotify_children := List.filter (fun p -> p <> pid) !inotify_children

let teardown_signals_installed = ref false

(* Install once: on SIGTERM/SIGINT, hard-kill every tracked watcher and exit
   promptly. Idempotent across the (mutually exclusive) inotify loop modes. *)
let install_teardown_signals () =
  if not !teardown_signals_installed then begin
    teardown_signals_installed := true;
    let handler _ =
      List.iter
        (fun pid -> try Unix.kill pid Sys.sigkill with _ -> ())
        !inotify_children;
      exit 0
    in
    (try Sys.set_signal Sys.sigterm (Sys.Signal_handle handler) with _ -> ());
    (try Sys.set_signal Sys.sigint (Sys.Signal_handle handler) with _ -> ())
  end

(* Spawn `inotifywait <args>` via `exec`, so the pid returned by
   process_full_pid is the watcher itself (killing it kills inotifywait, not a
   wrapping sh whose grandchild would orphan). Registers it for teardown.

   B156 (review): SIGTERM/SIGINT are blocked across spawn + pid lookup +
   tracking, so the teardown handler can never fire in the window after the
   watcher process exists but before it is tracked (which would let the handler
   see an empty list and exit, orphaning the watcher). A signal raised while
   blocked stays pending and is delivered on unblock — by which point the pid
   is tracked and the handler kills it. *)
let spawn_inotifywait (inotify_args : string) =
  let cmd = "exec inotifywait " ^ inotify_args in
  let blocked = [ Sys.sigterm; Sys.sigint ] in
  let prev = try Thread.sigmask Unix.SIG_BLOCK blocked with _ -> [] in
  Fun.protect
    ~finally:(fun () ->
      try ignore (Thread.sigmask Unix.SIG_SETMASK prev) with _ -> ())
    (fun () ->
      let (ic, oc, err_ic) = Unix.open_process_full cmd (Unix.environment ()) in
      let pid = Unix.process_full_pid (ic, oc, err_ic) in
      track_inotify_child pid;
      (ic, oc, err_ic, pid))

(* Kill the watcher (uncatchable SIGKILL) then reap it. close_process_full
   returns promptly once the child is dead, so this never blocks on the
   otherwise-immortal `inotifywait -m`. *)
let close_inotifywait (ic, oc, err_ic) pid =
  (try Unix.kill pid Sys.sigkill with _ -> ());
  (try ignore (Unix.close_process_full (ic, oc, err_ic)) with _ -> ());
  forget_inotify_child pid

(* Run the inotifywait subprocess. Falls back to polling on failure. *)
let run_inotify_loop
    ~(broker_root : string)
    ~(session_id : string)
    ~(client : string)
    ~(watched_pid : int option)
    ~(poll_interval : float)
    ~(max_iterations : int option)
    : unit =
  let inbox_path = broker_root // ".inbox" // session_id ^ ".inbox.json" in
  let checkpoint_path = broker_root // ".inbox" // session_id ^ ".deliver-checkpoint" in
  let last_seen_count = ref (read_checkpoint checkpoint_path) in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let iterations = ref 0 in
  let total_delivered = ref 0 in
  if not (Sys.file_exists inbox_path) then
    Printf.printf "[c2c-deliver-inbox] inotify: inbox not found: %s\n%!" inbox_path
  else
    Printf.printf "[c2c-deliver-inbox] inotify: watching %s (checkpoint=%d)\n%!"
      inbox_path !last_seen_count;
  flush stdout;
  install_teardown_signals ();
  let inotify_args = Printf.sprintf
    "-m -e close_write,modify --format '%%e %%f' %s"
    (Filename.quote inbox_path)
  in
  let rec fallback_poll () =
    let rec poll_loop () =
      match max_iterations with
      | Some m when !iterations >= m ->
          Printf.printf "[c2c-deliver-inbox] inotify: max iterations reached\n%!";
          flush stdout
      | _ ->
        incr iterations;
        let prev = !last_seen_count in
        let _new_count = deliver_new_messages
          ~broker ~session_id ~last_seen_count
          ~inbox_path ~checkpoint_path ~client ~broker_root
        in
        total_delivered := !total_delivered + (!last_seen_count - prev);
        (match watched_pid with
         | Some wp when not (pid_is_alive wp) ->
           Printf.printf "[c2c-deliver-inbox] inotify: watched pid %d exited\n%!" wp;
           flush stdout
         | _ ->
           Unix.sleepf (max 0.01 poll_interval);
           poll_loop ())
    in
    poll_loop ()
  and run_inotify () =
    let (ic, _oc, err_ic, watcher_pid) = spawn_inotifywait inotify_args in
    let ready_flag = Atomic.make false in
    let _err_thread = Thread.create (fun () ->
      (try
        while true do ignore (input_line err_ic : string)
        done
      with End_of_file | Sys_error _ -> ());
      Atomic.set ready_flag true
    ) () in
    let deadline = Unix.gettimeofday () +. 10.0 in
    while not (Atomic.get ready_flag) && Unix.gettimeofday () < deadline do
      Thread.delay 0.05
    done;
    Printf.printf "[c2c-deliver-inbox] inotify: watcher ready\n%!";
    flush stdout;
    Fun.protect ~finally:(fun () -> close_inotifywait (ic, _oc, err_ic) watcher_pid) (fun () ->
      let rec loop () =
        match max_iterations with
        | Some m when !iterations >= m ->
            Printf.printf "[c2c-deliver-inbox] inotify: max iterations reached\n%!";
            flush stdout
        | _ ->
          (match watched_pid with
           | Some wp when not (pid_is_alive wp) ->
             Printf.printf "[c2c-deliver-inbox] inotify: watched pid %d exited\n%!" wp;
             flush stdout
           | _ ->
             (try
                let _line = input_line ic in
                incr iterations;
                let prev = !last_seen_count in
                let _new_count = deliver_new_messages
                  ~broker ~session_id ~last_seen_count
                  ~inbox_path ~checkpoint_path ~client ~broker_root
                in
                total_delivered := !total_delivered + (!last_seen_count - prev);
                loop ()
              with
              | End_of_file ->
                  Printf.printf "[c2c-deliver-inbox] inotify: subprocess exited, polling\n%!";
                  flush stdout;
                  fallback_poll ()
              | Sys_error msg ->
                  Printf.printf "[c2c-deliver-inbox] inotify: read error '%s', polling\n%!" msg;
                  flush stdout;
                  fallback_poll ()))
      in
      loop ()
    )
  in
  run_inotify ();
  Printf.printf "[c2c-deliver-inbox] inotify loop finished, total delivered=%d\n%!"
    !total_delivered;
  flush stdout

(* ---------------------------------------------------------------------------
 * Inbox polling + delivery via c2c_mcp library
 * --------------------------------------------------------------------------- *)

(* For kimi: use the kimi notifier (REST POST /prompts is the wake path).
   Optional legacy composer nudge only if C2C_KIMI_TMUX_COMPOSER_WAKE=1.
   The session_id IS the kimi alias in managed context.
   P4: also polls the global sessions broker for session-id addressed messages. *)
let poll_once_kimi ?workdir ~(broker_root : string) ~(session_id : string) () : int =
  let tmux_pane = Sys.getenv_opt "TMUX_PANE" in
  (* Legacy workdir default (#36): c2c-deliver-inbox runs in the watched
     session's own directory, so its cwd is that session's Kimi workspace dir.
     Callers that know the session's real workdir (e.g. a machine-wide watcher
     reading the broker registration's [cwd]) should pass [?workdir]. *)
  let workdir = match workdir with Some w -> w | None -> Sys.getcwd () in
  let count_repo = C2c_kimi_notifier.run_once
    ~broker_root
    ~alias:session_id
    ~session_id
    ~tmux_pane
    ~workdir
  in
  let count_global = C2c_kimi_notifier.poll_once_global
    ~session_id
    ~alias:session_id
    ~tmux_pane
    ~workdir
  in
  let count = count_repo + count_global in
  (* #562: log kimi notification result *)
  C2c_deliver_inbox_log.log_kimi
    ~broker_root ~session_id ~who:session_id ~count ~ok:true;
  count

(* For non-kimi: drain via broker, then log (future: PTY injection, etc.) *)
let poll_once_generic ~(broker : C2c_mcp.Broker.t) ~(session_id : string)
    : C2c_mcp.message list =
  C2c_mcp.Broker.confirm_registration broker ~session_id;
  C2c_mcp.Broker.drain_inbox ~drained_by:"deliver-inbox" broker ~session_id

let peek_once_generic ~(broker : C2c_mcp.Broker.t) ~(session_id : string)
    : C2c_mcp.message list =
  C2c_mcp.Broker.confirm_registration broker ~session_id;
  C2c_mcp.Broker.read_inbox broker ~session_id

let truncate_content ~(full_body : bool) (content : string) =
  if full_body then content
  else String.sub content 0 (min (String.length content) 110)

let message_to_json ~(dry_run : bool) (m : C2c_mcp.message) : Yojson.Safe.t =
  `Assoc
    [ ("event", `String (if dry_run then "would_deliver" else "delivered"))
    ; ("dry_run", `Bool dry_run)
    ; ("delivered", `Int (if dry_run then 0 else 1))
    ; ("from_alias", `String m.from_alias)
    ; ("to_alias", `String m.to_alias)
    ; ("content", `String m.content)
    ; ("ts", `Float m.ts)
    ]

let print_messages ~(json : bool) ~(full_body : bool) ~(dry_run : bool)
    (messages : C2c_mcp.message list) : unit =
  List.iter
    (fun (m : C2c_mcp.message) ->
       if json then
         Printf.printf "%s\n%!" (Yojson.Safe.to_string (message_to_json ~dry_run m))
       else
         Printf.printf "[c2c-deliver-inbox] %s from=%s: %s\n%!"
           (if dry_run then "would deliver" else "delivered")
           m.from_alias
           (truncate_content ~full_body m.content))
    messages

let print_summary ~(json : bool) ~(session_id : string) ~(broker_root : string)
    ~(client : string) ~(dry_run : bool) ~(delivered : int) : unit =
  if json then
    Printf.printf "%s\n%!"
      (Yojson.Safe.to_string
         (`Assoc
            [ ("event", `String "summary")
            ; ("session", `String session_id)
            ; ("broker_root", `String broker_root)
            ; ("client", `String client)
            ; ("dry_run", `Bool dry_run)
            ; ("delivered", `Int delivered)
            ]))
  else
    Printf.printf "[c2c-deliver-inbox] session=%s broker_root=%s client=%s delivered=%d\n%!"
      session_id broker_root client delivered

let deliver_generic_once ~(emit_zero_summary : bool)
    ~(broker_root : string) ~(session_id : string)
    ~(client : string) ~(dry_run : bool) ~(json : bool) ~(full_body : bool)
    ~(drained_by_pid : int) : int =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let messages =
    if dry_run then peek_once_generic ~broker ~session_id
    else poll_once_generic ~broker ~session_id
  in
  if not dry_run then
    C2c_deliver_inbox_log.log_drain
      ~broker_root
      ~session_id
      ~client
      ~count:(List.length messages)
      ~drained_by_pid;
  print_messages ~json ~full_body ~dry_run messages;
  let delivered = if dry_run then 0 else List.length messages in
  if delivered > 0 || emit_zero_summary then
    print_summary ~json ~session_id ~broker_root ~client ~dry_run ~delivered;
  delivered

let run_inotify_drain_loop
    ~(broker_root : string)
    ~(session_id : string)
    ~(client : string)
    ~(watched_pid : int option)
    ~(poll_interval : float)
    ~(max_iterations : int option)
    ~(json : bool)
    ~(full_body : bool)
    : unit =
  let inbox_dir = broker_root in
  let inbox_path = inbox_dir // session_id ^ ".inbox.json" in
  let inbox_basename = Filename.basename inbox_path in
  let event_targets_inbox line =
    String.trim line
    |> String.split_on_char ' '
    |> List.filter (fun s -> s <> "")
    |> List.rev
    |> function
    | filename :: _ -> filename = inbox_basename
    | [] -> false
  in
  let iterations = ref 0 in
  let total_delivered = ref 0 in
  let drain_once () =
    let delivered = deliver_generic_once
      ~emit_zero_summary:false
      ~broker_root ~session_id ~client
      ~dry_run:false ~json ~full_body
      ~drained_by_pid:(Unix.getpid ())
    in
    total_delivered := !total_delivered + delivered
  in
  if not (Sys.file_exists inbox_path) then
    Printf.printf "[c2c-deliver-inbox] inotify-drain: inbox not found yet: %s\n%!" inbox_path
  else
    Printf.printf "[c2c-deliver-inbox] inotify-drain: watching %s\n%!" inbox_path;
  flush stdout;
  (* Drain anything already queued before waiting for future writes. *)
  drain_once ();
  install_teardown_signals ();
  (* B156: create the watched dir in-process (was `mkdir -p` inside the shell
     command) so the spawned process can be a bare `exec inotifywait` whose pid
     we can kill directly. *)
  (try Unix.mkdir inbox_dir 0o755 with _ -> ());
  let inotify_args = Printf.sprintf
    "-m -e close_write,modify,create,moved_to --format '%%e %%f' %s"
    (Filename.quote inbox_dir)
  in
  let rec fallback_poll () =
    match max_iterations with
    | Some m when !iterations >= m -> ()
    | _ ->
        (match watched_pid with
         | Some wp when not (pid_is_alive wp) -> ()
         | _ ->
             incr iterations;
             drain_once ();
             Unix.sleepf (max 0.01 poll_interval);
             fallback_poll ())
  in
  let (ic, _oc, err_ic, watcher_pid) = spawn_inotifywait inotify_args in
  Fun.protect ~finally:(fun () -> close_inotifywait (ic, _oc, err_ic) watcher_pid) (fun () ->
    let _err_thread = Thread.create (fun () ->
      try while true do ignore (input_line err_ic : string) done
      with End_of_file | Sys_error _ -> ()) () in
    Printf.printf "[c2c-deliver-inbox] inotify-drain: watcher ready\n%!";
    let rec loop () =
      match max_iterations with
      | Some m when !iterations >= m -> ()
      | _ ->
          (match watched_pid with
           | Some wp when not (pid_is_alive wp) -> ()
           | _ ->
               try
                 let line = input_line ic in
                 if event_targets_inbox line then begin
                   incr iterations;
                   drain_once ()
                 end;
                 loop ()
               with End_of_file | Sys_error _ -> fallback_poll ())
    in
    loop ());
  Printf.printf "[c2c-deliver-inbox] inotify-drain loop finished, total delivered=%d\n%!"
    !total_delivered;
  flush stdout

let register_self_if_requested ~(broker_root : string) ~(session_id : string) (args : cli_args) : unit =
  match args.register_self, args.alias with
  | false, _ -> ()
  | true, None -> failwith "--register requires --alias"
  | true, Some alias ->
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      let pid = Some (Unix.getpid ()) in
      let pid_start_time = C2c_mcp.Broker.capture_pid_start_time pid in
      C2c_mcp.Broker.register broker ~session_id ~alias ~pid ~pid_start_time
        ~client_type:(Some args.client) ~cwd:(Some (Sys.getcwd ())) ()


(* ---------------------------------------------------------------------------
 * Daemon: fork + setsid + pgrp + log redirection
 * --------------------------------------------------------------------------- *)

let rec start_daemon
    ~(_child_argv : string list)
    ~(args : cli_args)
    ~(pidfile_path : string)
    ~(log_path : string)
    : daemon_start_result =
  match already_running pidfile_path with
  | true ->
    (match read_pidfile pidfile_path with
     | Some p -> `Already_running p
     | None -> `Failed "pidfile exists but unreadable")
  | false ->
    (try Unix.unlink pidfile_path with Unix.Unix_error _ -> ());
    (match Unix.fork () with
     | 0 ->
       (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
       let log_dir = Filename.dirname log_path in
       (try Unix.mkdir log_dir 0o755
        with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
       let log_fd = Unix.openfile log_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644 in
       Unix.dup2 log_fd Unix.stdout;
       Unix.dup2 log_fd Unix.stderr;
       Unix.close log_fd;
        let pid = Unix.getpid () in
        write_pidfile pidfile_path pid;
        (* G-2 fix: child falls through to run_loop instead of assert false.
           After setsid() the child is a session leader detached from the parent's
           terminal. The pidfile write confirms liveness before the parent returns.
           When start_daemon is called in the exec'd path (c2c start), exec replaces
           the child so this code is never reached; when called directly with
           --daemon flag, we want the child to continue as the daemon. *)
        run_loop ~args ~watched_pid:args.terminal_pid;
        exit 0
     | child_pid ->
       let deadline = Unix.gettimeofday () +. args.daemon_timeout in
       let rec wait () =
         if Unix.gettimeofday () >= deadline then
           `Failed "pidfile not written before timeout"
         else
           match read_pidfile pidfile_path with
           | Some p when pid_is_alive p -> `Started p
           | _ ->
             (try ignore (Unix.waitpid [ Unix.WNOHANG ] child_pid)
              with Unix.Unix_error _ -> ());
             Unix.sleepf 0.1;
             wait ()
       in
       wait ())

(* ---------------------------------------------------------------------------
 * run_loop — poll inbox and sleep, until watched_pid exits or max_iterations
 * --------------------------------------------------------------------------- *)

and run_loop ~(args : cli_args) ~(watched_pid : int option) : unit =
  let session_id = args.session_id in
  if session_id = None then
    (Printf.eprintf "[c2c-deliver-inbox] --session-id required for loop mode\n%!";
     flush stderr;
     exit 1);
  let session_id = Option.get session_id in
  register_self_if_requested ~broker_root:args.broker_root ~session_id args;
  (* S4/S5/B013: delivery path selection. XML sideband (xml_output_fd) takes
     precedence over --inotify so codex never silently falls into the
     log-only run_inotify_loop. See select_delivery_mode for the rationale. *)
  match
    C2c_pty_inject.select_delivery_mode
      ~pty_master_fd:args.pty_master_fd
      ~xml_output_fd:args.xml_output_fd
      ~use_inotify:args.use_inotify
      ~client:args.client
  with
  | C2c_pty_inject.Mode_pty fd ->
      let master_fd : Unix.file_descr = Obj.magic fd in
      C2c_pty_inject.pty_deliver_loop_daemon
        ~master_fd
        ~broker_root:args.broker_root
        ~session_id
        ~watched_pid
        ~poll_interval:args.interval
        ~max_iterations:args.max_iterations
  | C2c_pty_inject.Mode_inotify_drain ->
      run_inotify_drain_loop
        ~broker_root:args.broker_root
        ~session_id
        ~client:args.client
        ~watched_pid
        ~poll_interval:args.interval
        ~max_iterations:args.max_iterations
        ~json:args.json
        ~full_body:args.full_body
  | C2c_pty_inject.Mode_inotify_print ->
      run_inotify_loop
        ~broker_root:args.broker_root
        ~session_id
        ~client:args.client
        ~watched_pid
        ~poll_interval:args.interval
        ~max_iterations:args.max_iterations
  | C2c_pty_inject.Mode_xml_fd fd ->
      let out_fd : Unix.file_descr = Obj.magic fd in
      C2c_pty_inject.xml_deliver_loop_daemon
        ~out_fd
        ~broker_root:args.broker_root
        ~session_id
        ~watched_pid
        ~poll_interval:args.interval
        ~max_iterations:args.max_iterations
  | C2c_pty_inject.Mode_wake_inject ->
      (* codex-wake-inject: watch the inbox and nudge the session's tmux/herdr
         pane when idle. NEVER drains — the codex UserPromptSubmit hook does
         the actual delivery on the injected turn. When the session has no
         registered wake target (not in tmux/herdr) the injector no-ops with
         skip reasons; nothing else to do for idle codex. *)
      Printf.printf
        "[c2c-deliver-inbox] wake-inject: watching %s for %s (tmux/herdr \
         nudge only; codex hooks deliver bodies)\n%!"
        args.broker_root session_id;
      C2c_wake_inject.watch_loop
        ~broker_root:args.broker_root
        ~session_id
        ?watched_pid
        ?max_iterations:args.max_iterations
        ()
  | C2c_pty_inject.Mode_agy_inject ->
      Printf.printf
        "[c2c-deliver-inbox] agy-inject: watching %s for %s\n%!"
        args.broker_root session_id;
      C2c_agy_deliver.deliver_loop
        ~broker_root:args.broker_root
        ~session_id
        ?watched_pid:watched_pid
        ?max_iterations:args.max_iterations
        ~interval:args.interval
        ()
  | C2c_pty_inject.Mode_poll ->
            let iterations = ref 0 in
            let total_delivered = ref 0 in
            let max_iterations = args.max_iterations in
            let is_kimi = args.client = "kimi" in
            let rec loop () =
              match max_iterations with
              | Some m when !iterations >= m ->
                  Printf.printf "[c2c-deliver-inbox] max iterations (%d) reached, stopping\n%!" m;
                  flush stdout
              | _ ->
                  incr iterations;
                  let delivered =
                    if is_kimi then
                      poll_once_kimi ~broker_root:args.broker_root ~session_id ()
                    else
                      deliver_generic_once
                        ~emit_zero_summary:true
                        ~broker_root:args.broker_root
                        ~session_id
                        ~client:args.client
                        ~dry_run:args.dry_run
                        ~json:args.json
                        ~full_body:args.full_body
                        ~drained_by_pid:(Unix.getpid ())
                  in
                  total_delivered := !total_delivered + delivered;
                  (if delivered > 0 then
                     Printf.printf "[c2c-deliver-inbox] iteration %d: delivered %d message(s)\n%!"
                       !iterations delivered
                   else
                     Printf.printf "[c2c-deliver-inbox] iteration %d: no messages\n%!" !iterations);
                  flush stdout;
                  (match watched_pid with
                   | Some wp when not (pid_is_alive wp) ->
                       Printf.printf "[c2c-deliver-inbox] watched pid %d exited, stopping\n%!" wp;
                       flush stdout;
                       ()
                   | _ ->
                       (* #612: clamp interval to 0.01s minimum to prevent edge-case
                          zero/negative sleep (interval can be set to 0.1 for testing) *)
                       let safe_interval = max 0.01 args.interval in
                       Unix.sleepf safe_interval;
                       loop ())
            in
            loop ();
            Printf.printf "[c2c-deliver-inbox] loop finished after %d iterations, %d total delivered\n%!"
              !iterations !total_delivered;
            flush stdout

(* ---------------------------------------------------------------------------
 * CLI argument parsing
 * --------------------------------------------------------------------------- *)

let parse_args () : cli_args =
  let session_id = ref None in
  let terminal_pid = ref None in
  let pts = ref None in
  let broker_root = ref None in
  let alias = ref None in
  let cross_repo = ref false in
  let register_self = ref false in
  let client = ref "generic" in
  let loop = ref false in
  let interval = ref 1.0 in
  let max_iterations = ref None in
  let pidfile = ref None in
  let daemon = ref false in
  let daemon_log = ref None in
  let daemon_timeout = ref 10.0 in
  let notify_debounce = ref 30.0 in
  let xml_output_fd = ref None in
  let xml_output_path = ref None in
  let file_fallback = ref false in
  let timeout = ref 5.0 in
  let dry_run = ref false in
  let json = ref false in
  let full_body = ref false in
  let pty_master_fd = ref None in
  let use_inotify = ref false in

  let speclist = [
    ("--session-id", Arg.String (fun s -> session_id := Some s),
     " broker session id to deliver");
    ("--alias", Arg.String (fun s -> alias := Some s),
     " alias whose inbox to deliver (reverse-looks-up session id)");
    ("-a", Arg.String (fun s -> alias := Some s),
     " alias whose inbox to deliver (same as --alias)");
    ("--broker-root", Arg.String (fun s -> broker_root := Some s),
     " broker root directory");
    ("--cross-repo", Arg.Set cross_repo,
     " use the shared sessions broker instead of the repo broker");
    ("--global-broker", Arg.Set cross_repo,
     " alias for --cross-repo");
    ("--register", Arg.Set register_self,
     " register --alias as a live receiver pinned to this process pid");
    ("--client", Arg.String (fun s -> client := s),
     " client type (claude|codex|codex-headless|opencode|kimi|crush|generic)");
    ("--loop", Arg.Set loop, " keep polling and delivering");
    ("--interval", Arg.Set_float interval, " polling interval in seconds");
    ("--max-iterations", Arg.Int (fun i -> max_iterations := Some i),
     " maximum loop iterations");
    ("--pidfile", Arg.String (fun s -> pidfile := Some s),
     " pidfile path");
    ("--daemon", Arg.Set daemon, " start detached");
    ("--daemon-log", Arg.String (fun s -> daemon_log := Some s),
     " daemon log path");
    ("--daemon-timeout", Arg.Set_float daemon_timeout,
     " timeout for daemon startup (default 10s)");
    ("--notify-debounce", Arg.Set_float notify_debounce,
     " minimum seconds between repeated notify nudges");
    ("--xml-output-fd", Arg.Int (fun i -> xml_output_fd := Some i),
     " write Codex XML frames to this fd");
    ("--xml-output-path", Arg.String (fun s -> xml_output_path := Some s),
     " write Codex XML frames by opening this fifo/path");
    ("--file-fallback", Arg.Set file_fallback,
     " use file-based broker when Unix socket unavailable");
    ("--timeout", Arg.Set_float timeout,
     " timeout for inbox drain operations (default 5s)");
    ("--dry-run", Arg.Set dry_run,
     " peek and render without draining or injecting");
    ("--json", Arg.Set json, " output JSON");
    ("--full-body", Arg.Set full_body,
     " print complete message bodies instead of truncating previews");
    ("--pid", Arg.Int (fun i -> terminal_pid := Some i),
     " terminal/process pid");
    ("--terminal-pid", Arg.Int (fun i -> terminal_pid := Some i),
     " terminal/process pid (same as --pid)");
    ("--pts", Arg.String (fun s -> pts := Some s),
     " pts device (required with --terminal-pid)");
    ("--pty-master-fd", Arg.Int (fun i -> pty_master_fd := Some i),
     " PTY master fd for PTY-based delivery (S4)");
    ("--inotify", Arg.Set use_inotify,
     " use inotifywait-based delivery instead of polling (H3)");
  ] in
  let anon _ = () in
  Arg.parse speclist anon "c2c-deliver-inbox [options]";
  (match !session_id, !alias with
   | Some _, Some _ -> failwith "--session-id and --alias are mutually exclusive"
   | _ -> ());
  let broker_root_val =
    match !broker_root with
    | Some b -> b
    | None when !cross_repo -> C2c_repo_fp.resolve_sessions_broker_root ()
    | None -> ""
  in
  {
    session_id = !session_id;
    terminal_pid = !terminal_pid;
    pts = !pts;
    broker_root = broker_root_val;
    alias = !alias;
    cross_repo = !cross_repo;
    register_self = !register_self;
    client = !client;
    loop = !loop;
    interval = !interval;
    max_iterations = !max_iterations;
    pidfile = !pidfile;
    daemon = !daemon;
    daemon_log = !daemon_log;
    daemon_timeout = !daemon_timeout;
    notify_debounce = !notify_debounce;
    xml_output_fd = !xml_output_fd;
    xml_output_path = !xml_output_path;
    file_fallback = !file_fallback;
    timeout = !timeout;
    dry_run = !dry_run;
    json = !json;
    full_body = !full_body;
    pty_master_fd = !pty_master_fd;
    use_inotify = !use_inotify;
  }

(* ---------------------------------------------------------------------------
 * Broker root resolution (mirrors c2c_poll_inbox.default_broker_root)
 * S1 stub: returns $C2C_MCP_BROKER_ROOT or $HOME/.c2c/repos/default/broker
 * --------------------------------------------------------------------------- *)

let default_broker_root () : string =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some b -> b
  | None ->
    let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
    home // ".c2c" // "repos" // "default" // "broker"

let resolve_session_id_by_alias ~(broker_root : string) ~(alias : string) : string =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let alias_norm = String.lowercase_ascii alias in
  let matches =
    C2c_mcp.Broker.list_registrations broker
    |> List.filter (fun (r : C2c_mcp.registration) ->
           String.lowercase_ascii r.alias = alias_norm)
  in
  match matches with
  | [] -> failwith (Printf.sprintf "alias %s is not registered in this broker" alias)
  | regs ->
      let live =
        List.filter
          (fun r -> C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive)
          regs
      in
      let chosen = match live with r :: _ -> r | [] -> List.hd regs in
      chosen.session_id

let resolve_effective_session_id ~(broker_root : string) (args : cli_args) : string =
  match args.session_id, args.alias with
  | Some sid, None -> sid
  | None, Some alias ->
      if args.register_self then
        try resolve_session_id_by_alias ~broker_root ~alias
        with Failure _ -> alias
      else
        resolve_session_id_by_alias ~broker_root ~alias
  | Some _, Some _ -> failwith "--session-id and --alias are mutually exclusive"
  | None, None -> failwith "--session-id or --alias required"

(* ---------------------------------------------------------------------------
 * OCaml program body — the `let () =` below IS the executable entry point.
 * --------------------------------------------------------------------------- *)

let () =
  let args = parse_args () in
  let broker_root =
    if args.broker_root <> "" then args.broker_root
    else default_broker_root ()
  in
  let session_id = resolve_effective_session_id ~broker_root args in
  let pidfile_path =
    match args.pidfile with
    | Some p -> p
    | None ->
      let state_dir = Filename.concat (Sys.getcwd ()) ".c2c-deliver-state" in
      (try Unix.mkdir state_dir 0o755
       with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      Filename.concat state_dir (session_id ^ ".pid")
  in
  let log_path =
    match args.daemon_log with
    | Some l -> l
    | None -> pidfile_path ^ ".log"
  in

  let args = { args with session_id = Some session_id; broker_root } in

  if args.daemon then begin
    match start_daemon
        ~_child_argv:(Sys.argv |> Array.to_list)
        ~args
        ~pidfile_path
        ~log_path with
    | `Already_running pid ->
      if args.json then
        Printf.printf "%s\n"
          (Yojson.Safe.pretty_to_string (
            `Assoc [
              "ok", `Bool true;
              "daemon", `Bool true;
              "already_running", `Bool true;
              "pid", `Int pid;
              "pidfile", `String pidfile_path;
              "log_path", `String log_path;
            ]))
      else
        Printf.printf "daemon already running pid=%d\n" pid
    | `Started pid ->
      if args.json then
        Printf.printf "%s\n"
          (Yojson.Safe.pretty_to_string (
            `Assoc [
              "ok", `Bool true;
              "daemon", `Bool true;
              "already_running", `Bool false;
              "pid", `Int pid;
              "pidfile", `String pidfile_path;
              "log_path", `String log_path;
            ]))
      else
        Printf.printf "daemon started pid=%d\n" pid
    | `Failed msg ->
      if args.json then
        Printf.printf "%s\n"
          (Yojson.Safe.pretty_to_string (
            `Assoc ["ok", `Bool false; "error", `String msg]))
      else
        Printf.eprintf "daemon start failed: %s\n" msg;
      exit 1
  end else begin
    let watched_pid = args.terminal_pid in
    if args.loop then
      run_loop ~args ~watched_pid
    else
      (* Single-shot: one poll + deliver for kimi, full render/drain for others. *)
      if args.client = "kimi" then
        let delivered = poll_once_kimi ~broker_root ~session_id () in
        print_summary
          ~json:args.json
          ~session_id
          ~broker_root
          ~client:args.client
          ~dry_run:args.dry_run
          ~delivered
      else
        ignore (deliver_generic_once
          ~emit_zero_summary:true
          ~broker_root
          ~session_id
          ~client:args.client
          ~dry_run:args.dry_run
          ~json:args.json
          ~full_body:args.full_body
          ~drained_by_pid:0)
  end
