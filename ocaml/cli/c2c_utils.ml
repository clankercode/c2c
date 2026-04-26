(* c2c_utils.ml — shared helper functions extracted from c2c.ml.
   Goal: eliminate duplicated boilerplate, centralize idioms. *)

let ( // ) = Filename.concat
let likes_shell_substitution = C2c_start.likes_shell_substitution

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

(** XDG_STATE_HOME per XDG spec, with HOME fallback. *)
let xdg_state_home () =
  match Sys.getenv_opt "XDG_STATE_HOME" with
  | Some v when String.trim v <> "" -> String.trim v
  | _ ->
      (match Sys.getenv_opt "HOME" with
       | Some h when String.trim h <> "" -> String.trim h // ".local" // "state"
       | _ -> "/tmp")

(** Delegates to the authoritative implementation in C2c_repo_fp (library module).
    C2c_repo_fp.resolve_broker_root uses Digestif.SHA256 for repo fingerprint. *)
let resolve_broker_root () = C2c_repo_fp.resolve_broker_root ()

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
