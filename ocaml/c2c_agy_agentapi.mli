(** Shared agy agentapi helpers (P4) — env file + send-message + payload format. *)

type agy_env = {
  ls_address : string;
  conversation_id : string;
}

val env_file_path : string -> string
val read_agy_env : string -> agy_env option
val write_agy_env :
  string -> ls_address:string -> conversation_id:string -> unit

val run_agentapi_send :
  ls_address:string -> conversation_id:string -> content:string -> bool

val format_inbound_payload : C2c_mcp.message list -> string

val deliver_messages :
  session_id:string -> C2c_mcp.message list -> (unit, string) result
(** Read agy-env for [session_id], format msgs, agentapi send. *)
