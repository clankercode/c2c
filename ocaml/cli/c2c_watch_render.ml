(* c2c_watch_render.ml — PURE render layer for `c2c watch` (slice B0).

   This module is deliberately terminal-free: NO lambda-term, NO IO, no
   reads of the clock / environment / randomness. Every output is a pure
   function of its arguments, which is what makes the golden snapshot
   tests in [test_c2c_watch_render.ml] a deterministic plaintext diff
   (an agent can review the diff without a real terminal — see spec §9).

   The render/state separation (spec §2) keeps lambda-term confined to
   [c2c_watch.ml]; everything visual is assembled here as a plain string.

   Column math reuses [Banner.visible_width] / [Banner.pad_right] (from the
   already-linked c2c_mcp lib) so future ANSI-tinted content lands on the
   right column count. In B0 the frame is plain so [pad_right] on ASCII is
   exact; the Unicode box-drawing border chars are composed around the
   padded interior (each border glyph is one display column even though it
   is multi-byte UTF-8, so we never feed them through byte-indexed padding). *)

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
