(* test_c2c_watch_render.ml — golden snapshot test for the pure render layer
   of `c2c watch` (slice B0).

   [C2c_watch_render.render_empty_frame] is a pure function of (cols, rows): no
   clock, no env, no randomness. So an exact-bytes golden file is a stable,
   agent-reviewable regression surface — an agent can diff the plaintext
   without a real terminal (spec §9).

   The golden lives at test_fixtures/watch_empty_80x24.txt and is wired into
   the dune test's sandbox via a (deps ...) entry. To (re)generate it after an
   intentional render change, run the test binary directly with
   C2C_WATCH_REGEN_GOLDEN pointing at the absolute source path of the fixture:

     C2C_WATCH_REGEN_GOLDEN=/abs/.../test_fixtures/watch_empty_80x24.txt \
       dune exec ocaml/cli/test_c2c_watch_render.exe

   In normal `@runtest` mode that env var is unset and the test only asserts. *)

let golden_rel = "test_fixtures/watch_empty_80x24.txt"

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let write_file path s =
  let oc = open_out_bin path in
  output_string oc s;
  close_out oc

let test_empty_frame_80x24 () =
  let rendered = C2c_watch_render.render_empty_frame ~cols:80 ~rows:24 in
  (* Regen escape hatch: only fires when explicitly requested. *)
  (match Sys.getenv_opt "C2C_WATCH_REGEN_GOLDEN" with
   | Some path when path <> "" ->
       write_file path rendered;
       Printf.printf "[regen] wrote golden to %s (%d bytes)\n%!" path
         (String.length rendered)
   | _ -> ());
  let golden = read_file golden_rel in
  Alcotest.(check string)
    "render_empty_frame 80x24 matches checked-in golden" golden rendered

(* Count UTF-8 code points in a string. The frame's only non-ASCII content is
   box-drawing glyphs, each a single code point AND a single display column, so
   code-point count == display width here. (Banner.visible_width is byte-based
   — it would over-count the 3-byte box glyphs — so we use our own counter for
   the display-width invariant.) *)
let utf8_len (s : string) : int =
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

(* Structural invariants that do not depend on the golden bytes — these catch
   a malformed frame even if the golden were regenerated wrongly. *)
let test_frame_dimensions () =
  let cols = 80 and rows = 24 in
  let s = C2c_watch_render.render_empty_frame ~cols ~rows in
  let lines = String.split_on_char '\n' s in
  Alcotest.(check int) "line count = rows" rows (List.length lines);
  List.iteri
    (fun i line ->
      Alcotest.(check int)
        (Printf.sprintf "line %d display-width = cols" i)
        cols (utf8_len line))
    lines

let () =
  Alcotest.run "c2c_watch_render"
    [ ( "render",
        [ Alcotest.test_case "empty_frame_80x24_golden" `Quick
            test_empty_frame_80x24;
          Alcotest.test_case "empty_frame_dimensions" `Quick
            test_frame_dimensions ] ) ]
