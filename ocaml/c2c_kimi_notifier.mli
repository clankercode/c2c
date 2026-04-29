(** C2c_kimi_notifier — push c2c broker DMs into a managed kimi instance via
    kimi-cli's file-based notification store. Replaces c2c-kimi-wire-bridge.

    Architecture: per-tick, drain broker inbox for [alias], resolve the
    active kimi TUI session-id (parse [~/.kimi/logs/kimi.log] for the most
    recent ["Created new session: <UUID>"] line), write [event.json] +
    [delivery.json] to
    [<KIMI_SHARE_DIR>/sessions/<md5(work_dir_path)>/<session-id>/notifications/<id>/],
    and optionally [tmux send-keys]-wake the kimi pane if it's at idle.

    Background: the prior wire-bridge architecture spawned a fully-agentic
    [kimi --wire --yolo] subprocess per delivery batch. That subprocess
    registered as the same alias as the FG TUI, drained the inbox
    independently, and processed prompts agentically — two live agents
    sharing one alias. See finding [b6455d8e] (c2c-start-kimi-spawns-double-process)
    and the validated probe research at
    [.collab/research/2026-04-29T10-27-00Z-stanza-coder-kimi-notification-store-push-validated.md].

    The [shell] sink toast appears in the kimi TUI within ~3s of writing
    (continuous async watcher, idle-capable). The [llm] sink injects
    [<notification>...</notification>] as a synthetic user-turn message into
    the agent's context, but only drains at agent turn boundaries — which is
    why we send a tmux wake-prompt when the pane is idle. *)

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
    daemon is running. *)
val stop_daemon : alias:string -> unit

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

(** [resolve_active_session_id ()] parses [~/.kimi/logs/kimi.log] for the
    most recent ["Created new session: <UUID>"] line and returns the UUID,
    or [None] if not found. The regex is anchored on a stable kimi-cli
    log format; if kimi-cli updates the format, the regex needs to be
    updated in parallel (see runbook anchor in
    [.collab/runbooks/kimi-delivery-via-notification-store.md]). *)
val resolve_active_session_id : unit -> string option

(** [workspace_hash_for_path path] computes [md5(path)] as kimi-cli does
    (see [kimi_cli/metadata.py:WorkDirMeta.sessions_dir]). *)
val workspace_hash_for_path : string -> string

(** [notification_id_for_msg ~from_alias ~ts ~content] returns a
    deterministic 12-char id (lowercase hex) that maps the same broker
    message to the same notification id across c2c retries — so the kimi
    notification store de-dupes naturally. *)
val notification_id_for_msg :
  from_alias:string ->
  ts:float ->
  content:string ->
  string
