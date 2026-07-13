(* c2c_kimi_deliver.mli — deliver c2c messages into Kimi Code via its local REST server. *)

val server_token_path : unit -> string
val server_base_url : unit -> string option
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

val server_listening_url : unit -> string option
(** [server_listening_url ()] scans ~/.kimi-code/server/server.log for the
    latest "server listening" log line and returns the bound address. *)

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
