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
(** List of supported client names. *)

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

val generate_alias : unit -> string
(** [generate_alias ()] returns a random two-word alias like "ember-frost". *)

val fds_to_close : preserve:Unix.file_descr list -> Unix.file_descr list
(** [fds_to_close ~preserve] is a pure function that returns the list of
    file descriptors that [close_unlisted_fds] would close — i.e. all fds in
    /proc/self/fd except those in [preserve] and stdin/stdout/stderr.
    This is testable without closing anything. *)

val default_name : string -> string
(** [default_name _client] returns "<word1>-<word2>" using random words.
    The client argument is retained for call-site compatibility but is
    no longer used in the returned name (#277). *)

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

val default_managed_heartbeat_content : string
val push_aware_heartbeat_content : string

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

val swarm_config_restart_intro : unit -> string
(** [swarm_config_restart_intro ()] reads the [swarm] [restart_intro] key
    from .c2c/config.toml and returns the override (with \n / \t escapes
    decoded), or [builtin_swarm_restart_intro] when the section/key is
    absent or empty. Mirrors the #318 v3 thunk pattern
    (swarm_config_coordinator_alias / swarm_config_social_room). #341. *)

val default_coord_fallthrough_idle_seconds : float
(** Default seconds the primary (and each subsequent backup) has to ack
    before the next backup is DM'd by the fallthrough scheduler. 120.0.
    See .collab/design/2026-04-29-coord-backup-fallthrough-stanza.md. *)

val default_coord_fallthrough_broadcast_room : string
(** Default room ID for the final "all coords missing" broadcast tier
    of the fallthrough scheduler. ["swarm-lounge"]. *)

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

(** {1 Environment building} *)

val build_env : ?broker_root_override:string option -> ?auto_join_rooms_override:string option -> ?role_class_opt:string option -> ?client:string option -> ?reply_to_override:string option -> ?tmux_location:string option -> string -> string option -> string array
(** [build_env ?broker_root_override ?auto_join_rooms_override ?role_class_opt ?client name alias_override] builds the environment array for a managed
    client subprocess. Sets C2C_MCP_SESSION_ID, C2C_MCP_AUTO_REGISTER_ALIAS,
    C2C_MCP_BROKER_ROOT, C2C_MCP_AUTO_JOIN_ROOMS (defaults to "swarm-lounge"),
    C2C_MCP_AUTO_DRAIN_CHANNEL=0, and client-native session env when requested.
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
  ?codex_xml_input_fd:string ->
  ?codex_resume_target:string ->
  ?thread_id_fd:string ->
  ?server_request_events_fd:string ->
  ?server_request_responses_fd:string ->
  ?agent_name:string ->
  ?kickoff_prompt:string ->
  unit ->
  string list
(** [prepare_launch_args] returns client args, adding managed per-instance
    config where needed. Handles --session-id, --resume for claude, --session
    for opencode, resume --last or resume <target> for codex, optional
    --xml-input-fd for Codex,
    optional --thread-id/--thread-id-fd for codex-headless,
    optional --agent for Claude/agent launches, and
    --mcp-config-file for kimi. *)

val build_kimi_mcp_config :
  string -> string -> string option -> Yojson.Safe.t
(** [build_kimi_mcp_config name broker_root alias_override] returns the
    JSON object written to a kimi instance's [kimi-mcp.json] file.
    [command] is the canonical [c2c-mcp-server] OCaml binary; [args] is
    empty. The env block omits [C2C_MCP_BROKER_ROOT] when [broker_root]
    equals the resolver default ([""] also treated as default). Exposed
    for tests; use via [cmd_start] / [cmd_restart] in production. *)

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

val delivery_mode :
  ?now:float ->
  ?startup_grace_s:float ->
  ?opencode_plugin_freshness_window_s:float ->
  ?available_capabilities:string list ->
  client:string ->
  name:string ->
  binary_path:string ->
  start_time:float option ->
  unit ->
  string
(** Return the currently selected delivery mode label for a managed instance,
    combining static launcher capabilities with runtime state such as the
    OpenCode plugin heartbeat. *)

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
  ?event_fifo_path:string ->
  ?response_fifo_path:string ->
  ?preserve_fds:Unix.file_descr list ->
  ?pty_master_fd:int ->
  unit ->
  int option
(** [start_deliver_daemon ~name ~client ~broker_root ?child_pid_opt
     ?command_override ()] spawns
    c2c_deliver_inbox.py and returns its PID, or [None] if the script is not
    found. Without XML output settings it uses the notify-only PTY path; with
    [xml_output_fd] or [xml_output_path] it uses the Codex XML sideband path. *)

val start_poker :
  name:string -> client:string -> broker_root:string -> ?child_pid_opt:int -> unit -> int option
(** [start_poker ~name ~client ~broker_root ?child_pid_opt ()] spawns c2c_poker.py
    for clients that need it (needs_poker = true) and returns its PID, or [None]. *)

val codex_heartbeat_interval_s : float
(** Interval, in seconds, between managed Codex heartbeat messages. *)

val codex_heartbeat_content : string
(** Message body delivered to managed Codex agents as a heartbeat. *)

val codex_heartbeat_enabled : client:string -> bool
(** Return whether [client] should receive managed Codex heartbeat messages. *)

val should_start_codex_heartbeat : client:string -> deliver_started:bool -> bool
(** Return whether [run_outer_loop] should start the heartbeat thread for this
    launch. Requires the regular Codex deliver daemon to be running. *)

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
  ?no_prompt:bool ->
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
  ?no_prompt:bool ->
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
