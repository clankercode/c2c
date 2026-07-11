(* c2c_codex_app_server — internal app-server-backed Codex session launcher
   primitive (P1.M1.E1.T002). See the .ml header for the full ownership /
   auth-boundary contract. Summary:

   - Internal PRIMITIVE + SECURITY BOUNDARY only; wired into the build, NOT a
     public CLI. T006 owns public grammar/aliases/--yolo/flag-forwarding; T003
     owns passive `thread/inject_items` ingress; T007 owns `turn/start`. This
     module opens no control JSON-RPC session, delivers nothing, starts no turn.
   - Auth: the app-server is always launched with
     `--ws-auth capability-token --ws-token-sha256 <sha>`; the frontend attaches
     with `--remote-auth-token-env <ENVVAR>`. The raw token is memory-only + the
     frontend child's env — never argv, disk, logs, or persisted/status JSON. A
     recovering process cannot re-authenticate a persisted endpoint, so resume
     NEVER silently attaches (see {!classify_persisted}). *)

(* ------------------------------- lifecycle -------------------------------- *)

type state =
  | Allocating
  | Starting_server
  | Waiting_ready
  | Starting_frontend
  | Running
  | Frontend_exited
  | Stopping_server
  | Offline
  | Failed
  | Cleaning_up

val state_to_string : state -> string
val state_of_string : string -> state

(* ------------------------------ diagnostics ------------------------------- *)

type diag_code =
  | Codex_not_found
  | Codex_version_unsupported
  | Endpoint_alloc_failed
  | Server_spawn_failed
  | Readiness_timeout
  | Server_died_before_ready
  | Auth_setup_failed
  | Frontend_spawn_failed
  | Internal_error

val diag_code_to_string : diag_code -> string

type diagnostic = {
  code : diag_code;
  message : string;
  codex_version : string option;
  min_codex_version : string option;
}

(** Structured, T006-consumable diagnostic. Contains no secret. *)
val diagnostic_to_json : diagnostic -> Yojson.Safe.t

(* -------------------------------- endpoint -------------------------------- *)

type endpoint = { transport : string; host : string; port : int }

val endpoint_uri : endpoint -> string
val endpoint_to_json : endpoint -> Yojson.Safe.t
val endpoint_of_json : Yojson.Safe.t -> endpoint option

(* -------------------------------- versions -------------------------------- *)

val parse_version : string -> (int * int * int) option
val version_ge : int * int * int -> int * int * int -> bool
val version_triple_to_string : int * int * int -> string

(* -------------------------------- auth util ------------------------------- *)

val sha256_hex : string -> string
(** Env var NAME derived from a unit id (sanitized to [A-Z0-9_]); carries the raw
    token into the frontend child. Only the name is ever persisted/logged. *)
val token_env_var_name : string -> string

(* ------------------------------ handshake --------------------------------- *)

type handshake_result =
  | Hs_ready
  | Hs_unauthorized
  | Hs_refused
  | Hs_status of int
  | Hs_error of string

val handshake_result_to_string : handshake_result -> string

(** One WebSocket-upgrade handshake against [endpoint], optionally presenting a
    bearer [token]. Reads only the HTTP status line: [Hs_ready] on 101,
    [Hs_unauthorized] on 401/403. This is the T001-proven auth boundary; call
    with [token:None] to prove an unauthenticated client is rejected. *)
val handshake : ?timeout:float -> endpoint -> token:string option -> handshake_result

(* ------------------------------ child procs ------------------------------- *)

type child_status = Running_ | Exited of int | Signaled of int

val child_status_to_string : child_status -> string

type child = {
  child_id : int;
  poll_fn : unit -> child_status;
  signal_fn : int -> unit;
  reap_fn : float -> child_status;
}

val child_poll : child -> child_status
val child_signal : child -> int -> unit
val child_reap : ?timeout:float -> child -> child_status
val make_real_child : int -> child

(* --------------------------------- config --------------------------------- *)

type config = {
  cwd : string;
  codex_bin : string;
  instance_name : string;
  alias : string option;
  instance_dir : string;
  readiness_timeout_s : float;
  reap_timeout_s : float;
  min_codex_version : int * int * int;
  extra_server_args : string list;
  extra_frontend_args : string list;
}

val default_config : instance_name:string -> instance_dir:string -> cwd:string -> config

(* -------------------------------- backend --------------------------------- *)

type ready_error = Re_unauthorized | Re_not_yet | Re_server_gone

(** Injectable effect seam. Tests script every transition without live processes;
    {!real_backend} is the Unix production implementation. *)
type backend = {
  now : unit -> float;
  sleep : float -> unit;
  gen_token : unit -> string;
  alloc_port : unit -> (int, string) result;
  codex_version : string -> (string, string) result;
  spawn_server : argv:string array -> env:string array -> log_path:string -> (child, string) result;
  spawn_frontend : argv:string array -> env:string array -> (child, string) result;
  probe_ready : endpoint -> token:string -> (unit, ready_error) result;
}

val real_backend : unit -> backend

(* argv/env builders — exposed for hygiene tests (raw token must not appear in
   server argv or frontend argv, only in the frontend env). *)
val build_server_argv : config -> endpoint -> sha256:string -> string array
val build_frontend_argv : config -> endpoint -> token_env_var:string -> string array
val build_frontend_env : token_env_var:string -> raw_token:string -> string array

(* ------------------------------ persistence ------------------------------- *)

type persisted = {
  unit_id : string;
  instance_name : string;
  alias : string option;
  codex_version : string;
  endpoint : endpoint;
  token_env_var : string;
  token_sha256 : string;
  server_pid : int option;
  frontend_pid : int option;
  thread_id : string option;
  state : state;
  created_at : float;
  updated_at : float;
}

val persisted_to_json : persisted -> Yojson.Safe.t
val persisted_of_json : Yojson.Safe.t -> persisted option
val persisted_path : instance_dir:string -> string
val write_persisted : instance_dir:string -> persisted -> (unit, string) result
val load_persisted : instance_dir:string -> persisted option

(* --------------------------- stale-state recovery ------------------------- *)

type recovery = Start_fresh of string

(** Classify a loaded persisted record. Always [Start_fresh]: a recovering
    process lacks the memory-only capability token and cannot verify ownership of
    the persisted endpoint. [reap_recorded] (default true) best-effort SIGTERMs
    still-alive recorded pids so no unowned app-server is orphaned. *)
val classify_persisted : ?reap_recorded:bool -> persisted -> recovery

val pid_alive : int -> bool

(* -------------------------------- handle ---------------------------------- *)

type handle

val current_state : handle -> state
val endpoint_of : handle -> endpoint
val unit_id_of : handle -> string
val token_env_var_of : handle -> string
val token_sha256_of : handle -> string
val persisted_of : handle -> persisted

(* -------------------------------- driver ---------------------------------- *)

(** Drive Allocating→Starting_server→Waiting_ready→Starting_frontend→Running.
    Version gate runs FIRST (before any spawn). Any post-server-spawn failure
    reaps the server (no orphan) and returns a structured {!diagnostic} after
    Failed→Cleaning_up→Offline. *)
val start : ?backend:backend -> config -> (handle, diagnostic) result

type supervise_result =
  | Sv_running
  | Sv_frontend_exited
  | Sv_server_died
  | Sv_offline

(** One nonblocking supervision step. Frontend exit → reap server (Sv_frontend_exited).
    App-server death while frontend runs → kill frontend, unit offline (Sv_server_died). *)
val supervise_step : handle -> supervise_result

(** Bring the whole unit down: reap frontend then server, scrub the token, mark
    Offline. Idempotent, leaves no zombies. Route parent SIGTERM/SIGINT here. *)
val stop : handle -> unit
