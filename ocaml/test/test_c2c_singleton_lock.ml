(* Tests for C2c_singleton_lock.

   The core guarantee — at most one live owner per path — is a cross-process
   property, so the central test forks a child to hold the lock while the
   parent probes it. The c2c_name/Alcotest test executable is single-threaded
   (plain [Alcotest.run], no Lwt/Thread before the fork), so [Unix.fork] is
   safe here. *)

open Alcotest

let acquire_result =
  Alcotest.(result
    (module struct
      type t = C2c_singleton_lock.acquire_result =
        | Acquired of Unix.file_descr | Already_running
      let pp ppf = function
        | Acquired _ -> Fmt.string ppf "Acquired"
        | Already_running -> Fmt.string ppf "Already_running"
      let equal a b = match a, b with
        | Already_running, Already_running -> true
        | Acquired _, Acquired _ -> true
        | _ -> false
    end))

let unique_path () =
  let p = Filename.temp_file "c2c_singleton" "" in
  (* Filename.temp_file creates an empty file; we want a fresh base path that
     does not yet exist, so remove it and use its name as the resource id. *)
  Unix.unlink p;
  p

let cleanup_lockfile path =
  try Unix.unlink (C2c_singleton_lock.lockfile_path ~path) with _ -> ()

(* lockfile_path derivation *)
let test_lockfile_path () =
  Alcotest.(check string) "appends .lock"
    "/tmp/foo.sock.lock" (C2c_singleton_lock.lockfile_path ~path:"/tmp/foo.sock")

(* acquire then release then re-acquire (single process, sequential) *)
let test_acquire_release_reacquire () =
  let path = unique_path () in
  let r1 = C2c_singleton_lock.try_acquire ~path in
  Alcotest.(check bool) "first acquire succeeds" true
    (match r1 with Acquired _ -> true | _ -> false);
  (match r1 with Acquired fd -> C2c_singleton_lock.release fd | _ -> ());
  let r2 = C2c_singleton_lock.try_acquire ~path in
  Alcotest.(check bool) "re-acquire after release succeeds" true
    (match r2 with Acquired _ -> true | _ -> false);
  (match r2 with Acquired fd -> C2c_singleton_lock.release fd | _ -> ());
  cleanup_lockfile path

(* THE bug-2 regression: a second process cannot acquire while a live owner
   holds the lock; once that owner exits, the lock is free again. *)
let test_cross_process_singleton () =
  let path = unique_path () in
  let pid = Unix.fork () in
  if pid = 0 then begin
    (* Child: acquire and hold the lock briefly, then exit (which releases
       it). Exit codes are only for debugging if the parent waits on them. *)
    (match C2c_singleton_lock.try_acquire ~path with
     | Acquired _fd -> Unix.sleepf 1.5 |> ignore
     | Already_running -> ());
    exit 0
  end else begin
    (* Parent: give the child time to acquire before probing. *)
    Unix.sleepf 0.4 |> ignore;
    let while_held = C2c_singleton_lock.try_acquire ~path in
    Alcotest.(check bool) "second process sees lock held (Already_running)" true
      (match while_held with Already_running -> true | _ -> false);
    (* Wait for the child to exit; process exit releases the POSIX lock. *)
    let _ = Unix.waitpid [] pid in
    let after_exit = C2c_singleton_lock.try_acquire ~path in
    Alcotest.(check bool) "after owner exits, lock is free (Acquired)" true
      (match after_exit with Acquired _ -> true | _ -> false);
    (match after_exit with Acquired fd -> C2c_singleton_lock.release fd | _ -> ());
    cleanup_lockfile path
  end

let tests = [
  "lockfile_path", `Quick, test_lockfile_path;
  "acquire release reacquire", `Quick, test_acquire_release_reacquire;
  "cross-process singleton", `Quick, test_cross_process_singleton;
]

let () = Alcotest.run "c2c_singleton_lock"
  [ "singleton", tests ]
