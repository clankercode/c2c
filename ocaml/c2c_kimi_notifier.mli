(** C2c_kimi_notifier — push c2c broker DMs into a managed kimi instance via
    Kimi Code's local REST prompt endpoint. Replaces c2c-kimi-wire-bridge.

    Architecture: per-tick, drain broker inbox for [alias], resolve the
    active kimi TUI session-id by reading the pinned UUID from c2c instance
    config (pre-minted before exec by [#158]), POST the message as a text
    prompt to [http://127.0.0.1:<port>/api/v1/sessions/<session-id>/prompts],
    and optionally [tmux send-keys]-wake the kimi pane if it's at idle. The
    legacy file-based notification writer is retained for tests and
    diagnostics but is no longer the live delivery path.

    Background: the prior wire-bridge architecture spawned a fully-agentic
    [kimi --wire --yolo] subprocess per delivery batch. That subprocess
    registered as the same alias as the FG TUI, drained the inbox
    independently, and processed prompts agentically — two live agents
    sharing one alias. See finding [b6455d8e] (c2c-start-kimi-spawns-double-process).

    The REST prompt is injected as a synthetic user-turn message into the
    agent's context; the tmux wake ensures the TUI surface refreshes promptly
    when the pane is idle. *)

(** [start_daemon ~alias ~broker_root ~session_id ~tmux_pane ?interval ()]
    forks a session-leader child that polls the broker every [interval]
    seconds (default 2.0) and pushes new messages to the kimi session.
    Returns the daemon PID, or [None] if start failed.

    [tmux_pane] is the [TMUX_PANE]-style identifier (e.g. ["%15"]) of the
    kimi TUI pane. If [None], no wake-trigger is sent — toasts still surface
    via the shell-sink watcher, but agent-context injection waits for the
    operator's next input. *)
val start_daemon :
  alias:string ->
  broker_root:string ->
  session_id:string ->
  tmux_pane:string option ->
  ?interval:float ->
  unit ->
  int option

(** [stop_daemon ~alias] sends SIGTERM to the running notifier (tracked via
    pidfile), then SIGKILL after a 3s grace period. Safe to call when no
    daemon is running. Removes the pidfile. *)
val stop_daemon : alias:string -> unit

(** [stop_all_daemons ()] reaps every kimi notifier on this host by scanning the
    notifier state dir and calling the identity-gated {!stop_daemon} on each
    alias found. Returns the number of pidfiles processed. Best-effort (an
    unreadable state dir yields [0]). Used by the B146 temporary-disable path to
    sweep a notifier left over from a pre-disable session. *)
val stop_all_daemons : unit -> int

(** [pidfile_path alias] is the on-disk pidfile for the [alias] notifier
    ([~/.local/share/c2c/kimi-notifiers/<alias>.pid]). Exposed for the
    supervisor teardown wiring + tests. *)
val pidfile_path : string -> string

(** [already_running alias] returns [true] iff the notifier pidfile for
    [alias] names a process that is alive AND whose comm matches the daemon's
    ([notifier_comm]) — i.e. *our* notifier, not merely some live pid (guards
    the PID-reuse footgun). Exposed for tests + the supervisor. *)
val already_running : string -> bool

(** The daemon's [/proc/<pid>/comm] value (as set via prctl PR_SET_NAME). This
    14-char string is stored verbatim by the kernel (under the 15-char limit).
    Identity token for [pid_is_our_notifier]. *)
val notifier_comm : string

(** [pid_is_our_notifier pid] is [true] iff [pid] is alive AND its
    [/proc/<pid>/comm] equals [notifier_comm]. Fail-closed on any read failure
    or mismatch. Used to avoid signalling an unrelated same-UID process after a
    stale-pidfile PID reuse. *)
val pid_is_our_notifier : int -> bool

(** B145 upgrade-correctness. The detached notifier is deduped on startup, so
    without this a daemon that outlives [c2c restart] keeps running stale code
    after [just install-all]. *)
type notifier_start_decision =
  | Start_fresh   (** nothing running → start a new daemon *)
  | Skip_current  (** running on the installed binary (or SHA undeterminable) → leave it *)
  | Respawn_stale (** running on a DIFFERENT binary SHA → kill + respawn on the new binary *)

(** [decide_notifier_start ~running ~running_sha ~installed_sha] is the pure
    upgrade decision. Fail-safe: an undeterminable SHA on either side yields
    [Skip_current] (never kills a working notifier); only a confidently-observed
    mismatch yields [Respawn_stale]. *)
val decide_notifier_start :
  running:bool ->
  running_sha:string option ->
  installed_sha:string option ->
  notifier_start_decision

(** [ensure_daemon] behaves like [start_daemon] but is upgrade-aware: if a
    notifier is already running for [alias] on a binary whose SHA differs from
    the installed c2c binary, the stale daemon is killed and a fresh one spawned
    on the new binary; if it is current, its pid is returned unchanged. Returns
    the pid of the running (fresh or existing) daemon, or [None] on start
    failure.

    SHA sources can be overridden for tests via
    [C2C_KIMI_NOTIFIER_FIXTURE_RUNNING_SHA] /
    [C2C_KIMI_NOTIFIER_FIXTURE_INSTALLED_SHA]. *)
val ensure_daemon :
  alias:string ->
  broker_root:string ->
  session_id:string ->
  tmux_pane:string option ->
  ?interval:float ->
  unit ->
  int option

(** [run_once ~broker_root ~alias ~session_id ~tmux_pane] performs one drain
    cycle: read pending broker messages for [alias], emit each as a
    notification under the kimi session's notification store, and (if
    [tmux_pane] is set + pane is idle) send a wake-prompt. Returns the
    number of messages delivered.

    Exposed for unit tests + dogfood smokes. The daemon's inner loop is
    just [run_once] in a [while true] with [Unix.sleepf interval]. *)
val run_once :
  broker_root:string ->
  alias:string ->
  session_id:string ->
  tmux_pane:string option ->
  int

(** [poll_once_global ~session_id ~alias ~tmux_pane] drains pending messages
    from the global sessions broker (C2C_SESSIONS_BROKER_ROOT) for the given
    session_id and delivers them via the kimi notification store. This enables
    cross-client delivery: `c2c send --session <kimi-session-id>` reaches
    managed kimi sessions. Returns the number of messages delivered.

    Uses drain_inbox (destructive) since the global broker is separate from the
    per-repo broker — no risk of double-delivery. await-reply never reads an
    inbox; approval resolution is host-local and file-only.
    Exposed for unit tests + dogfood smokes. *)
val poll_once_global :
  session_id:string ->
  alias:string ->
  tmux_pane:string option ->
  int

(** [read_session_id_from_config alias] reads the pinned session UUID from
    [~/.local/share/c2c/instances/<alias>/config.json] (written before exec
    by [#158]) and returns it, or [None] if not found / unreadable. *)
val read_session_id_from_config : string -> string option

(** [resolve_kimi_session_id ~cwd] discovers the real Kimi session id for
    [cwd] by reading [~/.kimi-code/session_index.jsonl] (the same discovery
    the notifier's REST delivery uses). Managed [c2c start kimi] sessions
    launch without [--session], so Kimi mints the id and we resolve it
    afterwards. [None] until Kimi has recorded the session for that workdir.
    Exposed so the managed launcher can arm the notifier on the REAL
    session-id inbox rather than the alias inbox (#9 B). *)
val resolve_kimi_session_id : cwd:string -> string option

(** [workspace_hash_for_path path] computes [md5(path)] as kimi-cli does
    (see [kimi_cli/metadata.py:WorkDirMeta.sessions_dir]). *)
val workspace_hash_for_path : string -> string

(** [atomic_write_string path content] writes [content] to a sibling
    temp file in the same directory as [path], fsyncs the temp fd, then
    renames into place. Exposed for unit tests. The fsync is best-effort
    (wrapped in [try]) for filesystems where it returns EINVAL; the
    atomic-rename guarantee is preserved either way. *)
val atomic_write_string : string -> string -> unit
(** [is_system_event ~from_alias] returns [true] when [from_alias] is the
    canonical broker system sender ([c2c-system]) — used to gate out
    peer-register / room-join broadcasts from the kimi llm-sink, which
    would otherwise surface as user-turn input and cause identity-
    confusion. See #475. *)
val is_system_event : from_alias:string -> bool

(** [write_chat_log ~session_dir ~from_alias ~body] appends a human-readable
    entry to [<session_dir>/c2c-chat-log.md>]. Logs ALL messages including
    system events — this is the operator scrollback, independent of the
    notification store's llm/sink routing. Idempotent on retry. *)
val write_chat_log :
  session_dir:string ->
  from_alias:string ->
  body:string ->
  unit

(** [write_notification ~session_dir ~notification_id ~from_alias ~to_alias ~body]
    writes [event.json] + [delivery.json] under
    [<session_dir>/notifications/<notification_id>/], unless
    [is_system_event ~from_alias] is true — in which case the write is
    skipped (system events are operator-visibility only, never injected
    into the kimi user-turn stream). The structured title identifies the
    undecorated local recipient, sender, and correct reply tool while [body]
    remains byte-for-byte peer content. Exposed for unit tests. *)
val write_notification :
  session_dir:string ->
  notification_id:string ->
  from_alias:string ->
  to_alias:string ->
  body:string ->
  unit

(** [kimi_session_is_idle ~session_dir ~now ~threshold_s] returns [true]
    iff [<session_dir>/wire.jsonl] is missing OR its mtime is older than
    [threshold_s] seconds before [now]. kimi-cli appends to wire.jsonl on
    every TurnBegin / Step / Tool / Done event, so a fresh mtime is a
    reliable signal that the agent loop is mid-step. Default threshold in
    callers is 2s. Replaces tmux-scrape heuristic for the busy-vs-idle
    decision. See #590. *)
val kimi_session_is_idle :
  session_dir:string ->
  now:float ->
  threshold_s:float ->
  bool

(** [tmux_pane_has_pending_wake ~pane] captures the bottom of the pane
    and returns [true] if the literal text ["[c2c] check inbox"] is
    present in the input-box region (last 4 lines of the captured tail).
    When [true], the previous wake's typed text is still sitting unsent
    in kimi's input box; firing another wake would just stack more text
    on top. Used by [tmux_pane_is_idle] to suppress duplicate wakes. *)
val tmux_pane_has_pending_wake : pane:string -> bool

(** [tmux_pane_is_idle ~pane ?session_dir ?now ()] returns [true] iff the
    pane is safe to wake. Three guards (all must pass):
    - no busy-marker (Thinking / Tool: / elapsed_steps= / permission)
      visible in the captured pane tail,
    - no prior ["[c2c] check inbox"] wake-text still pending in the
      input box,
    - if [session_dir] is supplied, [wire.jsonl] mtime older than 2s.
    Defaults [now] to [Unix.gettimeofday ()]. Logs skip reasons to
    stderr so notifier.log shows when wakes were correctly suppressed. *)
val tmux_pane_is_idle :
  pane:string ->
  ?session_dir:string ->
  ?now:float ->
  unit ->
  bool

(** [notification_id_for_msg ~from_alias ~ts ~content] returns a
    deterministic 12-char id (lowercase hex) that maps the same broker
    message to the same notification id across c2c retries — so the kimi
    notification store de-dupes naturally. *)
val notification_id_for_msg :
  from_alias:string ->
  ts:float ->
  content:string ->
  string
