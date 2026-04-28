(* c2c_history.ml — formatters for `c2c history` output.

   Extracted from inline c2c.ml so it can be unit-tested. The CLI's
   --json branch keeps using the inline JSON serializer (parity with
   the MCP tool), and the human branch routes through [format_human]
   here, which produces a list of lines (no trailing newline) so tests
   can assert structure without re-parsing stdout. *)

(** Format a UNIX timestamp as local-time [YYYY-MM-DD HH:MM:SS]. *)
let format_timestamp (ts : float) : string =
  let t = Unix.localtime ts in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
    (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday
    t.tm_hour t.tm_min t.tm_sec

(** Render one archive entry as a header line + body line. With
    [headers=true] (default) emits:

    {v
    [YYYY-MM-DD HH:MM:SS] from-alias -> to-alias
    <content>
    v}

    With [headers=false] emits just [<content>] for grep-friendly
    output (back-compat for scripts that assumed bare bodies). *)
let format_entry ?(headers = true) (e : C2c_mcp.Broker.archive_entry) : string list =
  if headers then
    let header =
      Printf.sprintf "[%s] %s -> %s"
        (format_timestamp e.ae_drained_at)
        e.ae_from_alias
        e.ae_to_alias
    in
    [ header; e.ae_content ]
  else
    [ e.ae_content ]

(** Format a list of archive entries for human display. Returns the
    full sequence of lines (entries separated by a blank line when
    headers are enabled, joined directly otherwise). Empty input
    returns [["(no history)"]] so callers can [print_endline]
    uniformly. *)
let format_human ?(headers = true) (entries : C2c_mcp.Broker.archive_entry list) : string list =
  match entries with
  | [] -> [ "(no history)" ]
  | _ ->
      let blocks = List.map (format_entry ~headers) entries in
      if headers then
        (* Separate entries with a blank line for readability. *)
        let rec join = function
          | [] -> []
          | [ b ] -> b
          | b :: rest -> b @ [ "" ] @ join rest
        in
        join blocks
      else
        List.concat blocks
