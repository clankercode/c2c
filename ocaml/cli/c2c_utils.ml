(* c2c_utils.ml — shared helper functions extracted from c2c.ml.
   Goal: eliminate duplicated boilerplate, centralize idioms. *)

(** [mkdir_p dir] creates dir and all parents, like Unix mkdir -p.
    Idempotent: succeeds if dir already exists.
    Uses 0o755 permissions. *)
let rec mkdir_p dir =
  if dir = "/" || dir = "." || dir = "" then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(** [atomic_write_json path json] writes json to a temp file then atomically
    renames to [path], ensuring readers never see a partial write.
    The payload is followed by a newline. *)
let atomic_write_json path json =
  let payload = Yojson.Safe.to_string json ^ "\n" in
  let tmp = path ^ ".tmp" in
  try
    let oc = open_out tmp in
    output_string oc payload;
    close_out oc;
    Unix.rename tmp path
  with _ -> ()
