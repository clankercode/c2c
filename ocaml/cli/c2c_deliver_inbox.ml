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
  let cmd = Printf.sprintf
    "inotifywait -m -e close_write,modify --format '%%e %%f' %s"
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
    let (ic, _oc, err_ic) = Unix.open_process_full cmd (Unix.environment ()) in
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
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_full (ic, _oc, err_ic))) (fun () ->
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

(* For kimi: use the kimi notifier which handles notification-store writes
   and tmux wake internally. The session_id IS the kimi alias in managed context. *)
let poll_once_kimi ~(broker_root : string) ~(session_id : string) : int =
  let tmux_pane = Sys.getenv_opt "TMUX_PANE" in
  let count = C2c_kimi_notifier.run_once
    ~broker_root
    ~alias:session_id
    ~session_id
    ~tmux_pane
  in
  (* #562: log kimi notification result *)
  C2c_deliver_inbox_log.log_kimi
    ~broker_root ~session_id ~who:session_id ~count ~ok:true;
  count

(* For non-kimi: drain via broker, then log (future: PTY injection, etc.) *)
let poll_once_generic ~(broker : C2c_mcp.Broker.t) ~(session_id : string)
    : C2c_mcp.message list =
  C2c_mcp.Broker.confirm_registration broker ~session_id;
  C2c_mcp.Broker.drain_inbox ~drained_by:"deliver-inbox" broker ~session_id

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
  (* S4/S5: delivery path selection based on available fd *)
  match args.pty_master_fd with
  | Some fd ->
      let master_fd : Unix.file_descr = Obj.magic fd in
      C2c_pty_inject.pty_deliver_loop_daemon
        ~master_fd
        ~broker_root:args.broker_root
        ~session_id
        ~watched_pid
        ~poll_interval:args.interval
        ~max_iterations:args.max_iterations
  | None ->
      (* H3: inotify-based delivery when --inotify is set *)
      (if args.use_inotify then
         run_inotify_loop
           ~broker_root:args.broker_root
           ~session_id
           ~client:args.client
           ~watched_pid
           ~poll_interval:args.interval
           ~max_iterations:args.max_iterations
       else
         (* S5: XML sideband delivery via --xml-output-fd for Codex *)
         match args.xml_output_fd with
       | Some fd ->
           let out_fd : Unix.file_descr = Obj.magic fd in
           C2c_pty_inject.xml_deliver_loop_daemon
             ~out_fd
             ~broker_root:args.broker_root
             ~session_id
             ~watched_pid
             ~poll_interval:args.interval
             ~max_iterations:args.max_iterations
        | None ->
            let iterations = ref 0 in
            let total_delivered = ref 0 in
            let max_iterations = args.max_iterations in
            let is_kimi = args.client = "kimi" in
            (* For kimi: notifier handles broker lifecycle internally.
               For others: create broker once and reuse. *)
            let broker =
              if is_kimi then None
              else Some (C2c_mcp.Broker.create ~root:args.broker_root)
            in
            let rec loop () =
              match max_iterations with
              | Some m when !iterations >= m ->
                  Printf.printf "[c2c-deliver-inbox] max iterations (%d) reached, stopping\n%!" m;
                  flush stdout
              | _ ->
                  incr iterations;
                  let delivered =
                    if is_kimi then
                      poll_once_kimi ~broker_root:args.broker_root ~session_id
                    else
                      let messages = poll_once_generic
                        ~broker:(Option.get broker)
                        ~session_id
                      in
                      (* #562: log drain event *)
                      C2c_deliver_inbox_log.log_drain
                        ~broker_root:args.broker_root
                        ~session_id
                        ~client:args.client
                        ~count:(List.length messages)
                        ~drained_by_pid:(Unix.getpid ());
                      List.iter
                        (fun (m : C2c_mcp.message) ->
                           Printf.printf "[c2c-deliver-inbox] would deliver to %s: %s\n%!"
                             m.from_alias
                             (String.sub m.content 0 (min (String.length m.content) 80)))
                        messages;
                      List.length messages
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
            flush stdout)

(* ---------------------------------------------------------------------------
 * CLI argument parsing
 * --------------------------------------------------------------------------- *)

let parse_args () : cli_args =
  let session_id = ref None in
  let terminal_pid = ref None in
  let pts = ref None in
  let broker_root = ref None in
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
  let pty_master_fd = ref None in
  let use_inotify = ref false in

  let speclist = [
    ("--session-id", Arg.String (fun s -> session_id := Some s),
     " broker session id to deliver");
    ("--broker-root", Arg.String (fun s -> broker_root := Some s),
     " broker root directory");
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
  let broker_root_val =
    match !broker_root with
    | Some b -> b
    | None -> failwith "--broker-root required"
  in
  {
    session_id = !session_id;
    terminal_pid = !terminal_pid;
    pts = !pts;
    broker_root = broker_root_val;
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

(* ---------------------------------------------------------------------------
 * OCaml program body — the `let () =` below IS the executable entry point.
 * --------------------------------------------------------------------------- *)

let () =
  let args = parse_args () in
  let broker_root =
    if args.broker_root <> "" then args.broker_root
    else default_broker_root ()
  in
  let session_id =
    match args.session_id with
    | Some s -> s
    | None -> failwith "--session-id required"
  in
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
      (* Single-shot: one poll + deliver for kimi, poll-only for others *)
      let delivered =
        if args.client = "kimi" then
          poll_once_kimi ~broker_root ~session_id
        else
          let broker = C2c_mcp.Broker.create ~root:broker_root in
          let messages = poll_once_generic ~broker ~session_id in
          (* #562: log single-shot drain (pid=0 = not a daemon) *)
          C2c_deliver_inbox_log.log_drain
            ~broker_root
            ~session_id
            ~client:args.client
            ~count:(List.length messages)
            ~drained_by_pid:0;
          List.iter
            (fun (m : C2c_mcp.message) ->
               Printf.printf "[c2c-deliver-inbox] would deliver to %s: %s\n%!"
                 m.from_alias
                 (String.sub m.content 0 (min (String.length m.content) 80)))
            messages;
          List.length messages
      in
      Printf.printf "[c2c-deliver-inbox] session=%s broker_root=%s client=%s delivered=%d\n%!"
        session_id broker_root args.client delivered
  end