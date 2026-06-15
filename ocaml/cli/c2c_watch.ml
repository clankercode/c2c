(* c2c_watch.ml — `c2c watch` subcommand (slices B0-B5, complete).

   This is the ONLY module in the watch feature that touches lambda-term.
   Everything visual is delegated to the pure [C2c_watch_render] layer so a
   library swap (the spec's Plan-B mosaic) touches only this file, and so the
   render output stays golden-snapshot-testable without a terminal (spec §2).
   It is ALSO the only module that touches the clock / env / Unix.stat — the
   pure [C2c_watch_state] / [C2c_watch_render] / [C2c_watch_data] layers never
   do (spec §1, §5).

   The #1 correctness hazard — terminal teardown on EVERY exit path (normal
   quit, q, Ctrl-c key, uncaught exception, external SIGINT/SIGTERM) — was
   landed first (B0) and is preserved unchanged through everything below. On
   top of it this module:
   - resolves the broker root, [Broker.create], builds a [C2c_watch_data.snapshot];
   - holds a [C2c_watch_state.t] (navigable UI state: active tab, per-tab
     selection, compose buffer);
   - renders the active tab via [C2c_watch_render.render] and prints it;
   - runs a poll loop: [Lwt.pick [ LTerm.read_event ; refresh_timer ]] — NO
     separate thread (spec §5). On a refresh tick it rebuilds the live peer
     roster every tick (liveness is process state) and re-reads the heavier
     archive/room data only when the watched-file mtime fingerprint changed;
     on a key it translates [LTerm_key.t] -> [C2c_watch_state.event] (FOCUS-
     aware: nav in list focus, text entry in compose focus) and applies it.
   All three tabs are live — Peers (roster), DMs (per-session shards + detail),
   Rooms (room list + canonical history). [Enter] on a selection opens a
   compose line; submitting sends a DM / room post in-process via the broker
   ([C2c_watch_data] send wrappers, which never raise — a send error surfaces
   on the status line, never crashing the watcher).

   Teardown design:
   - [Lwt.finalize] wraps the event loop so the normal-quit and
     exception/crash paths both restore the terminal.
   - [Sys.signal] handlers for SIGINT and SIGTERM restore the terminal
     synchronously (best-effort, blocking) and exit, covering an external
     `kill` that the lwt loop never sees as a key event. In raw mode the
     terminal does NOT raise SIGINT on Ctrl-c (it arrives as a key event
     instead, handled in the loop) — the SIGINT handler is purely for an
     external signal. *)

let doc = "Live TUI over the c2c broker (read + send)."

let man =
  [ `S "DESCRIPTION"
  ; `P "$(b,c2c watch) opens a full-screen, in-process terminal UI over the \
        c2c broker with three tabs: $(b,Peers) (the live roster with an \
        Alive/Dead/Unknown liveness tristate), $(b,DMs) (per-session message \
        shards and their detail), and $(b,Rooms) (the room list with each \
        room's canonical history). $(b,Tab)/$(b,Shift-Tab) or \
        $(b,1)/$(b,2)/$(b,3) switch tabs; $(b,Up)/$(b,Down) (or $(b,k)/\
        $(b,j)) move the selection; $(b,r) forces a refresh; $(b,q) or \
        Ctrl-c quit. The view auto-refreshes on a poll interval \
        (see $(b,--interval)), re-reading broker state only when a watched \
        file changed."
  ; `P "$(b,Enter) on a selected peer / shard / room opens a compose line; \
        type a message and press $(b,Enter) to send it in-process via the \
        broker (a DM, or a room post), or $(b,Esc) to cancel. The sender \
        identity is the $(b,--as) alias (default $(b,operator)). Send errors \
        (an unknown or offline recipient, an empty body) surface on the status \
        line; a room post that succeeds but reached no live members is shown as \
        a warning, not an error. A send never crashes the watcher."
  ; `P "This is an interactive operator tool (Tier 3): it is hidden from \
        managed agent sessions and requires a real terminal."
  ]

(* Restore the terminal to a sane state. Idempotent and total: each step is
   guarded so a failure mid-teardown still attempts the remaining steps. The
   [mode] is the raw-mode handle returned by [enter_raw_mode] (None if raw
   mode was never entered). This is run from the lwt finalizer AND, in a
   synchronous form, from the signal handlers. *)
let restore_terminal_lwt (term : LTerm.t) (mode : LTerm.mode option) :
    unit Lwt.t =
  let open Lwt.Infix in
  let guard f = Lwt.catch f (fun _ -> Lwt.return_unit) in
  (* Leave raw mode first (re-enable cooked line editing). *)
  (match mode with
   | Some m -> guard (fun () -> LTerm.leave_raw_mode term m)
   | None -> Lwt.return_unit)
  >>= fun () ->
  guard (fun () -> LTerm.show_cursor term) >>= fun () ->
  (* [load_state] restores the screen contents saved by [save_state]; this is
     lambda-term's alternate-screen equivalent. *)
  guard (fun () -> LTerm.load_state term) >>= fun () ->
  guard (fun () -> LTerm.flush term)

(* The operator's terminal_io captured BEFORE [enter_raw_mode], so the
   synchronous signal-handler path can restore it EXACTLY (lambda-term's raw
   mode clears far more than icanon/echo/isig). Set once at the top of
   [run_watch]; [None] until then (and on a tcgetattr failure). *)
let saved_termios : Unix.terminal_io option ref = ref None

(* Synchronous restore for the signal-handler path: we cannot run lwt from a
   signal handler safely, so emit the raw control sequences to the real fd
   directly. Show cursor + leave alternate-screen-ish + reset attributes; and
   restore cooked mode via Unix termios. Best-effort, never raises. *)
let restore_terminal_sync () : unit =
  (try
     (* Show cursor, reset SGR, leave alternate screen if entered. Matches the
        sequences lambda-term emits (load_state -> rmcup "\027[?1049l"); the
        rmcup is harmless if alt-screen was never entered. Without it an
        external SIGINT/SIGTERM exits still in the alt-screen buffer, leaving
        the operator's screen wedged (cooked mode + cursor restored, but the
        TUI frame lingers under the returning shell prompt). *)
     output_string stdout "\027[?25h\027[0m\027[?1049l";
     flush stdout
   with _ -> ());
  (try
     (* Restore the EXACT termios captured before raw mode was entered.
        lambda-term's raw mode clears far more than icanon/echo/isig (also
        brkint/inpck/istrip/ixon/csize/parenb/vmin/vtime), so flipping only
        those three would leave residual raw-mode flags (e.g. IXON off — broken
        flow control) after an external SIGINT/SIGTERM. Fall back to re-enabling
        the cooked-mode flags when no saved termios was captured (e.g. a signal
        during early setup before the capture). *)
     match !saved_termios with
     | Some tio -> Unix.tcsetattr Unix.stdin Unix.TCSANOW tio
     | None ->
         let attr = Unix.tcgetattr Unix.stdin in
         Unix.tcsetattr Unix.stdin Unix.TCSANOW
           { attr with Unix.c_icanon = true; c_echo = true; c_isig = true }
   with _ -> ())

(* Draw one empty frame sized to the live terminal — the pre-first-snapshot
   "loading" frame. Pure render in [C2c_watch_render]; here we just clear,
   home the cursor, and print it. Kept intact from B0 (the empty-frame golden
   asserts [render_empty_frame] byte-for-byte). *)
let draw_frame (term : LTerm.t) : unit Lwt.t =
  let open Lwt.Infix in
  LTerm.get_size term >>= fun size ->
  let cols = LTerm_geom.cols size and rows = LTerm_geom.rows size in
  let frame = C2c_watch_render.render_empty_frame ~cols ~rows in
  LTerm.clear_screen term >>= fun () ->
  LTerm.goto term { LTerm_geom.row = 0; col = 0 } >>= fun () ->
  LTerm.fprint term frame >>= fun () ->
  LTerm.flush term

(* Draw the live frame for the current snapshot + state. Pure render; here we
   only clear/home/print. *)
let draw_state (term : LTerm.t) (snapshot : C2c_watch_data.snapshot)
    (state : C2c_watch_state.t) : unit Lwt.t =
  let open Lwt.Infix in
  LTerm.get_size term >>= fun size ->
  let cols = LTerm_geom.cols size and rows = LTerm_geom.rows size in
  let frame = C2c_watch_render.render ~cols ~rows ~snapshot ~state in
  LTerm.clear_screen term >>= fun () ->
  LTerm.goto term { LTerm_geom.row = 0; col = 0 } >>= fun () ->
  LTerm.fprint term frame >>= fun () ->
  LTerm.flush term

(* --- mtime fingerprint (impure; lives ONLY here, spec §5) ---------------- *)

(* The watched file classes (spec §5): registry.json, archive/*.jsonl +
   <sid>.inbox.json, rooms/<id>/history.jsonl, rooms/<id>/{meta,members}.json.
   We mtime-stat each and compare a cheap fingerprint across ticks; the
   snapshot is rebuilt ONLY when a watched mtime changed. */ *)
let mtime_opt (path : string) : float =
  match Unix.stat path with
  | st -> st.Unix.st_mtime
  | exception _ -> 0.0

(* Recursively accumulate mtimes of every regular file under [dir] (one level
   of subdirs is enough for rooms/<id>/*; we walk fully to be safe). Returns a
   list of (path, mtime) pairs; missing dir -> []. Order-independent: the
   caller folds these into a single float so order does not matter. *)
let rec dir_mtimes (dir : string) (acc : float ref) : unit =
  match Sys.readdir dir with
  | entries ->
      (* Stat the dir itself too so create/delete of entries is observed even
         when no surviving file changed mtime. *)
      acc := !acc +. mtime_opt dir;
      Array.iter
        (fun name ->
          let p = Filename.concat dir name in
          match Unix.stat p with
          | st when st.Unix.st_kind = Unix.S_DIR -> dir_mtimes p acc
          | st -> acc := !acc +. st.Unix.st_mtime
          | exception _ -> ())
        entries
  | exception _ -> ()

(* A single float fingerprint over all watched paths. Cheap, total, and
   order-independent (sum of mtimes + the broker-root dir mtime to catch
   top-level inbox.json create/delete). A different fingerprint => rebuild. *)
let fingerprint (root : string) : float =
  let acc = ref 0.0 in
  (* registry.json *)
  acc := !acc +. mtime_opt (Filename.concat root "registry.json");
  (* top-level dir mtime catches *.inbox.json create/delete *)
  acc := !acc +. mtime_opt root;
  (* top-level *.inbox.json files *)
  (match Sys.readdir root with
   | entries ->
       Array.iter
         (fun name ->
           if Filename.check_suffix name ".inbox.json" then
             acc := !acc +. mtime_opt (Filename.concat root name))
         entries
   | exception _ -> ());
  (* archive/*.jsonl *)
  dir_mtimes (Filename.concat root "archive") acc;
  (* rooms/<id>/{history,meta,members}.* *)
  dir_mtimes (Filename.concat root "rooms") acc;
  !acc

(* Active tab's list length, for the pure selection-clamp transition. *)
let active_list_len (snapshot : C2c_watch_data.snapshot)
    (state : C2c_watch_state.t) : int =
  match state.tab with
  | C2c_watch_state.Peers -> List.length snapshot.peers
  | C2c_watch_state.DMs -> List.length snapshot.shards
  | C2c_watch_state.Rooms -> List.length snapshot.rooms

(* A loop-level action for a key, AFTER focus-aware translation (spec §4.4 /
   §6). Most keys map to a pure [C2c_watch_state.event] applied by the loop;
   [Begin_compose], [Submit], and [Cancel_compose] are IO/snapshot-coupled
   (compute target / send / refresh) so they are handled directly in the loop,
   not via the pure variant. *)
type key_action =
  | A_event of C2c_watch_state.event
  | A_quit
  | A_refresh
  | A_begin_compose   (* Enter in List focus: open compose for the selection *)
  | A_submit          (* Enter in Input focus: send the buffer *)
  | A_cancel_compose  (* Esc in Input focus: drop the buffer, back to List *)

(* The UTF-8 byte encoding of a Uchar (1-4 bytes). Used to append a typed code
   point to the compose buffer. *)
let utf8_of_uchar (u : Uchar.t) : string =
  let b = Buffer.create 4 in
  Buffer.add_utf_8_uchar b u;
  Buffer.contents b

(* Translate a raw key into a loop action, FOCUS-AWARE (spec §4.4 / §6).
   Shift-Tab arrives as Tab with [shift=true] (lambda-term has no BackTab code).
   In raw mode Ctrl-c is a Char 'c' with [control=true], NOT SIGINT.

   LIST focus: Tab/1/2/3/j/k/r/q/arrows as before, PLUS Enter -> begin compose.
   INPUT focus (compose line active): a PRINTABLE char -> [AppendChar] (NOT a
   nav/jump!), Backspace -> [Backspace], Enter -> [A_submit], Esc ->
   [A_cancel_compose], Ctrl-c -> [A_quit] (still quits from compose). Typing
   '1'/'q'/'j' etc. in Input focus inserts the literal char and never
   navigates/quits. *)
let key_action (focus : C2c_watch_state.focus) (k : LTerm_key.t) : key_action =
  let is_char ch =
    match k.LTerm_key.code with
    | LTerm_key.Char c -> Uchar.equal c (Uchar.of_char ch)
    | _ -> false
  in
  let ctrl_c = k.LTerm_key.control && is_char 'c' in
  (* A bare printable nav key — must NOT have the control modifier, so a
     Ctrl-J / Ctrl-K (when a terminal delivers it as Char 'j'/'k' with
     control=true rather than as Enter) does not trip the j/k/r/q/1/2/3
     bindings. Ctrl-c is matched separately via [ctrl_c]. *)
  let plain_char ch = is_char ch && not k.LTerm_key.control in
  match focus with
  | C2c_watch_state.Input -> (
      (* Ctrl-c still quits even from compose. *)
      if ctrl_c then A_quit
      else
        match k.LTerm_key.code with
        | LTerm_key.Enter -> A_submit
        | LTerm_key.Escape -> A_cancel_compose
        | LTerm_key.Backspace -> A_event C2c_watch_state.Backspace
        | LTerm_key.Char u ->
            (* A printable code point. Control combos (e.g. Ctrl-<x>) other than
               Ctrl-c are ignored so a stray control key cannot inject a glyph. *)
            if k.LTerm_key.control then A_event C2c_watch_state.NoOp
            else A_event (C2c_watch_state.AppendChar (utf8_of_uchar u))
        | _ -> A_event C2c_watch_state.NoOp)
  | C2c_watch_state.List -> (
      match k.LTerm_key.code with
      | LTerm_key.Tab when k.LTerm_key.shift -> A_event C2c_watch_state.PrevTab
      | LTerm_key.Tab -> A_event C2c_watch_state.NextTab
      | LTerm_key.Up -> A_event C2c_watch_state.SelUp
      | LTerm_key.Down -> A_event C2c_watch_state.SelDown
      | LTerm_key.Enter -> A_begin_compose
      | LTerm_key.Char _ when plain_char '1' ->
          A_event (C2c_watch_state.JumpTab C2c_watch_state.Peers)
      | LTerm_key.Char _ when plain_char '2' ->
          A_event (C2c_watch_state.JumpTab C2c_watch_state.DMs)
      | LTerm_key.Char _ when plain_char '3' ->
          A_event (C2c_watch_state.JumpTab C2c_watch_state.Rooms)
      | LTerm_key.Char _ when plain_char 'k' -> A_event C2c_watch_state.SelUp
      | LTerm_key.Char _ when plain_char 'j' -> A_event C2c_watch_state.SelDown
      | LTerm_key.Char _ when plain_char 'r' -> A_refresh
      | LTerm_key.Char _ when plain_char 'q' -> A_quit
      | LTerm_key.Char _ when ctrl_c -> A_quit
      | _ -> A_event C2c_watch_state.NoOp)

(* Compute the "refreshed Xs ago" label. The LOOP owns the clock — never the
   render layer (spec §1). [last_refresh] is the wall-clock at the most recent
   snapshot rebuild; [now] is read here. *)
let refreshed_label ~(now : float) ~(last_refresh : float) : string =
  let dt = now -. last_refresh in
  let dt = if dt < 0.0 then 0.0 else dt in
  Printf.sprintf "refreshed %.1fs ago" dt

(* --- the poll loop ------------------------------------------------------- *)

type loop_ctx = {
  term : LTerm.t;
  broker : C2c_watch_data.Broker.t;
  root : string;
  interval : float;
  from_alias : string;
    (* The operator's send identity (the --as value, default "operator"). Passed
       straight to the broker as the DM/room sender; the broker validates it.
       No resolve_alias session-coupling — that is for agent sends. *)
}

(* Compute the compose target for an Enter in List focus from the active tab +
   selection + snapshot (spec §4.4). Returns [None] when the active list is
   empty (nothing to target) so the loop can show "nothing selected" and stay
   in List focus. PURE. *)
let compose_target_of (snapshot : C2c_watch_data.snapshot)
    (state : C2c_watch_state.t) : C2c_watch_state.compose_target option =
  let nth_opt = List.nth_opt in
  match state.C2c_watch_state.tab with
  | C2c_watch_state.Peers -> (
      match nth_opt snapshot.C2c_watch_data.peers state.C2c_watch_state.peers_sel with
      | Some p -> Some (C2c_watch_state.Compose_dm p.C2c_watch_data.pr_alias)
      | None -> None)
  | C2c_watch_state.DMs -> (
      match nth_opt snapshot.C2c_watch_data.shards state.C2c_watch_state.dms_sel with
      | Some s ->
          (* The DM compose target is the shard's owner alias (its registry
             label). An orphan shard has no owner — derive the label the same
             way the render does (newest entry's to_alias), else fall back to
             the session_id (a send to an unknown recipient surfaces a clean
             "not registered" error, never a crash). *)
          let label =
            match s.C2c_watch_data.ds_owner_alias with
            | Some a -> a
            | None -> (
                match s.C2c_watch_data.ds_entries with
                | (e : C2c_watch_data.Broker.archive_entry) :: _
                  when e.ae_to_alias <> "" -> e.ae_to_alias
                | _ -> s.C2c_watch_data.ds_session_id)
          in
          Some (C2c_watch_state.Compose_dm label)
      | None -> None)
  | C2c_watch_state.Rooms -> (
      match nth_opt snapshot.C2c_watch_data.rooms state.C2c_watch_state.rooms_sel with
      | Some rv ->
          Some
            (C2c_watch_state.Compose_room
               rv.C2c_watch_data.rv_info.C2c_watch_data.Broker.ri_room_id)
      | None -> None)

(* Perform the send for [target] with the current input. Returns the
   [send_result]; NEVER raises (the data-layer wrappers catch everything). *)
let do_send (ctx : loop_ctx) (target : C2c_watch_state.compose_target)
    (content : string) : C2c_watch_data.send_result =
  match target with
  | C2c_watch_state.Compose_dm to_alias ->
      C2c_watch_data.send_dm ctx.broker ~from_alias:ctx.from_alias ~to_alias
        ~content
  | C2c_watch_state.Compose_room room_id ->
      C2c_watch_data.send_room_message ctx.broker ~from_alias:ctx.from_alias
        ~room_id ~content

(* The event loop (spec §5): race a key read against a refresh timer.
   - key Quit -> return (teardown via the EXISTING B0 finalizer).
   - key Refresh -> force a snapshot rebuild now.
   - other key -> apply the pure transition, recompute label, redraw.
   - timer -> stat the watched paths; rebuild snapshot only if the fingerprint
     changed; recompute label; redraw (so the elapsed label advances each
     tick even when data is unchanged). *)
let rec event_loop (ctx : loop_ctx) (snapshot : C2c_watch_data.snapshot)
    (state : C2c_watch_state.t) (fp : float) (last_refresh : float) :
    unit Lwt.t =
  let open Lwt.Infix in
  let refresh_timer =
    Lwt_unix.sleep ctx.interval >>= fun () -> Lwt.return `Refresh
  in
  let key_read =
    LTerm.read_event ctx.term >>= fun ev -> Lwt.return (`Event ev)
  in
  Lwt.pick [ key_read; refresh_timer ] >>= fun outcome ->
  match outcome with
  | `Refresh ->
      let now = Unix.gettimeofday () in
      let new_fp = fingerprint ctx.root in
      (* Liveness is PROCESS state, not file state: a peer process dying (or a
         lease expiring) does not bump any watched mtime, so an mtime-gated
         rebuild would show stale Alive/Dead until an unrelated broker write.
         Rebuild the peers projection EVERY tick (cheap: registry read + per-pid
         /proc liveness) so the roster's tristate is always fresh; keep the
         heavy archive/room reads mtime-gated (they ARE append-only files, so
         mtime is a sound change signal there). *)
      let peers = C2c_watch_data.build_peers ctx.broker in
      let snapshot', fp' =
        if new_fp <> fp then (C2c_watch_data.build_snapshot ctx.broker, new_fp)
        else ({ snapshot with C2c_watch_data.peers }, fp)
      in
      (* The displayed roster is rebuilt every tick, so it is at most one
         interval old — advance last_refresh each tick. *)
      let last_refresh' = now in
      let state' =
        C2c_watch_state.clamp_counts
          ~peers:(List.length snapshot'.C2c_watch_data.peers)
          ~dms:(List.length snapshot'.C2c_watch_data.shards)
          ~rooms:(List.length snapshot'.C2c_watch_data.rooms)
          { state with
            C2c_watch_state.refreshed_label =
              refreshed_label ~now ~last_refresh:last_refresh' }
      in
      draw_state ctx.term snapshot' state' >>= fun () ->
      event_loop ctx snapshot' state' fp' last_refresh'
  | `Event (LTerm_event.Key k) -> (
      (* Force a full snapshot rebuild + re-clamp; carry [extra] state mutation
         (e.g. the status line / cancel_compose) applied AFTER the clamp. *)
      let rebuild_and_loop (extra : C2c_watch_state.t -> C2c_watch_state.t) :
          unit Lwt.t =
        let now = Unix.gettimeofday () in
        let new_fp = fingerprint ctx.root in
        let snapshot' = C2c_watch_data.build_snapshot ctx.broker in
        let state' =
          extra
            (C2c_watch_state.clamp_counts
               ~peers:(List.length snapshot'.C2c_watch_data.peers)
               ~dms:(List.length snapshot'.C2c_watch_data.shards)
               ~rooms:(List.length snapshot'.C2c_watch_data.rooms)
               { state with
                 C2c_watch_state.refreshed_label =
                   refreshed_label ~now ~last_refresh:now })
        in
        draw_state ctx.term snapshot' state' >>= fun () ->
        event_loop ctx snapshot' state' new_fp now
      in
      (* Redraw with [state'] against the CURRENT snapshot (no rebuild). *)
      let redraw_loop (state' : C2c_watch_state.t) : unit Lwt.t =
        let now = Unix.gettimeofday () in
        let state' =
          { state' with
            C2c_watch_state.refreshed_label =
              refreshed_label ~now ~last_refresh }
        in
        draw_state ctx.term snapshot state' >>= fun () ->
        event_loop ctx snapshot state' fp last_refresh
      in
      match key_action state.C2c_watch_state.focus k with
      | A_quit -> Lwt.return_unit
      | A_refresh -> rebuild_and_loop (fun s -> s)
      | A_begin_compose -> (
          (* Compute the target from the active tab + selection + snapshot;
             empty list -> "nothing selected", stay in List focus. *)
          match compose_target_of snapshot state with
          | Some target ->
              redraw_loop (C2c_watch_state.begin_compose state target)
          | None ->
              redraw_loop
                (C2c_watch_state.set_status state "nothing selected"))
      | A_cancel_compose -> redraw_loop (C2c_watch_state.cancel_compose state)
      | A_submit -> (
          (* SUBMIT (Enter in Input focus). The send goes through the
             data-layer wrappers, which NEVER raise — so a bad recipient / dead
             peer / reserved-from becomes a ✗ status, never a crash. *)
          match state.C2c_watch_state.compose with
          | None ->
              (* Defensive: Input focus with no target — cancel cleanly. *)
              redraw_loop (C2c_watch_state.cancel_compose state)
          | Some target ->
              let content = state.C2c_watch_state.input in
              if String.trim content = "" then
                (* Empty/whitespace -> do NOT send; keep composing. *)
                redraw_loop
                  (C2c_watch_state.set_status state "empty message, not sent")
              else begin
                let result = do_send ctx target content in
                let status = C2c_watch_render.status_of_send target result in
                match result with
                | C2c_watch_data.Send_failed _ ->
                    (* FAILURE: keep focus=Input + RETAIN input so the operator
                       can edit + set the ✗ status. No rebuild. *)
                    redraw_loop (C2c_watch_state.set_status state status)
                | _ ->
                    (* SUCCESS: rebuild the snapshot so the new row shows,
                       cancel_compose (back to List), set the ✓ status. *)
                    rebuild_and_loop (fun s ->
                        C2c_watch_state.set_status
                          (C2c_watch_state.cancel_compose s) status)
              end)
      | A_event ev ->
          let list_len = active_list_len snapshot state in
          redraw_loop (C2c_watch_state.apply ~list_len state ev))
  | `Event (LTerm_event.Resize _) ->
      draw_state ctx.term snapshot state >>= fun () ->
      event_loop ctx snapshot state fp last_refresh
  | `Event _ -> event_loop ctx snapshot state fp last_refresh

let run_watch ~(interval : float) ~(from_alias : string) () : unit Lwt.t =
  let open Lwt.Infix in
  Lazy.force LTerm.stdout >>= fun term ->
  (* Refuse gracefully if not a real tty (e.g. piped) rather than crashing in
     raw-mode setup. *)
  if not (LTerm.is_a_tty term) then begin
    Lwt_io.eprintl "c2c watch: not a tty (needs an interactive terminal)"
    >>= fun () -> Lwt.return_unit
  end else begin
    (* Capture the cooked terminal_io NOW — raw mode is not yet entered — so the
       synchronous signal-handler restore can put back the EXACT termios (not
       just three flags) on an external SIGINT/SIGTERM. *)
    (try saved_termios := Some (Unix.tcgetattr Unix.stdin) with _ -> ());
    (* Install the synchronous signal handler BEFORE save_state / enter_raw_mode
       so an external SIGINT/SIGTERM arriving during raw-mode SETUP still
       restores the terminal. [restore_terminal_sync] is harmless when raw mode
       / alt-screen were not yet entered (it only re-asserts cooked termios,
       shows the cursor, and emits rmcup). Installing handlers after entering
       raw mode would leave a setup-window where a signal takes the default
       (terminate) action and wedges the terminal. We capture the previous
       handlers to chain the default behaviour back on a clean exit. *)
    let handle_signal _ =
      restore_terminal_sync ();
      (* exit synchronously; lwt finalizer may not get a chance to run. *)
      exit 130
    in
    let prev_int = Sys.signal Sys.sigint (Sys.Signal_handle handle_signal) in
    let prev_term = Sys.signal Sys.sigterm (Sys.Signal_handle handle_signal) in
    (* Save screen state (alternate-screen equivalent) before entering raw
       mode so [load_state] can restore the operator's scrollback on exit. *)
    LTerm.save_state term >>= fun () ->
    LTerm.enter_raw_mode term >>= fun mode ->
    let mode_opt = Some mode in
    LTerm.hide_cursor term >>= fun () ->
    Lwt.finalize
      (fun () ->
        (* Resolve the broker + build the first snapshot. If broker resolution
           or the first read raises, the exception propagates through this
           [Lwt.finalize] — which restores the terminal FIRST — and the
           top-level [try/with] in [watch_term] prints it and exits non-zero, so
           teardown still runs cleanly on a startup failure. *)
        let root = C2c_utils.resolve_broker_root () in
        let broker = C2c_watch_data.Broker.create ~root in
        let now = Unix.gettimeofday () in
        let snapshot = C2c_watch_data.build_snapshot broker in
        let fp = fingerprint root in
        let state =
          { C2c_watch_state.initial with
            C2c_watch_state.refreshed_label =
              refreshed_label ~now ~last_refresh:now }
        in
        let ctx = { term; broker; root; interval; from_alias } in
        draw_state term snapshot state >>= fun () ->
        event_loop ctx snapshot state fp now)
      (fun () ->
        (* Restore the TERMINAL FIRST — while our signal handler is still
           installed and guarding the teardown — THEN restore the previous
           signal handlers. Restoring handlers first would open a window where
           an external SIGINT/SIGTERM during teardown takes the default
           (terminate) action and bypasses the terminal restore. *)
        restore_terminal_lwt term mode_opt >>= fun () ->
        Sys.set_signal Sys.sigint prev_int;
        Sys.set_signal Sys.sigterm prev_term;
        Lwt.return_unit)
  end

let watch_term =
  let open Cmdliner in
  let interval =
    let doc = "Refresh poll interval in seconds (re-reads broker state only \
               when a watched file's mtime changed)." in
    Arg.(
      value
      & opt float 1.0
      & info [ "interval" ] ~docv:"FLOAT" ~doc)
  in
  let from_alias =
    let doc =
      "Sender identity for sends (DM / room post). The operator running \
       $(b,c2c watch) has no agent session id, so this is passed straight to \
       the broker as the message sender; it must not be a reserved system \
       alias and (for DMs) the recipient must be registered. Defaults to the \
       reserved-for-operator alias $(b,operator)."
    in
    Arg.(value & opt string "operator" & info [ "as" ] ~docv:"ALIAS" ~doc)
  in
  let action interval from_alias =
    let interval = if interval <= 0.0 then 1.0 else interval in
    let from_alias =
      let trimmed = String.trim from_alias in
      if trimmed = "" then "operator" else trimmed
    in
    (try Lwt_main.run (run_watch ~interval ~from_alias ())
     with e ->
       (* Last-resort sync restore if something escaped the lwt finalizer. *)
       restore_terminal_sync ();
       Printf.eprintf "c2c watch: %s\n%!" (Printexc.to_string e);
       exit 1)
  in
  Term.(const action $ interval $ from_alias)

let watch_cmd =
  let open Cmdliner in
  Cmd.v (Cmd.info "watch" ~doc ~man) watch_term
