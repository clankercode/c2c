(* c2c_watch.ml — `c2c watch` subcommand (slice B0).

   This is the ONLY module in the watch feature that touches lambda-term.
   Everything visual is delegated to the pure [C2c_watch_render] layer so a
   library swap (the spec's Plan-B mosaic) touches only this file, and so the
   render output stays golden-snapshot-testable without a terminal (spec §2).

   B0 ships nothing user-facing: it opens raw mode + saved screen, draws one
   empty framed pane sized to the live terminal, then loops reading events and
   quits on [q] or Ctrl-c. Its entire reason to exist is to land the #1
   correctness hazard — terminal teardown on EVERY exit path (normal quit, q,
   Ctrl-c key, uncaught exception, external SIGINT/SIGTERM) — first, so every
   later slice (B1-B5) inherits a proven restore path (spec §10).

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
        c2c broker. Slice B0 draws a single empty framed pane and exits on \
        $(b,q) or Ctrl-c; later slices add the Peers / DMs / Rooms tabs and \
        the send path."
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

(* Draw one empty frame sized to the live terminal. Pure render in
   [C2c_watch_render]; here we just clear, home the cursor, and print it. *)
let draw_frame (term : LTerm.t) : unit Lwt.t =
  let open Lwt.Infix in
  LTerm.get_size term >>= fun size ->
  let cols = LTerm_geom.cols size and rows = LTerm_geom.rows size in
  let frame = C2c_watch_render.render_empty_frame ~cols ~rows in
  LTerm.clear_screen term >>= fun () ->
  LTerm.goto term { LTerm_geom.row = 0; col = 0 } >>= fun () ->
  LTerm.fprint term frame >>= fun () ->
  LTerm.flush term

(* Is this key event a quit request? [q] (any modifiers ignored beyond the
   char itself) or Ctrl-c. In raw mode Ctrl-c is delivered as a Char 'c' with
   [control = true] — NOT as SIGINT. *)
let is_quit_key (k : LTerm_key.t) : bool =
  match k.LTerm_key.code with
  | LTerm_key.Char c when Uchar.equal c (Uchar.of_char 'q') -> true
  | LTerm_key.Char c when k.LTerm_key.control && Uchar.equal c (Uchar.of_char 'c')
    -> true
  | _ -> false

(* The event loop: redraw on resize, quit on q / Ctrl-c, ignore everything
   else. Returns when a quit key is seen. *)
let rec event_loop (term : LTerm.t) : unit Lwt.t =
  let open Lwt.Infix in
  LTerm.read_event term >>= fun ev ->
  match ev with
  | LTerm_event.Key k when is_quit_key k -> Lwt.return_unit
  | LTerm_event.Resize _ -> draw_frame term >>= fun () -> event_loop term
  | _ -> event_loop term

let run_watch () : unit Lwt.t =
  let open Lwt.Infix in
  Lazy.force LTerm.stdout >>= fun term ->
  (* Refuse gracefully if not a real tty (e.g. piped) rather than crashing in
     raw-mode setup. *)
  if not (LTerm.is_a_tty term) then begin
    Lwt_io.eprintl "c2c watch: not a tty (needs an interactive terminal)"
    >>= fun () -> Lwt.return_unit
  end else begin
    (* Save screen state (alternate-screen equivalent) before entering raw
       mode so [load_state] can restore the operator's scrollback on exit. *)
    LTerm.save_state term >>= fun () ->
    LTerm.enter_raw_mode term >>= fun mode ->
    let mode_opt = Some mode in
    (* Install signal handlers so an external SIGINT/SIGTERM still restores the
       terminal. We capture the previous behaviour to chain a default exit. *)
    let handle_signal _ =
      restore_terminal_sync ();
      (* exit synchronously; lwt finalizer may not get a chance to run. *)
      exit 130
    in
    let prev_int = Sys.signal Sys.sigint (Sys.Signal_handle handle_signal) in
    let prev_term = Sys.signal Sys.sigterm (Sys.Signal_handle handle_signal) in
    LTerm.hide_cursor term >>= fun () ->
    Lwt.finalize
      (fun () -> draw_frame term >>= fun () -> event_loop term)
      (fun () ->
        (* Restore signal handlers, then the terminal. *)
        Sys.set_signal Sys.sigint prev_int;
        Sys.set_signal Sys.sigterm prev_term;
        restore_terminal_lwt term mode_opt)
  end

let watch_term =
  let open Cmdliner in
  let action () =
    (try Lwt_main.run (run_watch ())
     with e ->
       (* Last-resort sync restore if something escaped the lwt finalizer. *)
       restore_terminal_sync ();
       Printf.eprintf "c2c watch: %s\n%!" (Printexc.to_string e);
       exit 1)
  in
  Term.(const action $ const ())

let watch_cmd =
  let open Cmdliner in
  Cmd.v (Cmd.info "watch" ~doc ~man) watch_term
