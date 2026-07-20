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

(** [stop_daemons_for_session ~session_id] tears down every notifier daemon
    whose recorded session binding ([<alias>.sid]) equals [session_id],
    regardless of the notifier's own alias, and returns the aliases torn down
    (#42). Used by [c2c stop] (via [C2c_start.teardown_kimi_notifiers_for_stop])
    to reap a differently-aliased daemon still draining a managed session's
    inbox, which the alias-keyed {!stop_daemon} misses.

    Safe by construction: it matches ONLY on the binding the daemon wrote for
    itself, so a daemon serving a DIFFERENT (incl. live) session — a different
    recorded sid — is never touched; a daemon with no sidfile (unknown binding)
    FAILS CLOSED (left running); and the signal itself goes through the
    identity-gated {!stop_daemon}. The CALLER is responsible for passing a
    [session_id] that provably belongs to the session being stopped (the
    instance name, not a resolved uuid) — see
    [C2c_start.teardown_kimi_notifiers_for_stop]. Best-effort: unreadable state
    dir yields [[]]. *)
val stop_daemons_for_session : session_id:string -> string list

(** [pidfile_path alias] is the on-disk pidfile for the [alias] notifier
    ([~/.local/share/c2c/kimi-notifiers/<alias>.pid]). Exposed for the
    supervisor teardown wiring + tests. *)
val pidfile_path : string -> string

(** Path of the file recording which session_id the notifier for an alias is
    bound to (written beside the pidfile by [start_daemon], removed by
    [stop_daemon]). Notifier state is alias-keyed while broker inboxes are
    session-id keyed; this records the binding so a mis-keyed daemon is
    detectable (#9 B). *)
val session_file_path : string -> string

(** [running_session_id alias] is the session_id the live notifier for [alias]
    is bound to, or [None] when unrecorded (daemon from a pre-#9 binary). *)
val running_session_id : string -> string option

(** [decide_notifier_rekey ~alias ~requested_sid ~running_sid] decides whether
    a live notifier must be respawned purely to bind it to a different
    session_id (#9 B).

    The managed launcher arms at t≈0, before anything can name the real Kimi
    session id, so it arms with the alias as a PLACEHOLDER. The SessionStart
    hook later calls [ensure_daemon] with the REAL sid; without this check
    that call was a no-op and the daemon stayed on an empty [<alias>] inbox.

    Re-keys iff [requested_sid] differs from what is running AND is not the
    alias placeholder — refusing to downgrade back to the placeholder is what
    prevents a later placeholder arm from flapping a correctly-bound daemon.
    Pure; exposed for unit tests.

    [authoritative] (#40) opts out of the placeholder guard. Since #40 the
    managed launcher registers [session_id = <instance name>] and arms the
    notifier on it, so in the default managed case
    ([alias = name = session_id]) an AUTHORITATIVE binding is byte-identical to
    a placeholder. Without this flag a leftover live notifier bound to a
    different sid (SIGKILLed outer loop, failed `c2c restart` teardown) never
    converges onto [<name>] — it reaches the stale-binary branch and
    [Skip_current]s on an unchanged binary, leaving the session deaf while
    `c2c send` reports success. Pass [true] only when the sid is a real
    binding rather than a t≈0 guess. Defaults to [false]. *)
val decide_notifier_rekey :
  alias:string ->
  requested_sid:string ->
  ?authoritative:bool ->
  running_sid:string option ->
  unit ->
  bool

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
    [C2C_KIMI_NOTIFIER_FIXTURE_INSTALLED_SHA].

    [authoritative] is forwarded to {!decide_notifier_rekey}: pass [true] when
    [session_id] is a known-real binding (the managed launcher's own
    registration) rather than a t≈0 placeholder guess, so a leftover daemon
    bound elsewhere is re-keyed onto it (#40). *)
val ensure_daemon :
  alias:string ->
  broker_root:string ->
  session_id:string ->
  ?authoritative:bool ->
  tmux_pane:string option ->
  ?interval:float ->
  unit ->
  int option

(** [run_once ~broker_root ~alias ~session_id ~tmux_pane ~workdir] performs one
    drain cycle: read pending broker messages for [alias], emit each as a
    notification under the kimi session's notification store, and (if
    [tmux_pane] is set + pane is idle) send a wake-prompt. Returns the
    number of messages delivered.

    [workdir] is the Kimi *workspace* directory of the target session — the key
    used to resolve its session id from [~/.kimi-code/session_index.jsonl].
    It is explicit rather than read from [Sys.getcwd ()] inside (#36): callers
    MUST pass the session's own workdir (e.g. the broker registration's [cwd]),
    not the process cwd, whenever they know it. Only legacy call sites that are
    genuinely running inside the session's own directory may default it to
    [Sys.getcwd ()].

    Exposed for unit tests + dogfood smokes. The daemon's inner loop is
    just [run_once] in a [while true] with [Unix.sleepf interval]. *)
val run_once :
  broker_root:string ->
  alias:string ->
  session_id:string ->
  tmux_pane:string option ->
  workdir:string ->
  int

(** [poll_once_global ~session_id ~alias ~tmux_pane] drains pending messages
    from the global sessions broker (C2C_SESSIONS_BROKER_ROOT) for the given
    session_id and delivers them via the kimi notification store. This enables
    cross-client delivery: `c2c send --session <kimi-session-id>` reaches
    managed kimi sessions. Returns the number of messages delivered.

    Uses drain_inbox (destructive) since the global broker is separate from the
    per-repo broker — no risk of double-delivery. await-reply never reads an
    inbox; approval resolution is host-local and file-only.

    [workdir] carries the same contract as in {!run_once}: the target session's
    Kimi workspace directory, supplied by the caller rather than read from the
    process cwd (#36).
    Exposed for unit tests + dogfood smokes. *)
val poll_once_global :
  session_id:string ->
  alias:string ->
  tmux_pane:string option ->
  workdir:string ->
  int

(** [read_session_id_from_config alias] reads the pinned session UUID from
    [~/.local/share/c2c/instances/<alias>/config.json] (written before exec
    by [#158]) and returns it, or [None] if not found / unreadable. *)
val read_session_id_from_config : string -> string option

(** [resolve_kimi_session_id ?not_before ~cwd ()] discovers the real Kimi
    session id for [cwd]. Managed [c2c start kimi] sessions launch without
    [--session], so Kimi mints the id and we resolve it afterwards. [None]
    until we can name the session for that workdir. Exposed so the managed
    launcher can arm the notifier on the REAL session-id inbox rather than
    the alias inbox (#9 B).

    #41: [~/.kimi-code/session_index.jsonl] alone CANNOT answer this at
    session start — kimi appends the new session's line only after its
    SessionStart hooks run, so the index's newest entry is the PREVIOUS
    session and every arm-time resolution was one session behind. Resolution
    is therefore: the sid kimi reported through its own SessionStart hook
    ({!record_kimi_session_id}), unless the index has since recorded a NEWER
    session for the workspace (a stale record from a session that ended
    without SessionEnd firing); otherwise the index's newest match.

    [?not_before] filters index entries by [sessionDir] mtime, defaulting to
    {!set_session_freshness_floor}. It is a PREFERENCE, not a hard reject: if
    it eliminates every candidate we retry unfiltered, because parking mail
    forever is a worse failure than the wrong-session delivery the
    authoritative record already prevents. *)
val resolve_kimi_session_id :
  ?not_before:float -> cwd:string -> unit -> string option

(** [record_kimi_session_id ~workdir ~session_id] records the AUTHORITATIVE
    kimi session id for a workspace — the id kimi itself put in its
    SessionStart hook payload. Keyed by workspace (not alias) because REST
    delivery is workdir-keyed (#36). Best-effort; never raises.

    [workdir] is canonicalised (realpath + trailing-slash strip) before it is
    hashed into the record filename, and {!read_kimi_session_record} /
    {!clear_kimi_session_record} apply the SAME canonicalisation — we own both
    ends of this key, so a trailing slash or a symlinked cwd in kimi's payload
    must not silently produce an unfindable record. (This does not alter
    {!workspace_hash_for_path}, which reproduces kimi-cli's own convention.)

    This is NOT the [<alias>.sid] notifier binding: that names the BROKER
    INBOX the daemon drains (since #40, the instance name), while this names
    the real kimi session used as the REST path component. *)
val record_kimi_session_id : workdir:string -> session_id:string -> unit

(** [set_session_freshness_floor t] sets the process-wide default [not_before]
    used by {!resolve_kimi_session_id} (#41). Called by the notifier daemon
    with its own arm time; left unset (0.0) by the machine-wide watcher, which
    serves many sessions and has no single session start. *)
val set_session_freshness_floor : float -> unit

(** [read_kimi_session_record ~workdir] reads back {!record_kimi_session_id}.
    [None] when absent, malformed, or recorded against a different workdir. *)
val read_kimi_session_record : workdir:string -> string option

(** [clear_kimi_session_record ~workdir ~session_id] removes the record only
    if it still names [session_id], so a late SessionEnd for an older session
    cannot delete the live session's binding. *)
val clear_kimi_session_record : workdir:string -> session_id:string -> unit

(** [decide_kimi_session_id ~recorded ~index_matches ~all_index_matches] is the
    pure resolution rule behind {!resolve_kimi_session_id}. Both lists are
    {!C2c_kimi_deliver.session_ids_for_workdir} output (file-append order, so
    the last element is newest); [index_matches] is freshness-filtered and
    [all_index_matches] is not.

    The split is load-bearing, not cosmetic. "Which candidate is newest" is
    answered from the FILTERED list so a stale entry cannot win; "has the
    record been superseded" is answered from the UNFILTERED list, because a
    stale recorded sid is old by construction and the freshness filter exists
    precisely to drop old entries — checking membership against the filtered
    list makes the anti-stale-record safeguard disarm itself in the one
    configuration the notifier daemon always runs in (it sets a floor
    unconditionally). Required rather than optional-with-default for the same
    reason. Exposed for unit tests. *)
val decide_kimi_session_id :
  recorded:string option ->
  index_matches:string list ->
  all_index_matches:string list ->
  string option

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

(** Legacy opt-in only ([C2C_KIMI_TMUX_COMPOSER_WAKE=1]). Primary kimi wake is
    REST [POST /api/v1/sessions/\{id\}/prompts] — no tmux required.

    [tmux_pane_has_pending_wake ~pane] captures the bottom of the pane
    and returns [true] if the literal text ["[c2c] check inbox"] is
    present in the input-box region (last 4 lines of the captured tail).
    When [true], the previous nudge's typed text is still sitting unsent
    in kimi's input box; firing another nudge would just stack more text
    on top. Used by [tmux_pane_is_idle] to suppress duplicate nudges. *)
val tmux_pane_has_pending_wake : pane:string -> bool

(** Legacy opt-in only ([C2C_KIMI_TMUX_COMPOSER_WAKE=1]). Returns [true] iff the
    pane is safe for a composer nudge. Three guards (all must pass):
    - no busy-marker (Thinking / Tool: / elapsed_steps= / permission)
      visible in the captured pane tail,
    - no prior ["[c2c] check inbox"] text still pending in the input box,
    - if [session_dir] is supplied, [wire.jsonl] mtime older than 2s.
    Defaults [now] to [Unix.gettimeofday ()]. Logs skip reasons to
    stderr so notifier.log shows when nudges were correctly suppressed. *)
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
