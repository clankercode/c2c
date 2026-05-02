(* #61: size-based rotation for <broker_root>/broker.log.

   Every structured-event writer in the broker (peer-pass reject,
   pin rotate, send-memory handoff, RPC trace, nudge enqueue/tick)
   appends a single JSON line to <broker_root>/broker.log. Without
   a cap that file grows unbounded — a flood of forged peer-pass
   DMs or a long-lived busy session can fill the disk. This module
   funnels all writers through one ingress, [append_json], that
   stat()s the file before each write and rotates the ring
   (broker.log.1 .. broker.log.N) when adding the next line would
   cross the cap.

   Defaults: 10 MiB cap, ring depth 5.
   Overrides: [C2C_BROKER_LOG_MAX_BYTES], [C2C_BROKER_LOG_KEEP].

   All operations are wrapped in a flock on
   <broker_root>/broker.log.lock (matching the [Trust_pin.with_pin_lock]
   idiom from peer_review.ml) so concurrent writers cannot tear or
   double-rotate. The whole helper is total — never raises; audit
   logging must never break the RPC path that called it. *)

let default_max_bytes = 10 * 1024 * 1024

let default_keep = 5

let env_int name default =
  match Sys.getenv_opt name with
  | None -> default
  | Some s ->
    (match int_of_string_opt (String.trim s) with
     | Some n when n > 0 -> n
     | _ -> default)

let max_bytes () = env_int "C2C_BROKER_LOG_MAX_BYTES" default_max_bytes

let keep () = env_int "C2C_BROKER_LOG_KEEP" default_keep

let log_path ~broker_root = Filename.concat broker_root "broker.log"

let lock_path ~broker_root = Filename.concat broker_root "broker.log.lock"

let with_lock ~broker_root f =
  let lp = lock_path ~broker_root in
  (* Best-effort mkdir of the parent — broker_root may not exist yet
     in tests that point at a fresh tmpdir. *)
  (try
     if not (Sys.file_exists broker_root) then
       Unix.mkdir broker_root 0o700
   with _ -> ());
  let fd =
    try Some (Unix.openfile lp [ O_RDWR; O_CREAT ] 0o600)
    with _ -> None
  in
  match fd with
  | None ->
    (* Couldn't open the lockfile — degrade to unlocked write rather
       than dropping the line entirely. *)
    (try f () with _ -> ())
  | Some fd ->
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        (try Unix.lockf fd Unix.F_LOCK 0 with _ -> ());
        (try f () with _ -> ()))

(* Rotate the ring: drop broker.log.<keep>, shift broker.log.<n> ->
   broker.log.<n+1> for n in [keep-1 .. 1], then move broker.log ->
   broker.log.1. After this the live path does not exist; the next
   append will recreate it. *)
let rotate ~broker_root =
  let path = log_path ~broker_root in
  let n = keep () in
  (* Drop the oldest if it exists. *)
  let oldest = path ^ "." ^ string_of_int n in
  (try if Sys.file_exists oldest then Sys.remove oldest with _ -> ());
  (* Shift down: .{n-1} -> .{n}, .{n-2} -> .{n-1}, ..., .1 -> .2. *)
  for i = n - 1 downto 1 do
    let src = path ^ "." ^ string_of_int i in
    let dst = path ^ "." ^ string_of_int (i + 1) in
    if Sys.file_exists src then
      try Sys.rename src dst with _ -> ()
  done;
  (* Move live -> .1 *)
  if Sys.file_exists path then
    try Sys.rename path (path ^ ".1") with _ -> ()

let file_size path =
  try (Unix.stat path).Unix.st_size with _ -> 0

let append_line ~broker_root line =
  let path = log_path ~broker_root in
  let cap = max_bytes () in
  let next_size = file_size path + String.length line + 1 in
  if next_size > cap && cap > 0 then rotate ~broker_root;
  let oc =
    try Some (open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o600 path)
    with _ -> None
  in
  match oc with
  | None -> ()
  | Some oc ->
    (try
       output_string oc line;
       output_char oc '\n';
       close_out oc
     with _ -> close_out_noerr oc)

(* Public ingress. Single-line JSON per event. Total — never raises. *)
let append_json ~broker_root ~(json : Yojson.Safe.t) =
  try
    let line = Yojson.Safe.to_string json in
    with_lock ~broker_root (fun () -> append_line ~broker_root line)
  with _ -> ()
