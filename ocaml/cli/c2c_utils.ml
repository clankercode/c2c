(* c2c_utils.ml — shared helper functions extracted from c2c.ml.
   Goal: eliminate duplicated boilerplate, centralize idioms. *)

let ( // ) = Filename.concat

(** [likes_shell_substitution s] returns true if [s] looks like it contains
    an un-expanded shell substitution pattern — $(...) or backtick pairs that
    were likely meant to be expanded by the shell but arrived literally.

    Avoids false positives on:
    - Makefile escapes: $$ (double dollar)
    - Escaped dollar: \$ (backslash-dollar) *)
let likes_shell_substitution (s : string) : bool =
  let rec find_dollar i =
    if i >= String.length s then None
    else
      let ch = s.[i] in
      if ch = '$' then
        if i + 1 < String.length s then
          let next = s.[i + 1] in
          if next = '$' then find_dollar (i + 2)  (* $$ skip, makefile escape *)
          else if next = '\\' then find_dollar (i + 2)  (* \$ skip *)
          else if next = '(' then
            (* Dollar-open-paren: check balanced parens *)
            let depth = ref 1 in
            let j = ref (i + 2) in
            while !j < String.length s && !depth > 0 do
              (match s.[!j] with
               | '(' -> incr depth
               | ')' -> decr depth
               | _ -> ());
              incr j
            done;
            if !depth = 0 then Some (Printf.sprintf "$(...) at %d" i)
            else find_dollar (!j + 1)
          else if next = '`' then
            (* Dollar-backtick: check balanced backticks *)
            let depth = ref 1 in
            let j = ref (i + 2) in
            while !j < String.length s && !depth > 0 do
              (match s.[!j] with
               | '`' -> decr depth
               | '$' ->
                   (if !j + 1 < String.length s && s.[!j + 1] = '`' then incr depth);
                   incr j
               | _ -> ());
              incr j
            done;
            if !depth = 0 then Some (Printf.sprintf "`...` at %d" i)
            else find_dollar (!j + 1)
          else find_dollar (i + 2)
        else None
      else find_dollar (i + 1)
  in
  find_dollar 0 <> None

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

(** Pure broker-root path resolution — no side effects.
    Mirrors the logic in c2c.ml:resolve_broker_root for use by shared modules.
    The broker creates the directory lazily on first use via Broker.ensure_root. *)
let resolve_broker_root () =
  let abs_path p = if Filename.is_relative p then Sys.getcwd () // p else p in
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some dir -> abs_path dir
  | None -> (
      match Git_helpers.git_common_dir () with
      | Some git_dir -> abs_path git_dir // "c2c" // "mcp"
      | None -> xdg_state_home () // "c2c" // "default" // "mcp")

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
