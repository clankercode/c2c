(* c2c_codex_session — public UX for app-server-backed Codex sessions
   (P1.M1.E1.T006).

   Owns the command grammar semantics, deterministic session-ID-derived alias
   generation, the [--yolo] forwarding contract, per-instance identity/thread
   mapping, lifecycle status terminology, and the supervision glue that drives
   T002's internal primitive ({!C2c_codex_app_server}). It does NOT re-implement
   spawning/auth/transport — that boundary belongs to T002. Passive ingress
   ({!thread/inject_items}) is T003; message-triggered turns are T007; durable
   offline delivery is B127. *)

(* ------------------------------- identity --------------------------------- *)

(** The minimum Codex version whose app-server/remote-TUI capability set this
    path requires. Consumed as {!C2c_codex_app_server.config.min_codex_version}. *)
val codex_min_version : int * int * int

(** [derive_alias ~session_id ~taken] deterministically maps a stable Codex/
    app-server session id to a human-readable [codex-<word>-<word>-<hex>] c2c
    alias. Pure and total: the SAME [session_id] with the SAME [taken]
    predicate always yields the SAME alias, so resume/restart retain identity.
    On collision ([taken base = true]) it extends the base with entropy derived
    from the same [session_id] hash (never an unrelated random alias); the
    extension is itself deterministic and re-probes [taken]. Two distinct
    session ids yield distinct base aliases. *)
val derive_alias : session_id:string -> taken:(string -> bool) -> string

(** [derive_alias_base session_id] is the un-extended base alias (exposed for
    tests and collision reasoning). *)
val derive_alias_base : string -> string

(* --------------------------------- --yolo --------------------------------- *)

(** The exact Codex flag that [--yolo] forwards. *)
val yolo_bypass_flag : string

(** Conspicuous human-facing warning printed to stderr when [--yolo] is used. *)
val yolo_warning : string

(** [frontend_extra_args ~yolo ~extra] builds the extra argv appended to the
    stock [codex --remote] frontend. When [yolo] is set the Codex bypass flag is
    prepended; [extra] (operator passthrough) follows. [--yolo] is a per-launch
    decision and is NEVER written into any persisted mapping. *)
val frontend_extra_args : yolo:bool -> extra:string list -> string list

(** Colored lifecycle logs render this label as one unit so c2c ownership is
    explicit while preserving the Codex app-server context. *)
val app_server_log_label : string

(** Operator-facing follow-up text after an app-server startup diagnostic.
    Suggests "upgrade codex" only for version/capability/not-found failures;
    readiness timeouts and process exits on a supported Codex get actionable
    non-upgrade guidance (B175). *)
val diagnostic_followup : C2c_codex_app_server.diagnostic -> string

(** Local wall-clock [HH:MM:SS] for a Unix timestamp (B176). Pure / testable. *)
val app_server_log_hms : float -> string

(** Format one operator-facing app-server log line:
    [[c2c codex app-server] [HH:MM:SS] <body>]. When [color] is true the label
    is yellow-bold (historical styling); the timestamp and body stay plain.
    [now] defaults to [Unix.gettimeofday]. *)
val format_app_server_log : color:bool -> ?now:float -> string -> string

(** Stable, testable content of the online-attached lifecycle log. *)
val online_attached_log_body : alias:string -> endpoint:string -> string

val startup_banner : color:bool -> alias:string -> endpoint:string -> string

(** B176 lifecycle phase bodies (no label/timestamp) — launching / ready /
    pre-TUI handoff. *)
val lifecycle_launching_body : alias:string -> string
val lifecycle_ready_body : endpoint:string -> string
val lifecycle_tui_handoff_body : alias:string -> endpoint:string -> string

(** Non-secret c2c identity/context variables injected only into an app-server
    remote frontend.  In particular, [C2C_MCP_SESSION_ID] keeps `c2c init`
    bound to the launcher identity instead of generating an alias drift, and
    [C2C_MCP_AUTO_REGISTER_ALIAS] carries the banner alias for whoami fallback. *)
val app_server_frontend_env : session_id:string -> alias:string -> string list

(* ------------------------- positional splitting --------------------------- *)

(** Drop one leading [--] separator (cmdliner sometimes surfaces it as the first
    positional). *)
val drop_sep : string list -> string list

(** [split_client raw] peels the leading client token; the remainder (past an
    optional [--]) is the verbatim codex passthrough. *)
val split_client : string list -> string option * string list

(** [split_client_alias raw] peels the leading client + alias tokens. *)
val split_client_alias : string list -> string option * string option * string list

(** [reconcile_thread ~requested ~saved] returns the effective thread id. A
    non-empty [requested] that differs from a [saved] thread is [Error] — the
    grammar rejects thread conflicts rather than guessing. *)
val reconcile_thread :
  requested:string option -> saved:string option -> (string option, string) result

(* -------------------------------- status ---------------------------------- *)

type status =
  | Starting          (* app-server/frontend coming up, not yet attached *)
  | Online_attached   (* remote TUI attached to a ready app-server *)
  | Offline           (* frontend exited / unit stopped, no live server *)
  | Failed_startup    (* startup aborted before a routable alias published *)

val status_to_string : status -> string
val status_of_app_server_state : C2c_codex_app_server.state -> status

(** [status_of_instance ~instance_dir] reads the T002 persisted app-server
    record (if any) and returns the mapped {!status}. [None] when no
    app-server-backed session was ever recorded for that instance. *)
val status_of_instance : instance_dir:string -> status option

(* ------------------------- deliver-loop health ---------------------------- *)

(** [delivery_status_path ~instance_dir] is the JSON file the deliver loop
    persists its degraded (no-thread-loaded) signal into (B138). *)
val delivery_status_path : instance_dir:string -> string

(** [write_delivery_degraded ~instance_dir ~unit_id degraded] persists the
    deliver-loop degraded signal, STAMPED with the attached app-server unit's
    generation [unit_id] (best-effort; never raises). [true] = the app-server
    unit is supervised but no frontend thread has loaded, so nothing is actually
    delivered; [false] = a thread loaded and delivery is live. *)
val write_delivery_degraded : instance_dir:string -> unit_id:string -> bool -> unit

(** [delivery_degraded_of_instance ~instance_dir ~unit_id] reads the persisted
    signal, trusting it ONLY when its stamped unit_id matches [unit_id]. [None]
    when the file is absent / unparseable / stamped for a DIFFERENT unit (a
    stale record from a prior run on a reused instance dir). Total. *)
val delivery_degraded_of_instance :
  instance_dir:string -> unit_id:string -> bool option

(** [online_attached_delivery_degraded ~instance_dir] decides, fail-closed,
    whether an ONLINE-ATTACHED session's delivery loop is degraded (B138). Loads
    the live unit_id and trusts the persisted signal only on a stamp match;
    absence / staleness / a missing persisted record all read as [true] (fail
    toward degraded — never overclaim LIVE). A genuinely healthy session (thread
    loaded, matching stamp, degraded=false) still reads [false]. Total. *)
val online_attached_delivery_degraded : instance_dir:string -> bool

(* --------------------------- identity mapping ----------------------------- *)

type mapping = {
  session_id : string;          (* stable identity seed (authoritative for alias) *)
  alias : string;               (* published/routing alias *)
  thread_id : string option;    (* Codex thread id (authoritative for resume) *)
  created_at : float;
  updated_at : float;
}

val mapping_path : instance_dir:string -> string
val load_mapping : instance_dir:string -> mapping option
val write_mapping : instance_dir:string -> mapping -> unit
val persist_discovered_thread :
  instance_dir:string -> name:string -> thread_id:string -> unit

val restart_request_path : instance_dir:string -> string
val restart_result_path : instance_dir:string -> request_id:string -> string
val request_restart : instance_dir:string -> force:bool -> string
val await_restart_result :
  instance_dir:string -> request_id:string -> timeout_s:float -> string option
val resolve_restart_executable :
  ?path:string option -> ?self:string -> unit -> string option

(* --------------------------------- run ------------------------------------ *)

type launch_mode =
  | Start           (* canonical entry; resume saved thread only if selected *)
  | New             (* always a fresh thread + identity; never resume *)
  | Resume of string (* resume the saved thread for this alias *)

type resolved = {
  r_name : string;
  r_session_id : string;
  r_alias : string;
  r_thread_id : string option;
}

(** Pure identity resolution shared by all four command forms. [lookup] returns
    the saved mapping for an alias; [config_exists] reports whether a
    non-app-server managed instance already owns it. Returns [Error msg] for an
    ambiguous/conflicting request (unknown resume alias, `--alias` owned by a
    different session, `--thread-id` conflicting with the saved thread, `new`
    reusing a taken alias) — the CLI layer surfaces the message and exits. *)
val resolve_identity :
  mode:launch_mode ->
  alias_override:string option ->
  thread_id:string option ->
  lookup:(string -> mapping option) ->
  config_exists:(string -> bool) ->
  (resolved, string) result

(** [run] is the single shared implementation path behind
    [c2c start codex] / [c2c codex] / [c2c new codex] / [c2c resume codex].

    - The app-server transport is the DEFAULT and ONLY managed path for a
      supported Codex (≥ {!codex_min_version}). It launches `codex app-server`
      plus a stock `codex --remote` TUI and drives the B131 delivery loop
      ({!C2c_codex_deliver_loop}) so inbound c2c mail is auto-injected +
      auto-turned while attached.
    - [fallback ~extra_args ()] launches the hook-backed Codex path (the existing
      {!C2c_start.cmd_start}). [run] calls it AUTOMATICALLY — never via a
      user-selectable flag — when the app-server startup returns a structured
      diagnostic (unsupported Codex / capability gap / spawn failure). A hidden
      [C2C_CODEX_FORCE_HOOKS=1] env escape forces the hook path (operator testing
      only; not a user-facing option).
    - [alias_override] sets the display/routing alias but never the authoritative
      Codex thread id; a conflict with a differently-owned saved alias is
      rejected.
    - [thread_id] pins the exact Codex thread; a conflict with the saved thread
      is rejected rather than guessed.
    - [yolo] forwards {!yolo_bypass_flag} and prints {!yolo_warning}; it is never
      persisted.
    - [backend] is a test seam threaded into {!C2c_codex_app_server.start}.

    Returns a process exit code. *)
val run :
  mode:launch_mode ->
  ?alias_override:string ->
  ?thread_id:string ->
  yolo:bool ->
  extra_args:string list ->
  ?model_override:string ->
  ?backend:C2c_codex_app_server.backend ->
  fallback:(extra_args:string list -> unit -> int) ->
  unit ->
  int
