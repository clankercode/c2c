(** Native OCaml client for an unmodified local T3 server (P9.M1.E1.T002).

    Scope: runtime discovery + same-user/loopback/incarnation validation,
    PKCE pairing, private credential files, and a bounded, serialized,
    allow-listed MCP client. No provider SDKs, no t3-bridge, no Node, no T3
    source. The service/state/CLI lanes (T003+) build on this surface.

    Security invariants:
    - A token is only ever sent after [validate] succeeds against the live
      runtime (loopback origin, same-user PID, matching incarnation, PID owns
      the listening socket). Validation runs before {e every} HTTP request.
    - Redirects are never followed; any 3xx is refused with the body unread.
    - The token lives only in the private credential file and in memory. It
      never appears in an {!error}, a command argument or a log line.
    - Responses are bounded by bytes, time, pages and items. Truncated
      evidence is reported as [complete = false], never as success.

    Assumption: [T3CODE_HOME] (else [$HOME/.t3]) is T3's base directory, with
    the runtime record at [userdata/server-runtime.json] (production) or
    [dev/server-runtime.json] (dev). *)

(** {1 Errors} *)

type error =
  | Discovery of string  (** no usable runtime; message is actionable *)
  | Ambiguous of string list  (** more than one live runtime record *)
  | Unsafe_state of string  (** ownership / permission refusal *)
  | Runtime_changed of string  (** incarnation / endpoint / home mismatch *)
  | Credential of string  (** credential file missing, malformed, exists *)
  | Timeout of string
  | Oversize of string
  | Protocol of string  (** malformed JSON/SSE/JSON-RPC or unexpected shape *)
  | Rpc_error of int
  | Http_status of { status : int; during : string }
  | Auth_denied of { status : int }  (** token rejected: re-pair required *)
  | Redirect_refused of int
  | Tool_rejected of { tool : string; code : string }
  | Unsupported of string  (** protocol / required tool missing *)

val error_to_string : error -> string
(** Never contains a token, a response body or a transcript. *)

val is_auth_error : error -> bool

(** {1 Constants and limits} *)

val protocol_version : string
val required_scopes : string list
(** Exactly [orchestration:read] and [orchestration:operate]; pairing never
    requests (and the client refuses) settings/source-control scopes. *)

val supported_tools : string list
(** The allow-list. Any other tool name is refused before sending. *)

type limits = {
  max_response_bytes : int;
  request_timeout_s : float;
  max_pages : int;
  max_items : int;
}

val default_limits : limits

(** {1 Strict JSON / SSE decoding (pure)} *)

val strict_json_of_string : max_bytes:int -> string -> (Yojson.Safe.t, error) result
(** Rejects NaN/Infinity, big-int literals, tuples/variants, duplicate object
    keys, trailing garbage, excessive depth and oversize input. *)

val parse_rpc :
  max_bytes:int -> content_type:string -> id:int -> string ->
  (Yojson.Safe.t, error) result
(** Decode an [application/json] or [text/event-stream] MCP response and return
    the [result] of the single message carrying [id]. Notifications without an
    [id] are ignored; an unterminated SSE data event, a missing/duplicated
    match, a non-2.0 envelope, or result+error together is [Protocol]. *)

(** {1 PKCE (pure given RNG)} *)

val pkce_verifier : unit -> string
(** 32 random bytes, base64url without padding (43 chars). *)

val pkce_challenge : string -> string
(** [base64url(sha256 verifier)], RFC 7636 S256. *)

(** {1 Runtime discovery} *)

type proof = {
  pid : int;
  start_ticks : int;
  boot_id : string;
  listeners : string list;  (** socket inodes, sorted *)
  exe_dev : int;
  exe_ino : int;
}

type runtime = {
  origin : string;  (** canonical [http://127.0.0.1:PORT] *)
  port : int;
  pid : int;
  started_at : string;
  server_version : string option;
  record_path : string;
  t3_home : string;  (** realpath *)
  proof : proof;
}

val resolve_home : ?getenv:(string -> string option) -> unit -> (string, error) result
(** [T3CODE_HOME] (must be absolute) else [HOME/.t3]. *)

val is_exclusive_user_group :
  group_row:string -> passwd_rows:string -> username:string -> uid:int -> gid:int -> bool
(** User-private primary group: named after the user, same gid, no other
    members, and no other account has it as primary group. Fail-closed. *)

val discover :
  ?proc_root:string -> ?uid:int -> ?gid:int -> ?now:float -> ?clk_tck:int ->
  ?group_file:string -> ?passwd_file:string -> t3_home:string -> unit ->
  (runtime, error) result
(** Test seams ([proc_root], [uid], [now], ...) default to the live system.
    If both the production and dev records are live, [Ambiguous]; if exactly
    one validates it is used; if none, [Discovery] with every refusal reason. *)

(** {1 Credentials} *)

type credential

val make_credential :
  origin:string -> t3_home:string -> token:string -> client_id:string ->
  scopes:string list -> generation:int -> issued_at:string ->
  expires_in:int option -> proof:proof -> credential

val credential_origin : credential -> string
val credential_generation : credential -> int
val credential_scopes : credential -> string list
val credential_proof : credential -> proof
(** No token accessor on purpose. *)

val default_config_dir : ?getenv:(string -> string option) -> unit -> (string, error) result
(** [C2C_T3_CONFIG_DIR] else [$HOME/.c2c/t3]. *)

val credential_path : config_dir:string -> string

val save_credential :
  config_dir:string -> replace:bool -> credential -> (unit, error) result
(** Private dir (0700), O_EXCL 0600 temp, fsync, then atomic publish:
    [link] (no-replace) when [replace = false], [rename] otherwise. *)

val load_credential : config_dir:string -> (credential, error) result
(** Refuses a file not owned by this user or readable by anyone else. *)

(** {1 Pairing} *)

val create_pairing_code :
  runtime:runtime -> t3_bin:string -> (string, error) result Lwt.t
(** Runs [t3 auth pairing create --scope ... --json] after checking the binary
    is the one the runtime is executing (same dev/inode, same-user, not
    group/world-writable). The code is read from stdout, never an argument. *)

val pair :
  ?limits:limits -> runtime:runtime -> validate:(unit -> (unit, error) result) ->
  pairing_code:string -> client_name:string -> config_dir:string ->
  replace:bool -> unit -> (credential, error) result Lwt.t
(** Dynamic client registration + PKCE exchange against the verified loopback
    endpoint. Rejects any granted scope set other than {!required_scopes}.
    [replace:true] publishes generation+1 (an explicit credential-generation
    change); [replace:false] fails if a credential already exists. *)

(** {1 MCP client} *)

type client

type 'a field = Unknown | Known of 'a
(** Omitted fields stay [Unknown]; JSON null is [Known None]/[Known ""]-style
    only where the type says so. Never default an omitted field. *)

val create :
  ?limits:limits -> origin:string -> credential:credential ->
  validate:(unit -> (unit, error) result) -> unit -> client

val authorize :
  ?limits:limits -> ?rebind:bool -> ?proc_root:string -> ?uid:int -> ?gid:int ->
  ?now:float -> ?clk_tck:int -> config_dir:string -> t3_home:string -> unit ->
  (client * runtime, error) result
(** Discover, load the credential, and require origin/home/scopes/proof to
    match. A proof mismatch is [Runtime_changed] (hold) unless [rebind:true],
    which accepts a freshly validated incarnation of the {e same} origin/home
    and persists the new proof under the same credential generation. *)

val credential_generation_of : client -> int
val transport_epoch : client -> int
(** Incremented on every (re)initialization; the credential is retained. *)

val initialize : client -> (unit, error) result Lwt.t
(** MCP handshake, protocol check, [tools/list], required-tool validation. *)

val reconnect : client -> (unit, error) result Lwt.t
(** Drop the MCP session and reinitialize with the same credential. Refused
    after an auth denial: expiry/revocation requires explicit re-pairing. *)

type provider = {
  provider_instance_id : string field;
  driver_kind : string field;
  models : string list;
}

type capabilities = {
  runtime_mode : string field;  (** access ceiling, e.g. ["auto"] *)
  interaction_mode : string field;
  providers : provider list;
}

val capabilities : client -> (capabilities, error) result Lwt.t

type page = { items : Yojson.Safe.t list; complete : bool }
(** [complete = false] when [max_pages]/[max_items] stopped enumeration. *)

val environment : client -> (Yojson.Safe.t, error) result Lwt.t
val list_projects : client -> (page, error) result Lwt.t

val list_threads :
  client -> project_id:string -> ?title_contains:string ->
  ?include_subagents:bool -> unit -> (page, error) result Lwt.t

type run = {
  run_id : string;
  status : string field;
  run_raw : Yojson.Safe.t;
}

type activity = {
  thread_id : string;
  parent_thread_id : string option field;
  runtime_mode : string field;
  provider_instance_id : string option field;
  model : string option field;
  pending_request_count : int field;
  settled : bool field;
  archived : bool field;
  deleted : bool field;
  snoozed : bool field;
  active_run_id : string option field;
  items : Yojson.Safe.t list;
  recent_runs : run list;
  runs_complete : bool;
  complete : bool;  (** [hasMore = false] reached within limits *)
  text_truncated : bool;  (** some item reported [textTruncated = true] *)
  thread_raw : Yojson.Safe.t;
}

val read_activity :
  client -> thread_id:string -> ?run_limit:int -> unit -> (activity, error) result Lwt.t

type queue = { queued_run_ids : string list; queue_complete : bool }

val list_queue : client -> thread_id:string -> (queue, error) result Lwt.t
(** Queued text is discarded on decode: it never reaches matching or logs. *)

type send_mode = [ `Auto | `Queue | `Steer | `Restart ]

type receipt = { receipt_thread_id : string; message_id : string; run_id : string }

val send_message :
  client -> thread_id:string -> message:string -> mode:send_mode ->
  client_request_id:string -> (receipt, error) result Lwt.t
(** Operator control, not a c2c DATA path. Not auto-retried: the service owns
    uncertain-outcome policy and replays the same [client_request_id]. *)
