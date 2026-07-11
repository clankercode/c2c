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

(* ===== B3: synthetic DMs fixtures ======================================= *)

(* Synthetic archive_entry — short fixed strings only (spec §9 fixture
   hygiene: NO live content). ae_drained_at rendered through
   C2c_history.format_timestamp under forced TZ=UTC for byte stability. *)
let mk_entry ~from_ ~to_ ~content ~ts : C2c_watch_data.Broker.archive_entry =
  { ae_drained_at = ts
  ; ae_from_alias = from_
  ; ae_to_alias = to_
  ; ae_content = content
  ; ae_deferrable = false
  ; ae_drained_by = "test"
  ; ae_message_id = None
  }

(* Synthetic in-flight message (undrained inbox row). *)
let mk_msg ~from_ ~to_ ~content ~ts : C2c_mcp.message =
  { from_alias = from_
  ; to_alias = to_
  ; content
  ; deferrable = false
  ; reply_via = None
  ; enc_status = None
  ; ts
  ; ephemeral = false
  ; message_id = None
  ; pow_difficulty = None
  }

let ts1 = fixed_ts (* 2024-06-13 14:02:00 UTC *)
let ts2 = fixed_ts +. 31.0 (* 14:02:31 *)
let ts3 = fixed_ts +. 95.0 (* 14:03:35 *)

(* IMPORTANT: ds_entries MUST be in the order the real data layer delivers them
   — NEWEST-FIRST. Broker.read_archive reverses the append-only file on read
   ("reverse to get newest-first", c2c_broker.ml ~:2465) and B1's build_shards
   passes that order through unchanged. The render reverses again for display
   (oldest at top, newest at bottom). Building the fixture newest-first is what
   makes this golden a faithful regression surface — see test_dms_overflow. *)

(* (i) Normal shard: owner "axl-impl", entries from 2+ senders. NEWEST-FIRST. *)
let shard_normal : C2c_watch_data.dm_shard =
  { ds_session_id = "cfef26df-1111-2222-3333-444455556666"
  ; ds_owner_alias = Some "axl-impl"
  ; ds_entries =
      [ mk_entry ~from_:"qix-peer" ~to_:"axl-impl"
          ~content:"nice — sending you the patch" ~ts:ts3   (* newest *)
      ; mk_entry ~from_:"axl-impl" ~to_:"zeb-coord"
          ~content:"on it, build clean rc=0" ~ts:ts2
      ; mk_entry ~from_:"zeb-coord" ~to_:"axl-impl"
          ~content:"ack picking up the slice" ~ts:ts1 ]    (* oldest *)
  ; ds_inflight = []
  ; ds_is_orphan = false
  }

(* (ii) Shard with an in-flight (undrained) row. *)
let shard_inflight : C2c_watch_data.dm_shard =
  { ds_session_id = "ab12cd34-aaaa-bbbb-cccc-ddddeeeeffff"
  ; ds_owner_alias = Some "wisp-coord"
  ; ds_entries =
      [ mk_entry ~from_:"axl-impl" ~to_:"wisp-coord"
          ~content:"heads up: zed pin bumped" ~ts:ts1 ]
  ; ds_inflight =
      [ mk_msg ~from_:"axl-impl" ~to_:"wisp-coord"
          ~content:"one more before peer-PASS" ~ts:ts2 ]
  ; ds_is_orphan = false
  }

(* (iii) ORPHAN shard: ds_owner_alias=None, label derived from entries'
   to_alias (the most-recent entry's to_alias = the shard owner). *)
let shard_orphan : C2c_watch_data.dm_shard =
  { ds_session_id = "deadbeef-9999-8888-7777-666655554444"
  ; ds_owner_alias = None
  ; ds_entries =
      [ mk_entry ~from_:"zeb-coord" ~to_:"vox-gone"
          ~content:"are you still around?" ~ts:ts1 ]
  ; ds_inflight = []
  ; ds_is_orphan = true
  }

let dms_snapshot : C2c_watch_data.snapshot =
  { peers = []
  ; shards = [ shard_normal; shard_inflight; shard_orphan ]
  ; rooms = []
  ; broker_root
  }

(* State on the DMs tab with the first (normal) shard selected. *)
let state_dms : C2c_watch_state.t =
  { C2c_watch_state.initial with
    C2c_watch_state.tab = C2c_watch_state.DMs
  ; dms_sel = 0
  ; refreshed_label = "refreshed 0.6s ago" }

(* (iv) Overflow shard: 12 entries, NEWEST-FIRST (msg-12 newest .. msg-01
   oldest), for the overflow regression test (newest must stay visible). *)
let shard_many : C2c_watch_data.dm_shard =
  { ds_session_id = "facefeed-0000-1111-2222-333344445555"
  ; ds_owner_alias = Some "axl-impl"
  ; ds_entries =
      List.init 12 (fun k ->
          let n = 12 - k in (* k=0 -> msg-12 (newest); k=11 -> msg-01 (oldest) *)
          mk_entry ~from_:"peer" ~to_:"axl-impl"
            ~content:(Printf.sprintf "msg-%02d" n)
            ~ts:(fixed_ts +. float_of_int n))
  ; ds_inflight = []
  ; ds_is_orphan = false
  }

let many_snapshot : C2c_watch_data.snapshot =
  { peers = []; shards = [ shard_many ]; rooms = []; broker_root }

(* ===== B4: synthetic Rooms fixtures ===================================== *)

(* Synthetic room_message — short fixed strings only (spec §9 fixture hygiene:
   NO live content). rm_ts rendered through C2c_history.format_timestamp under
   forced TZ=UTC for byte stability. *)
let mk_room_msg ~from_ ~room ~content ~ts : C2c_mcp.room_message =
  { rm_from_alias = from_; rm_room_id = room; rm_content = content; rm_ts = ts }

(* Synthetic room_info — direct record construction (spec §9). *)
let mk_room_info ~room ~members ~alive ~dead ~unknown ~vis :
    C2c_watch_data.Broker.room_info =
  { ri_room_id = room
  ; ri_member_count = members
  ; ri_members = []
  ; ri_alive_member_count = alive
  ; ri_dead_member_count = dead
  ; ri_unknown_member_count = unknown
  ; ri_member_details = []
  ; ri_visibility = vis
  ; ri_invited_members = []
  }

(* (i) PUBLIC room with multiple history messages, built OLDEST-FIRST (ts
   ascending down the list) — this MIRRORS [Broker.read_room_history], which
   returns oldest-first / newest-last (it reads the append-only history.jsonl
   in file order and keeps the newest [limit] WITHOUT a final reverse, see
   c2c_broker.ml read_room_history ~:3791). The render keeps this order AS-IS
   (oldest at top, newest at bottom — NO List.rev). 2+ senders. *)
let room_public : C2c_watch_data.room_view =
  { rv_info =
      mk_room_info ~room:"swarm-lounge" ~members:3 ~alive:1 ~dead:1 ~unknown:1
        ~vis:C2c_mcp.Public
  ; rv_history =
      [ mk_room_msg ~from_:"zeb-coord" ~room:"swarm-lounge"
          ~content:"morning swarm" ~ts:ts1 (* oldest, at top *)
      ; mk_room_msg ~from_:"axl-impl" ~room:"swarm-lounge"
          ~content:"joining the watch slice" ~ts:ts2
      ; mk_room_msg ~from_:"qix-peer" ~room:"swarm-lounge"
          ~content:"build clean rc=0" ~ts:ts3 (* newest, at bottom *) ]
  }

(* (ii) PRIVATE EMPTY room (rv_history=[]) — the COMMON quiet case → the
   detail pane must show "(no history)" explicitly, never an error. *)
let room_empty : C2c_watch_data.room_view =
  { rv_info =
      mk_room_info ~room:"relay-debug" ~members:0 ~alive:0 ~dead:0 ~unknown:0
        ~vis:C2c_mcp.Private
  ; rv_history = []
  }

(* Populated rooms snapshot: a public room (selected) + an empty private room. *)
let rooms_snapshot : C2c_watch_data.snapshot =
  { peers = []
  ; shards = []
  ; rooms = [ room_public; room_empty ]
  ; broker_root
  }

(* State on the Rooms tab with the first (public) room selected so its history
   shows in the detail pane. *)
let state_rooms : C2c_watch_state.t =
  { C2c_watch_state.initial with
    C2c_watch_state.tab = C2c_watch_state.Rooms
  ; rooms_sel = 0
  ; refreshed_label = "refreshed 0.6s ago" }

(* (iii) Overflow room: 12 messages built OLDEST-FIRST (msg-01 oldest .. msg-12
   newest) for the order + overflow regression. rv_history is rendered AS-IS
   (no reverse); the clip keeps the TAIL (newest at the bottom). If the order
   were wrong (a stray List.rev), msg-12 (newest) would scroll off and msg-01
   (oldest) would stay — the bug this test guards against. *)
let room_many : C2c_watch_data.room_view =
  { rv_info =
      mk_room_info ~room:"busy-room" ~members:2 ~alive:2 ~dead:0 ~unknown:0
        ~vis:C2c_mcp.Public
  ; rv_history =
      List.init 12 (fun k ->
          let n = k + 1 in (* k=0 -> msg-01 (oldest); k=11 -> msg-12 (newest) *)
          mk_room_msg ~from_:"peer" ~room:"busy-room"
            ~content:(Printf.sprintf "msg-%02d" n)
            ~ts:(fixed_ts +. float_of_int n))
  }

let rooms_many_snapshot : C2c_watch_data.snapshot =
  { peers = []; shards = []; rooms = [ room_many ]; broker_root }

(* (iv) Small order room: 4 messages built OLDEST-FIRST (msg-01 .. msg-04).
   At 80x24 all 4 fit in the detail pane, so the order test can assert the
   oldest sits ABOVE the newest (order preserved, NO reverse) WITHOUT clipping
   confounding the result. The 12-message [room_many] covers the overflow/clip
   case separately. *)
let room_order : C2c_watch_data.room_view =
  { rv_info =
      mk_room_info ~room:"order-room" ~members:1 ~alive:1 ~dead:0 ~unknown:0
        ~vis:C2c_mcp.Public
  ; rv_history =
      List.init 4 (fun k ->
          let n = k + 1 in (* k=0 -> msg-01 (oldest); k=3 -> msg-04 (newest) *)
          mk_room_msg ~from_:"peer" ~room:"order-room"
            ~content:(Printf.sprintf "msg-%02d" n)
            ~ts:(fixed_ts +. float_of_int n))
  }

let rooms_order_snapshot : C2c_watch_data.snapshot =
  { peers = []; shards = []; rooms = [ room_order ]; broker_root }

(* Substring search (no stdlib helper for this in the std we target). *)
let contains_sub (hay : string) (needle : string) : bool =
  let hl = String.length hay and nl = String.length needle in
  let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i + 1)) in
  nl = 0 || go 0

(* Assert every line of a rendered frame is exactly 80 display columns. *)
let check_all_lines_80 (s : string) : unit =
  List.iteri
    (fun i line ->
      Alcotest.(check int) (Printf.sprintf "line %d display-width = 80" i) 80
        (utf8_len line))
    (String.split_on_char '\n' s)

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

(* B3: DMs tab golden — populated (normal + in-flight + orphan shards, first
   shard selected so its detail is shown). *)
let test_dms_populated () =
  golden_test ~rel:"test_fixtures/watch_dms_populated_80x24.txt"
    ~snapshot:dms_snapshot ~state:state_dms ()

(* B3: DMs tab golden — empty broker (0 shards). Valid quiet state, not an
   error. *)
let test_dms_empty () =
  golden_test ~rel:"test_fixtures/watch_dms_empty_80x24.txt"
    ~snapshot:quiet_snapshot ~state:state_dms ()

(* B3 OVERFLOW REGRESSION (the order/clip blocker): when the detail overflows
   the pane, the NEWEST messages MUST stay visible at the bottom and the OLDEST
   scroll off behind a "(N older hidden)" marker. ds_entries is newest-first;
   render reverses for display + the clip keeps the tail (newest). If the order
   were wrong (the bug), msg-01 (oldest) would show and msg-12 (newest) hide. *)
let test_dms_overflow () =
  let s =
    C2c_watch_render.render ~cols:80 ~rows:12 ~snapshot:many_snapshot
      ~state:state_dms
  in
  Alcotest.(check bool) "newest message (msg-12) visible" true
    (contains_sub s "msg-12");
  Alcotest.(check bool) "oldest message (msg-01) scrolled off" false
    (contains_sub s "msg-01");
  Alcotest.(check bool) "older-hidden marker present" true
    (contains_sub s "older hidden");
  check_all_lines_80 s

(* B3: render is TOTAL for an out-of-range dms_sel (data shrink can leave
   state.dms_sel past the shard list until the loop's clamp_counts fires) —
   must not raise and must hold the exact-width contract. *)
let test_dms_out_of_range_sel () =
  let st = { state_dms with C2c_watch_state.dms_sel = 99 } in
  let s =
    C2c_watch_render.render ~cols:80 ~rows:24 ~snapshot:dms_snapshot ~state:st
  in
  Alcotest.(check int) "row count = 24" 24
    (List.length (String.split_on_char '\n' s));
  check_all_lines_80 s

(* ===== B4: Rooms tab tests ============================================== *)

(* B4: Rooms tab golden — populated (public room selected so its history shows
   + an empty private room visible in the list). *)
let test_rooms_populated () =
  golden_test ~rel:"test_fixtures/watch_rooms_populated_80x24.txt"
    ~snapshot:rooms_snapshot ~state:state_rooms ()

(* B4: Rooms tab golden — empty broker (0 rooms). Valid quiet state, not an
   error → a clean "no rooms" body. *)
let test_rooms_empty () =
  golden_test ~rel:"test_fixtures/watch_rooms_empty_80x24.txt"
    ~snapshot:quiet_snapshot ~state:state_rooms ()

(* B4 HISTORY-ORDER (the B3-blocker class, opposite direction): rv_history is
   OLDEST-FIRST and the render must keep it AS-IS — oldest ABOVE newest. Build
   a room oldest-first, render, assert the oldest message's row appears at a
   SMALLER line index than the newest's (order preserved, NOT reversed). *)
let line_index (s : string) (needle : string) : int option =
  let lines = String.split_on_char '\n' s in
  let rec go i = function
    | [] -> None
    | l :: rest -> if contains_sub l needle then Some i else go (i + 1) rest
  in
  go 0 lines

let test_rooms_history_order () =
  (* room_order has msg-01 (oldest) .. msg-04 (newest), built oldest-first. At
     80x24 the body holds all 4 (no clipping), so both ends are visible; assert
     oldest is ABOVE newest (order preserved AS-IS, NOT reversed). *)
  let s =
    C2c_watch_render.render ~cols:80 ~rows:24 ~snapshot:rooms_order_snapshot
      ~state:state_rooms
  in
  (match (line_index s "msg-01", line_index s "msg-04") with
   | Some oldest_i, Some newest_i ->
       Alcotest.(check bool)
         "oldest (msg-01) appears ABOVE newest (msg-04)" true
         (oldest_i < newest_i)
   | _ ->
       Alcotest.fail
         "expected both msg-01 (oldest) and msg-04 (newest) visible at 80x24");
  check_all_lines_80 s

(* B4 OVERFLOW (mirrors test_dms_overflow but for the OLDEST-FIRST room source):
   when the detail overflows the pane, the NEWEST message MUST stay visible and
   the OLDEST scroll off behind a "(N older hidden)" marker. rv_history is
   oldest-first and the render keeps it AS-IS (NO reverse) so the clip keeps the
   TAIL = newest. If a stray List.rev were present, msg-01 (oldest) would stay
   and msg-12 (newest) hide — the bug this guards. *)
let test_rooms_overflow () =
  let s =
    C2c_watch_render.render ~cols:80 ~rows:12 ~snapshot:rooms_many_snapshot
      ~state:state_rooms
  in
  Alcotest.(check bool) "newest message (msg-12) visible" true
    (contains_sub s "msg-12");
  Alcotest.(check bool) "oldest message (msg-01) scrolled off" false
    (contains_sub s "msg-01");
  Alcotest.(check bool) "older-hidden marker present" true
    (contains_sub s "older hidden");
  check_all_lines_80 s

(* B4: empty room must show "(no history)" explicitly (the common quiet case),
   not blank or an error. Select the second (empty private) room. *)
let test_rooms_empty_room_no_history () =
  let st = { state_rooms with C2c_watch_state.rooms_sel = 1 } in
  let s =
    C2c_watch_render.render ~cols:80 ~rows:24 ~snapshot:rooms_snapshot ~state:st
  in
  Alcotest.(check bool) "(no history) shown for empty room" true
    (contains_sub s "(no history)");
  check_all_lines_80 s

(* B4: render is TOTAL for an out-of-range rooms_sel (data shrink can leave
   state.rooms_sel past the rooms list until the loop's clamp_counts fires) —
   must not raise and must hold the exact-width contract. *)
let test_rooms_out_of_range_sel () =
  let st = { state_rooms with C2c_watch_state.rooms_sel = 99 } in
  let s =
    C2c_watch_render.render ~cols:80 ~rows:24 ~snapshot:rooms_snapshot ~state:st
  in
  Alcotest.(check int) "row count = 24" 24
    (List.length (String.split_on_char '\n' s));
  check_all_lines_80 s

(* ===== B5: compose line + status golden ================================= *)

(* Input-focus state on the Peers tab: a Compose_dm target with typed input and
   a prior ✗-failed status, so the golden pins BOTH the compose prompt+caret
   (last interior row) AND the status row above it. The body above is the
   normal populated Peers roster (unchanged from the read view) — this proves
   the read body and the new bottom region coexist exactly. *)
let state_compose : C2c_watch_state.t =
  { C2c_watch_state.initial with
    C2c_watch_state.tab = C2c_watch_state.Peers
  ; peers_sel = 0
  ; focus = C2c_watch_state.Input
  ; compose = Some (C2c_watch_state.Compose_dm "alpha-impl")
  ; input = "ack — picking up the slice"
  ; status = "\xe2\x9c\x97 recipient is not alive: gamma-old"
  ; refreshed_label = "refreshed 0.6s ago" }

let test_compose_golden () =
  golden_test ~rel:"test_fixtures/watch_compose_80x24.txt"
    ~snapshot:populated_snapshot ~state:state_compose ()

(* B5: the compose line keeps the caret visible by left-truncating a LONG input
   (showing its tail nearest the caret with a leading …). At a narrow width the
   render must still be exact-width and total — no raise, every line = cols. *)
let test_compose_long_input_narrow () =
  let long =
    "this is a very long compose buffer that must be left-truncated so the \
     caret stays visible at the right edge of the input field no matter how \
     much the operator types into it"
  in
  let st =
    { state_compose with
      C2c_watch_state.input = long
    ; compose = Some (C2c_watch_state.Compose_room "swarm-lounge")
    ; status = "" }
  in
  List.iter
    (fun (cols, rows) ->
      let s =
        C2c_watch_render.render ~cols ~rows ~snapshot:populated_snapshot
          ~state:st
      in
      let lines = String.split_on_char '\n' s in
      Alcotest.(check int)
        (Printf.sprintf "%dx%d row count" cols rows)
        rows (List.length lines);
      List.iteri
        (fun i line ->
          Alcotest.(check int)
            (Printf.sprintf "%dx%d line %d display-width" cols rows i)
            cols (utf8_len line))
        lines;
      (* The caret stays visible whenever the inner width can hold the prompt +
         caret (cols >= ~20). At an 8-col degenerate width the prompt itself is
         truncated to fit and the caret may be dropped — the exact-width
         contract (asserted above) is what must always hold there. *)
      if cols >= 20 then
        Alcotest.(check bool)
          (Printf.sprintf "%dx%d caret visible" cols rows)
          true
          (contains_sub s "\xe2\x96\x8f"))
    [ (80, 24); (40, 12); (20, 8); (8, 5) ]

(* The render exact-width contract must hold at ANY size >= the clamp floor
   (cols>=8, rows>=5), including narrow terminals where the title border cannot
   hold the fixed lead+tabs. Regression for the Codex finding that title_border
   could emit a line WIDER than cols on a narrow terminal. Assert every line is
   exactly cols display columns and the frame is exactly rows lines, across a
   span of sizes AND all three tabs. *)
let test_render_dimensions_various () =
  let sizes = [ (80, 24); (120, 30); (40, 12); (20, 8); (8, 5) ] in
  (* Each case pairs a state with the snapshot to render it against. The DMs
     case uses a POPULATED-DMs snapshot (not just the empty shards=[] case) so
     the two-pane split + detail wrap are exercised at narrow sizes — the B2
     lesson: narrow-terminal sizes must be tested. *)
  let cases =
    [ (state_peers, populated_snapshot)
    ; ({ state_peers with C2c_watch_state.tab = C2c_watch_state.DMs },
       populated_snapshot) (* DMs tab over the empty-shards peers snapshot *)
    ; (state_dms, dms_snapshot) (* DMs tab over the populated-DMs snapshot *)
    ; ({ state_peers with C2c_watch_state.tab = C2c_watch_state.Rooms },
       populated_snapshot) (* Rooms tab over the empty-rooms snapshot *)
    ; (state_rooms, rooms_snapshot) (* Rooms tab over the populated-rooms
                                       snapshot: exercises the two-pane room
                                       list + history wrap at narrow sizes *)
    ; ({ state_peers with
         C2c_watch_state.focus = C2c_watch_state.Input
       ; compose = Some (C2c_watch_state.Compose_dm "alpha-impl")
       ; input = "hello there"
       ; status = "\xe2\x9c\x93 sent to alpha-impl" },
       populated_snapshot)
      (* B5 Input focus: the compose line + status row replace the footer; the
         exact-width contract must hold at narrow sizes too. *) ]
  in
  List.iter
    (fun (cols, rows) ->
      List.iter
        (fun (state, snapshot) ->
          let s = C2c_watch_render.render ~cols ~rows ~snapshot ~state in
          let lines = String.split_on_char '\n' s in
          Alcotest.(check int)
            (Printf.sprintf "%dx%d row count" cols rows)
            rows (List.length lines);
          List.iteri
            (fun i line ->
              Alcotest.(check int)
                (Printf.sprintf "%dx%d line %d display-width" cols rows i)
                cols (utf8_len line))
            lines)
        cases)
    sizes

(* B5: status_of_send maps a send_result to the status line. The three outcomes
   get THREE distinct glyphs — ✓ clean, ⚠ posted-with-warning (0-member room,
   spec §4.3: a soft warning, NOT a failure), ✗ failure. A 0-member room post
   must NOT read as a clean ✓ (misleading) nor as a ✗ failure (the message WAS
   posted to history.jsonl) — it is ⚠ with the warning text surfaced. *)
let test_status_of_send () =
  let open C2c_watch_data in
  let open C2c_watch_state in
  let ok = "\xe2\x9c\x93" and warn = "\xe2\x9a\xa0" and fail = "\xe2\x9c\x97" in
  let dm = C2c_watch_render.status_of_send (Compose_dm "alice") Sent_dm in
  Alcotest.(check bool) "DM sent => check" true (contains_sub dm ok);
  let warned =
    C2c_watch_render.status_of_send (Compose_room "lounge")
      (Sent_room { delivered = 0; skipped = 2; warning = Some "room has no members" })
  in
  Alcotest.(check bool) "0-member room => warn glyph" true (contains_sub warned warn);
  Alcotest.(check bool) "0-member room NOT clean check" false (contains_sub warned ok);
  Alcotest.(check bool) "0-member room NOT failure cross" false (contains_sub warned fail);
  Alcotest.(check bool) "warning text surfaced" true (contains_sub warned "no members");
  Alcotest.(check bool) "delivered count shown" true (contains_sub warned "delivered 0");
  let clean =
    C2c_watch_render.status_of_send (Compose_room "lounge")
      (Sent_room { delivered = 3; skipped = 0; warning = None })
  in
  Alcotest.(check bool) "clean room post => check" true (contains_sub clean ok);
  Alcotest.(check bool) "clean room post NOT warn" false (contains_sub clean warn);
  let failed =
    C2c_watch_render.status_of_send (Compose_dm "x") (Send_failed "not registered")
  in
  Alcotest.(check bool) "Send_failed => cross" true (contains_sub failed fail);
  Alcotest.(check bool) "failure msg surfaced" true (contains_sub failed "not registered")

(* EXACT-WIDTH for ARBITRARY WIDE UNICODE (the whole-feature contract). CJK is
   2 display columns and emoji 2, so a naive codepoint count would think they
   fit when they don't and the frame would break. We render real wide content /
   wide aliases / wide compose input and assert every line is EXACTLY cols
   columns using C2c_watch_render.disp_width (the SAME wcwidth the renderer
   uses — Uucp.Break.tty_width_hint). *)
let test_wide_unicode_exact_width () =
  let wide_shard : C2c_watch_data.dm_shard =
    { ds_session_id = "wide-sid-000011112222"
    ; ds_owner_alias = Some "\xe4\xbd\xa0-peer-\xe5\x90\x8d" (* 你-peer-名 *)
    ; ds_entries =
        [ mk_entry ~from_:"\xe6\x93\x8d\xe4\xbd\x9c\xe5\x91\x98" (* 操作员 *)
            ~to_:"\xe4\xbd\xa0-peer-\xe5\x90\x8d"
            ~content:"hi \xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c \xf0\x9f\x8c\x8d\xf0\x9f\x9a\x80 end"
            (* hi 你好世界 🌍🚀 end *)
            ~ts:ts1 ]
    ; ds_inflight = []
    ; ds_is_orphan = false }
  in
  let snap : C2c_watch_data.snapshot =
    { peers = []; shards = [ wide_shard ]; rooms = []; broker_root }
  in
  let st = { state_dms with C2c_watch_state.dms_sel = 0 } in
  let dw line = C2c_watch_render.disp_width line in
  List.iter
    (fun (cols, rows) ->
      let s = C2c_watch_render.render ~cols ~rows ~snapshot:snap ~state:st in
      let lines = String.split_on_char '\n' s in
      Alcotest.(check int) (Printf.sprintf "%dx%d rows" cols rows) rows
        (List.length lines);
      List.iteri
        (fun i line ->
          Alcotest.(check int)
            (Printf.sprintf "%dx%d DMs line %d TRUE display-width" cols rows i)
            cols (dw line))
        lines)
    [ (80, 24); (40, 12); (20, 8) ];
  (* Wide compose input must also keep the frame exact. *)
  let cst = C2c_watch_state.begin_compose state_dms (C2c_watch_state.Compose_dm "\xe4\xbd\xa0-peer") in
  let cst =
    { cst with
      C2c_watch_state.input =
        "\xe5\x9b\x9e\xe5\xa4\x8d \xf0\x9f\x9a\x80 body \xe6\xb5\x8b\xe8\xaf\x95" }
    (* 回复 🚀 body 测试 *)
  in
  let s = C2c_watch_render.render ~cols:80 ~rows:24 ~snapshot:snap ~state:cst in
  List.iter
    (fun line ->
      Alcotest.(check int) "compose wide-input line TRUE width=80" 80 (dw line))
    (String.split_on_char '\n' s)

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
            test_peers_quiet;
          Alcotest.test_case "dms_populated_80x24_golden" `Quick
            test_dms_populated;
          Alcotest.test_case "dms_empty_80x24_golden" `Quick
            test_dms_empty;
          Alcotest.test_case "dms_overflow_keeps_newest" `Quick
            test_dms_overflow;
          Alcotest.test_case "dms_out_of_range_sel_total" `Quick
            test_dms_out_of_range_sel;
          Alcotest.test_case "rooms_populated_80x24_golden" `Quick
            test_rooms_populated;
          Alcotest.test_case "rooms_empty_80x24_golden" `Quick
            test_rooms_empty;
          Alcotest.test_case "rooms_history_order_preserved" `Quick
            test_rooms_history_order;
          Alcotest.test_case "rooms_overflow_keeps_newest" `Quick
            test_rooms_overflow;
          Alcotest.test_case "rooms_empty_room_no_history" `Quick
            test_rooms_empty_room_no_history;
          Alcotest.test_case "rooms_out_of_range_sel_total" `Quick
            test_rooms_out_of_range_sel;
          Alcotest.test_case "render_dimensions_various" `Quick
            test_render_dimensions_various;
          Alcotest.test_case "compose_80x24_golden" `Quick
            test_compose_golden;
          Alcotest.test_case "compose_long_input_narrow" `Quick
            test_compose_long_input_narrow;
          Alcotest.test_case "status_of_send_glyphs" `Quick
            test_status_of_send;
          Alcotest.test_case "wide_unicode_exact_width" `Quick
            test_wide_unicode_exact_width ] ) ]
