(* c2c_watch_render.ml — PURE render layer for `c2c watch` (slices B0, B2).

   This module is deliberately terminal-free: NO lambda-term, NO IO, no
   reads of the clock / environment / randomness. Every output is a pure
   function of its arguments, which is what makes the golden snapshot
   tests in [test_c2c_watch_render.ml] a deterministic plaintext diff
   (an agent can review the diff without a real terminal — see spec §9).

   The render/state separation (spec §2) keeps lambda-term confined to
   [c2c_watch.ml]; everything visual is assembled here as a plain string.

   PLAIN TEXT (no ANSI color escapes). Liveness is conveyed entirely by the
   GLYPH — ● Alive / ○ Dead / ? Unknown — not by colour, so the output is a
   byte-stable golden surface. Colour styling is explicitly DEFERRED to a
   later slice; when added it must wrap the plain string in [c2c_watch.ml]'s
   draw path (e.g. an LTerm style matrix) and never on this pure path.

   The "refreshed Xs ago" header text is NOT computed here — it is read
   verbatim from [State.refreshed_label], which the impure loop in
   [c2c_watch.ml] sets from the clock. Render never touches [Unix.time].

   Column math uses a UTF-8 codepoint-count display-width helper [disp_width]
   (NOT [Banner.visible_width], which is byte-based and over-counts the 3-byte
   box-drawing / liveness glyphs). All padding/truncation goes through
   [pad_to] / [truncate_to] so every emitted line is exactly [cols] DISPLAY
   columns wide. *)

(* Box-drawing glyphs (each renders as exactly one terminal column). *)
let tl = "\xe2\x94\x8c" (* ┌ U+250C *)
let tr = "\xe2\x94\x90" (* ┐ U+2510 *)
let bl = "\xe2\x94\x94" (* └ U+2514 *)
let br = "\xe2\x94\x98" (* ┘ U+2518 *)
let h  = "\xe2\x94\x80" (* ─ U+2500 *)
let v  = "\xe2\x94\x82" (* │ U+2502 *)

(* Repeat a single-column glyph [n] times (n>=0). *)
let repeat_glyph (g : string) (n : int) : string =
  if n <= 0 then ""
  else begin
    let buf = Buffer.create (String.length g * n) in
    for _ = 1 to n do Buffer.add_string buf g done;
    Buffer.contents buf
  end

(* [render_empty_frame ~cols ~rows] returns a framed empty pane:
   - a top border line   (┌────┐)
   - [rows-2] side-bordered blank lines (│  ...  │)
   - a bottom border line (└────┘)
   joined by '\n'. Each line is exactly [cols] display columns wide.

   Degenerate sizes are clamped so the function is total: a frame needs
   at least 2 columns (the two walls) and at least 2 rows (top+bottom
   border). Below that we still emit something well-formed rather than
   raising — the watcher should never crash on a tiny terminal. *)
let render_empty_frame ~(cols : int) ~(rows : int) : string =
  let cols = if cols < 2 then 2 else cols in
  let rows = if rows < 2 then 2 else rows in
  let inner_cols = cols - 2 in
  let top = tl ^ repeat_glyph h inner_cols ^ tr in
  let bottom = bl ^ repeat_glyph h inner_cols ^ br in
  (* A blank interior row: left wall, [inner_cols] spaces, right wall.
     [Banner.pad_right ""] gives exactly [inner_cols] ASCII spaces. *)
  let blank = v ^ Banner.pad_right "" inner_cols ^ v in
  let interior_rows = rows - 2 in
  let lines =
    top
    :: (List.init interior_rows (fun _ -> blank))
    @ [ bottom ]
  in
  String.concat "\n" lines

(* ===== B2: display-width helpers + the live [render] ==================== *)

(* Count UTF-8 code points in [s]. Every glyph this module renders (ASCII +
   box-drawing ─│┌┐└┘ + liveness ●○ + selection ▸) is exactly one code point
   AND one display column, so code-point count == display width here. This is
   the SAME counter the B0 test uses for its dimension invariant; defining it
   here lets the renderer pad/truncate to display columns. *)
let disp_width (s : string) : int =
  let n = String.length s and i = ref 0 and count = ref 0 in
  while !i < n do
    let c = Char.code s.[!i] in
    let step =
      if c < 0x80 then 1
      else if c < 0xE0 then 2
      else if c < 0xF0 then 3
      else 4
    in
    i := !i + step;
    incr count
  done;
  !count

(* Take the first [w] display columns of [s] (whole code points only). *)
let take_disp (s : string) (w : int) : string =
  if w <= 0 then ""
  else begin
    let n = String.length s and i = ref 0 and count = ref 0 in
    while !i < n && !count < w do
      let c = Char.code s.[!i] in
      let step =
        if c < 0x80 then 1
        else if c < 0xE0 then 2
        else if c < 0xF0 then 3
        else 4
      in
      i := !i + step;
      incr count
    done;
    String.sub s 0 !i
  end

(* Truncate [s] to at most [w] display columns, appending a single-column
   ellipsis '…' when truncation actually drops content (so the result is
   never wider than [w]). [w<=0] -> "". *)
let truncate_to (s : string) (w : int) : string =
  if disp_width s <= w then s
  else if w <= 0 then ""
  else if w = 1 then "\xe2\x80\xa6" (* … alone *)
  else take_disp s (w - 1) ^ "\xe2\x80\xa6"

(* Pad/truncate [s] to EXACTLY [w] display columns: truncate (with ellipsis)
   if wider, right-pad with ASCII spaces if narrower. *)
let pad_to (s : string) (w : int) : string =
  let s = truncate_to s w in
  let dw = disp_width s in
  if dw >= w then s else s ^ String.make (w - dw) ' '

(* A left-aligned table cell of EXACTLY [w] display columns that always keeps
   at least one trailing space as a column separator: content is truncated to
   [w-1] columns (ellipsis if needed) then padded to [w]. Without this a value
   that fills the column (e.g. an 18-col alias, or a truncated long alias)
   butts directly against the next column with no gap — caught in live QA. *)
let cell (s : string) (w : int) : string =
  if w <= 1 then pad_to s w else pad_to (truncate_to s (w - 1)) w

(* Liveness glyph (one display column). Plain text — colour deferred. *)
let liveness_glyph (l : C2c_watch_data.Broker.liveness_state) : string =
  match l with
  | C2c_watch_data.Broker.Alive -> "\xe2\x97\x8f" (* ● *)
  | C2c_watch_data.Broker.Dead -> "\xe2\x97\x8b" (* ○ *)
  | C2c_watch_data.Broker.Unknown -> "?"

(* Optional sparse string field: the value, or '—' (em dash) when None. *)
let opt_field = function Some "" | None -> "\xe2\x80\x94" | Some s -> s

(* Flags column: dnd / compacting state. '-' when neither (spec §3.1). *)
let flags_of_peer (p : C2c_watch_data.peer_row) : string =
  let parts =
    (if p.pr_dnd then [ "dnd" ] else [])
    @ (match p.pr_compacting with Some _ -> [ "compacting" ] | None -> [])
  in
  match parts with [] -> "-" | _ -> String.concat "," parts

(* Column widths for the Peers roster (interior is [cols]-2 display columns;
   for cols=80 that is 78 = 2+18+6+12+8+20+12). The last-activity column is
   20 to hold "YYYY-MM-DD HH:MM:SS" (19) + a trailing space. *)
let col_marker = 2
let col_alias = 18
let col_live = 6
let col_role = 12
let col_client = 8
let col_last = 20

(* Wrap an interior content string (already padded to [inner]) in side walls. *)
let wall (inner_cols : int) (content : string) : string =
  v ^ pad_to content inner_cols ^ v

(* The framed title border: "┌ c2c watch ─── broker: <root> ─── [P]eers …┐"
   exactly [cols] display columns. The broker root is truncated with an
   ellipsis if the whole line would exceed [cols] (real broker roots are
   long). Build the labelled segments, then fill the remaining run with ─. *)
let title_border ~(cols : int) ~(broker_root : string) : string =
  (* Spec §3.1 form:
       ┌ c2c watch ──── broker: <root> ──── [P]eers  [D]Ms  [R]ooms ┐
     A fixed lead "┌ c2c watch ──── broker: ", then the (truncated) root, then
     a ─ fill that absorbs the slack, then the tabs and ┐. The fill keeps the
     row exactly [cols] display columns regardless of the root length. *)
  let lead = " c2c watch " ^ repeat_glyph h 4 ^ " broker: " in
  let tabs = " [P]eers  [D]Ms  [R]ooms " in
  (* Reserve: tl(1) + lead + a trailing " " ─ gap + tabs + tr(1). Whatever
     remains is the root budget (floored at 0). *)
  let fixed =
    1 (* tl *) + disp_width lead + 1 (* gap after root *)
    + disp_width tabs + 1 (* tr *)
  in
  let root_budget = cols - fixed in
  let root_shown =
    if root_budget <= 0 then "" else truncate_to broker_root root_budget
  in
  let assembled = lead ^ root_shown ^ " " in
  (* Fill between [assembled] and [tabs] with ─ so the row is exactly cols. *)
  let used = 1 (* tl *) + disp_width assembled + disp_width tabs + 1 (* tr *) in
  let fill = max 0 (cols - used) in
  let line = tl ^ assembled ^ repeat_glyph h fill ^ tabs ^ tr in
  (* Exact-width contract guard: on a terminal too narrow to hold the fixed
     lead + tabs (even with the root dropped), [fill] floors at 0 and [line]
     would exceed [cols]. Degrade to a plain border that is EXACTLY [cols]
     display columns — the frame stays rectangular at any size. *)
  if disp_width line > cols then tl ^ repeat_glyph h (max 0 (cols - 2)) ^ tr
  else line

(* One interior text row (left-aligned, padded), bordered. *)
let text_row ~(inner_cols : int) (s : string) : string = wall inner_cols s

(* Render the Peers tab body rows (header + roster) into interior strings of
   width [inner_cols]. Returns the list of CONTENT strings (no walls). *)
let peers_body ~(inner_cols : int) ~(peers : C2c_watch_data.peer_row list)
    ~(sel : int) : string list =
  (* Column header. *)
  let header =
    String.make col_marker ' '
    ^ pad_to "alias" col_alias
    ^ pad_to "live" col_live
    ^ pad_to "role" col_role
    ^ pad_to "client" col_client
    ^ pad_to "last-activity" col_last
    ^ "flags"
  in
  let row i (p : C2c_watch_data.peer_row) =
    let marker = if i = sel then "\xe2\x96\xb8 " (* ▸ + space *) else "  " in
    let last =
      match p.pr_last_activity with
      | Some ts -> C2c_history.format_timestamp ts
      | None -> "\xe2\x80\x94" (* — *)
    in
    marker
    ^ cell (opt_field (Some p.pr_alias)) col_alias
    ^ pad_to (liveness_glyph p.pr_liveness) col_live
    ^ cell (opt_field p.pr_role) col_role
    ^ cell (opt_field p.pr_client_type) col_client
    ^ cell last col_last
    ^ flags_of_peer p
  in
  let _ = inner_cols in
  header :: List.mapi row peers

(* Placeholder body for the Rooms tab (B4 implements it). *)
let placeholder_body (label : string) : string list = [ ""; "  " ^ label; "" ]

(* ===== B3: DMs tab — two-pane shard browser ============================== *)

(* The DMs left pane (shard list) is a fixed-width column; the right pane (the
   selected shard's detail) takes the remaining interior width with a single
   vertical separator between. Tuned for cols=80 (inner=78): 24 + 1 + 53.
   Degrades gracefully on narrow panes (see [dms_split_widths]). *)
let dms_left_w = 24

(* First 8 chars (display columns) of a session_id, plus an ellipsis when the
   id is longer than 8 (real sids are UUID-shaped, always longer). *)
let sid8 (sid : string) : string =
  if disp_width sid <= 8 then sid else take_disp sid 8 ^ "\xe2\x80\xa6" (* … *)

(* Derive the display label for a shard. A normal shard uses its registry
   owner alias. An ORPHAN shard (ds_owner_alias=None) has no registration, so
   we recover a label from the shard's own messages: the archive shard is the
   destination inbox of one session, so [ae_to_alias] on every row is that
   session's owner alias (they all agree) — use the newest entry's to_alias.
   [ds_entries] is NEWEST-FIRST (Broker.read_archive reverses on read), so the
   newest entry is the HEAD. Fallbacks: an in-flight row's to_alias, then the
   short session_id. PURE — a function only of the shard. *)
let dms_shard_label (s : C2c_watch_data.dm_shard) : string =
  match s.ds_owner_alias with
  | Some a -> a
  | None -> (
      (* Newest archive entry = head of the newest-first list. *)
      match s.ds_entries with
      | (e : C2c_watch_data.Broker.archive_entry) :: _ when e.ae_to_alias <> "" ->
          e.ae_to_alias
      | _ -> (
          match s.ds_inflight with
          | (m : C2c_mcp.message) :: _ when m.to_alias <> "" -> m.to_alias
          | _ -> sid8 s.ds_session_id))

(* Total entry count surfaced for a shard = archived rows + in-flight rows.
   (Documented choice: count INCLUDES in-flight so the left-pane count matches
   the number of detail rows the right pane will show.) *)
let dms_shard_count (s : C2c_watch_data.dm_shard) : int =
  List.length s.ds_entries + List.length s.ds_inflight

(* One left-pane shard row (CONTENT only, exactly [w] display columns):
   "<marker><label> <sid8> <count-or-⚠count>". Orphan shards show ⚠ before the
   count. A second cue line "(orphan: sid gone)" is emitted separately by the
   caller for orphan shards. *)
let dms_shard_row ~(w : int) ~(selected : bool) (s : C2c_watch_data.dm_shard) :
    string =
  let marker = if selected then "\xe2\x96\xb8 " (* ▸ + space *) else "  " in
  let count = dms_shard_count s in
  let count_str =
    if s.ds_is_orphan then "\xe2\x9a\xa0" (* ⚠ *) ^ string_of_int count
    else string_of_int count
  in
  let label = dms_shard_label s in
  let sid = sid8 s.ds_session_id in
  (* marker(2) + label + " " + sid + " " + count_str, padded/truncated to [w].
     The label is the flexible field: reserve room for the sid + count + gaps,
     truncate the label to whatever's left. *)
  let fixed = 2 (* marker *) + 1 + disp_width sid + 1 + disp_width count_str in
  let label_budget = max 0 (w - fixed) in
  let label_shown = truncate_to label label_budget in
  let row =
    marker ^ pad_to label_shown label_budget ^ " " ^ sid ^ " " ^ count_str
  in
  pad_to row w

(* The full left-pane CONTENT lines (no walls, no separator) for the shard
   list, exactly [w] display columns each. Orphan shards get a follow-up cue
   line. Returns lines in list order (one or two per shard). *)
let dms_left_lines ~(w : int) ~(shards : C2c_watch_data.dm_shard list)
    ~(sel : int) : string list =
  List.concat
    (List.mapi
       (fun i (s : C2c_watch_data.dm_shard) ->
         let row = dms_shard_row ~w ~selected:(i = sel) s in
         if s.ds_is_orphan then
           [ row; pad_to "     (orphan: sid gone)" w ]
         else [ row ])
       shards)

(* Build the right-pane detail CONTENT lines (no walls) for ONE shard, each
   exactly [w] display columns. Archive entries render oldest-first as a
   "[<ts>] <from> -> <to>" header + wrapped content; in-flight rows append at
   the TAIL marked "‹in-flight› [undrained] <from> -> <to>" + content. A blank
   line separates entries.

   PURE except for [C2c_history.format_timestamp] which reads localtime — the
   tests force TZ=UTC so this stays deterministic (spec §9). *)

(* Wrap [content] into >=1 line(s) of <= [w] display columns (whole code
   points). A long line is split into successive [w]-wide chunks. Empty
   content yields a single blank line so every entry has a body row. *)
let wrap_content (content : string) (w : int) : string list =
  if w <= 0 then [ "" ]
  else begin
    (* Split on embedded newlines first (archive content can be multi-line),
       then hard-wrap each segment to [w] columns. *)
    let segs = String.split_on_char '\n' content in
    let chunks_of (seg : string) : string list =
      if disp_width seg = 0 then [ "" ]
      else begin
        let acc = ref [] and rest = ref seg in
        while disp_width !rest > 0 do
          let head = take_disp !rest w in
          acc := head :: !acc;
          rest := String.sub !rest (String.length head)
                    (String.length !rest - String.length head)
        done;
        List.rev !acc
      end
    in
    List.concat_map chunks_of segs
  end

(* Per-entry detail blocks for a shard, in CHRONOLOGICAL display order (oldest
   at the TOP, newest at the BOTTOM — chat convention). ORDER IS LOAD-BEARING:
   [ds_entries] arrives NEWEST-FIRST from [Broker.read_archive] (it reverses on
   read — see the "reverse to get newest-first" tail of read_archive in
   c2c_broker.ml ~:2465), so we [List.rev] it here to put oldest at the top.
   [ds_inflight] arrives OLDEST-FIRST (inbox arrival order via load_inbox) and
   is the most-recent, still-undrained traffic, so it appends AFTER the archive
   at the very bottom, in arrival order. Each block = a "[<ts>] <from> -> <to>"
   header (or "‹in-flight› [undrained] ..." for inflight) + its wrapped content
   (>=1 line). PURE except for [C2c_history.format_timestamp] (localtime; tests
   force TZ=UTC for byte-stable goldens, spec §9). *)
let dms_detail_blocks ~(w : int) (s : C2c_watch_data.dm_shard) : string list list =
  let entry_block (e : C2c_watch_data.Broker.archive_entry) : string list =
    let header =
      Printf.sprintf "[%s] %s -> %s"
        (C2c_history.format_timestamp e.ae_drained_at)
        e.ae_from_alias e.ae_to_alias
    in
    header :: wrap_content e.ae_content w
  in
  let inflight_block (m : C2c_mcp.message) : string list =
    let header =
      Printf.sprintf "\xe2\x80\xb9in-flight\xe2\x80\xba [undrained] %s -> %s"
        (* ‹in-flight› *)
        m.from_alias m.to_alias
    in
    header :: wrap_content m.content w
  in
  (* rev archive (newest-first -> oldest-first) ++ inflight (arrival order). *)
  List.map entry_block (List.rev s.ds_entries)
  @ List.map inflight_block s.ds_inflight

(* Flatten chronological detail [blocks] (oldest-first) into CONTENT lines and
   clip to [avail] rows, keeping the NEWEST that fit (the TAIL — newest is at
   the bottom). When older ENTRIES are dropped, the first visible row is a
   "(N older hidden)" marker counting hidden ENTRIES (messages), not lines, and
   it counts against [avail]. [avail<=0] -> []. *)
let dms_detail_clip ~(avail : int) (blocks : string list list) : string list =
  if avail <= 0 then []
  else begin
    let sep = [ "" ] in
    let rec join = function
      | [] -> []
      | [ b ] -> b
      | b :: rest -> b @ sep @ join rest
    in
    let flat = join blocks in
    let total = List.length flat in
    if total <= avail then flat
    else begin
      (* Reserve one row for the marker; keep the last [avail-1] lines. *)
      let keep = max 0 (avail - 1) in
      let drop_n = total - keep in
      let rec drop n = function
        | l when n <= 0 -> l
        | [] -> []
        | _ :: rest -> drop (n - 1) rest
      in
      let tail = drop drop_n flat in
      (* Count ENTRIES entirely within the dropped prefix. Walk blocks from
         oldest, accumulating each block's flat span (its lines + 1 trailing
         separator); a block is fully hidden when its span ends within
         [drop_n]. At least 1 (a partially-scrolled entry still counts). *)
      let rec count_hidden pos hidden = function
        | [] -> hidden
        | b :: rest ->
            let next = pos + List.length b + 1 in
            if next <= drop_n then count_hidden next (hidden + 1) rest
            else hidden
      in
      let hidden = max 1 (count_hidden 0 0 blocks) in
      Printf.sprintf "(%d older hidden)" hidden :: tail
    end
  end

(* Choose the left/right pane widths for an inner width [inner_cols]. Returns
   [(left, right)] where [left + 1 (separator) + right = inner_cols]. On a
   narrow inner pane (cannot hold the preferred 24-col left + a usable right),
   shrink the left pane; if even that doesn't fit, fall back to left=0 (no
   separator handled by the caller). PURE. *)
let dms_split_widths (inner_cols : int) : int * int =
  (* Need at least 1 separator col + 1 col each side to be a real split. *)
  if inner_cols < 3 then (0, inner_cols)
  else begin
    let left = min dms_left_w (inner_cols - 1 - 1) (* leave >=1 for right *) in
    let left = max 1 left in
    let right = inner_cols - 1 - left in
    (left, right)
  end

(* The DMs heading line CONTENT (no walls), exactly [inner_cols] columns:
   "DMs — shard: <label> (<sid8>) <N> entries          [S shards · O orphan]".
   When there are no shards: "DMs — no DM shards". *)
let dms_heading ~(inner_cols : int) ~(snapshot : C2c_watch_data.snapshot)
    ~(sel : int) : string =
  let shards = snapshot.shards in
  let total = List.length shards in
  let orphans = List.length (List.filter (fun s -> s.C2c_watch_data.ds_is_orphan) shards) in
  if total = 0 then pad_to " DMs \xe2\x80\x94 no DM shards" inner_cols (* — *)
  else begin
    let sel = if sel < 0 then 0 else if sel > total - 1 then total - 1 else sel in
    let s = List.nth shards sel in
    let label = dms_shard_label s in
    let n = dms_shard_count s in
    let left =
      Printf.sprintf " DMs \xe2\x80\x94 shard: %s (%s)  %d entries" label
        (sid8 s.C2c_watch_data.ds_session_id) n
    in
    let right =
      Printf.sprintf "[%d shards \xc2\xb7 %d orphan] " total orphans (* · *)
    in
    let lw = disp_width left and rw = disp_width right in
    if lw + 1 + rw >= inner_cols then truncate_to (left ^ " " ^ right) inner_cols
    else left ^ String.make (inner_cols - lw - rw) ' ' ^ right
  end

(* Compose the DMs interior CONTENT lines (no walls), exactly [body_budget]
   rows. Row layout within the body budget:
     row 0      : the two-pane column titles ("shards (S)" │ detail-context)
     rows 1..   : left shard list | right detail, joined by │ per row
   Each composed row is exactly [inner_cols] display columns. *)
let dms_body ~(inner_cols : int) ~(body_budget : int)
    ~(snapshot : C2c_watch_data.snapshot) ~(sel : int) : string list =
  let shards = snapshot.shards in
  let left_w, right_w = dms_split_widths inner_cols in
  let has_split = left_w > 0 && right_w > 0 in
  (* Compose one body row from optional left + right content. *)
  let compose (l : string) (r : string) : string =
    if has_split then pad_to l left_w ^ v ^ pad_to r right_w
    else pad_to l inner_cols
  in
  if body_budget <= 0 then []
  else if shards = [] then
    (* Empty broker: a single clean "no DM shards" body line + blanks. *)
    let first = compose "  no DM shards" "" in
    first :: List.init (max 0 (body_budget - 1)) (fun _ -> pad_to "" inner_cols)
  else begin
    let sel = if sel < 0 then 0 else if sel > List.length shards - 1 then List.length shards - 1 else sel in
    (* Title row: left "shards (S)" / right header for the selected shard. *)
    let title_l = Printf.sprintf "shards (%d)" (List.length shards) in
    let title_r = if has_split then "detail" else "" in
    let title_row = compose title_l title_r in
    (* Body rows below the title fill [body_budget-1] rows. *)
    let inner_rows = max 0 (body_budget - 1) in
    let left_lines = dms_left_lines ~w:left_w ~shards ~sel in
    let sel_shard = List.nth shards sel in
    let right_lines =
      if has_split then dms_detail_clip ~avail:inner_rows
          (dms_detail_blocks ~w:right_w sel_shard)
      else []
    in
    (* Pair up left/right lines row-by-row; pad the shorter side with blanks. *)
    let nth_or_blank lst i = match List.nth_opt lst i with Some x -> x | None -> "" in
    let rows =
      List.init inner_rows (fun i ->
          compose (nth_or_blank left_lines i) (nth_or_blank right_lines i))
    in
    title_row :: rows
  end

(* The DMs footer (spec §3.2): hidden-room note + key legend. *)
let dms_footer : string =
  " #room rows hidden here (see Rooms)   "
  ^ "\xe2\x86\x91/\xe2\x86\x93 shard \xc2\xb7 Enter\xe2\x86\x92reply \xc2\xb7 / search"
  (* ↑/↓ shard · Enter→reply · / search *)

(* The status/legend footer for the active tab. *)
let footer_for (tab : C2c_watch_state.tab) : string =
  (* One leading space for breathing room (spec mockup: "│ ● alive"). *)
  " "
  ^
  match tab with
  | C2c_watch_state.Peers ->
      "\xe2\x97\x8f alive  \xe2\x97\x8b dead  ? unknown(null)   "
      ^ "\xe2\x86\x91/\xe2\x86\x93 select \xc2\xb7 Enter\xe2\x86\x92DM \xc2\xb7 r refresh"
  | C2c_watch_state.DMs ->
      (* The DMs tab supplies its own footer via [dms_footer]; this leg is
         unused (render branches the DMs tab before [footer_for]) but kept
         total for the variant. *)
      "DMs"
  | C2c_watch_state.Rooms -> "Rooms detail \xe2\x80\x94 coming in B4"

(* The PEERS/DMs/ROOMS heading line, with the right-aligned refreshed label. *)
let heading_line ~(inner_cols : int) ~(tab : C2c_watch_state.tab)
    ~(snapshot : C2c_watch_data.snapshot) ~(refreshed_label : string) : string =
  let left =
    match tab with
    | C2c_watch_state.Peers ->
        Printf.sprintf "PEERS (%d)" (List.length snapshot.peers)
    | C2c_watch_state.DMs ->
        Printf.sprintf "DMs (%d)" (List.length snapshot.shards)
    | C2c_watch_state.Rooms ->
        Printf.sprintf "ROOMS (%d)" (List.length snapshot.rooms)
  in
  (* One leading space for breathing room (spec mockup: "│ PEERS (4)"). *)
  let left = " " ^ left in
  let lw = disp_width left and rw = disp_width refreshed_label in
  if lw + 1 + rw >= inner_cols then
    (* Not enough room to right-align; just left + truncate. *)
    truncate_to (left ^ " " ^ refreshed_label) inner_cols
  else
    let gap = inner_cols - lw - rw in
    left ^ String.make gap ' ' ^ refreshed_label

(* [render ~cols ~rows ~snapshot ~state] returns the full framed frame for the
   ACTIVE tab, exactly [cols] display columns per line and [rows] lines.
   PURE — a function only of its arguments (spec §1).

   Layout (spec §3.1):
     row 0        : title border (┌ c2c watch ─ broker: … ─ [P]eers …┐)
     row 1        : heading line (PEERS (N) … <refreshed_label>)
     row 2        : blank
     rows 3..k    : tab body (Peers roster | DMs/Rooms placeholder)
     row rows-2   : footer/legend line
     row rows-1   : bottom border (└──────┘)
   Interior body rows beyond the content are blank-padded so the frame is a
   solid rows×cols block. *)
let render ~(cols : int) ~(rows : int) ~(snapshot : C2c_watch_data.snapshot)
    ~(state : C2c_watch_state.t) : string =
  let cols = if cols < 8 then 8 else cols in
  let rows = if rows < 5 then 5 else rows in
  let inner_cols = cols - 2 in
  let top = title_border ~cols ~broker_root:snapshot.broker_root in
  let bottom = bl ^ repeat_glyph h inner_cols ^ br in
  (* The interior holds rows-2 lines (top+bottom borders consume 2). The
     footer occupies the last interior row; everything above it is the body
     budget. *)
  let interior_count = rows - 2 in
  let body_budget = max 0 (interior_count - 1) in
  (* [take n] keeps the first [n] elements (tiny-term truncation). *)
  let take n l =
    let rec go n = function
      | [] -> []
      | _ when n <= 0 -> []
      | x :: rest -> x :: go (n - 1) rest
    in
    go n l
  in
  let interior_text =
    match state.tab with
    | C2c_watch_state.DMs ->
        (* The DMs tab composes its OWN interior: its custom heading + a blank
           + the two-pane body sized to fill the remaining budget + its custom
           footer. Heading + blank consume 2 of [body_budget]; the two-pane
           body takes the rest. *)
        let heading =
          dms_heading ~inner_cols ~snapshot ~sel:state.dms_sel
        in
        let body_rows = max 0 (body_budget - 2) in
        let body =
          dms_body ~inner_cols ~body_budget:body_rows ~snapshot
            ~sel:state.dms_sel
        in
        let head_lines = take body_budget (heading :: "" :: body) in
        let fill_n = max 0 (body_budget - List.length head_lines) in
        head_lines @ List.init fill_n (fun _ -> "") @ [ dms_footer ]
    | C2c_watch_state.Peers | C2c_watch_state.Rooms ->
        let heading =
          heading_line ~inner_cols ~tab:state.tab ~snapshot
            ~refreshed_label:state.refreshed_label
        in
        let body =
          match state.tab with
          | C2c_watch_state.Peers ->
              peers_body ~inner_cols ~peers:snapshot.peers ~sel:state.peers_sel
          | C2c_watch_state.Rooms -> placeholder_body "Rooms — coming in B4"
          | C2c_watch_state.DMs -> [] (* unreachable *)
        in
        let footer = footer_for state.tab in
        let head_lines = take body_budget (heading :: "" :: body) in
        let fill_n = max 0 (body_budget - List.length head_lines) in
        head_lines @ List.init fill_n (fun _ -> "") @ [ footer ]
  in
  let interior_lines =
    List.map (fun s -> text_row ~inner_cols s) interior_text
  in
  String.concat "\n" (top :: interior_lines @ [ bottom ])
