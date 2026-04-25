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
  needs_wire_daemon : bool;
      (** Whether to spawn c2c_kimi_wire_bridge.py loop for Wire-based delivery.
          Used for Kimi — replaces the PTY deliver daemon. *)
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
  broker_root : string;
  auto_join_rooms : string;
  binary_override : string option;
  model_override : string option;
  agent_name : string option;
}

(** {1 Client Configurations} *)

val clients : (string, client_config) Stdlib.Hashtbl.t
(** Map from client name (claude, codex, opencode, kimi, crush) to config. *)

val supported_clients : string list
(** List of supported client names. *)

(** {1 Paths} *)

val instances_dir : string
(** ~/.local/share/c2c/instances *)

val instance_dir : string -> string
(** [instance_dir name] returns the state directory for a named instance. *)

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

val default_name : string -> string
(** [default_name client] returns "<client>-<word1>-<word2>" using random words. *)

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

val repo_config_pmodel : unit -> (string * pmodel) list
(** Read the [pmodel] table from .c2c/config.toml in the repo root. Returns the
    list of (class_key, pmodel) pairs. Malformed entries are silently dropped. *)

val repo_config_pmodel_lookup : string -> pmodel option
(** [repo_config_pmodel_lookup class_key] looks up a class (e.g. "coder",
    "coordinator") in the repo pmodel table. Returns [None] if absent. *)

val repo_config_git_attribution : unit -> bool
(** [repo_config_git_attribution ()] reads git_attribution from .c2c/config.toml.
    Returns [true] if absent (default on). When true, `c2c git` injects
    --author=<alias> <alias@c2c.im> into git calls unless --author is already present. *)

val repo_config_git_sign : unit -> bool
(** [repo_config_git_sign ()] reads git_sign from .c2c/config.toml.
    Returns [true] if absent (default on). When true and argv[0]="commit",
    `c2c git` injects SSH signing flags (-c gpg.format=ssh, etc.) for
    git commit signing. *)

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

(** {1 Broker root} *)

val broker_root : unit -> string
(** Return the MCP broker root. Uses [C2C_MCP_BROKER_ROOT] env override when set,
    otherwise shells out to [git rev-parse --git-common-dir]. *)

(** {1 Environment building} *)

val build_env : ?broker_root_override:string option -> ?auto_join_rooms_override:string option -> ?role_class_opt:string option -> ?client:string option -> ?reply_to_override:string option -> string -> string option -> string array
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

val persist_headless_thread_id : name:string -> thread_id:string -> unit
(** [persist_headless_thread_id ~name ~thread_id] updates the managed instance
    config with the lazily handed-off Codex thread id, if the config exists. *)

val persist_codex_resume_target : name:string -> thread_id:string -> unit
(** [persist_codex_resume_target ~name ~thread_id] stores an explicit Codex
    resume target for a managed normal-codex instance, if the config exists. *)

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

val cmd_start :
  client:string ->
  name:string ->
  extra_args:string list ->
  ?binary_override:string ->
  ?alias_override:string ->
  ?session_id_override:string ->
  ?model_override:string ->
  ?one_hr_cache:bool ->
  ?kickoff_prompt:string ->
  ?auto_join_rooms:string ->
  ?agent_name:string ->
  ?reply_to:string ->
  unit ->
  int
(** [cmd_start] validates and starts a managed instance. Returns 0 on success,
    1 on error. Handles duplicate-running checks, config inheritance, and
    stable session ID generation. *)

val cmd_stop : string -> int
(** [cmd_stop name] stops a running instance. Returns 0. *)

val cmd_restart : ?session_id_override:string -> string -> int
(** [cmd_restart ?session_id_override name] stops then restarts an instance.
    When [session_id_override] is provided, it becomes the persisted exact
    resume target for clients that support it. Returns exit code. *)

val cmd_reset_thread : string -> string -> int
(** [cmd_reset_thread name thread_id] stores an explicit thread/session target
    for a managed Codex-family instance and restarts it onto that thread. *)

val cmd_restart_self : ?name:string -> unit -> int
(** [cmd_restart_self ?name ()] signals the managed inner client for this
    instance so the outer loop relaunches it. Intended for agents running
    inside a managed c2c-start session (name falls back to
    [C2C_MCP_SESSION_ID]). Returns 0 on signal, non-zero on error. *)

val cmd_instances : unit -> int
(** [cmd_instances ()] lists all known instances. Returns 0. *)
