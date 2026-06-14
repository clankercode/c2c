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

   In normal `@runtest` mode that env var is unset and the test only asserts.

   RUN-MODE NOTE: the golden paths below are cwd-relative ("test_fixtures/..").
   This resolves correctly in the two supported invocations — under dune's
   sandbox (`dune build @ocaml/cli/runtest-test_c2c_watch_render`, where the
   `(deps test_fixtures/..)` entries stage the files into the per-test cwd) and
   when the exe is run with cwd = ocaml/cli. Running the exe via `dune exec`
   from the repo ROOT will fail with Sys_error (cwd is then the repo root, not
   ocaml/cli) — that is a wrong-invocation footgun, not a render defect. *)

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

(* ===== B2: golden tests over the live [render] ========================== *)

(* A synthetic peer_row builder — no broker needed (spec §9 fixture hygiene:
   synthetic only, never live archive content). *)
let mk_peer ~alias ~liveness ~role ~last_activity ~dnd ~compacting ~client :
    C2c_watch_data.peer_row =
  { pr_alias = alias
  ; pr_session_id = alias ^ "-sid"
  ; pr_liveness = liveness
  ; pr_role = role
  ; pr_last_activity = last_activity
  ; pr_dnd = dnd
  ; pr_compacting = compacting
  ; pr_client_type = client
  }

(* A fixed timestamp; rendered through C2c_history.format_timestamp under a
   forced TZ=UTC (set in [let ()] below) so the golden is byte-stable on any
   box. 1718287320 = 2024-06-13 14:02:00 UTC. *)
let fixed_ts = 1718287320.0

(* State with a FIXED refreshed_label (constraint 1: the loop owns the clock;
   tests pin it to a literal so the golden is deterministic). *)
let state_peers : C2c_watch_state.t =
  { C2c_watch_state.initial with
    C2c_watch_state.tab = C2c_watch_state.Peers
  ; peers_sel = 0
  ; refreshed_label = "refreshed 0.6s ago" }

(* SHORT fixed synthetic broker_root (constraint: no live paths). *)
let broker_root = "/tmp/c2c-fixture/broker"

let populated_snapshot : C2c_watch_data.snapshot =
  { peers =
      [ mk_peer ~alias:"alpha-impl" ~liveness:C2c_watch_data.Broker.Alive
          ~role:(Some "coder") ~last_activity:(Some fixed_ts) ~dnd:false
          ~compacting:None ~client:(Some "claude")
      ; mk_peer ~alias:"beta-coord" ~liveness:C2c_watch_data.Broker.Unknown
          ~role:(Some "coordinator") ~last_activity:(Some fixed_ts) ~dnd:false
          ~compacting:None ~client:(Some "claude")
      ; mk_peer ~alias:"gamma-old" ~liveness:C2c_watch_data.Broker.Dead
          ~role:None ~last_activity:None ~dnd:false ~compacting:None
          ~client:None
      ; mk_peer ~alias:"delta-dnd" ~liveness:C2c_watch_data.Broker.Dead
          ~role:None ~last_activity:(Some fixed_ts) ~dnd:true ~compacting:None
          ~client:(Some "claude")
      (* Regression rows for the column-separator fix (caught in live QA): an
         alias EXACTLY col_alias (18) wide must still keep a space before the
         liveness glyph, and an OVERFLOWING alias must truncate-with-ellipsis
         and still keep that separator. "wide-alias-18chars" is exactly 18. *)
      ; mk_peer ~alias:"wide-alias-18chars" ~liveness:C2c_watch_data.Broker.Unknown
          ~role:None ~last_activity:None ~dnd:false ~compacting:None ~client:None
      ; mk_peer ~alias:"overflowing-long-alias-xyz"
          ~liveness:C2c_watch_data.Broker.Alive ~role:(Some "coder")
          ~last_activity:(Some fixed_ts) ~dnd:false ~compacting:None
          ~client:(Some "claude") ]
  ; shards = []
  ; rooms = []
  ; broker_root
  }

let quiet_snapshot : C2c_watch_data.snapshot =
  { peers = []; shards = []; rooms = []; broker_root }

let read_file_opt path =
  match open_in_bin path with
  | ic ->
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      Some s
  | exception _ -> None

let golden_test ~rel ~snapshot ~state () =
  let rendered =
    C2c_watch_render.render ~cols:80 ~rows:24 ~snapshot ~state
  in
  (match Sys.getenv_opt "C2C_WATCH_REGEN_GOLDEN" with
   | Some v when v <> "" ->
       (* Regen hatch: write the golden at its cwd-relative path [rel]. Run the
          test exe directly from ocaml/cli (NOT under dune's sandbox) so [rel]
          resolves to the real source fixture. Any non-empty value enables it. *)
       write_file rel rendered;
       Printf.printf "[regen] wrote golden to %s (%d bytes)\n%!" rel
         (String.length rendered)
   | _ -> ());
  (* Dimension invariant: every line exactly 80 display columns, 24 rows. *)
  let lines = String.split_on_char '\n' rendered in
  Alcotest.(check int) "row count = 24" 24 (List.length lines);
  List.iteri
    (fun i line ->
      Alcotest.(check int)
        (Printf.sprintf "line %d display-width = 80" i)
        80 (utf8_len line))
    lines;
  match read_file_opt rel with
  | Some golden ->
      Alcotest.(check string)
        (Printf.sprintf "render matches golden %s" rel) golden rendered
  | None ->
      Alcotest.fail
        (Printf.sprintf
           "golden %s missing — regen with C2C_WATCH_REGEN_GOLDEN=<abs \
            fixtures dir>" rel)

let test_peers_populated () =
  golden_test ~rel:"test_fixtures/watch_peers_populated_80x24.txt"
    ~snapshot:populated_snapshot ~state:state_peers ()

let test_peers_quiet () =
  golden_test ~rel:"test_fixtures/watch_peers_quiet_80x24.txt"
    ~snapshot:quiet_snapshot ~state:state_peers ()

let () =
  (* Force UTC so C2c_history.format_timestamp is deterministic across boxes.
     glibc reads TZ on the first localtime call, so set it before any render. *)
  Unix.putenv "TZ" "UTC";
  Alcotest.run "c2c_watch_render"
    [ ( "render",
        [ Alcotest.test_case "empty_frame_80x24_golden" `Quick
            test_empty_frame_80x24;
          Alcotest.test_case "empty_frame_dimensions" `Quick
            test_frame_dimensions;
          Alcotest.test_case "peers_populated_80x24_golden" `Quick
            test_peers_populated;
          Alcotest.test_case "peers_quiet_80x24_golden" `Quick
            test_peers_quiet ] ) ]
