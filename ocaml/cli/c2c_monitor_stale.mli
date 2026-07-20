(** Monitor self-stale detection (I013 / spike I011-J).

    A long-running [c2c monitor] can outlive a binary upgrade: after
    [just install-all] the on-disk path points at a new inode while the
    process keeps executing the old (deleted-but-open) image. This module
    answers "is this monitor process stale?" and reconstructs the exact
    relaunch command so the operator can restart it.

    Hard constraint (B098 / product): the monitor must NOT respawn itself
    and must not trigger any message-driven restart. On stale it prints the
    relaunch hint and exits 0 — a local, operator-driven loop only. *)

type reason =
  | Binary_upgraded
      (** Running image differs from the installed binary. *)
  | Orphan
      (** Parent died ([ppid = 1]). Already handled in the main loop; exposed
          here so callers can format a uniform exit message if desired. *)

type action =
  | Continue
  | Exit_stale of reason
      (** Caller should print {!format_stale_exit} and [exit 0]. *)

val default_check_interval_s : float
(** Default interval between binary-upgrade checks (60s). The first check is
    deferred by one full interval so a monitor that starts during an install
    does not immediately self-exit (spike invariant 3). *)

val shell_quote : string -> string
(** Shell-safe single-argument quoting for relaunch command reconstruction. *)

val reconstruct_monitor_command : ?argv:string array -> unit -> string
(** Exact relaunch command from [argv] (default [Sys.argv]). Every original
    argument is preserved and shell-quoted so pasting the line reproduces
    the same monitor invocation. *)

val resolve_installed_exe : ?argv0:string -> ?home:string -> unit -> string option
(** Best-effort path of the installed [c2c] binary to compare against
    [/proc/self/exe]. Prefers a resolvable [argv0], then
    [Sys.executable_name], then [$HOME/.local/bin/c2c]. Never returns
    [/proc/self/exe] — that is the *running* image, not the install path. *)

val decide_binary_verdict : C2c_stale.verdict -> action
(** Pure: [Stale] → [Exit_stale Binary_upgraded]; [Current]/[Unknown _] →
    [Continue]. Unknown is intentionally non-fatal (spike: skip unless forced). *)

val format_stale_exit :
  ?now_hms:string -> reason:reason -> relaunch_command:string -> unit -> string
(** Human-readable multi-line stale-exit message (includes the exact relaunch
    command and an explicit "do not auto-respawn" note). *)

val stale_exit_json :
  reason:reason -> relaunch_command:string -> Yojson.Safe.t
(** NDJSON payload for [event_type = "monitor.stale-exit"]. *)

val reason_label : reason -> string
(** Short lowercase label for logs / JSON. *)
