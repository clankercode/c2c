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

(* Placeholder body for the DMs / Rooms tabs (B3/B4 implement them). *)
let placeholder_body (label : string) : string list = [ ""; "  " ^ label; "" ]

(* The status/legend footer for the active tab. *)
let footer_for (tab : C2c_watch_state.tab) : string =
  (* One leading space for breathing room (spec mockup: "│ ● alive"). *)
  " "
  ^
  match tab with
  | C2c_watch_state.Peers ->
      "\xe2\x97\x8f alive  \xe2\x97\x8b dead  ? unknown(null)   "
      ^ "\xe2\x86\x91/\xe2\x86\x93 select \xc2\xb7 Enter\xe2\x86\x92DM \xc2\xb7 r refresh"
  | C2c_watch_state.DMs -> "DMs detail \xe2\x80\x94 coming in B3"
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
  let heading =
    heading_line ~inner_cols ~tab:state.tab ~snapshot
      ~refreshed_label:state.refreshed_label
  in
  let body =
    match state.tab with
    | C2c_watch_state.Peers ->
        peers_body ~inner_cols ~peers:snapshot.peers
          ~sel:state.peers_sel
    | C2c_watch_state.DMs -> placeholder_body "DMs — coming in B3"
    | C2c_watch_state.Rooms -> placeholder_body "Rooms — coming in B4"
  in
  let footer = footer_for state.tab in
  (* Interior content rows, in order, BEFORE wall-wrapping:
       heading, blank, <body...>, <blank fill...>, footer.
     The interior holds rows-2 lines (top+bottom borders consume 2). The
     footer occupies the last interior row; everything between the body and
     the footer is blank-filled. *)
  let interior_count = rows - 2 in
  (* Lines that are fixed at the top of the interior. *)
  let head_lines = heading :: "" :: body in
  (* Reserve the final interior row for the footer. *)
  let body_budget = max 0 (interior_count - 1) in
  let head_lines =
    (* Truncate the head block if it overflows the body budget (tiny term). *)
    let rec take n = function
      | [] -> []
      | _ when n <= 0 -> []
      | x :: rest -> x :: take (n - 1) rest
    in
    take body_budget head_lines
  in
  let fill_n = max 0 (body_budget - List.length head_lines) in
  let interior_text =
    head_lines @ List.init fill_n (fun _ -> "") @ [ footer ]
  in
  let interior_lines =
    List.map (fun s -> text_row ~inner_cols s) interior_text
  in
  String.concat "\n" (top :: interior_lines @ [ bottom ])
