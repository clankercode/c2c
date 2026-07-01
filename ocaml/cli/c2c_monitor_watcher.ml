type t = {
  pid : int;
  pgid : int;
  stdout_ic : in_channel;
  stderr_ic : in_channel;
  mutable closed : bool;
}

let sleep_seconds seconds =
  ignore (Unix.select [] [] [] seconds)

let close_noerr fd =
  try Unix.close fd with _ -> ()

let close_in_noerr ic =
  try Stdlib.close_in_noerr ic with _ -> ()

let pid_alive pid =
  try Unix.kill pid 0; true with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) -> true
  | _ -> false

let waitpid_nohang pid =
  try
    match Unix.waitpid [Unix.WNOHANG] pid with
    | 0, _ -> false
    | _ -> true
  with
  | Unix.Unix_error (Unix.ECHILD, _, _) -> true
  | _ -> false

let start ~(program : string) ~(args : string list) : t =
  let stdout_rd, stdout_wr = Unix.pipe () in
  let stderr_rd, stderr_wr = Unix.pipe () in
  let pid =
    match Unix.fork () with
    | 0 ->
        let devnull = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
        Unix.dup2 devnull Unix.stdin;
        Unix.dup2 stdout_wr Unix.stdout;
        Unix.dup2 stderr_wr Unix.stderr;
        close_noerr devnull;
        close_noerr stdout_rd;
        close_noerr stdout_wr;
        close_noerr stderr_rd;
        close_noerr stderr_wr;
        (try Unix.execvp "setsid" (Array.of_list ("setsid" :: program :: args))
         with exn ->
           let msg = Printf.sprintf "execvp setsid %s failed: %s\n" program (Printexc.to_string exn) in
           ignore (Unix.write_substring Unix.stderr msg 0 (String.length msg));
           exit 127)
    | child_pid -> child_pid
  in
  close_noerr stdout_wr;
  close_noerr stderr_wr;
  { pid; pgid = pid;
    stdout_ic = Unix.in_channel_of_descr stdout_rd;
    stderr_ic = Unix.in_channel_of_descr stderr_rd;
    closed = false }

let terminate ?(grace_seconds = 0.25) (watcher : t) : unit =
  if not watcher.closed then begin
    watcher.closed <- true;
    (try Unix.kill (-watcher.pgid) Sys.sigterm with _ -> ());
    let deadline = Unix.gettimeofday () +. grace_seconds in
    let rec wait_grace () =
      if waitpid_nohang watcher.pid then true
      else if Unix.gettimeofday () >= deadline then false
      else (sleep_seconds 0.02; wait_grace ())
    in
    if not (wait_grace ()) then begin
      (try Unix.kill (-watcher.pgid) Sys.sigkill with _ -> ());
      ignore (waitpid_nohang watcher.pid)
    end
  end;
  close_in_noerr watcher.stdout_ic;
  close_in_noerr watcher.stderr_ic

let reap_if_exited (watcher : t) : unit =
  if not watcher.closed then begin
    if waitpid_nohang watcher.pid then watcher.closed <- true
  end
