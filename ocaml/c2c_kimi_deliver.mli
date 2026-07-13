(* c2c_kimi_deliver.mli — deliver c2c messages into Kimi Code via its local REST server. *)

val server_token_path : unit -> string
val server_base_url : unit -> string option
val read_server_token : unit -> string option

val submit_prompt : session_id:string -> body:string -> (int, string) result
(** [submit_prompt ~session_id ~body] POSTs a text prompt to
    /api/v1/sessions/{session_id}/prompts. Returns [Ok http_code] on a completed
    HTTP round-trip, [Error reason] on transport/parse failure. *)

val deliver_message : session_id:string -> msg:C2c_mcp.message -> (unit, string) result
(** [deliver_message ~session_id ~msg] serialises a c2c message into a Kimi
    text prompt and submits it. Returns [Ok ()] only on HTTP 200. *)
