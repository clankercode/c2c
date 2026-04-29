(* c2c_approval_paths.ml — slice 5a of #490 (approval side-channel).

   File-based pending/verdict store, sibling to the broker root, used by
   the kimi PreToolUse approval hook + the new `c2c approval-reply` CLI
   subcommand. Replaces the slice-1 broker-DM reply path which races the
   notifier daemon's inbox-drain (see
   .collab/findings/2026-04-30T05-43-00Z-stanza-coder-await-reply-vs-notifier-drain-race.md
   and .collab/design/2026-04-30-142-approval-side-channel-stanza.md).

   Layout (under broker root, per-repo, host-local):
     <broker_root>/approval-pending/<token>.json   — written by hook
     <broker_root>/approval-verdict/<token>.json   — written by reviewer

   v1 is local-only (single host). Cross-host approval is a follow-up. *)

let ( // ) = Filename.concat

let pending_subdir = "approval-pending"
let verdict_subdir = "approval-verdict"

(** Resolve the parent directory under which approval-pending/ and
    approval-verdict/ live. Defaults to the broker root; override with
    [override_root] (used by tests). *)
let approval_root ?override_root () =
  match override_root with
  | Some r -> r
  | None -> C2c_repo_fp.resolve_broker_root ()

let pending_dir ?override_root () =
  approval_root ?override_root () // pending_subdir

let verdict_dir ?override_root () =
  approval_root ?override_root () // verdict_subdir

(** Sanitize a token for safe use as a filename component. The hook
    mints tokens of the form `ka_<id>` where <id> is a kimi tool_call_id
    (alphanumeric) or sha256-hash + nanos (alphanumeric + `_`). The
    sanitizer is defensive belt-and-braces: only `[A-Za-z0-9._-]` are
    kept; everything else becomes `_`. Empty input becomes "_". *)
let sanitize_token tok =
  if tok = "" then "_"
  else
    let buf = Buffer.create (String.length tok) in
    String.iter
      (fun c ->
        match c with
        | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' ->
            Buffer.add_char buf c
        | _ -> Buffer.add_char buf '_')
      tok;
    Buffer.contents buf

let pending_file ?override_root ~token () =
  pending_dir ?override_root () // (sanitize_token token ^ ".json")

let verdict_file ?override_root ~token () =
  verdict_dir ?override_root () // (sanitize_token token ^ ".json")

(** Ensure both side-channel dirs exist; mode 0700 on the parent if it
    has to be created (auth-by-filesystem; the design doc calls out that
    v1 is single-user). Idempotent. *)
let ensure_dirs ?override_root () =
  let pdir = pending_dir ?override_root () in
  let vdir = verdict_dir ?override_root () in
  (try C2c_mcp.mkdir_p pdir with _ -> ());
  (try C2c_mcp.mkdir_p vdir with _ -> ());
  (try Unix.chmod pdir 0o700 with _ -> ());
  (try Unix.chmod vdir 0o700 with _ -> ())

(** Atomic write via temp + rename, mode 0600. *)
let atomic_write_string path contents =
  let dir = Filename.dirname path in
  (try C2c_mcp.mkdir_p dir with _ -> ());
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out_gen [Open_wronly; Open_creat; Open_trunc] 0o600 tmp in
  Fun.protect
    ~finally:(fun () -> try close_out oc with _ -> ())
    (fun () -> output_string oc contents);
  Unix.rename tmp path

(** [write_pending ~token ~payload] writes a JSON document to
    `<pending_dir>/<token>.json`. The hook calls this BEFORE sending
    the awareness DM, so a reviewer who runs `c2c approval-list` can
    see the pending request even before reading the DM. *)
let write_pending ?override_root ~token ~payload () =
  let path = pending_file ?override_root ~token () in
  atomic_write_string path payload;
  path

(** [write_verdict ~token ~payload] writes a JSON document to
    `<verdict_dir>/<token>.json`. The reviewer's `c2c approval-reply`
    subcommand calls this. *)
let write_verdict ?override_root ~token ~payload () =
  let path = verdict_file ?override_root ~token () in
  atomic_write_string path payload;
  path

(** Generic file-read helper used by both verdict and pending readers. *)
let read_file_opt path =
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let len = in_channel_length ic in
          Some (really_input_string ic len))
    with _ -> None

(** [read_verdict ~token] returns Some contents if the verdict file
    exists, None otherwise. The hook polls this in await-reply. *)
let read_verdict ?override_root ~token () =
  read_file_opt (verdict_file ?override_root ~token ())

(** [read_pending ~token] returns Some contents if the pending file
    exists, None otherwise. *)
let read_pending ?override_root ~token () =
  read_file_opt (pending_file ?override_root ~token ())

(** List the tokens currently in the approval-pending dir. Tokens are
    derived from filenames by stripping the `.json` suffix. Returns
    an empty list if the dir is missing or unreadable. *)
let list_pending_tokens ?override_root () =
  let dir = pending_dir ?override_root () in
  if not (Sys.file_exists dir) then []
  else
    try
      Sys.readdir dir
      |> Array.to_list
      |> List.filter_map (fun name ->
          if Filename.check_suffix name ".json"
          then Some (Filename.chop_suffix name ".json")
          else None)
      |> List.sort compare
    with _ -> []

(** True iff a verdict file exists for [token] (sibling of pending). *)
let has_verdict ?override_root ~token () =
  Sys.file_exists (verdict_file ?override_root ~token ())

(** List the tokens currently in the approval-verdict dir. *)
let list_verdict_tokens ?override_root () =
  let dir = verdict_dir ?override_root () in
  if not (Sys.file_exists dir) then []
  else
    try
      Sys.readdir dir
      |> Array.to_list
      |> List.filter_map (fun name ->
          if Filename.check_suffix name ".json"
          then Some (Filename.chop_suffix name ".json")
          else None)
      |> List.sort compare
    with _ -> []

(** Lightweight extraction of an integer field from a JSON payload.
    Used to read `timeout_at` from the pending payload without pulling
    in a full JSON parser. *)
let parse_int_field s field =
  let needle = "\"" ^ field ^ "\"" in
  let nlen = String.length needle in
  let slen = String.length s in
  let rec find_needle i =
    if i + nlen > slen then None
    else if String.sub s i nlen = needle then Some (i + nlen)
    else find_needle (i + 1)
  in
  match find_needle 0 with
  | None -> None
  | Some after_key ->
      let rec skip_to_value j =
        if j >= slen then None
        else
          match s.[j] with
          | ' ' | '\t' | '\n' | '\r' | ':' -> skip_to_value (j + 1)
          | '0' .. '9' | '-' -> Some j
          | _ -> None
      in
      (match skip_to_value after_key with
       | None -> None
       | Some start ->
           let rec scan k =
             if k >= slen then k
             else
               match s.[k] with
               | '0' .. '9' | '-' -> scan (k + 1)
               | _ -> k
           in
           let stop = scan start in
           if stop = start then None
           else
             try Some (int_of_string (String.sub s start (stop - start)))
             with _ -> None)

(** Read pending file's `timeout_at` integer; None on missing/parse-fail. *)
let read_pending_timeout_at ?override_root ~token () =
  match read_pending ?override_root ~token () with
  | None -> None
  | Some s -> parse_int_field s "timeout_at"

(** Best-effort mtime of a file; None on missing/error. *)
let mtime_opt path =
  try Some (Unix.stat path).Unix.st_mtime with _ -> None

(** Best-effort cleanup of the pending+verdict files for a token. Used
    after await-reply has consumed the verdict. *)
let cleanup ?override_root ~token () =
  let p = pending_file ?override_root ~token () in
  let v = verdict_file ?override_root ~token () in
  (try Sys.remove p with _ -> ());
  (try Sys.remove v with _ -> ())

(** Build the canonical pending-file JSON payload. *)
let make_pending_payload
    ~token ~agent_alias ~tool_name ~tool_input
    ~timeout_at ~reviewer_alias =
  let escape s =
    (* Minimal JSON string escape: backslash, double-quote, control chars. *)
    let buf = Buffer.create (String.length s + 2) in
    String.iter
      (fun c ->
        match c with
        | '\\' -> Buffer.add_string buf "\\\\"
        | '"' -> Buffer.add_string buf "\\\""
        | '\n' -> Buffer.add_string buf "\\n"
        | '\r' -> Buffer.add_string buf "\\r"
        | '\t' -> Buffer.add_string buf "\\t"
        | c when Char.code c < 0x20 ->
            Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
        | c -> Buffer.add_char buf c)
      s;
    Buffer.contents buf
  in
  Printf.sprintf
    "{\"token\":\"%s\",\"agent_alias\":\"%s\",\"tool_name\":\"%s\",\"tool_input\":%s,\"timeout_at\":%d,\"reviewer_alias\":\"%s\"}\n"
    (escape token) (escape agent_alias) (escape tool_name)
    (* tool_input is already a JSON value (jq -c emits compact JSON);
       passed through verbatim. Hook ensures non-empty/valid. *)
    (if tool_input = "" then "{}" else tool_input)
    timeout_at (escape reviewer_alias)

(** Build the canonical verdict-file JSON payload. *)
let make_verdict_payload ~token ~verdict ~reason ~reviewer_alias ~ts =
  let escape s =
    let buf = Buffer.create (String.length s + 2) in
    String.iter
      (fun c ->
        match c with
        | '\\' -> Buffer.add_string buf "\\\\"
        | '"' -> Buffer.add_string buf "\\\""
        | '\n' -> Buffer.add_string buf "\\n"
        | '\r' -> Buffer.add_string buf "\\r"
        | '\t' -> Buffer.add_string buf "\\t"
        | c when Char.code c < 0x20 ->
            Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
        | c -> Buffer.add_char buf c)
      s;
    Buffer.contents buf
  in
  Printf.sprintf
    "{\"token\":\"%s\",\"verdict\":\"%s\",\"reason\":\"%s\",\"reviewer_alias\":\"%s\",\"ts\":%d}\n"
    (escape token) (escape verdict) (escape reason) (escape reviewer_alias) ts

(** Extract the "verdict" string from a verdict JSON payload. Returns
    None on parse failure. Tolerant: minimal scan for `"verdict":"..."` —
    we don't pull in a full JSON parser for this single field. *)
let parse_verdict_field s =
  let needle = "\"verdict\"" in
  let nlen = String.length needle in
  let slen = String.length s in
  let rec find_needle i =
    if i + nlen > slen then None
    else if String.sub s i nlen = needle then Some (i + nlen)
    else find_needle (i + 1)
  in
  match find_needle 0 with
  | None -> None
  | Some after_key ->
      (* Skip whitespace + colon + whitespace + opening quote *)
      let rec skip_to_quote j =
        if j >= slen then None
        else
          match s.[j] with
          | ' ' | '\t' | '\n' | '\r' | ':' -> skip_to_quote (j + 1)
          | '"' -> Some (j + 1)
          | _ -> None
      in
      (match skip_to_quote after_key with
       | None -> None
       | Some start ->
           let buf = Buffer.create 8 in
           let rec scan k =
             if k >= slen then None
             else
               match s.[k] with
               | '"' -> Some (Buffer.contents buf)
               | '\\' when k + 1 < slen ->
                   (* minimal unescape: backslash, quote, n, t, r — others as-is *)
                   (match s.[k + 1] with
                    | 'n' -> Buffer.add_char buf '\n'; scan (k + 2)
                    | 't' -> Buffer.add_char buf '\t'; scan (k + 2)
                    | 'r' -> Buffer.add_char buf '\r'; scan (k + 2)
                    | c -> Buffer.add_char buf c; scan (k + 2))
               | c -> Buffer.add_char buf c; scan (k + 1)
           in
           scan start)
