(** coord_fallthrough — broker-side per-DM redundancy chain.

    Design: .collab/design/2026-04-29-coord-backup-fallthrough-stanza.md

    When a permission DM to the primary coord doesn't get a
    [check_pending_reply] within the configured idle window, the
    scheduler escalates: backup1 → backup2 → ... → broadcast to
    [coord_fallthrough_broadcast_room]. The scheduler runs as a
    dedicated Lwt loop separate from [Relay_nudge]. *)

open C2c_mcp

val default_tick_seconds : float
(** Cadence of the scheduler tick (60s by default). *)

val broadcast_sender_alias : string
(** Alias used for backup DMs and broadcast messages
    ([c2c-coord-fallthrough]). *)

val tick :
     ?now:float
  -> broker:Broker.t
  -> broker_root:string
  -> chain:string list
  -> idle_seconds:float
  -> broadcast_room:string
  -> unit
  -> unit
(** [tick ~broker ~broker_root ~chain ~idle_seconds ~broadcast_room ()]
    runs one scheduler scan over the pending_permissions store.
    Public so tests can drive a tick at a controlled timestamp without
    spawning the loop. The optional [?now] override lets tests inject
    a synthetic clock; defaults to [Unix.gettimeofday ()].

    Behavior per design:
    - entries with [resolved_at = Some _] are skipped (a supervisor
      already replied)
    - entries past their [expires_at] are skipped (TTL path reaps)
    - for each unresolved entry, fire the next eligible tier:
        - tier idx (0-based into chain) fires at
          [elapsed >= idle_seconds * (idx + 1)]
        - if [chain.(idx)] has no [Alive] registration, skip-and-advance
          to idx+1 in the SAME tick (don't wait the next 60s)
        - once every chain entry is fired-or-skipped, broadcast to
          [broadcast_room] (or no-op if [broadcast_room = ""])
    - each fire updates [fallthrough_fired_at] on the entry to prevent
      double-fire on the next tick (idempotent) *)

val start_scheduler :
     broker_root:string
  -> broker:Broker.t
  -> ?tick_seconds:float
  -> unit
  -> unit
(** [start_scheduler ~broker_root ~broker ()] launches the background
    Lwt loop. Reads chain/idle/broadcast config via [C2c_start] thunks
    on every tick (so operator-edits to [.c2c/config.toml] take effect
    without a broker restart). [?tick_seconds] defaults to
    [default_tick_seconds]. *)
