(* c2c_utils.ml — shared helper functions extracted from c2c.ml.
   Goal: eliminate duplicated boilerplate, centralize idioms. *)

let ( // ) = Filename.concat
let likes_shell_substitution = C2c_start.likes_shell_substitution

(** [mkdir_p dir] creates dir and all parents, like Unix mkdir -p.
    Idempotent; uses 0o755 permissions.
    Delegates to [C2c_mcp.mkdir_p] — the single canonical helper
    (#400b, which itself delegates to [C2c_io.mkdir_p]). For
    non-default permission bits, call [C2c_mcp.mkdir_p ~mode] directly. *)
let mkdir_p = C2c_mcp.mkdir_p

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

(** Re-exports of the pure legacy-broker-root detection helpers from
    C2c_broker_root_check (#352). Kept here for call-site convenience;
    the underlying module is dependency-free for unit-testability. *)
let is_legacy_broker_root = C2c_broker_root_check.is_legacy_broker_root
let legacy_broker_warning_text = C2c_broker_root_check.legacy_broker_warning_text

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
