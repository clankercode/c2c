(* C2c_singleton_lock: cross-process singleton guard via POSIX lockf on a
   lockfile.

   Used by long-running daemon processes (e.g. [relay subscribe-daemon]) to
   enforce at most one live instance per resource, identified by a path
   (typically a Unix socket path). A second process that tries to acquire
   while a live owner holds the lock gets [Already_running] and should exit 0
   (idempotent auto-start).

   The lock is a non-blocking exclusive POSIX lock ([Unix.lockf] [F_TLOCK]) on
   <path>.lock. POSIX locks are released automatically by the OS when the
   owning process exits — cleanly or via crash/kill -9 — so there is no stale
   LOCK to clean up. A stale SOCKET file left by a crashed owner is unlinked
   by the new owner after it acquires the lock (it is provably the sole owner
   at that point).

   The returned [Unix.file_descr] must be kept open for the owner's entire
   lifetime; closing it releases the lock.

   bugs.txt 2026-06-29 (c2c side): relay subscribe-daemon had no singleton
   guard and unconditionally unlinked+rebound its socket on every start, so N
   concurrent starts each stole the socket path and orphaned the previous
   owner (which kept its listen fd alive forever) — 344 duplicate daemons
   observed on a 4-day uptime. This module is the fix. *)

type acquire_result =
  | Acquired of Unix.file_descr
      (* Caller owns the singleton. The fd MUST stay open until the owner is
         done; closing it (or process exit) releases the lock. *)
  | Already_running
      (* A live owner holds the lock. The caller should exit 0 (idempotent). *)

let lockfile_path ~path = path ^ ".lock"

(* [try_acquire ~path]: open (creating if needed) <path>.lock and attempt a
   non-blocking exclusive lock.

   Returns [Acquired fd] on success or [Already_running] if a live owner
   holds it. [EAGAIN]/[EACCES] (the two codes POSIX permits for a held lock)
   map to [Already_running]; any other error propagates to the caller. *)
let try_acquire ~path =
  let lock_path = lockfile_path ~path in
  let fd = Unix.openfile lock_path [Unix.O_RDWR; Unix.O_CREAT] 0o644 in
  try
    Unix.lockf fd Unix.F_TLOCK 0;
    Acquired fd
  with
  | Unix.Unix_error (Unix.EAGAIN, _, _)
  | Unix.Unix_error (Unix.EACCES, _, _) ->
    Unix.close fd;
    Already_running

(* [release fd]: release a previously acquired lock. Equivalent to
   [Unix.close fd] but named for readability. Total. *)
let release fd =
  try Unix.close fd with _ -> ()
