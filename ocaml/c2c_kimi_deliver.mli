(* c2c_kimi_deliver.mli — deliver c2c messages into Kimi Code via its local REST server. *)

val server_token_path : unit -> string
val server_base_url : unit -> string option
(** [server_base_url ()] resolves the base URL of the local Kimi Code server.

    Precedence (#39): fixture override → live lock file / instance registry →
    [$C2C_KIMI_SERVER_PORT] → liveness-probed server.log record → default port
    58627. The log record is last-resort and probed because modern kimi-code
    only appends it on a COLD start, so it ages into a dead port and used to
    pre-empt every correct source. *)
val read_server_token : unit -> string option
val fixture_enabled : unit -> bool

val session_index_path : unit -> string
val read_session_index : unit -> (string * string * string) list
(** [read_session_index ()] parses ~/.kimi-code/session_index.jsonl and
    returns [(session_id, workdir, updated_at)] entries. [updated_at] is the
    raw ISO-8601 string so callers can sort lexicographically. *)

val session_id_for_workdir : workdir:string -> string option
(** [session_id_for_workdir ~workdir] returns the most recently updated Kimi
    session id whose [workDir] equals [workdir]. *)

val session_dir_for_session_id : session_id:string -> string option
(** [session_dir_for_session_id ~session_id] returns the [sessionDir] path
    recorded in ~/.kimi-code/session_index.jsonl for [session_id], if present.
    This is the authoritative session directory used by Kimi Code, avoiding
    any drift between c2c's hash computation and Kimi Code's on-disk layout. *)

val server_listening_url : unit -> string option
(** [server_listening_url ()] scans ~/.kimi-code/server/server.log for the
    latest "server listening" log line and returns the bound address.

    HISTORICAL ONLY (#39): the log is append-only and the record is written on
    a cold start, so the address may name a long-dead server. Never use it
    without [address_is_live]. *)

val server_lock_path : unit -> string
(** Path to kimi's single-instance server lock, ~/.kimi-code/server/lock. *)

val live_lock_url : unit -> string option
(** [live_lock_url ()] returns the base URL recorded by the currently-running
    Kimi server, from the exclusive lock file or (under kimi's [multi_server]
    flag) the server/instances registry. [None] when the file is missing,
    malformed, or records a dead pid. Never raises. *)

val address_is_live : string -> bool
(** [address_is_live url] TCP-connects to the host:port of [url] with a short
    timeout ([$C2C_KIMI_PROBE_TIMEOUT], default 0.5s). Never raises. *)

val submit_prompt : session_id:string -> body:string -> (int, string) result
(** [submit_prompt ~session_id ~body] POSTs a text prompt to
    /api/v1/sessions/{session_id}/prompts. Returns [Ok http_code] when the
    server responds with a JSON body whose top-level [code] field is [0] or
    absent, [Error reason] on a non-zero [code], transport failure, or
    non-JSON response. *)

val deliver_message : session_id:string -> msg:C2c_mcp.message -> (unit, string) result
(** [deliver_message ~session_id ~msg] serialises a c2c message into a Kimi
    text prompt and submits it. Returns [Ok ()] only on HTTP 200. *)

val message_envelope : msg:C2c_mcp.message -> string
(** [message_envelope ~msg] returns the raw XML envelope string that
    [deliver_message] would POST as the prompt body. Exported for tests and
    diagnostics; the output is not escaped beyond the canonical xml_escape
    rendering of alias and content fields. *)
