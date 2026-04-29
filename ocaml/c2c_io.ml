(** [C2c_io] — shared filesystem helpers used across the OCaml tree.

    Lives early in the [c2c_mcp] library's module chain so it is reachable
    from every other module in the library (relay, relay_identity, c2c_start,
    c2c_wire_*, c2c_mcp itself) as well as the [c2c] executable, the
    [tools/] hooks, and the test suites. #400b: single canonical
    [mkdir_p] for the entire OCaml tree. *)

(** [mkdir_p ?mode dir] creates [dir] and all missing parents, like
    Unix [mkdir -p]. Idempotent (treats [EEXIST] as success). Default
    mode 0o755. The single canonical helper for the OCaml tree.

    Behavior:
    - Returns silently for "", "/", or "." (no-op).
    - Returns silently if [dir] already exists.
    - Otherwise recurses on [Filename.dirname dir] before [Unix.mkdir dir]
      (parent-first ordering).
    - On [Unix.EEXIST] — e.g. if a peer racing alongside us created the
      directory between our [Sys.file_exists] check and our [Unix.mkdir]
      call — swallows the error and returns success.
    - Other [Unix_error] values are NOT caught (the caller is responsible
      for [EACCES], [ENOSPC], etc.). *)
let rec mkdir_p ?(mode = 0o755) dir =
  if dir = "" || dir = "/" || dir = "." then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p ~mode (Filename.dirname dir);
    try Unix.mkdir dir mode with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(** [read_file path] slurps the entire contents of [path] as a string.
    Raises [Sys_error] / [End_of_file] on I/O failure. Canonical helper
    (#388) — converges duplicates across c2c_stats, c2c_memory, c2c_mcp,
    and c2c.ml. *)
let read_file (path : string) : string =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic))

(** [read_file_opt path] returns [path]'s contents or [""] on any I/O
    error. Convenience wrapper for "best effort" reads where callers
    treat missing/unreadable files as empty. *)
let read_file_opt (path : string) : string =
  try read_file path with _ -> ""

(** [write_file path content] writes [content] to [path], truncating any
    existing file. Non-atomic; callers wanting crash-safety should use
    [C2c_utils.atomic_write_json] or write-to-tmp + [Unix.rename]. *)
let write_file (path : string) (content : string) : unit =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc content)
