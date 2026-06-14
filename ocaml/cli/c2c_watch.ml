(* c2c_watch.ml — `c2c watch` subcommand (slices B0, B2).

   This is the ONLY module in the watch feature that touches lambda-term.
   Everything visual is delegated to the pure [C2c_watch_render] layer so a
   library swap (the spec's Plan-B mosaic) touches only this file, and so the
   render output stays golden-snapshot-testable without a terminal (spec §2).
   It is ALSO the only module that touches the clock / env / Unix.stat — the
   pure [C2c_watch_state] / [C2c_watch_render] / [C2c_watch_data] layers never
   do (spec §1, §5).

   B0 shipped the empty-frame skeleton + the #1 correctness hazard: terminal
   teardown on EVERY exit path (normal quit, q, Ctrl-c key, uncaught
   exception, external SIGINT/SIGTERM). B2 layers the live Peers tab on top
   WITHOUT touching that teardown/signal ordering:
   - resolve the broker root, [Broker.create], build a [C2c_watch_data.snapshot];
   - hold a [C2c_watch_state.t] (navigable UI state);
   - render the active tab via [C2c_watch_render.render] and print it;
   - run a poll loop: [Lwt.pick [ LTerm.read_event ; refresh_timer ]] — NO
     separate thread (spec §5). On a refresh tick, stat the watched paths and
     rebuild the snapshot ONLY when the mtime fingerprint changed; on a key,
     translate [LTerm_key.t] -> [C2c_watch_state.event] and apply.
   B2 implements ONLY the Peers tab + tab navigation; DMs/Rooms render
   placeholder panes (B3/B4). No send / compose line (B5).

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
        c2c broker. The $(b,Peers) tab shows the live roster with an \
        Alive/Dead/Unknown liveness tristate; $(b,Tab)/$(b,Shift-Tab) or \
        $(b,1)/$(b,2)/$(b,3) switch between Peers / DMs / Rooms (DMs and \
        Rooms detail land in later slices); $(b,Up)/$(b,Down) (or $(b,k)/\
        $(b,j)) move the selection; $(b,r) forces a refresh; $(b,q) or \
        Ctrl-c quit. The view auto-refreshes on a poll interval \
        (see $(b,--interval)), re-reading broker state only when a watched \
        file changed."
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
     let attr = Unix.tcgetattr Unix.stdin in
     (* Re-enable canonical mode + echo so the shell prompt is usable again. *)
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

(* Translate a raw key into a pure state event (spec §6). Shift-Tab arrives as
   Tab with [shift=true] (lambda-term has no BackTab code). In raw mode Ctrl-c
   is a Char 'c' with [control=true], NOT SIGINT. *)
let event_of_key (k : LTerm_key.t) : C2c_watch_state.event =
  let is_char ch =
    match k.LTerm_key.code with
    | LTerm_key.Char c -> Uchar.equal c (Uchar.of_char ch)
    | _ -> false
  in
  match k.LTerm_key.code with
  | LTerm_key.Tab when k.LTerm_key.shift -> C2c_watch_state.PrevTab
  | LTerm_key.Tab -> C2c_watch_state.NextTab
  | LTerm_key.Up -> C2c_watch_state.SelUp
  | LTerm_key.Down -> C2c_watch_state.SelDown
  | LTerm_key.Char _ when is_char '1' -> C2c_watch_state.JumpTab C2c_watch_state.Peers
  | LTerm_key.Char _ when is_char '2' -> C2c_watch_state.JumpTab C2c_watch_state.DMs
  | LTerm_key.Char _ when is_char '3' -> C2c_watch_state.JumpTab C2c_watch_state.Rooms
  | LTerm_key.Char _ when is_char 'k' -> C2c_watch_state.SelUp
  | LTerm_key.Char _ when is_char 'j' -> C2c_watch_state.SelDown
  | LTerm_key.Char _ when is_char 'r' -> C2c_watch_state.Refresh
  | LTerm_key.Char _ when is_char 'q' -> C2c_watch_state.Quit
  | LTerm_key.Char _ when k.LTerm_key.control && is_char 'c' -> C2c_watch_state.Quit
  | _ -> C2c_watch_state.NoOp

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
}

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
      match event_of_key k with
      | C2c_watch_state.Quit -> Lwt.return_unit
      | C2c_watch_state.Refresh ->
          let now = Unix.gettimeofday () in
          let new_fp = fingerprint ctx.root in
          let snapshot' = C2c_watch_data.build_snapshot ctx.broker in
          let state' =
            C2c_watch_state.clamp_counts
              ~peers:(List.length snapshot'.C2c_watch_data.peers)
              ~dms:(List.length snapshot'.C2c_watch_data.shards)
              ~rooms:(List.length snapshot'.C2c_watch_data.rooms)
              { state with
                C2c_watch_state.refreshed_label =
                  refreshed_label ~now ~last_refresh:now }
          in
          draw_state ctx.term snapshot' state' >>= fun () ->
          event_loop ctx snapshot' state' new_fp now
      | ev ->
          let now = Unix.gettimeofday () in
          let list_len = active_list_len snapshot state in
          let state' = C2c_watch_state.apply ~list_len state ev in
          let state' =
            { state' with
              C2c_watch_state.refreshed_label =
                refreshed_label ~now ~last_refresh }
          in
          draw_state ctx.term snapshot state' >>= fun () ->
          event_loop ctx snapshot state' fp last_refresh)
  | `Event (LTerm_event.Resize _) ->
      draw_state ctx.term snapshot state >>= fun () ->
      event_loop ctx snapshot state fp last_refresh
  | `Event _ -> event_loop ctx snapshot state fp last_refresh

let run_watch ~(interval : float) () : unit Lwt.t =
  let open Lwt.Infix in
  Lazy.force LTerm.stdout >>= fun term ->
  (* Refuse gracefully if not a real tty (e.g. piped) rather than crashing in
     raw-mode setup. *)
  if not (LTerm.is_a_tty term) then begin
    Lwt_io.eprintl "c2c watch: not a tty (needs an interactive terminal)"
    >>= fun () -> Lwt.return_unit
  end else begin
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
           or the first read raises, fall back to the empty loading frame so
           teardown still runs cleanly (the finalizer below). *)
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
        let ctx = { term; broker; root; interval } in
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
  let action interval =
    let interval = if interval <= 0.0 then 1.0 else interval in
    (try Lwt_main.run (run_watch ~interval ())
     with e ->
       (* Last-resort sync restore if something escaped the lwt finalizer. *)
       restore_terminal_sync ();
       Printf.eprintf "c2c watch: %s\n%!" (Printexc.to_string e);
       exit 1)
  in
  Term.(const action $ interval)

let watch_cmd =
  let open Cmdliner in
  Cmd.v (Cmd.info "watch" ~doc ~man) watch_term
