(* c2c_hermes_config.ml — surgical edits to ~/.hermes/config.yaml.

   `c2c install hermes` must add "c2c" to plugins.enabled and
   `c2c uninstall hermes` must take it back out, without reformatting the rest
   of an operator's ~200-line config and without a YAML dependency (this repo
   hand-rolls its YAML for the same reason the registry does — see CLAUDE.md
   "Registry is hand-rolled YAML").

   The file hermes itself writes is PyYAML's default block style, in which
   sequence items sit at the SAME column as their key:

     plugins:
       enabled:
       - c2c
       - model-providers/llmp
       disabled: []
       entries:
         c2c:
           allow_tool_override: false

   Emitting a fixed 4-space item indent against that shape yields
   `enabled:` / `    - c2c` / `  - model-providers/llmp`, which PyYAML rejects
   outright (ParserError: while parsing a block mapping). So the item indent is
   DETECTED from the existing list and only falls back to PyYAML's style when
   there is no item to copy it from.

   The other shapes that have to survive intact:
     * an inline flow list (`enabled: []` — the natural shape of a fresh
       block, and of `disabled: []` in the file above): rewritten in place,
       never followed by a block item;
     * a `plugins:` mapping with no `enabled:` key: the key is inserted under
       it, because appending a second top-level `plugins:` silently destroys
       the first (PyYAML keeps the last duplicate);
     * an unrelated `enabled:` elsewhere in the file (e.g.
       `mcp_servers:` / `foo:` / `enabled: true`): never touched, because the
       scan is bounded by the `plugins:` key's own indent column;
     * `c2c` listed under `disabled:`: install strips it, otherwise install
       "succeeds" and the plugin still never loads;
     * CRLF line endings and a missing trailing newline: preserved.

   Anything this parser does not positively understand is an [Error], never a
   best-effort rewrite. Refusing to install is recoverable; corrupting a shared
   operator config is not.

   That guarantee needs key RECOGNITION to be total, not merely key PARSING.
   `"plugins":` (quoted) and `plugins :` (space before the colon) are legal
   YAML that the strict matcher below does not match; if "no strict match" were
   read as "the key is absent", the writer would append a SECOND `plugins:`,
   PyYAML would resolve the duplicate in our favour, and the operator's whole
   mapping would vanish with install reporting success. So every lookup goes
   through [find_key_total], which cross-checks a deliberately loose recogniser
   and bails when the two disagree. A UTF-8 BOM is a third such shape; that one
   is genuinely supported — [split_doc] holds it aside and [join_doc] puts it
   back, so a BOM'd config round-trips byte-identically. *)

let plugin_name = "c2c"

(* -------------------------------------------------------------------------- *)
(* Tiny YAML-shaped line predicates                                            *)
(* -------------------------------------------------------------------------- *)

let indent_width line =
  let n = String.length line in
  let rec go i = if i < n && line.[i] = ' ' then go (i + 1) else i in
  go 0

(* A tab anywhere in the leading whitespace. YAML forbids tabs for indentation,
   and our column arithmetic would be wrong anyway, so we refuse the file. *)
let leading_tab line =
  let n = String.length line in
  let rec go i =
    if i >= n then false
    else match line.[i] with ' ' -> go (i + 1) | '\t' -> true | _ -> false
  in
  go 0

let is_blank line = String.trim line = ""

let is_comment line =
  let t = String.trim line in
  String.length t > 0 && t.[0] = '#'

(* Skippable = carries no structure: blank lines and whole-line comments. *)
let is_skippable line = is_blank line || is_comment line

let body_of line =
  let i = indent_width line in
  String.sub line i (String.length line - i)

(* [key_rest body key] is [Some after_colon] when [body] is "<key>:...". *)
let key_rest body key =
  let kl = String.length key in
  if String.length body > kl && String.sub body 0 kl = key && body.[kl] = ':'
  then Some (String.sub body (kl + 1) (String.length body - kl - 1))
  else None

(* [seq_item body] is [Some raw_value] when [body] is a block sequence entry. *)
let seq_item body =
  if body = "-" then Some ""
  else if String.length body >= 2 && body.[0] = '-' && body.[1] = ' ' then
    Some (String.sub body 2 (String.length body - 2))
  else None

(* A '#' opens a comment only at the start of the scalar or after whitespace. *)
let strip_trailing_comment s =
  let n = String.length s in
  let rec go i =
    if i >= n then s
    else if s.[i] = '#' && (i = 0 || s.[i - 1] = ' ' || s.[i - 1] = '\t') then
      String.sub s 0 i
    else go (i + 1)
  in
  String.trim (go 0)

let unquote s =
  let n = String.length s in
  if
    n >= 2
    && ((s.[0] = '"' && s.[n - 1] = '"') || (s.[0] = '\'' && s.[n - 1] = '\''))
  then String.sub s 1 (n - 2)
  else s

let scalar_value s = unquote (strip_trailing_comment s)

(* [loose_key body key] — does [body] declare mapping key [key] in ANY shape,
   including the ones [key_rest] rejects: `"plugins":` (quoted, either quote
   style) and `plugins :` (space before the colon)?

   Used ONLY to detect that the strict matcher missed something real. A
   sequence entry (`- plugins: x`) does not match, because the token keeps its
   `- ` prefix; a key whose value merely mentions the name (`note: plugins: x`)
   does not match either, because only the text before the FIRST colon is
   considered. *)
let loose_key body key =
  match String.index_opt body ':' with
  | None -> false
  | Some j -> unquote (String.trim (String.sub body 0 j)) = key

let spaces n = String.make n ' '

(* -------------------------------------------------------------------------- *)
(* Line plumbing (line-ending and trailing-newline preserving)                 *)
(* -------------------------------------------------------------------------- *)

type doc = {
  bom : string; (* "\xef\xbb\xbf" when the file carries a UTF-8 BOM, else "" *)
  lines : string array; (* without line terminators *)
  crlf : bool;
  trailing_newline : bool;
}

exception Bail of string

let bail fmt = Printf.ksprintf (fun m -> raise (Bail m)) fmt

let utf8_bom = "\xef\xbb\xbf"

let split_doc (content : string) : doc =
  (* Hold the BOM aside rather than stripping it: any editor that wrote one is
     likely to want it back, and leaving it in place would make the very first
     key read as `\xef\xbb\xbfplugins` — unrecognised, and therefore appended
     to as if `plugins:` were absent. *)
  let bom, content =
    let bl = String.length utf8_bom in
    if String.length content >= bl && String.sub content 0 bl = utf8_bom then
      (utf8_bom, String.sub content bl (String.length content - bl))
    else ("", content)
  in
  let cr_count = ref 0 in
  let n = String.length content in
  let ends_nl = n > 0 && content.[n - 1] = '\n' in
  let parts = String.split_on_char '\n' content in
  let parts =
    if ends_nl then
      match List.rev parts with _ :: tl -> List.rev tl | [] -> []
    else parts
  in
  let strip_cr s =
    let m = String.length s in
    if m > 0 && s.[m - 1] = '\r' then begin
      incr cr_count;
      String.sub s 0 (m - 1)
    end
    else s
  in
  let lines = Array.of_list (List.map strip_cr parts) in
  (* Lines that were actually terminated by a newline in the source. *)
  let terminated =
    let l = Array.length lines in
    if ends_nl then l else max 0 (l - 1)
  in
  (* Mixed endings would force us to normalise every untouched line, which is
     exactly the "reformat the operator's file" outcome this module exists to
     avoid. Refuse instead. *)
  if !cr_count > 0 && !cr_count <> terminated then
    bail "mixed CRLF and LF line endings; refusing to edit this config";
  (* Document-wide, not just inside the plugins block: [indent_width] counts
     SPACES, so a tab-indented line reads as column 0 and would be mistaken for
     a top-level key — which is how an insert lands in the wrong place and
     shreds the mapping. YAML forbids tabs for indentation anyway, so any
     leading tab means our column arithmetic cannot be trusted here. *)
  Array.iteri
    (fun i line ->
       if (not (is_blank line)) && leading_tab line then
         bail "line %d indents with a TAB; refusing to edit this config" (i + 1))
    lines;
  { bom; lines; crlf = !cr_count > 0; trailing_newline = ends_nl }

let join_doc (d : doc) : string =
  let sep = if d.crlf then "\r\n" else "\n" in
  d.bom
  ^ String.concat sep (Array.to_list d.lines)
  ^ (if d.trailing_newline then sep else "")

(* -------------------------------------------------------------------------- *)
(* Structure location                                                          *)
(* -------------------------------------------------------------------------- *)

(* Last mapping key [key] at exactly column [col] within [start, stop), made
   TOTAL: the strict matcher and the loose recogniser must agree on which line
   (if any) declares the key. When they disagree, the file uses a shape this
   parser cannot edit, and we [bail] instead of proceeding as though the key
   were absent — that fallthrough is what appends a duplicate key and silently
   discards the operator's mapping.

   "Last" in both scans, because PyYAML's safe_load keeps the final duplicate
   key, so that is the one a running hermes actually sees. *)
let find_key_total lines ~start ~stop ~col ~key =
  let strict = ref None and loose = ref None in
  let stop = min stop (Array.length lines) in
  for i = start to stop - 1 do
    let line = lines.(i) in
    if (not (is_skippable line)) && indent_width line = col then begin
      let body = body_of line in
      (match key_rest body key with
       | Some rest -> strict := Some (i, rest)
       | None -> ());
      if loose_key body key then loose := Some i
    end
  done;
  match (!strict, !loose) with
  | Some (si, rest), Some li when si = li -> Some (si, rest)
  (* [key_rest] matching implies [loose_key] matching, so this arm is
     unreachable today; accept it rather than assert, so a future tweak to
     either matcher degrades to "parse it", not "crash". *)
  | Some (si, rest), None -> Some (si, rest)
  | None, None -> None
  | _, Some li ->
      bail
        "line %d declares `%s` in a shape this parser does not understand \
         (quoted key, or whitespace before the colon); refusing to edit this \
         config"
        (li + 1) key

(* First structural line after [start] whose indent is <= [parent_indent].
   Blank/comment lines never terminate a block. *)
let block_end lines start parent_indent =
  let n = Array.length lines in
  let rec go i =
    if i >= n then n
    else if is_skippable lines.(i) then go (i + 1)
    else if indent_width lines.(i) <= parent_indent then i
    else go (i + 1)
  in
  go (start + 1)

(* Index of the first line in [start, stop) that carries structure. *)
let first_structural lines start stop =
  let stop = min stop (Array.length lines) in
  let rec go i =
    if i >= stop then None
    else if is_skippable lines.(i) then go (i + 1)
    else Some i
  in
  go start

let child_indent lines start stop =
  Option.map (fun i -> indent_width lines.(i)) (first_structural lines start stop)

(* Direct child [key] of the mapping whose keys sit at column [ci]. *)
let find_child_key lines start stop ci key =
  find_key_total lines ~start ~stop ~col:ci ~key

(* -------------------------------------------------------------------------- *)
(* Sequence values under a key                                                 *)
(* -------------------------------------------------------------------------- *)

(* A key's value is either an inline flow list, a block sequence, or something
   we refuse to touch. *)
type seq_value =
  | Flow of { items : string list; trailing : string }
      (** `key: [a, b]`; [trailing] is whatever followed the `]` (a comment). *)
  | Block of { items : (int * string) list; item_indent : int option }
      (** `key:` with `- item` lines; [items] pairs line index with value. *)

let parse_flow rest =
  let t = String.trim rest in
  if String.length t = 0 || t.[0] <> '[' then None
  else
    match String.index_opt t ']' with
    | None -> bail "unterminated inline list after `enabled:`"
    | Some j ->
        let inner = String.sub t 1 (j - 1) in
        let trailing = String.trim (String.sub t (j + 1) (String.length t - j - 1)) in
        String.iter
          (fun c ->
             if c = '[' || c = ']' || c = '{' || c = '}' then
               bail "nested inline collection in `%s` is not supported" t)
          inner;
        let items =
          String.split_on_char ',' inner
          |> List.map String.trim
          |> List.filter (fun s -> s <> "")
        in
        Some (Flow { items; trailing })

(* Block sequence entries that belong to the key at line [ki] / column [kind].
   PyYAML puts items at [kind]; other emitters indent them further, so both are
   accepted, and anything deeper that is NOT a sequence entry means the value is
   a mapping (or a block scalar) and we refuse. *)
let parse_block lines ki kind stop =
  let items = ref [] in
  let item_indent = ref None in
  let rec go i =
    if i >= stop then ()
    else if is_skippable lines.(i) then go (i + 1)
    else
      let ind = indent_width lines.(i) in
      let body = body_of lines.(i) in
      match seq_item body with
      | Some v when ind >= kind ->
          if !item_indent = None then item_indent := Some ind;
          items := (i, scalar_value v) :: !items;
          go (i + 1)
      | _ ->
          if ind > kind then
            bail "`enabled:` is not a sequence (unexpected nested content)"
          else () (* sibling key: the sequence ends here *)
  in
  go (ki + 1);
  Block { items = List.rev !items; item_indent = !item_indent }

let parse_seq_value lines ki kind stop rest =
  let t = strip_trailing_comment rest in
  if t = "" then parse_block lines ki kind stop
  else
    match parse_flow rest with
    | Some v -> v
    | None -> bail "unsupported value after key: %s" (String.trim rest)

let render_flow items =
  "[" ^ String.concat ", " items ^ "]"

(* -------------------------------------------------------------------------- *)
(* Array splicing helpers                                                      *)
(* -------------------------------------------------------------------------- *)

let insert_at (lines : string array) (idx : int) (new_lines : string list) =
  let before = Array.sub lines 0 idx in
  let after = Array.sub lines idx (Array.length lines - idx) in
  Array.concat [ before; Array.of_list new_lines; after ]

let drop_indices (lines : string array) (idxs : int list) =
  Array.of_list
    (List.filteri (fun i _ -> not (List.mem i idxs)) (Array.to_list lines))

(* -------------------------------------------------------------------------- *)
(* Reading: is the plugin enabled?                                             *)
(* -------------------------------------------------------------------------- *)

type located = {
  d : doc;
  plugins_idx : int;
  plugins_stop : int;
  ci : int; (* direct-child column of the plugins mapping *)
}

let locate_plugins (content : string) : located option =
  let d = split_doc content in
  match
    find_key_total d.lines ~start:0 ~stop:(Array.length d.lines) ~col:0
      ~key:"plugins"
  with
  | None ->
      (* No `plugins:` key that a line-oriented scan can see. Before concluding
         it is absent — and appending a block — the document root must be shown
         to BE a block mapping. A whole-document flow mapping
         (`{plugins: {...}}`) hides its keys from this scan entirely, a root
         sequence has nowhere to hang a key, and a bare scalar is not a mapping
         at all; appending after any of them yields a file PyYAML cannot parse.

         The test is positive ("this line looks like a block mapping key"), not
         a list of known-bad shapes — the earlier negative form was defeated by
         a leading `---`, which is neither a sequence item nor a flow opener. *)
      let rec root_body i =
        match first_structural d.lines i (Array.length d.lines) with
        | None -> None
        | Some j ->
            let b = body_of d.lines.(j) in
            (* `%YAML`/`%TAG` directives and a bare `---` marker carry no
               mapping structure of their own; look past them. *)
            if b.[0] = '%' || strip_trailing_comment b = "---" then
              root_body (j + 1)
            else Some b
      in
      (match root_body 0 with
       (* Empty file, or nothing but comments/directives: a fresh block is the
          right answer. *)
       | None -> ()
       | Some b ->
           if seq_item b <> None then
             bail "the document root is a sequence, not a mapping; refusing to \
                   edit this config"
           else if b.[0] = '{' || b.[0] = '[' then
             bail "the document root is an inline flow collection; refusing to \
                   edit this config"
           else if String.length b >= 3 && String.sub b 0 3 = "---" then
             (* `--- model: x` puts the root mapping at column 4, so every
                column assumption below it is wrong. *)
             bail "content sits on the document-start marker; refusing to edit \
                   this config"
           else if not (String.contains b ':') then
             (* A block mapping's first key line always carries its `:`
                separator; anything else is a scalar or a shape we cannot
                append to. *)
             bail "the document root is not a block mapping; refusing to edit \
                   this config");
      None
  | Some (plugins_idx, plugins_rest) ->
      (* Tab indentation is already refused by [split_doc], document-wide. *)
      let plugins_stop = block_end d.lines plugins_idx 0 in
      if strip_trailing_comment plugins_rest <> "" then
        bail "`plugins:` has an inline value (%s); refusing to edit it"
          (String.trim plugins_rest);
      (* The VALUE must be a mapping. `plugins:` followed by `- alpha` is a
         perfectly good sequence; inserting `enabled:` into it either retypes
         the node (swallowing the operator's list) or produces a file PyYAML
         rejects outright. This cannot be scoped by [plugins_stop]: a block
         sequence may sit at the KEY's own column, in which case [block_end]
         stops at the first `- ` line and the mapping looks merely empty. *)
      (match first_structural d.lines (plugins_idx + 1) (Array.length d.lines) with
       | Some i when seq_item (body_of d.lines.(i)) <> None ->
           bail "`plugins:` is a sequence, not a mapping; refusing to edit this \
                 config"
       | _ -> ());
      let ci =
        match child_indent d.lines (plugins_idx + 1) plugins_stop with
        | Some c -> c
        | None -> 2 (* empty mapping — PyYAML's two-space child indent *)
      in
      Some { d; plugins_idx; plugins_stop; ci }

let enabled_items_of (l : located) : string list =
  match find_child_key l.d.lines (l.plugins_idx + 1) l.plugins_stop l.ci "enabled" with
  | None -> []
  | Some (ki, rest) -> (
      match parse_seq_value l.d.lines ki l.ci l.plugins_stop rest with
      | Flow { items; _ } -> List.map scalar_value items
      | Block { items; _ } -> List.map snd items)

(** [is_enabled content] — is "c2c" listed under plugins.enabled?
    Scoped to the `enabled:` block only: a `c2c` under `disabled:` must NOT
    read as enabled, or install no-ops while the plugin never loads. Returns
    [false] for any config this module refuses to parse. *)
let is_enabled (content : string) : bool =
  try
    match locate_plugins content with
    | None -> false
    | Some l -> List.mem plugin_name (enabled_items_of l)
  with Bail _ -> false

(* -------------------------------------------------------------------------- *)
(* Writing                                                                     *)
(* -------------------------------------------------------------------------- *)

(* PyYAML's own block style: two-space child indent, sequence items at the
   key's column. This is what hermes rewrites the file as anyway. *)
let fresh_block =
  [ "plugins:"; "  enabled:"; "  - " ^ plugin_name; "  disabled: []" ]

(* Append a whole `plugins:` mapping to a file that has none. *)
let append_fresh_block (content : string) : string =
  let d = split_doc content in
  let existing = Array.to_list d.lines in
  let existing =
    (* An empty file splits to [""]; do not emit a leading blank line. *)
    match existing with [ "" ] -> [] | _ -> existing
  in
  let sep = if d.crlf then "\r\n" else "\n" in
  let all = existing @ fresh_block in
  d.bom ^ String.concat sep all ^ sep

(* Remove [plugin_name] from a `disabled:` list, if present. Returns the new
   line array. Install must do this: a plugin listed in BOTH enabled and
   disabled stays off, so adding to `enabled` alone "succeeds" and does
   nothing. *)
let strip_from_disabled (lines : string array) ~plugins_idx ~plugins_stop ~ci =
  match find_child_key lines (plugins_idx + 1) plugins_stop ci "disabled" with
  | None -> lines
  | Some (ki, rest) -> (
      match parse_seq_value lines ki ci plugins_stop rest with
      | Flow { items; trailing } ->
          let kept =
            List.filter (fun it -> scalar_value it <> plugin_name) items
          in
          if List.length kept = List.length items then lines
          else begin
            let lines = Array.copy lines in
            lines.(ki) <-
              spaces ci ^ "disabled: " ^ render_flow kept
              ^ (if trailing = "" then "" else " " ^ trailing);
            lines
          end
      | Block { items; _ } ->
          let doomed =
            List.filter_map
              (fun (i, v) -> if v = plugin_name then Some i else None)
              items
          in
          if doomed = [] then lines
          else if List.length doomed = List.length items then begin
            (* Removing every item would leave a valueless `disabled:` (null,
               not []), so collapse it to an explicit empty flow list. *)
            let lines = drop_indices lines doomed in
            let shift = List.length (List.filter (fun i -> i < ki) doomed) in
            let lines = Array.copy lines in
            lines.(ki - shift) <- spaces ci ^ "disabled: []";
            lines
          end
          else drop_indices lines doomed)

(** [enable content] returns the config with "c2c" present exactly once under
    plugins.enabled and absent from plugins.disabled. The result is
    byte-identical to [content] when nothing had to change. *)
let enable (content : string) : (string, string) result =
  try
    match locate_plugins content with
    | None -> Ok (append_fresh_block content)
    | Some l -> (
        let lines = strip_from_disabled l.d.lines
                      ~plugins_idx:l.plugins_idx ~plugins_stop:l.plugins_stop ~ci:l.ci
        in
        (* strip_from_disabled can only delete or rewrite lines *inside* the
           plugins block, so re-derive the block end rather than trusting a
           stale index. *)
        let plugins_stop = block_end lines l.plugins_idx 0 in
        match find_child_key lines (l.plugins_idx + 1) plugins_stop l.ci "enabled" with
        | None ->
            (* `plugins:` exists but has no `enabled:` key. Insert one under it
               — appending a second top-level `plugins:` would silently destroy
               `disabled:` / `entries:` (PyYAML keeps the last duplicate). *)
            let lines =
              insert_at lines (l.plugins_idx + 1)
                [ spaces l.ci ^ "enabled:"; spaces l.ci ^ "- " ^ plugin_name ]
            in
            Ok (join_doc { l.d with lines })
        | Some (ki, rest) -> (
            match parse_seq_value lines ki l.ci plugins_stop rest with
            | Flow { items; trailing } ->
                if List.exists (fun it -> scalar_value it = plugin_name) items then
                  Ok (join_doc { l.d with lines })
                else begin
                  let lines = Array.copy lines in
                  lines.(ki) <-
                    spaces l.ci ^ "enabled: "
                    ^ render_flow (items @ [ plugin_name ])
                    ^ (if trailing = "" then "" else " " ^ trailing);
                  Ok (join_doc { l.d with lines })
                end
            | Block { items; item_indent } ->
                if List.exists (fun (_, v) -> v = plugin_name) items then
                  Ok (join_doc { l.d with lines })
                else begin
                  (* Copy the existing item indent; PyYAML's block style puts
                     items at the key's own column, so that is the fallback. *)
                  let ind = match item_indent with Some i -> i | None -> l.ci in
                  let after =
                    match List.rev items with
                    | (last_idx, _) :: _ -> last_idx + 1
                    | [] -> ki + 1
                  in
                  let lines =
                    insert_at lines after [ spaces ind ^ "- " ^ plugin_name ]
                  in
                  Ok (join_doc { l.d with lines })
                end))
  with
  | Bail msg -> Error msg
  | Invalid_argument msg -> Error ("malformed config: " ^ msg)

(** [disable content] removes "c2c" from plugins.enabled, leaving every other
    key (including `disabled:` and `entries:`) untouched. Byte-identical output
    when "c2c" was not listed. *)
let disable (content : string) : (string, string) result =
  try
    match locate_plugins content with
    | None -> Ok content
    | Some l -> (
        match
          find_child_key l.d.lines (l.plugins_idx + 1) l.plugins_stop l.ci "enabled"
        with
        | None -> Ok content
        | Some (ki, rest) -> (
            match parse_seq_value l.d.lines ki l.ci l.plugins_stop rest with
            | Flow { items; trailing } ->
                let kept =
                  List.filter (fun it -> scalar_value it <> plugin_name) items
                in
                if List.length kept = List.length items then Ok content
                else begin
                  let lines = Array.copy l.d.lines in
                  lines.(ki) <-
                    spaces l.ci ^ "enabled: " ^ render_flow kept
                    ^ (if trailing = "" then "" else " " ^ trailing);
                  Ok (join_doc { l.d with lines })
                end
            | Block { items; _ } ->
                let doomed =
                  List.filter_map
                    (fun (i, v) -> if v = plugin_name then Some i else None)
                    items
                in
                if doomed = [] then Ok content
                else if List.length doomed = List.length items then begin
                  (* Last entry: a bare `enabled:` would parse as null, so make
                     the now-empty list explicit. *)
                  let lines = drop_indices l.d.lines doomed in
                  let shift = List.length (List.filter (fun i -> i < ki) doomed) in
                  lines.(ki - shift) <- spaces l.ci ^ "enabled: []";
                  Ok (join_doc { l.d with lines })
                end
                else Ok (join_doc { l.d with lines = drop_indices l.d.lines doomed })))
  with
  | Bail msg -> Error msg
  | Invalid_argument msg -> Error ("malformed config: " ^ msg)
