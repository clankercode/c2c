(** c2c_start — OCaml port of the managed-instance lifecycle.

    Brings the core [c2c start] lifecycle into OCaml, eliminating the Python
    dependency for the managed-instance subsystem. Sidecar scripts (deliver
    daemon, poker) remain Python for now. *)

(** {1 Types} *)

type client_config = {
  binary : string;
      (** Executable name or path to launch (e.g. "claude", "kimi",
          "/usr/local/bin/codex"). *)
  deliver_client : string;
      (** Client identifier passed to the deliver daemon
          (e.g. "claude", "kimi"). *)
  needs_deliver : bool;
      (** Whether to spawn c2c_deliver_inbox.py (the Python PTY-inject daemon).
          Off for clients whose delivery is handled in-tree (e.g. claude via
          PostToolUse hook + MCP channel notifications). *)
  needs_poker : bool;
      (** Whether this client needs a poker sidecar. *)
  poker_event : string option;
      (** Event name for the poker (e.g. "heartbeat"). *)
  poker_from : string option;
      (** Sender alias for the poker messages. *)
  extra_env : (string * string) list;
      (** Additional environment variables to merge into the subprocess env. *)
}

type instance_config = {
  name : string;
  client : string;
  session_id : string;
  resume_session_id : string;
  codex_resume_target : string option;
  alias : string;
  extra_args : string list;
  created_at : float;
  last_launch_at : float option;
  last_exit_code : int option;
  last_exit_reason : string option;
  broker_root : string;
  auto_join_rooms : string;
  binary_override : string option;
  model_override : string option;
  agent_name : string option;
}

val signal_name : int -> string
(** Map a signal number to a short readable name:
    [SIGTERM] → "term", [SIGKILL] → "kill", [SIGHUP] → "hup", etc.
    Unknown signals render as "sigN". *)

type tmux_target_info = { tmux_location : string }

val parse_tmux_target_info : string -> tmux_target_info option
(** Parse [tmux display-message -p '#S:#I.#P #{pane_id}'] output. *)

val tmux_shell_command_of_argv : string list -> string
(** Shell-quote an argv vector for typing into a tmux pane's shell. *)

val tmux_message_payload : C2c_mcp.message list -> string
(** Render broker messages for generic tmux delivery. *)

val tmux_deliver_once :
  broker_root:string -> session_id:string -> target:string -> int
(** Drain and deliver one batch of inbox messages to a tmux target. Returns the
    number of messages delivered. Leaves the inbox intact if tmux delivery
    fails. *)

(** {1 Client Configurations} *)

val clients : (string, client_config) Stdlib.Hashtbl.t
(** Map from client name (claude, codex, opencode, kimi, crush) to config. *)

val supported_clients : string list

(** B146: single source of truth — kimi support is temporarily disabled for this
    release when [true]. Flip to [false] to re-enable kimi everywhere (client
    lists filter on it; the `c2c start`/`c2c new` + `c2c install` guards refuse
    while [true]). Not a permanent deprecation. *)
val kimi_disabled_for_release : bool

(** Human-facing notice shown by the B146 kimi-disabled guards. *)
val kimi_disabled_notice : string
(** List of supported client names. *)

(** [register_managed_kimi_session ~broker_root ~name ~alias ~pid ~cwd]
    registers a managed `c2c start kimi` instance on the broker under
    [session_id = name] and [alias], recording [cwd] and [pid], then READS the
    registry back to confirm the row persisted. [Error reason] on any failure —
    the launcher turns that into a loud, actionable operator message
    ({!managed_kimi_registration_failure_message}); it never raises.

    Why the launcher and not the SessionStart hook (#40): Kimi Code >= 0.27
    runs sessions inside a SHARED long-lived `kimi server` daemon and spawns
    hook commands from that daemon's environment, so the per-instance
    [C2C_MCP_SESSION_ID] / [C2C_MCP_AUTO_REGISTER_ALIAS] that {!build_env} puts
    in the TUI's env are invisible to `c2c hook kimi`. Before this, every
    managed kimi session was registered under a freshly-minted alias against
    Kimi's real session id, and `c2c send <instance-name>` failed with
    "alias '<name>' is not registered" — silently, from the operator's side.
    One daemon serves many sessions, so its env can never identify any one of
    them: the launcher is the only correct identity authority here. *)
val register_managed_kimi_session :
  broker_root:string ->
  name:string ->
  alias:string ->
  pid:int ->
  cwd:string ->
  (unit, string) result

(** [kimi_notifier_arm_is_authoritative ~registered_ok ~resolved_sid ~name] —
    may the launcher mark its [ensure_daemon] arm AUTHORITATIVE (#40 F1)?
    True only when {!register_managed_kimi_session} succeeded AND the notifier
    resolver picked that row ([resolved_sid = name]); a sid from the kimi
    session_index or the bare alias fallback is the placeholder case the #9
    no-downgrade guard exists for. Pure; exposed for unit tests. *)
val kimi_notifier_arm_is_authoritative :
  registered_ok:bool -> resolved_sid:string -> name:string -> bool

(** Operator-facing text for a failed managed-kimi registration: names the
    unreachable alias, the exact `c2c send` error peers will see, the broker
    root, and the recovery command. Pure; exposed so the wording is pinned by
    a test rather than drifting. *)
val managed_kimi_registration_failure_message :
  name:string -> alias:string -> broker_root:string -> reason:string -> string

(** [pick_live_registration_sid ~alias ~now regs] is the session_id of the
    MOST-RECENT registration for [alias] that can be corroborated as live
    (any explicit pid still exists, and a timestamp places it inside the
    freshness window). Aliases are reused across runs, so a registration left
    behind by an unclean exit must never be adopted — it would point the
    notifier at a dead session's inbox. Pure; exposed for unit tests. *)
val pick_live_registration_sid :
  alias:string -> now:float -> C2c_mcp.registration list -> string option

(** [resolve_kimi_notifier_session_id ?now ~broker_root ~alias ~cwd ~fallback ()]
    picks the session-id inbox a managed Kimi notifier should drain (#9 B).
    Priority: (1) the most-recent LIVE broker registration for [alias],
    (2) the Kimi session_index for [cwd], (3) [fallback] (the alias) as a
    PLACEHOLDER.

    At managed-spawn time (t≈0) sources (1) and (2) are both legitimately
    empty — the alias→real-sid registration is written later by the
    SessionStart hook inside the just-forked kimi process — so the placeholder
    is the expected result there. Correctness does not depend on resolving
    here: the hook's own [ensure_daemon] call re-keys the notifier onto the
    real sid (see [C2c_kimi_notifier.decide_notifier_rekey]). This resolver
    exists to do better when a live registration IS already present, and to
    refuse stale ones. Read-only; never raises. Exposed for unit tests. *)
val resolve_kimi_notifier_session_id :
  ?now:float ->
  broker_root:string ->
  alias:string ->
  cwd:string ->
  fallback:string ->
  unit ->
  string

val deliver_kickoff_for_client :
  client:string ->
  name:string ->
  alias:string ->
  kickoff_text:string ->
  ?broker_root:string ->
  unit ->
  ((string * string) list, string) result
(** [deliver_kickoff_for_client ~client ~name ~alias ~kickoff_text ?broker_root ()]
    dispatches to the registered [CLIENT_ADAPTER] for [client] and runs
    its [deliver_kickoff] contract method.

    Returns the env-pair list the launch loop must append to the launch
    env (so e.g. opencode's [.opencode/plugins/c2c.ts] receives the
    [C2C_AUTO_KICKOFF] / [C2C_KICKOFF_PROMPT_PATH] handshake), or
    [Ok []] for adapters with no env contribution / no working kickoff
    path.  Returns [Ok []] when [client] has no registered adapter
    ([crush], legacy [pty]/[tmux] modes — they go through the
    [clients] hashtable but not the adapter table).

    Per #143 the launch loop calls this helper instead of inlining
    per-client kickoff branches. *)

(** {1 Paths} *)

val instances_dir : string
(** ~/.local/share/c2c/instances *)

val instance_dir : string -> string
(** [instance_dir name] returns the state directory for a named instance. *)

val expected_cwd_path : string -> string
(** [expected_cwd_path name] returns the path to the expected-cwd file for [name].
    The file lives at [<instances_dir>/<name>/expected-cwd] and is written by
    [write_expected_cwd] at startup and restart. *)

val config_path : string -> string
(** [config_path name] returns the config.json path for an instance. *)

val outer_pid_path : string -> string
(** [outer_pid_path name] returns the outer.pid path for an instance. *)

val deliver_pid_path : string -> string
(** [deliver_pid_path name] returns the deliver.pid path for an instance. *)

val poker_pid_path : string -> string
(** [poker_pid_path name] returns the poker.pid path for an instance. *)

val generate_alias : ?no_nonce:bool -> unit -> string
(** [generate_alias ?no_nonce ()] returns a random two-word alias like
    "ember-frost". When [~no_nonce:false] (the default), a 4-character
    lowercase alphanumeric nonce is appended: "ember-frost-a7c2". *)

val default_alias_prefix : string -> string
(** [default_alias_prefix client] normalizes a client name into the prefix used
    for default auto-generated aliases. Empty/unknown registration paths use
    ["agent"]. *)

val fds_to_close : preserve:Unix.file_descr list -> Unix.file_descr list
(** [fds_to_close ~preserve] is a pure function that returns the list of
    file descriptors that [close_unlisted_fds] would close — i.e. all fds in
    /proc/self/fd except those in [preserve] and stdin/stdout/stderr.
    This is testable without closing anything. *)

val default_name : ?no_nonce:bool -> string -> string
(** [default_name ?no_nonce client] returns
    "<client>-<word1>-<word2>-<nonce>" using random words. [no_nonce] is
    accepted for old callers but ignored so default auto-generated names keep
    their entropy suffix. *)

val likes_shell_substitution : string -> bool
(** [likes_shell_substitution s] returns true when [s] looks like an unexpanded
    shell substitution pattern such as [$(...)] or bare backticks. *)

(** {1 Per-role-class pmodel preferences} *)

type pmodel = { provider : string; model : string }
(** Parsed provider:model preference. The original string form supports an
    optional leading ':' prefix char so the model itself may contain colons
    (e.g. ":groq:openai/gpt-oss-120b" -> provider="groq", model="openai/gpt-oss-120b"). *)

val parse_pmodel : string -> (pmodel, string) result
(** [parse_pmodel s] parses "provider:model" or ":provider:model" (prefix form
    when the model contains ':'). Returns [Error msg] on empty provider, empty
    model, or missing separator. *)

(** {1 Managed heartbeats} *)

type heartbeat_schedule =
  | Interval of float
  | Aligned_interval of { interval_s : float; offset_s : float }

type managed_heartbeat = {
  heartbeat_name : string;
  schedule : heartbeat_schedule;
  interval_s : float;
  message : string;
  command : string option;
  command_timeout_s : float;
  clients : string list;
  role_classes : string list;
  enabled : bool;
  idle_only : bool;
  (** When true (default), the heartbeat fires only when the target agent's
      broker [last_activity_ts] is older than [idle_threshold_s] (or absent).
      Set false to restore legacy always-fire-on-tick behavior. *)
  idle_threshold_s : float;
  (** Activity-age cutoff for idle-only mode (seconds). *)
}

val agent_is_idle :
  now:float ->
  idle_threshold_s:float ->
  last_activity_ts:float option ->
  bool
(** Pure idle predicate. [None] last_activity_ts is treated as idle (fire to
    surface state). Otherwise idle iff [now - ts >= idle_threshold_s]. *)

val should_fire_heartbeat :
  broker_root:string ->
  alias:string ->
  managed_heartbeat ->
  bool
(** True when the heartbeat for [alias] should fire right now. Honors
    [idle_only]: when false, always true; when true, fires only if the
    agent has been quiet for at least [idle_threshold_s]. Looks up the
    registration's [last_activity_ts] from the broker registry. *)

val parse_heartbeat_duration_s : string -> (float, string) result
(** Parse heartbeat durations like ["240s"], ["4m"], and ["1h"]. *)

val parse_heartbeat_offset_s : string -> (float, string) result
(** Parse heartbeat offsets like ["0s"], ["30s"]. Accepts 0 unlike
    [parse_heartbeat_duration_s]. *)

val parse_heartbeat_schedule : string -> (heartbeat_schedule, string) result
(** Parse relative schedules like ["4m"] or aligned schedules like ["@1h+7m"]. *)

val next_heartbeat_delay_s : now:float -> managed_heartbeat -> float
(** Compute the next sleep delay for a heartbeat, including wall-clock aligned
    schedules. *)

val repo_config_managed_heartbeats : unit -> managed_heartbeat list
(** Read managed heartbeat defaults and named specs from [.c2c/config.toml]. *)

val per_agent_managed_heartbeats : name:string -> managed_heartbeat list
(** Read managed heartbeat overrides from the instance-local
    [heartbeat.toml], if present. *)

val builtin_managed_heartbeat : managed_heartbeat
(** Default heartbeat used as base when building role-heartbeats. *)

(** {1 S5: Role heartbeat persistence} *)

val resolve_managed_heartbeats_and_persist_role :
  client:string ->
  deliver_started:bool ->
  role:C2c_role.t option ->
  ?per_agent_specs:managed_heartbeat list ->
  managed_heartbeat list ->
  managed_heartbeat list * managed_heartbeat list
(** Split role heartbeats (persisted to .toml, started by watcher) from
    config/per-agent heartbeats (started directly). *)

val schedule_entry_of_managed_heartbeat :
  managed_heartbeat -> C2c_mcp.schedule_entry
(** Convert a role-derived managed_heartbeat to a schedule_entry for TOML
    persistence. *)

val render_schedule_entry :
  C2c_mcp.schedule_entry -> string
(** Render a schedule_entry to TOML string. *)

val persist_role_heartbeats_to_schedule_dir :
  alias:string -> managed_heartbeat list -> unit
(** Write role-derived heartbeats to [.c2c/schedules/<alias>/].
    Idempotent — each boot overwrites with fresh timestamps. *)

val resolve_managed_heartbeats :
  client:string ->
  deliver_started:bool ->
  role:C2c_role.t option ->
  ?per_agent_specs:managed_heartbeat list ->
  managed_heartbeat list ->
  managed_heartbeat list
(** Resolve effective heartbeats after built-in defaults, repo config, role
    overrides, and runtime client/delivery gates. *)

val render_heartbeat_content :
  ?broker_root:string ->
  ?alias:string ->
  managed_heartbeat -> string
(** Render one heartbeat message, appending allowed command output when set.
    When [broker_root] and [alias] are provided, the body may be swapped to
    a push-aware variant via {!heartbeat_body_for_alias}. *)

val automated_delivery_for_alias :
  broker_root:string -> alias:string -> bool option
(** Look up the [automated_delivery] flag for an alias from the broker
    registry. Returns [None] when the alias is unregistered or its
    registration predates this field. *)

val heartbeat_body_for_alias :
  broker_root:string -> alias:string -> message:string -> string
(** When [message] is the legacy default
    ([default_managed_heartbeat_content]) and the alias is push-capable
    ([automated_delivery = Some true]), returns
    [push_aware_heartbeat_content]. Otherwise returns [message] unchanged.
    Operator-authored custom heartbeat bodies are never rewritten. *)

val default_managed_heartbeat_content : unit -> string
(** Default managed-session heartbeat body. Coordinator alias and social
    room are resolved through [C2c_swarm_config] so configured repos see
    overrides. *)

val push_aware_heartbeat_content : unit -> string
(** Push-aware variant of the default heartbeat body. *)

val repo_config_pmodel : unit -> (string * pmodel) list
(** Read the [pmodel] table from .c2c/config.toml in the repo root. Returns the
    list of (class_key, pmodel) pairs. Malformed entries are silently dropped. *)

val repo_config_pmodel_lookup : string -> pmodel option
(** [repo_config_pmodel_lookup class_key] looks up a class (e.g. "coder",
    "coordinator") in the repo pmodel table. Returns [None] if absent. *)

val repo_config_default_binary : string -> string option
(** [repo_config_default_binary client] looks up a per-client binary override
    in the [default_binary] table of .c2c/config.toml (e.g. "codex" key when
    client = "codex"). Returns [None] when the table or key is absent. Values
    must be quoted strings; inline comments after values are not supported. *)


val repo_config_git_attribution : unit -> bool
(** [repo_config_git_attribution ()] reads git_attribution from .c2c/config.toml.
    Returns [true] if absent (default on). When true, `c2c git` injects
    --author=<alias> <alias@c2c.im> into git calls unless --author is already present. *)

val swarm_git_shim_dir : unit -> string
(** [swarm_git_shim_dir ()] returns the canonical swarm-wide git-shim
    install directory (#462). Resolution: [C2C_GIT_SHIM_DIR] override, else
    [$XDG_STATE_HOME/c2c/bin] (with HOME fallback per
    [C2c_repo_fp.xdg_state_home]). Pure — does not touch disk. *)

val ensure_swarm_git_shim_installed : unit -> string
(** [ensure_swarm_git_shim_installed ()] mkdirs [swarm_git_shim_dir ()],
    writes the git shim there, chmods +x, and returns the directory.
    Idempotent — safe to call on every [c2c start] invocation. (#462) *)

val repo_config_git_sign : unit -> bool
(** [repo_config_git_sign ()] reads git_sign from .c2c/config.toml.
    Returns [true] if absent (default on). When true and argv[0]="commit",
    `c2c git` injects SSH signing flags (-c gpg.format=ssh, etc.) for
    git commit signing. *)

val repo_config_supervisor_strategy : unit -> string option
(** [repo_config_supervisor_strategy ()] reads [supervisor_strategy] from
    [.c2c/repo.json]. Returns the configured strategy string or [None] if absent.
    Valid strategies: "first-alive", "round-robin", "broadcast".
    Without this reader the field was dead state (#524). *)

val builtin_swarm_restart_intro : string
(** Default restart/kickoff intro template emitted into the agent's
    transcript when [c2c start <client>] launches a fresh session.
    Contains {name}, {alias}, {role} placeholders. #341. *)

val claude_onboarding_preamble : name:string -> string
(** [claude_onboarding_preamble ~name] is the startup-steps preamble injected
    as the first transcript turn for a managed [c2c start claude] session.
    Contains NO heartbeat-Monitor step — managed sessions already get a native
    4.1m wake.toml via the inner MCP schedule timer, so arming a Monitor would
    double-wake. B011. *)

val intro_on_no_role : string -> bool
(** [intro_on_no_role client] is [true] when a no-role managed start of
    [client] should still receive the minimal builtin swarm intro (so a plain
    [c2c start <agent>] is never intro-less). [false] for raw passthrough /
    bridge clients (pty, tmux, relay-connect) that ignore or have no use for a
    kickoff prompt. B011. *)

val swarm_config_restart_intro : unit -> string
(** [swarm_config_restart_intro ()] reads the [swarm] [restart_intro] key
    from .c2c/config.toml and returns the override (with \n / \t escapes
    decoded), or [builtin_swarm_restart_intro] when the section/key is
    absent or empty. Mirrors the #318 v3 thunk pattern
    (swarm_config_coordinator_alias / swarm_config_social_room). #341. *)

val swarm_config_social_room : unit -> string
(** [swarm_config_social_room ()] reads the [swarm] [social_room] key from
    .c2c/config.toml, or returns ["swarm-lounge"] when the section/key is
    absent or empty. Implemented in [C2c_swarm_config] and re-exported
    here so both [C2c_start] consumers and the broker share the same
    config seam without a module cycle. *)

val swarm_config_coordinator_alias : unit -> string
(** [swarm_config_coordinator_alias ()] reads the [swarm]
    [coordinator_alias] key from .c2c/config.toml, or returns
    ["coordinator1"] when the section/key is absent or empty.
    Implemented in [C2c_swarm_config] and re-exported here. *)

val default_coord_fallthrough_idle_seconds : float
(** Default seconds the primary (and each subsequent backup) has to ack
    before the next backup is DM'd by the fallthrough scheduler. 120.0.
    See .collab/design/2026-04-29-coord-backup-fallthrough-stanza.md. *)

val default_coord_fallthrough_broadcast_room : string
(** Default room ID for the final "all coords missing" broadcast tier
    of the fallthrough scheduler. Derived from
    [C2c_swarm_config.swarm_config_social_room ()] so it follows the
    [swarm] [social_room] config; unconfigured repos resolve to
    ["swarm-lounge"]. *)

val swarm_config_coord_chain : unit -> string list
(** [swarm_config_coord_chain ()] reads the [swarm] [coord_chain] inline
    string-array from .c2c/config.toml. Index 0 is the primary; later
    entries are tried in order if the primary doesn't ack within
    [swarm_config_coord_fallthrough_idle_seconds ()]. Empty list means
    feature-off for this repo. *)

val swarm_config_coord_fallthrough_idle_seconds : unit -> float
(** [swarm_config_coord_fallthrough_idle_seconds ()] reads the per-tier
    idle window. Returns [default_coord_fallthrough_idle_seconds] when
    absent or unparseable. *)

val swarm_config_coord_fallthrough_broadcast_room : unit -> string
(** [swarm_config_coord_fallthrough_broadcast_room ()] reads the room ID
    used for the final-tier broadcast. Empty string disables the
    broadcast tier (TTL alone ends the entry's life). Default
    ["swarm-lounge"]. *)

val read_toml_sections_with_prefix :
  string -> (string * (string * string) list) list
(** [read_toml_sections_with_prefix prefix] reads .c2c/config.toml and
    returns [(subsection, key-value pairs)] for every section matching
    [\[prefix\]] (returned with subsection ["default"]) or
    [\[prefix.X\]] (returned with subsection ["X"]). #414 exposed for
    [c2c_coord]'s `[author_aliases]` reader; older callers used the
    private `*_from_path` form. *)

val normalize_model_override_for_client :
  client:string -> string -> (string, string) result
(** Normalize a user-supplied [--model] override for the target client.
    OpenCode keeps provider/model syntax, while single-provider clients accept
    either bare model names or provider:model input and emit just the model. *)

val strip_start_extra_argv_prefix : string list -> string list
(** Strip the leading client name (pos 0) from the raw [pos_all] positional
    capture of [c2c start], yielding the child's extra argv. Cmdliner consumes
    the [--] separator in production; a literal separator is also tolerated
    for direct helper callers. Shared by the command term and B129/B221 tests. *)

type namespaced_passthrough = {
  c2c_name : string option;
  client_args : string list;
}

val parse_namespaced_passthrough :
  string list -> (namespaced_passthrough, string) result
(** Extract the reserved post-separator [--c2c:name NAME] or
    [--c2c:name=NAME] wrapper control while preserving every ordinary client
    argument in order. Rejects missing/invalid/duplicate names and unknown
    [--c2c:*] keys (B221). *)

val merge_namespaced_name :
  existing:string option ->
  namespaced:string option ->
  (string option, string) result
(** Merge a normal pre-separator name with [--c2c:name]. Equal values coalesce;
    conflicting values are rejected. *)

val codex_alias_override_for_managed_start :
  alias_opt:string option -> requested_name:string option -> string option
(** Resolve the alias override for generic [c2c start codex]. An explicit or
    role-derived [--alias] wins; otherwise the requested instance name
    ([-n NAME], or the B221 [--c2c:name] that merges into the same slot)
    supplies the alias consumed by the app-server launch path (#34). [None]
    when the name was auto-picked, so the app-server keeps deriving a stable
    alias from its session id. *)

val managed_alias_override_for_role :
  alias_opt:string option -> role_alias:string option -> string option
(** Resolve the broker alias for a role-backed managed start. An explicit
    [--alias] outranks the role's [c2c_alias] — the precedence documented in
    [docs/commands.md]. The [--agent] / auto-inferred-role branches used to bind
    the role alias directly and discard [--alias] entirely, silently publishing
    the wrong address (#34 review, fix 2). *)

val codex_requested_name_for_managed_start :
  name:string -> name_from_auto_gen:bool -> string option
(** The [requested_name] fed to {!codex_alias_override_for_managed_start} from
    generic [c2c start codex]: the operator's [-n NAME] / [--c2c:name], or [None]
    when c2c auto-picked the instance name. Extracted so the #34 wiring itself is
    assertable — an inline expression there could regress with a green suite. *)

val kickoff_alias_is_authoritative :
  client:string -> alias_opt:string option -> requested_name:string option ->
  bool
(** #58: is the alias the launcher would interpolate into a kickoff prompt's
    [{alias}] the address that will actually be published? [false] only for
    codex when {!codex_alias_override_for_managed_start} resolves to [None] (an
    auto-picked name with no [--alias] / [-n]) — the app-server then derives a
    [codex-…] alias post-launch, so the kickoff cannot know it and must tell the
    agent to self-verify via [c2c whoami] rather than assert the instance name.
    [true] for every non-codex client and for codex with any override. A safe
    over-approximation for the codex-role-alias-with-auto-name case (defers to
    whoami rather than showing the role alias — never wrong). Pure. *)

val managed_published_alias :
  client:string -> name:string -> alias_override:string option ->
  requested_name:string option -> string option
(** #76: the address the publish path actually registers for a managed start.
    [alias_override] is the branch's real override (the CLI [--alias] on the
    no-role path, or {!managed_alias_override_for_role} on the [--agent] /
    auto-inferred-role paths). For codex this is
    {!codex_alias_override_for_managed_start} ([None] when the app-server derives
    a [codex-…] alias post-launch); for every other client it is the
    [C2C_MCP_AUTO_REGISTER_ALIAS] value ([alias_override], else the instance
    [name]). Never a role's display name. Pure. *)

val managed_kickoff_alias :
  client:string -> name:string -> alias_override:string option ->
  requested_name:string option -> string option
(** #76 (follow-up to #58): the alias to interpolate into a kickoff prompt's
    [{alias}], or [None] when the launcher must defer to [c2c whoami]. Returns
    [Some (alias_override, else name)] exactly when
    {!kickoff_alias_is_authoritative} — keyed on the branch's real
    [alias_override], never a role display name — which is precisely when that
    value equals {!managed_published_alias}. Fixes the [--agent] branch, which
    used to show the ROLE name while the session published the instance name.
    Invariant: whenever this is [Some a], {!managed_published_alias} with the
    same arguments is [Some a]. Pure. *)

type managed_alias_source = Alias_flag | Role_alias

val codex_managed_start_name_notice :
  ?source:managed_alias_source ->
  name:string -> alias:string -> unit -> string option
(** Operator notice for [c2c start codex] when the instance name is not the
    published broker alias. [None] when they agree (case-insensitively).
    [source] names where the winning alias actually came from — [Alias_flag]
    (an explicit [--alias]) or [Role_alias] (a role's [c2c_alias]); saying
    "--alias wins" for a role-derived alias sends the operator looking for a
    flag they never typed. *)

val managed_name_not_alias_record :
  name:string -> alias:string -> detail:string -> ts:float -> Yojson.Safe.t
(** The durable broker.log record emitted alongside
    {!codex_managed_start_name_notice}. The codex TUI paints over the terminal
    moments later, so the stderr note alone is not "loud" (#40 F5). Exported so
    the record shape is testable, not only the notice string. *)

val parse_pty_cmd_argv : string list -> string * string list
(** Parse the command + argv for [c2c start pty] from the already-stripped
    [extra_args] (the shared positional parser has removed the leading client
    name + [--]). Returns [(cmd, argv)] where the first token is the command
    and the rest is its argv. Exits with a clear error when [extra_args] is
    empty. Note: it does NOT require a leading [--] (B129) — the tokens it
    receives are the raw command already. Exported for tests. *)

type pty_inject_capability = [ `Ok | `Missing_cap of string | `Unknown ]

val check_pty_inject_capability :
  ?python_path:string ->
  ?yama_ptrace_scope:string ->
  ?getcap_output:string ->
  unit ->
  pty_inject_capability
(** Return whether PTY injection is available on this host. When Yama
    ptrace_scope is 0, PTY injection is considered available without an
    explicit cap. Otherwise the selected python interpreter must advertise
    [cap_sys_ptrace] via [getcap]. Optional overrides exist for deterministic
    tests. *)

(** {1 Opencode identity sidecar (test-visible)} *)

val refresh_opencode_identity :
  name:string ->
  alias:string ->
  broker_root:string ->
  project_dir:string ->
  instances_dir:string ->
  agent_name:string option ->
  unit
(** Rewrite the opencode identity sidecar at
    [<instances_dir>/<name>/c2c-plugin.json] with the current
    [session_id]/[alias]/[agent_name] tuple, plus [broker_root] iff it differs
    from the resolver default (drift-prevention follow-up to #504 /
    kimi-mcp-canonical).  Stale [broker_root] entries from prior runs are
    stripped on every refresh so the omit-when-default rule actually takes
    effect on resume.  Exported for tests; the production caller is the
    OpenCodeAdapter [refresh_identity] entry. *)

(** {1 Broker root} *)

val broker_root : unit -> string
(** Return the MCP broker root. Uses [C2C_MCP_BROKER_ROOT] env override when set,
    otherwise shells out to [git rev-parse --git-common-dir]. *)

val registry_alive_conflict :
  broker_root:string -> name:string -> (string * int) option
(** [Some (alias, pid)] when a broker registry row whose [session_id] or [alias]
    equals [name] is held by a LIVE process other than the caller. This is the
    pure decision behind {!check_registry_alias_alive}: it sees every
    MCP-registered peer (vanilla Claude Code, hook-codex, relay peers), not just
    the saved codex mappings / managed-instance configs that
    [C2c_codex_session.resolve_identity] consults. Rows owned by the calling pid
    are deliberately not conflicts — the app-server launcher restarts in place
    with [execve], which preserves the pid.

    "LIVE" is decided by [C2c_mcp.Broker.registration_is_alive], the same
    predicate [Broker.register] applies, so this guard can never be stricter
    than the refusal it front-runs (#56): a row naming a recycled pid has a
    stale [pid_start_time] and is not a conflict.

    Pid-less rows are likewise not conflicts, and that too is agreement rather
    than an override: [register]'s conflict test is
    [Option.is_some reg.pid && registration_is_alive reg && ...] — it excludes
    pid-less rows with its own clause, whatever [registration_is_alive]'s #51
    leniency answers for them. [i56_pidless_row_guard_agrees_with_register]
    enforces that coupling; without the [Option.is_some reg.pid] clause on the
    [register] side this guard would be a false ACCEPT.

    Alias matching is case-insensitive, as [register]'s is; session ids are
    compared byte-exactly, as [register]'s are. Exported for tests. *)

val check_registry_alias_alive : broker_root:string -> name:string -> unit
(** Registry precheck for launchers: print a FATAL message and [exit 1] when
    {!registry_alive_conflict} reports a live holder. Must be called BEFORE any
    launch side effect (instance config, outer pidfile, app-server, TUI spawn):
    the broker's own [register] refusal lands only after the TUI already owns the
    terminal, which strands an orphaned frontend with no delivery loop (#34
    review, fix 1). *)

val clear_registration_pid : broker_root:string -> session_id:string -> unit
(** Mark the registration for [session_id] as pid-cleared (offline) so peers stop
    routing to it. Used by managed supervisors on clean teardown (the same path
    the tmux/outer-loop launchers use). Best-effort; never raises. *)

(** {1 Environment building} *)

val build_env : ?broker_root_override:string option -> ?auto_join_rooms_override:string option -> ?role_class_opt:string option -> ?client:string option -> ?reply_to_override:string option -> ?tmux_location:string option -> ?alias_from_auto_gen:bool -> string -> string option -> string array
(** [build_env ?broker_root_override ?auto_join_rooms_override ?role_class_opt ?client ?alias_from_auto_gen name alias_override] builds the environment array for a managed
    client subprocess. Sets C2C_MCP_SESSION_ID, C2C_MCP_AUTO_REGISTER_ALIAS,
    C2C_MCP_BROKER_ROOT, C2C_MCP_AUTO_JOIN_ROOMS (defaults to "swarm-lounge"),
    C2C_MCP_AUTO_DRAIN_CHANNEL=0, and client-native session env when requested.
    When [~alias_from_auto_gen:true], also sets
    C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN=1.
    When C2C_AUTO_JOIN_ROLE_ROOM=1 is set and role_class_opt is provided,
    appends the derived role room (e.g. "reviewers" from "reviewer") to C2C_MCP_AUTO_JOIN_ROOMS. *)

(** {1 Launch argument preparation} *)

val prepare_launch_args :
  name:string ->
  client:string ->
  extra_args:string list ->
  broker_root:string ->
  ?alias_override:string ->
  ?resume_session_id:string ->
  ?binary_override:string ->
  ?model_override:string ->
  ?codex_resume_target:string ->
  ?thread_id_fd:string ->
  ?server_request_events_fd:string ->
  ?server_request_responses_fd:string ->
  ?agent_name:string ->
  ?kickoff_prompt:string ->
  ?alias_from_auto_gen:bool ->
  unit ->
  string list
(** [prepare_launch_args] returns client args, adding managed per-instance
    config where needed. Handles --session-id, --resume for claude, --session
    for opencode, resume --last or resume <target> for codex (plus the
    kickoff prompt as a positional argv element on fresh codex starts),
    optional --thread-id/--thread-id-fd for codex-headless,
    optional --agent for Claude/agent launches, and
    --mcp-config-file for kimi. *)

val build_kimi_mcp_config :
  ?alias_from_auto_gen:bool -> string -> string -> string option -> Yojson.Safe.t
(** [build_kimi_mcp_config ?alias_from_auto_gen name broker_root alias_override] returns the
    JSON object written to a kimi instance's [kimi-mcp.json] file.
    [command] is the canonical [c2c-mcp-server] OCaml binary; [args] is
    empty. The env block omits [C2C_MCP_BROKER_ROOT] when [broker_root]
    equals the resolver default ([""] also treated as default). When
    [~alias_from_auto_gen:true], also includes
    C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN=1. Exposed
    for tests; use via [cmd_start] / [cmd_restart] in production. *)

val is_kimi_session_id_like : string -> bool
(** [is_kimi_session_id_like sid] returns [true] when [sid] looks like a Kimi
    Code session id: [session_<uuid>] or a bare UUID. Used by the resume logic
    to decide whether a persisted session id should be passed to
    [kimi --session]. *)

val fresh_kimi_session_id : unit -> string
(** [fresh_kimi_session_id ()] returns a fresh [session_<uuid>] id suitable for
    [kimi --session]. *)

val codex_supports_server_request_fds : string -> bool
(** [codex_supports_server_request_fds binary_path] returns whether the Codex
    binary advertises both server request event and response sideband flags. *)

val bridge_supports_thread_id_fd : string -> bool
(** [bridge_supports_thread_id_fd binary_path] returns whether the Codex
    headless bridge advertises [--thread-id-fd] in its help output. *)

val probed_capabilities : client:string -> binary_path:string -> string list
(** Return the currently known capability names that can be inferred for a
    managed client launch from static launcher/binary probes. *)

val runtime_capabilities :
  ?now:float ->
  ?opencode_plugin_freshness_window_s:float ->
  client:string ->
  name:string ->
  unit ->
  string list
(** Return runtime capability names inferred from managed-instance state on disk.
    This is separate from [probed_capabilities] because it depends on
    post-launch signals such as OpenCode plugin heartbeats. *)

val managed_capabilities :
  ?now:float ->
  ?opencode_plugin_freshness_window_s:float ->
  client:string ->
  name:string ->
  binary_path:string ->
  unit ->
  string list
(** Return the union of static [probed_capabilities] and runtime capability
    observations for a managed instance. *)

val should_enable_opencode_fallback :
  ?startup_grace_s:float ->
  ?opencode_plugin_freshness_window_s:float ->
  name:string ->
  start_time:float ->
  now:float ->
  unit ->
  bool
(** Return whether an OpenCode instance should engage non-plugin fallback
    delivery yet. The fallback is suppressed during the initial startup grace
    window, then enabled only when the plugin heartbeat is missing or stale. *)

val codex_hooks_config_begin_marker : string
(** BEGIN marker of the c2c-managed hooks block in ~/.codex/config.toml.
    MUST stay in sync with [C2c_codex_hooks.config_begin_marker] (cli layer);
    duplicated here because the core library cannot depend on the cli
    library. Guarded by an equality test in test_c2c_setup_codex.ml. *)

val codex_hooks_installed : ?config_path:string -> unit -> bool
(** True when the c2c-managed hooks block (`c2c hook codex` delivery) is
    present in ~/.codex/config.toml (or [config_path] when given). *)

val codex_wake_target_registered : name:string -> unit -> bool
(** True when the instance's broker registration carries a wake target
    (tmux_location or herdr_pane) the codex wake injector can nudge.
    Total: broker/registration failures read as false. *)

val delivery_mode :
  ?now:float ->
  ?startup_grace_s:float ->
  ?opencode_plugin_freshness_window_s:float ->
  ?available_capabilities:string list ->
  ?codex_hooks_installed:bool ->
  ?codex_wake_target:bool ->
  client:string ->
  name:string ->
  binary_path:string ->
  start_time:float option ->
  unit ->
  string
(** Return the currently selected delivery mode label for a managed instance,
    combining static launcher capabilities with runtime state such as the
    OpenCode plugin heartbeat. For codex: "hooks+wake" when hooks are
    installed AND a tmux/herdr wake target is registered (idle wake via
    C2c_wake_inject), "hooks" when hooks only, "unavailable" otherwise.
    [codex_wake_target] overrides the broker lookup (tests). *)

val missing_role_capabilities :
  client:string -> binary_path:string -> C2c_role.t -> string list
(** Return role [required_capabilities] that are not satisfied by the probed
    capability set for the chosen client/binary pair. *)

(** {1 Configuration persistence} *)

val write_config : instance_config -> unit
(** [write_config cfg] writes the instance config to config.json. *)

val load_config : string -> instance_config
(** [load_config name] loads instance config.json; raises [Failure] on error. *)

val load_config_opt : string -> instance_config option
(** [load_config_opt name] loads instance config.json; returns [None] if absent. *)

val default_restart_timeout_s : client:string -> float
(** #49: the default outer-exit wait ceiling for [c2c restart], per client.
    Managed kimi's outer winds down a notifier + REST client and exits just past
    the old flat 5s bound, so it gets a longer default (others keep 5s). Only an
    upper bound — [cmd_restart] returns as soon as the outer exits — and the
    [--timeout] flag overrides it. *)

val sync_instance_alias : session_id:string -> alias:string -> unit
(** Scan all instance configs and update any whose [session_id] matches the
    given [session_id] to use the new [alias]. Prevents stale-alias drift on
    restart. *)


val resolve_effective_extra_args :
  cli_extra_args:string list ->
  persisted_extra_args:string list ->
  string list
(** [resolve_effective_extra_args ~cli_extra_args ~persisted_extra_args] decides
    which extra_args list to apply to a (re-)launch. Per #471 (Option A), the
    CLI list always wins — a plain `c2c start <client> -n NAME` (no `--`) yields
    [cli_extra_args = []] and we DO NOT silently re-apply [persisted_extra_args].
    [persisted_extra_args] is accepted for symmetry / future evolution. *)

val persist_headless_thread_id : name:string -> thread_id:string -> unit
(** [persist_headless_thread_id ~name ~thread_id] updates the managed instance
    config with the lazily handed-off Codex thread id, if the config exists. *)

(** {1 Process utilities} *)

val pid_alive : int -> bool
(** [pid_alive pid] returns true if the process is running. *)

val read_pid : string -> int option
(** [read_pid path] reads a PID from a pidfile; returns [None] if invalid. *)

val write_pid : string -> int -> unit
(** [write_pid path pid] writes a PID to a pidfile, creating parent dirs. *)

val remove_pidfile : string -> unit
(** [remove_pidfile path] removes a pidfile if it exists. *)

val cleanup_stale_opentui_zig_cache : unit -> int
(** [cleanup_stale_opentui_zig_cache ()] removes stale OpenUI Zig-compiled
    .fea*.so files from /tmp that are older than 5 minutes. These accumulate
    from OpenUI (used by OpenCode) and can exhaust per-user disk quota.
    Returns the number of files deleted. *)

(** {1 Sidecar daemons} *)

 val start_deliver_daemon :
   name:string ->
   client:string ->
   broker_root:string ->
   ?child_pid_opt:int ->
   ?command_override:(string * string list) ->
   ?xml_output_fd:string ->
   ?xml_output_path:string ->
   ?preserve_fds:Unix.file_descr list ->
   ?pty_master_fd:int ->
   ?use_inotify:bool ->
   unit ->
   int option
(** [start_deliver_daemon ~name ~client ~broker_root ?child_pid_opt
     ?command_override ()] spawns
    c2c_deliver_inbox.py and returns its PID, or [None] if the script is not
    found. Without XML output settings it uses the broker-polling path; with
    [xml_output_fd] or [xml_output_path] it uses the Codex XML sideband path. *)

val start_poker :
  name:string -> client:string -> broker_root:string -> ?child_pid_opt:int -> unit -> int option
(** [start_poker ~name ~client ~broker_root ?child_pid_opt ()] spawns c2c_poker.py
    for clients that need it (needs_poker = true) and returns its PID, or [None]. *)

val codex_heartbeat_interval_s : float
(** Interval, in seconds, between managed Codex heartbeat messages. *)

val codex_heartbeat_content : unit -> string
(** Message body delivered to managed Codex agents as a heartbeat. *)

val deliver_start_failure_warning : name:string -> client:string -> string
(** B013: human-facing warning text surfaced (eprintf'd) when the deliver
    daemon fails to start for a needs_deliver client. Such a session gets no
    inbound delivery via the daemon path, so the failure must not be silent.
    Pure so it is unit-testable. *)

val enqueue_codex_heartbeat : broker_root:string -> alias:string -> unit
(** Enqueue one heartbeat message to [alias] through the broker inbox, using the
    same delivery path as regular inbound messages. *)

(** {1 Outer loop} *)

val run_outer_loop :
  name:string ->
  client:string ->
  extra_args:string list ->
  broker_root:string ->
  ?binary_override:string ->
  ?alias_override:string ->
  ?session_id:string ->
  ?resume_session_id:string ->
  ?codex_resume_target:string ->
  ?model_override:string ->
  ?one_hr_cache:bool ->
  ?kickoff_prompt:string ->
  ?auto_join_rooms:string ->
  ?agent_name:string ->
  ?reply_to:string ->
  ?alias_from_auto_gen:bool ->
  ?no_prompt:bool ->
  ?opencode_plugin_embedded:string ->
  unit ->
  int
(** [run_outer_loop] runs the outer restart loop for the given instance
    (blocking). Returns the client exit code. Handles SIGCHLD, SIGINT
    (double-SIGINT window), TTY save/restore, deliver daemon and poker
    management, and cleanup. *)

val finalize_outer_loop_exit :
  cleanup_and_exit:(int -> int) ->
  print_resume:(string -> unit) ->
  resume_cmd:string ->
  exit_code:int ->
  int
(** [finalize_outer_loop_exit ~cleanup_and_exit ~print_resume ~resume_cmd
     ~exit_code] runs cleanup before printing the final resume hint and
     returns the cleanup exit code. *)

(** {1 Commands} *)

(** Resolve the effective model using 3-way priority:
    explicit --model flag > role pmodel > saved instance config.
    Pure function for testability. *)
val resolve_model_override :
  model_override:string option ->
  role_pmodel_override:string option ->
  saved_model_override:string option ->
  string option

val cmd_start :
  client:string ->
  name:string ->
  extra_args:string list ->
  ?binary_override:string ->
  ?alias_override:string ->
  ?session_id_override:string ->
  ?model_override:string ->
  ?role_pmodel_override:string ->
  ?one_hr_cache:bool ->
  ?new_session:bool ->
  ?kickoff_prompt:string ->
  ?auto_join_rooms:string ->
  ?agent_name:string ->
  ?reply_to:string ->
  ?tmux_location:string ->
  ?tmux_command:string list ->
  ?alias_from_auto_gen:bool ->
  ?no_prompt:bool ->
  ?opencode_plugin_embedded:string ->
  unit ->
  int
(** [cmd_start] validates and starts a managed instance. Returns 0 on success,
    1 on error. Handles duplicate-running checks, config inheritance, and
    stable session ID generation. When [~new_session:true], discards the saved
    session ID and starts a fresh session even when an existing config exists. *)

val filter_env_for_restart : unit -> string array
(** [filter_env_for_restart ()] returns a copy of the current process environment
    with [C2C_INSTANCE_NAME] stripped. Prevents the re-launched [c2c start]
    from seeing the parent's session and hitting the "cannot run from inside a
    c2c session" guard (c2c.ml:8499). *)

val cmd_stop : string -> int
(** [cmd_stop name] stops a running instance. Returns 0. *)

val cmd_restart :
  ?session_id_override:string ->
  ?do_exec:(string array -> unit) ->
  string -> timeout_s:float -> int
(** [cmd_restart ?session_id_override ?do_exec name ~timeout_s] stops then restarts an instance.
    [timeout_s] is how long to wait for the outer process to exit before
    spawning the new start (default 5s). When [session_id_override] is provided,
    it becomes the persisted exact resume target for clients that support it.
    [do_exec] defaults to [Unix.execve argv.(0) argv (filter_env_for_restart ())];
    tests pass a no-op stub to drive the function without replacing the test process.
    Returns exit code. *)

val cmd_reset_thread :
  ?do_exec:(string array -> unit) ->
  string -> string -> int
(** [cmd_reset_thread ?do_exec name thread_id] stores an explicit thread/session
    target for a managed Codex-family instance and restarts it onto that thread.
    [do_exec] is forwarded to [cmd_restart]; production callers omit it. *)

val cmd_restart_self : ?name:string -> unit -> int
(** [cmd_restart_self ?name ()] signals the managed inner client for this
    instance so the outer loop relaunches it. Intended for agents running
    inside a managed c2c-start session (name falls back to
    [C2C_MCP_SESSION_ID]). Returns 0 on signal, non-zero on error. *)

val cmd_instances : unit -> int
(** [cmd_instances ()] lists all known instances. Returns 0. *)
