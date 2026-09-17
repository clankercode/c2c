(* c2c_instance_log.ml — B298: size-capped ring rotation for managed
   instance logs (<instances_dir>/<name>/log).

   The machine-wide supervisors (relay-connect, deliver-service) and the relay
   connector child open the instance log once with O_APPEND and nothing ever
   capped it — a crash-looping connector appended 810 MiB into a single file
   over 9,300 restarts. This module mirrors the #61 broker.log conventions
   (Broker_log / C2C_BROKER_LOG_MAX_BYTES / C2C_BROKER_LOG_KEEP) but is
   deliberately not coupled to that mechanism: instance logs are held open as
   stdio by their writers, not funneled through a per-append ingress, so the
   rotation points differ.

   fd-safety rules (why rotation is rename-only, and why it fires at start
   and at each child relaunch): a running child holds the log fd open; a
   rename keeps that fd valid and the child keeps writing to the renamed
   inode until it exits. Rotating by truncate or delete-and-recreate would
   corrupt or silently drop the child's output instead. Mid-run, the relay
   supervisor therefore rides its existing clean-restart path when the live
   path crosses the cap, so the actual rename happens at the relaunch where
   no writer holds the fresh file.

   Defaults: 10 MiB cap, ring depth 3 (log, log.1, log.2, log.3).
   Overrides: [C2C_INSTANCE_LOG_MAX_BYTES], [C2C_INSTANCE_LOG_KEEP] —
   invalid, empty, or <= 0 values fall back to the defaults.

   Total — never raises; log rotation must never break the start path. *)

let default_max_bytes = 10 * 1024 * 1024

let default_keep = 3

let env_int name default =
  match Sys.getenv_opt name with
  | None -> default
  | Some s ->
      (match int_of_string_opt (String.trim s) with
       | Some n when n > 0 -> n
       | _ -> default)

let max_bytes () = env_int "C2C_INSTANCE_LOG_MAX_BYTES" default_max_bytes

let keep () = env_int "C2C_INSTANCE_LOG_KEEP" default_keep

let oversized log_path =
  try
    Sys.file_exists log_path && (Unix.stat log_path).Unix.st_size > max_bytes ()
  with _ -> false

(* Open (creating if needed) in append mode — the single open convention for
   every managed-instance log fd (0o600, O_APPEND so siblings never
   overwrite each other). Returns None rather than raising: the historical
   open sites degrade silently and so must this one. *)
let open_append log_path =
  try
    Some
      (Unix.openfile log_path
         [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ]
         0o600)
  with _ -> None

(* Rotate the ring: drop the numbered overflow (log.<keep> and deeper strays
   left by a previously larger keep), shift log.<n> -> log.<n+1> for n in
   [keep-1 .. 1], then rename log -> log.1. Rename preserves the inode (and
   therefore the mode) and is safe under any writer that still holds the old
   fd — that writer keeps writing to the renamed file until it exits. After
   this the live path does not exist; the next [open_append] recreates it.
   The stray-cleanup probe window is bounded because numbered files beyond
   keep can only come from a smaller historical cap, not from this loop. *)
let rotate ~log_path =
  let n = keep () in
  for i = n to n + 16 do
    let p = log_path ^ "." ^ string_of_int i in
    try if Sys.file_exists p then Sys.remove p with _ -> ()
  done;
  for i = n - 1 downto 1 do
    let src = log_path ^ "." ^ string_of_int i in
    let dst = log_path ^ "." ^ string_of_int (i + 1) in
    if Sys.file_exists src then try Sys.rename src dst with _ -> ()
  done;
  if Sys.file_exists log_path then
    try Sys.rename log_path (log_path ^ ".1") with _ -> ()

(* Rotate when the live path exceeds the cap — the check supervisors run at
   start and at each child relaunch. Returns true when the path was over cap
   (and a rotation was attempted); total, never raises. *)
let rotate_if_oversized ~log_path =
  if oversized log_path then begin
    rotate ~log_path;
    true
  end
  else false
