(* c2c_watch_state.ml — PURE state machine for `c2c watch` (slice B2).

   This module is deliberately dependency-free: NO lambda-term, NO IO, no
   clock / env / randomness. It models the navigable UI state as an immutable
   record and exposes a single pure transition [apply : list_len:int -> t ->
   event -> t]. [c2c_watch.ml] owns the LTerm_key -> event translation, so ALL
   lambda-term use stays confined to that one module (spec §2), and these
   transitions are unit-testable with no terminal and no broker snapshot
   (spec §9).

   The [event] variant is the conventional, library-agnostic key vocabulary
   (spec §6): tab cycling, jump-to-tab, list selection up/down, force-refresh,
   quit. B2 implements ONLY navigation; [Input]/[input]/[status] are carried on
   the record (and [focus] declared) for later slices (B5 send/compose) but are
   not exercised by any B2 transition beyond [focus] resetting to [List] on a
   tab switch.

   Selection clamping lives HERE (not in render or the loop), parameterised by
   the active tab's list length [list_len], so it is exhaustively testable:
   [SelUp] never goes below 0, [SelDown] never exceeds [max 0 (list_len-1)],
   and an empty list (list_len=0) clamps selection to 0. *)

type tab = Peers | DMs | Rooms

(* [Input] focus = the compose line is active (B5). A tab switch always resets
   focus to [List] (the compose line never carries across tabs). *)
type focus = List | Input

(* The send target a compose buffer is bound to (B5). Computed by the loop from
   the active tab + selection + snapshot when [Enter] begins a compose; carried
   on the state so [render] can draw the right prompt and the submit path knows
   whether to call [send_dm] or [send_room_message]. *)
type compose_target =
  | Compose_dm of string    (* recipient alias *)
  | Compose_room of string  (* room_id *)

type t = {
  tab : tab;
  peers_sel : int;       (* selected row index in the Peers roster *)
  dms_sel : int;         (* selected shard index (B3) *)
  rooms_sel : int;       (* selected room index (B4) *)
  focus : focus;
  compose : compose_target option;
    (* Some _ exactly when focus=Input — the target the input buffer sends to. *)
  input : string;        (* compose buffer (B5) *)
  status : string;       (* status line text (B5): last ✓/✗ send result *)
  refreshed_label : string;
    (* The "refreshed Xs ago" header text. The IMPURE loop in c2c_watch.ml
       owns the clock and writes this; render reads it verbatim. Keeping the
       elapsed-time string off the render path is what makes golden tests a
       deterministic byte diff (spec §1 render-purity constraint). *)
}

type event =
  | NextTab           (* Tab: Peers -> DMs -> Rooms -> Peers *)
  | PrevTab           (* Shift-Tab: reverse cycle *)
  | JumpTab of tab    (* '1'/'2'/'3' (List focus only) *)
  | SelUp             (* Up / k *)
  | SelDown           (* Down / j *)
  | Refresh           (* r — force a data refresh (handled by the loop) *)
  | Quit              (* q / Ctrl-c *)
  | AppendChar of string
      (* Input focus: append one typed code point (UTF-8 bytes) to [input]. *)
  | Backspace         (* Input focus: drop the last code point of [input] *)
  | NoOp              (* unhandled key *)

let initial : t =
  { tab = Peers
  ; peers_sel = 0
  ; dms_sel = 0
  ; rooms_sel = 0
  ; focus = List
  ; compose = None
  ; input = ""
  ; status = ""
  ; refreshed_label = ""
  }

(* Selection of the active tab. *)
let active_sel (t : t) : int =
  match t.tab with
  | Peers -> t.peers_sel
  | DMs -> t.dms_sel
  | Rooms -> t.rooms_sel

(* Set the active tab's selection (used by the transition; exposed for tests). *)
let set_active_sel (t : t) (sel : int) : t =
  match t.tab with
  | Peers -> { t with peers_sel = sel }
  | DMs -> { t with dms_sel = sel }
  | Rooms -> { t with rooms_sel = sel }

let next_tab = function Peers -> DMs | DMs -> Rooms | Rooms -> Peers
let prev_tab = function Peers -> Rooms | DMs -> Peers | Rooms -> DMs

(* Clamp a selection index into [0, len-1] (0 when the list is empty). *)
let clamp_sel (len : int) (sel : int) : int =
  if len <= 0 then 0
  else if sel < 0 then 0
  else if sel > len - 1 then len - 1
  else sel

(* Re-clamp EVERY per-tab selection against current list lengths. The loop
   calls this after a snapshot rebuild: [apply]'s clamp only fires on key
   events, so a list that SHRINKS on refresh (e.g. a peer went away) would
   otherwise leave a stored index out of range. Data-driven, not event-driven. *)
let clamp_counts ~(peers : int) ~(dms : int) ~(rooms : int) (t : t) : t =
  { t with
    peers_sel = clamp_sel peers t.peers_sel
  ; dms_sel = clamp_sel dms t.dms_sel
  ; rooms_sel = clamp_sel rooms t.rooms_sel
  }

(* --- B5 compose helpers (pure) ------------------------------------------ *)

(* Enter compose mode targeting [target]: focus moves to [Input], the input
   buffer is cleared, and [compose] records where a submit will send. PURE —
   the loop computes [target] from the active tab + selection + snapshot, then
   calls this. The status is left as-is (cleared on a successful submit). *)
let begin_compose (t : t) (target : compose_target) : t =
  { t with focus = Input; compose = Some target; input = "" }

(* Cancel compose (Esc): back to list focus, buffer + target cleared. The
   status line is preserved so a prior ✓/✗ stays visible. PURE. *)
let cancel_compose (t : t) : t =
  { t with focus = List; compose = None; input = "" }

(* Set the status line (a send result / a "nothing selected" note). PURE. *)
let set_status (t : t) (s : string) : t = { t with status = s }

(* Drop the last UTF-8 code point of [s] (returns "" when already empty). The
   compose buffer is byte-stored UTF-8; backspace must remove a whole code
   point, not a single byte, or a multi-byte glyph leaves a dangling
   continuation byte. Walk from the start tracking the last code-point start. *)
let drop_last_codepoint (s : string) : string =
  let n = String.length s in
  if n = 0 then ""
  else begin
    let last_start = ref 0 and i = ref 0 in
    while !i < n do
      let c = Char.code s.[!i] in
      let step =
        if c < 0x80 then 1
        else if c < 0xE0 then 2
        else if c < 0xF0 then 3
        else 4
      in
      last_start := !i;
      i := !i + step
    done;
    String.sub s 0 !last_start
  end

(* [apply ~list_len t ev] is the pure transition. [list_len] is the length of
   the ACTIVE tab's list at apply time, so selection clamping is correct
   regardless of which tab is focused. A tab switch resets [focus] to [List]
   (the compose line never carries across tabs). [Quit]/[Refresh]/[NoOp] are
   inert to the navigable state — the loop interprets [Quit]/[Refresh].

   FOCUS-AWARENESS (spec §4.4 / §6): in [Input] focus the navigation events
   ([NextTab]/[PrevTab]/[JumpTab]/[SelUp]/[SelDown]) are INERT — they never
   fire here because the loop's focus-aware key translation maps printable keys
   (incl. '1'/'2'/'3') to [AppendChar] in Input focus. As a defence-in-depth
   belt, [apply] ALSO ignores those nav events when [focus = Input], so typing
   can never navigate even if the loop mistranslated. [AppendChar]/[Backspace]
   only edit the buffer in Input focus (no-op in List focus). *)
let apply ~(list_len : int) (t : t) (ev : event) : t =
  let max_sel = max 0 (list_len - 1) in
  match ev with
  | AppendChar s ->
      if t.focus = Input then { t with input = t.input ^ s } else t
  | Backspace ->
      if t.focus = Input then { t with input = drop_last_codepoint t.input }
      else t
  | NextTab when t.focus = Input -> t
  | PrevTab when t.focus = Input -> t
  | JumpTab _ when t.focus = Input -> t
  | SelUp when t.focus = Input -> t
  | SelDown when t.focus = Input -> t
  | NextTab -> { t with tab = next_tab t.tab; focus = List }
  | PrevTab -> { t with tab = prev_tab t.tab; focus = List }
  | JumpTab tab -> { t with tab; focus = List }
  | SelUp ->
      (* Clamp to [max_sel] as well as the 0 floor, so even a stored index
         left out of range by a data shrink recovers on the next key. *)
      let sel = active_sel t in
      set_active_sel t (min max_sel (max 0 (sel - 1)))
  | SelDown ->
      (* [max 0 sel] guards a (defensively) negative start; [min max_sel]
         clamps the ceiling and also recovers a too-high stored index. *)
      let sel = active_sel t in
      set_active_sel t (min max_sel (max 0 sel + 1))
  | Refresh -> t
  | Quit -> t
  | NoOp -> t
