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
