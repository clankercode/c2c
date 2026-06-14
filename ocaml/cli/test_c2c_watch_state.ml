(* test_c2c_watch_state.ml — pure transition tests for the `c2c watch` state
   machine (slice B2). No terminal, no broker, no IO — these assert the pure
   [C2c_watch_state.apply] transitions directly (spec §9). *)

module S = C2c_watch_state

let tab_testable =
  Alcotest.testable
    (fun ppf (t : S.tab) ->
      Format.pp_print_string ppf
        (match t with S.Peers -> "Peers" | S.DMs -> "DMs" | S.Rooms -> "Rooms"))
    ( = )

let focus_testable =
  Alcotest.testable
    (fun ppf (f : S.focus) ->
      Format.pp_print_string ppf
        (match f with S.List -> "List" | S.Input -> "Input"))
    ( = )

(* Tab cycling forward wraps Peers -> DMs -> Rooms -> Peers. *)
let test_next_tab_wraps () =
  let s0 = S.initial in
  Alcotest.check tab_testable "start Peers" S.Peers s0.tab;
  let s1 = S.apply ~list_len:0 s0 S.NextTab in
  Alcotest.check tab_testable "Peers->DMs" S.DMs s1.tab;
  let s2 = S.apply ~list_len:0 s1 S.NextTab in
  Alcotest.check tab_testable "DMs->Rooms" S.Rooms s2.tab;
  let s3 = S.apply ~list_len:0 s2 S.NextTab in
  Alcotest.check tab_testable "Rooms->Peers (wrap)" S.Peers s3.tab

(* Tab cycling backward wraps Peers -> Rooms -> DMs -> Peers. *)
let test_prev_tab_wraps () =
  let s0 = S.initial in
  let s1 = S.apply ~list_len:0 s0 S.PrevTab in
  Alcotest.check tab_testable "Peers->Rooms (wrap)" S.Rooms s1.tab;
  let s2 = S.apply ~list_len:0 s1 S.PrevTab in
  Alcotest.check tab_testable "Rooms->DMs" S.DMs s2.tab;
  let s3 = S.apply ~list_len:0 s2 S.PrevTab in
  Alcotest.check tab_testable "DMs->Peers" S.Peers s3.tab

(* JumpTab sets the tab directly. *)
let test_jump_tab () =
  let s0 = S.initial in
  let s = S.apply ~list_len:0 s0 (S.JumpTab S.Rooms) in
  Alcotest.check tab_testable "jump to Rooms" S.Rooms s.tab;
  let s = S.apply ~list_len:0 s (S.JumpTab S.DMs) in
  Alcotest.check tab_testable "jump to DMs" S.DMs s.tab;
  let s = S.apply ~list_len:0 s (S.JumpTab S.Peers) in
  Alcotest.check tab_testable "jump to Peers" S.Peers s.tab

(* SelUp at index 0 stays at 0 (no underflow). *)
let test_selup_floor () =
  let s0 = S.initial in
  Alcotest.check Alcotest.int "start sel 0" 0 (S.active_sel s0);
  let s = S.apply ~list_len:5 s0 S.SelUp in
  Alcotest.check Alcotest.int "SelUp at 0 stays 0" 0 (S.active_sel s)

(* SelDown clamps at list_len-1 (no overflow past the last row). *)
let test_seldown_ceiling () =
  let s0 = S.initial in
  (* list_len = 3 -> max index 2 *)
  let s1 = S.apply ~list_len:3 s0 S.SelDown in
  Alcotest.check Alcotest.int "0->1" 1 (S.active_sel s1);
  let s2 = S.apply ~list_len:3 s1 S.SelDown in
  Alcotest.check Alcotest.int "1->2" 2 (S.active_sel s2);
  let s3 = S.apply ~list_len:3 s2 S.SelDown in
  Alcotest.check Alcotest.int "2->2 (clamped)" 2 (S.active_sel s3);
  let s4 = S.apply ~list_len:3 s3 S.SelDown in
  Alcotest.check Alcotest.int "still 2" 2 (S.active_sel s4)

(* SelDown on an empty list (list_len=0) stays 0. *)
let test_seldown_empty () =
  let s0 = S.initial in
  let s = S.apply ~list_len:0 s0 S.SelDown in
  Alcotest.check Alcotest.int "SelDown on empty stays 0" 0 (S.active_sel s)

(* Selection is per-tab: moving in Peers does not move the DMs selection, and
   a tab switch preserves each tab's own index. *)
let test_per_tab_selection () =
  let s = S.initial in
  let s = S.apply ~list_len:5 s S.SelDown in (* peers_sel = 1 *)
  let s = S.apply ~list_len:5 s S.SelDown in (* peers_sel = 2 *)
  Alcotest.check Alcotest.int "peers_sel 2" 2 s.peers_sel;
  let s = S.apply ~list_len:5 s S.NextTab in (* now DMs *)
  Alcotest.check Alcotest.int "dms_sel still 0" 0 (S.active_sel s);
  let s = S.apply ~list_len:5 s S.SelDown in (* dms_sel = 1 *)
  Alcotest.check Alcotest.int "dms_sel 1" 1 s.dms_sel;
  Alcotest.check Alcotest.int "peers_sel preserved" 2 s.peers_sel

(* Focus defaults to List; a tab switch FROM List focus stays in List focus
   (the [focus = List] in the NextTab/PrevTab/JumpTab arms). B5 refines the
   Input-focus case: nav events are INERT in Input focus (typing must never
   navigate — see [test_nav_inert_in_input]); the Input→List reset is now an
   explicit [cancel_compose] (Esc), not a tab key. *)
let test_focus_resets_on_tab_switch () =
  let s0 = S.initial in
  Alcotest.check focus_testable "initial focus List" S.List s0.focus;
  (* A tab switch from List focus keeps List focus. *)
  let s = S.apply ~list_len:0 s0 S.NextTab in
  Alcotest.check focus_testable "NextTab keeps List focus" S.List s.focus;
  let s2 = S.apply ~list_len:0 s0 (S.JumpTab S.Rooms) in
  Alcotest.check focus_testable "JumpTab keeps List focus" S.List s2.focus;
  (* From Input focus, cancel_compose returns to List focus. *)
  let s_input = S.begin_compose s0 (S.Compose_dm "x") in
  Alcotest.check focus_testable "begin_compose -> Input" S.Input s_input.focus;
  let s_back = S.cancel_compose s_input in
  Alcotest.check focus_testable "cancel_compose -> List" S.List s_back.focus

(* clamp_counts re-clamps every per-tab selection against current list
   lengths — the data-driven clamp the loop applies after a snapshot rebuild.
   A list that SHRINKS must pull an out-of-range index back into bounds. *)
let test_clamp_counts_shrink () =
  (* Selections valid for a 7-row world. *)
  let s =
    { S.initial with S.peers_sel = 6; dms_sel = 4; rooms_sel = 2 }
  in
  (* World shrinks: peers 7->3, dms 5->0 (emptied), rooms 3->3 (unchanged). *)
  let s = S.clamp_counts ~peers:3 ~dms:0 ~rooms:3 s in
  Alcotest.check Alcotest.int "peers_sel clamped 6->2" 2 s.peers_sel;
  Alcotest.check Alcotest.int "dms_sel clamped to 0 (empty)" 0 s.dms_sel;
  Alcotest.check Alcotest.int "rooms_sel unchanged (in range)" 2 s.rooms_sel

(* After a shrink left the index out of range, a SelUp/SelDown key recovers it
   into bounds (apply also clamps to the ceiling, not just the 0 floor). *)
let test_apply_recovers_out_of_range () =
  let s = { S.initial with S.peers_sel = 6 } in (* stale: list now has 3 *)
  let up = S.apply ~list_len:3 s S.SelUp in
  Alcotest.check Alcotest.int "SelUp from stale 6 -> 2 (<=max)" 2 up.peers_sel;
  let down = S.apply ~list_len:3 s S.SelDown in
  Alcotest.check Alcotest.int "SelDown from stale 6 -> 2 (<=max)" 2 down.peers_sel

(* Quit / Refresh / NoOp are inert to navigable state. *)
let test_inert_events () =
  let s = S.apply ~list_len:5 S.initial S.SelDown in (* peers_sel = 1 *)
  let after_refresh = S.apply ~list_len:5 s S.Refresh in
  Alcotest.check Alcotest.int "Refresh inert" 1 after_refresh.peers_sel;
  let after_quit = S.apply ~list_len:5 s S.Quit in
  Alcotest.check Alcotest.int "Quit inert" 1 after_quit.peers_sel;
  let after_noop = S.apply ~list_len:5 s S.NoOp in
  Alcotest.check Alcotest.int "NoOp inert" 1 after_noop.peers_sel

(* --- B5: compose-mode transitions --------------------------------------- *)

(* begin_compose sets focus=Input, records the target, and clears the buffer. *)
let test_begin_compose () =
  let s = { S.initial with S.input = "stale" } in
  let s = S.begin_compose s (S.Compose_dm "alice") in
  Alcotest.check focus_testable "focus -> Input" S.Input s.focus;
  Alcotest.check Alcotest.string "input cleared" "" s.input;
  (match s.compose with
   | Some (S.Compose_dm a) ->
       Alcotest.check Alcotest.string "target alias" "alice" a
   | _ -> Alcotest.fail "expected Compose_dm target")

(* AppendChar appends in Input focus (incl. a MULTI-BYTE code point); Backspace
   drops exactly ONE code point (not one byte). *)
let test_input_edits () =
  let s = S.begin_compose S.initial (S.Compose_dm "bob") in
  let s = S.apply ~list_len:0 s (S.AppendChar "h") in
  let s = S.apply ~list_len:0 s (S.AppendChar "i") in
  Alcotest.check Alcotest.string "ascii appended" "hi" s.input;
  (* Append a 4-byte emoji (U+1F642) then a 2-byte é (U+00E9). *)
  let s = S.apply ~list_len:0 s (S.AppendChar "\xf0\x9f\x99\x82") in
  let s = S.apply ~list_len:0 s (S.AppendChar "\xc3\xa9") in
  Alcotest.check Alcotest.string "multibyte appended"
    "hi\xf0\x9f\x99\x82\xc3\xa9" s.input;
  (* Backspace drops the é (2 bytes) as ONE code point. *)
  let s = S.apply ~list_len:0 s S.Backspace in
  Alcotest.check Alcotest.string "backspace drops 2-byte é"
    "hi\xf0\x9f\x99\x82" s.input;
  (* Backspace drops the emoji (4 bytes) as ONE code point. *)
  let s = S.apply ~list_len:0 s S.Backspace in
  Alcotest.check Alcotest.string "backspace drops 4-byte emoji" "hi" s.input;
  let s = S.apply ~list_len:0 s S.Backspace in
  let s = S.apply ~list_len:0 s S.Backspace in
  Alcotest.check Alcotest.string "backspace to empty" "" s.input;
  (* Backspace on empty is a no-op (no underflow). *)
  let s = S.apply ~list_len:0 s S.Backspace in
  Alcotest.check Alcotest.string "backspace on empty stays empty" "" s.input

(* cancel_compose resets to List focus, clears the buffer + target. *)
let test_cancel_compose () =
  let s = S.begin_compose S.initial (S.Compose_room "swarm-lounge") in
  let s = S.apply ~list_len:0 s (S.AppendChar "x") in
  let s = S.cancel_compose s in
  Alcotest.check focus_testable "focus -> List" S.List s.focus;
  Alcotest.check Alcotest.string "input cleared" "" s.input;
  Alcotest.check Alcotest.bool "compose cleared" true (s.compose = None)

(* Nav events are INERT in Input focus: typing '1'/j/k/Tab must NOT navigate or
   move the selection. (The loop maps printables to AppendChar in Input focus;
   apply is the defence-in-depth belt asserted here directly.) *)
let test_nav_inert_in_input () =
  let s = S.begin_compose S.initial (S.Compose_dm "carol") in
  let before_tab = s.tab in
  let s1 = S.apply ~list_len:5 s S.NextTab in
  Alcotest.check tab_testable "NextTab inert in Input" before_tab s1.tab;
  Alcotest.check focus_testable "still Input after NextTab" S.Input s1.focus;
  let s2 = S.apply ~list_len:5 s (S.JumpTab S.Rooms) in
  Alcotest.check tab_testable "JumpTab inert in Input" before_tab s2.tab;
  let s3 = S.apply ~list_len:5 s S.SelDown in
  Alcotest.check Alcotest.int "SelDown inert in Input" 0 (S.active_sel s3)

(* set_status sets the status line without disturbing focus/selection. *)
let test_set_status () =
  let s = S.set_status S.initial "\xe2\x9c\x93 sent to alice" in
  Alcotest.check Alcotest.string "status set" "\xe2\x9c\x93 sent to alice"
    s.status;
  Alcotest.check focus_testable "focus unchanged" S.List s.focus

(* AppendChar/Backspace are INERT in List focus (no accidental buffer edits
   when not composing). *)
let test_input_edits_inert_in_list () =
  let s = S.initial in
  let s = S.apply ~list_len:0 s (S.AppendChar "x") in
  Alcotest.check Alcotest.string "AppendChar inert in List" "" s.input;
  let s = S.apply ~list_len:0 { s with S.input = "abc" } S.Backspace in
  Alcotest.check Alcotest.string "Backspace inert in List" "abc" s.input

let () =
  Alcotest.run "c2c_watch_state"
    [ ( "transitions",
        [ Alcotest.test_case "next_tab_wraps" `Quick test_next_tab_wraps;
          Alcotest.test_case "prev_tab_wraps" `Quick test_prev_tab_wraps;
          Alcotest.test_case "jump_tab" `Quick test_jump_tab;
          Alcotest.test_case "selup_floor" `Quick test_selup_floor;
          Alcotest.test_case "seldown_ceiling" `Quick test_seldown_ceiling;
          Alcotest.test_case "seldown_empty" `Quick test_seldown_empty;
          Alcotest.test_case "per_tab_selection" `Quick test_per_tab_selection;
          Alcotest.test_case "clamp_counts_shrink" `Quick
            test_clamp_counts_shrink;
          Alcotest.test_case "apply_recovers_out_of_range" `Quick
            test_apply_recovers_out_of_range;
          Alcotest.test_case "focus_resets_on_tab_switch" `Quick
            test_focus_resets_on_tab_switch;
          Alcotest.test_case "inert_events" `Quick test_inert_events;
          Alcotest.test_case "begin_compose" `Quick test_begin_compose;
          Alcotest.test_case "input_edits" `Quick test_input_edits;
          Alcotest.test_case "cancel_compose" `Quick test_cancel_compose;
          Alcotest.test_case "nav_inert_in_input" `Quick
            test_nav_inert_in_input;
          Alcotest.test_case "set_status" `Quick test_set_status;
          Alcotest.test_case "input_edits_inert_in_list" `Quick
            test_input_edits_inert_in_list ] ) ]
