(** Shared agy agentapi helpers (P4) — env file + discovery + send-message.

    Managed agy wake needs [agy-env.json] ({ls_address, conversation_id}).
    Hooks only write it when SessionStart/PostToolUse export
    [ANTIGRAVITY_LS_ADDRESS] + conversation id; managed starts often never
    do. [ensure_agy_env] discovers LS HTTP port + conversation from the
    agy CLI log (and optional pid listeners) and persists the env under the
    managed instances dir so deliver-watch can inject. It never mints a
    headless conversation (#78) — only TUI-owned conversation ids wake.
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
    When the log yields an HTTP LS but no conversation yet (idle TUI before its
    first user turn), returns [None] and does not write [agy-env.json] (#78).
    We never mint via [run_agentapi_new_conversation] for the wake target: a
    c2c-minted headless conversation does not wake the live TUI — [send-message]
    only wakes a conversation the TUI itself owns. Delivery retries once a
    TUI-created conversation appears in the CLI log (first turn or managed
    kickoff). *)

val with_ls_env : ls_address:string -> string array -> string array
(** Return [env] with [ANTIGRAVITY_LS_ADDRESS]/[ANTIGRAVITY_PROJECT_ID] set to
    the given LS (default-cli-project), stripping any inherited stale copies —
    this is how the agentapi call is routed to the right language server. *)

val agentapi_send_argv :
  conversation_id:string -> content:string -> string array
(** The exact argv for the wake command: [agy agentapi send-message
    --title=c2c inbound <conversation_id> <content>]. Pure, so the wake method
    can be asserted without spawning [agy]. *)

val run_agentapi_send :
  ls_address:string -> conversation_id:string -> content:string -> bool

val agentapi_new_conversation_argv :
  model:string -> title:string -> prompt:string -> string array

val run_agentapi_new_conversation :
  ls_address:string ->
  ?model:string ->
  ?title:string ->
  prompt:string ->
  unit ->
  string option
(** [Some conversation_id] on success. Spawns [agy agentapi new-conversation].
    Not used by [ensure_agy_env] for wake targets (#78 — headless mints do not
    wake the live TUI). Retained for tooling / tests; set
    [C2C_AGY_NEW_CONVERSATION_FIXTURE=<uuid>] in tests to force a return id
    without spawning [agy]. *)

val format_inbound_payload : C2c_mcp.message list -> string

val deliver_messages :
  session_id:string -> C2c_mcp.message list -> (unit, string) result
(** Ensure env, format msgs, agentapi send. *)
