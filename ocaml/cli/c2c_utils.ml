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

(** Compute a short fingerprint for the current repo, used to derive
    the per-repo broker root so distinct repos don't share a broker.
    Uses SHA-256 of remote.origin.url (when present) so clones of the
    same upstream share a broker; falls back to git toplevel path. *)
let repo_fingerprint () =
  let data =
    match Git_helpers.git_first_line [ "config"; "--get"; "remote.origin.url" ] with
    | Some url when url <> "" -> url
    | _ ->
        (match Git_helpers.git_repo_toplevel () with
         | Some t -> t
         | None -> "")
  in
  if data = "" then "default"
  else
    let hash = Digestif.SHA256.digest_string data in
    let raw = Digestif.SHA256.to_hex hash in
    String.sub raw 0 12

(** Pure broker-root path resolution — no side effects.
    Resolution order (coord1 2026-04-26):
      1. C2C_MCP_BROKER_ROOT env var (explicit override)
      2. $XDG_STATE_HOME/c2c/repos/<fp>/broker  (if XDG_STATE_HOME set)
      3. $HOME/.c2c/repos/<fp>/broker  (canonical default)
      4. ~/.local/state/c2c/repos/<fp>/broker  (XDG default fallback)
    The broker directory is created lazily on first use via Broker.ensure_root. *)
let resolve_broker_root () =
  let abs_path p = if Filename.is_relative p then Sys.getcwd () // p else p in
  let fp = repo_fingerprint () in
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some dir when String.trim dir <> "" -> abs_path (String.trim dir)
  | _ ->
      let xdg_root = xdg_state_home () // "c2c" // "repos" // fp // "broker" in
      match Sys.getenv_opt "XDG_STATE_HOME" with
      | Some xdg when String.trim xdg <> "" -> xdg_root  (* XDG_STATE_HOME wins *)
      | _ ->
          (* Canonical default: $HOME/.c2c/repos/<fp>/broker *)
          (match Sys.getenv_opt "HOME" with
           | Some h when String.trim h <> "" ->
               String.trim h // ".c2c" // "repos" // fp // "broker"
           | _ -> xdg_root)  (* No HOME: fall back to XDG default *)

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
