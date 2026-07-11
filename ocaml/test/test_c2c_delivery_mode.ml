(* B013: unit tests for C2c_pty_inject.select_delivery_mode.

   The regression these lock down: codex's managed deliver daemon is launched
   with BOTH --xml-output-fd (its delivery contract) and --inotify (auto-added
   by start_deliver_daemon when inotifywait is on PATH). The old dispatch
   checked use_inotify first and routed codex to the log-only inotify path,
   which never wrote XML to the fd — codex silently went dark. XML sideband
   delivery MUST take precedence over --inotify. *)

open C2c_pty_inject

let mode_to_string = function
  | Mode_pty fd -> Printf.sprintf "Mode_pty %d" fd
  | Mode_xml_fd fd -> Printf.sprintf "Mode_xml_fd %d" fd
  | Mode_inotify_drain -> "Mode_inotify_drain"
  | Mode_inotify_print -> "Mode_inotify_print"
  | Mode_wake_inject -> "Mode_wake_inject"
  | Mode_poll -> "Mode_poll"

let check_mode expected actual =
  Alcotest.(check string)
    "delivery mode" (mode_to_string expected) (mode_to_string actual)

(* The core regression: codex with xml fd + inotify must pick XML, not the
   log-only inotify path. *)
let codex_xml_and_inotify_picks_xml () =
  check_mode (Mode_xml_fd 4)
    (select_delivery_mode ~pty_master_fd:None ~xml_output_fd:(Some 4)
       ~use_inotify:true ~client:"codex")

(* XML fd alone (inotifywait absent) still picks XML. *)
let codex_xml_no_inotify_picks_xml () =
  check_mode (Mode_xml_fd 4)
    (select_delivery_mode ~pty_master_fd:None ~xml_output_fd:(Some 4)
       ~use_inotify:false ~client:"codex")

(* PTY fd wins over everything (S4 path). *)
let pty_fd_wins () =
  check_mode (Mode_pty 7)
    (select_delivery_mode ~pty_master_fd:(Some 7) ~xml_output_fd:(Some 4)
       ~use_inotify:true ~client:"codex")

(* generic + inotify, no xml → event-driven destructive drain (unchanged). *)
let generic_inotify_picks_drain () =
  check_mode Mode_inotify_drain
    (select_delivery_mode ~pty_master_fd:None ~xml_output_fd:None
       ~use_inotify:true ~client:"generic")

(* non-generic, no xml, inotify → log-only inotify path (manual/debug; the
   only place run_inotify_loop is still reachable). *)
let nongeneric_inotify_no_xml_picks_print () =
  check_mode Mode_inotify_print
    (select_delivery_mode ~pty_master_fd:None ~xml_output_fd:None
       ~use_inotify:true ~client:"claude")

(* codex-wake-inject: interactive codex with no fds routes to the wake-inject
   watcher (tmux/herdr nudge; hooks deliver) regardless of --inotify — the
   watcher handles its own inotify/poll fallback. Replaces the useless
   log-only Mode_inotify_print routing post-xmlfd-removal. *)
let codex_no_fds_picks_wake_inject () =
  check_mode Mode_wake_inject
    (select_delivery_mode ~pty_master_fd:None ~xml_output_fd:None
       ~use_inotify:true ~client:"codex")

let codex_no_fds_no_inotify_picks_wake_inject () =
  check_mode Mode_wake_inject
    (select_delivery_mode ~pty_master_fd:None ~xml_output_fd:None
       ~use_inotify:false ~client:"codex")

(* codex-headless keeps its own paths — never wake-inject. *)
let codex_headless_not_wake_inject () =
  check_mode Mode_inotify_print
    (select_delivery_mode ~pty_master_fd:None ~xml_output_fd:None
       ~use_inotify:true ~client:"codex-headless")

(* No fds, no inotify → polling loop (generic/kimi single-loop fallback). *)
let no_fd_no_inotify_picks_poll () =
  check_mode Mode_poll
    (select_delivery_mode ~pty_master_fd:None ~xml_output_fd:None
       ~use_inotify:false ~client:"kimi")

let generic_no_inotify_picks_poll () =
  check_mode Mode_poll
    (select_delivery_mode ~pty_master_fd:None ~xml_output_fd:None
       ~use_inotify:false ~client:"generic")

let suite = [
  "codex xml+inotify picks xml (B013 regression)", `Quick, codex_xml_and_inotify_picks_xml;
  "codex xml, no inotify picks xml", `Quick, codex_xml_no_inotify_picks_xml;
  "pty fd wins over xml+inotify", `Quick, pty_fd_wins;
  "generic + inotify picks drain", `Quick, generic_inotify_picks_drain;
  "non-generic + inotify, no xml picks print", `Quick, nongeneric_inotify_no_xml_picks_print;
  "codex, no fds, inotify picks wake-inject", `Quick, codex_no_fds_picks_wake_inject;
  "codex, no fds, no inotify picks wake-inject", `Quick, codex_no_fds_no_inotify_picks_wake_inject;
  "codex-headless not wake-inject", `Quick, codex_headless_not_wake_inject;
  "no fd, no inotify picks poll", `Quick, no_fd_no_inotify_picks_poll;
  "generic, no inotify picks poll", `Quick, generic_no_inotify_picks_poll;
]

let () = Alcotest.run "c2c_delivery_mode" [ "select_delivery_mode", suite ]
