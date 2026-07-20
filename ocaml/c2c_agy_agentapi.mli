(** Shared agy agentapi helpers (P4) — env file + discovery + send-message.

    Managed agy wake needs [agy-env.json] ({ls_address, conversation_id}).
    Hooks only write it when SessionStart/PostToolUse export
    [ANTIGRAVITY_LS_ADDRESS] + conversation id; managed starts often never
    do. [ensure_agy_env] discovers LS HTTP port + conversation from the
    agy CLI log (and optional pid listeners) and persists the env under the
    managed instances dir so deliver-watch can inject without a human turn.
*)

type agy_env = {
  ls_address : string;
  conversation_id : string;
}

type scan_hit = {
  ls_http_port : int option;
  conversation_id : string option;
}

val instance_dir : string -> string
(** Managed instance directory for [name] — same root as [c2c start]
    ([C2C_INSTANCES_DIR] or [~/.local/share/c2c/instances]). *)

val env_file_path : string -> string
val read_agy_env : string -> agy_env option
val write_agy_env :
  string -> ls_address:string -> conversation_id:string -> unit

val parse_http_ls_port_from_line : string -> int option
val parse_created_conversation_from_line : string -> string option
val scan_cli_log : string -> scan_hit option
(** Scan one CLI log; last HTTP LS port and last Created conversation win. *)

val default_cli_log_dir : unit -> string
val latest_cli_log : ?dir:string -> unit -> string option

val ensure_agy_env :
  session_id:string ->
  ?cli_log_dir:string ->
  ?agy_pid:int ->
  unit ->
  agy_env option
(** Return existing env, else discover from CLI log (+ optional pid) and write.
    Does not mint a conversation when none exists yet (needs a real agy
    conversation id for agentapi send-message to the live TUI). *)

val run_agentapi_send :
  ls_address:string -> conversation_id:string -> content:string -> bool

val run_agentapi_new_conversation :
  ls_address:string ->
  ?model:string ->
  ?title:string ->
  prompt:string ->
  unit ->
  string option
(** [Some conversation_id] on success. Used when log has HTTP LS but no
    conversation yet (idle TUI before first user turn). *)

val format_inbound_payload : C2c_mcp.message list -> string

val deliver_messages :
  session_id:string -> C2c_mcp.message list -> (unit, string) result
(** Ensure env, format msgs, agentapi send. *)
