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

(* [Input] is declared for B5 (the compose line) but B2 only ever holds
   [List]; a tab switch resets focus to [List]. *)
type focus = List | Input

type t = {
  tab : tab;
  peers_sel : int;       (* selected row index in the Peers roster *)
  dms_sel : int;         (* selected shard index (B3) *)
  rooms_sel : int;       (* selected room index (B4) *)
  focus : focus;
  input : string;        (* compose buffer — B5; unused in B2 *)
  status : string;       (* status line text — B5; unused in B2 *)
  refreshed_label : string;
    (* The "refreshed Xs ago" header text. The IMPURE loop in c2c_watch.ml
       owns the clock and writes this; render reads it verbatim. Keeping the
       elapsed-time string off the render path is what makes golden tests a
       deterministic byte diff (spec §1 render-purity constraint). *)
}

type event =
  | NextTab           (* Tab: Peers -> DMs -> Rooms -> Peers *)
  | PrevTab           (* Shift-Tab: reverse cycle *)
  | JumpTab of tab    (* '1'/'2'/'3' *)
  | SelUp             (* Up / k *)
  | SelDown           (* Down / j *)
  | Refresh           (* r — force a data refresh (handled by the loop) *)
  | Quit              (* q / Ctrl-c *)
  | NoOp              (* unhandled key *)

let initial : t =
  { tab = Peers
  ; peers_sel = 0
  ; dms_sel = 0
  ; rooms_sel = 0
  ; focus = List
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

(* [apply ~list_len t ev] is the pure transition. [list_len] is the length of
   the ACTIVE tab's list at apply time, so selection clamping is correct
   regardless of which tab is focused. A tab switch resets [focus] to [List]
   (the compose line never carries across tabs). [Quit]/[Refresh]/[NoOp] are
   inert to the navigable state — the loop interprets [Quit]/[Refresh]. *)
let apply ~(list_len : int) (t : t) (ev : event) : t =
  let max_sel = max 0 (list_len - 1) in
  match ev with
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
