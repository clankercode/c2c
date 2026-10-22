(* Expose c2c_mcp_server_inner functions needed by tests and binaries. *)

val auto_drain_channel_enabled : unit -> bool
(** Returns true when auto-drain is enabled for channel-capable clients.
    Default is ON (#346 flip). Gated by client declaring [experimental.claude/channel]
    in the initialize handshake. *)

val run_inner_server : broker_root:string -> unit
(** Entry point — runs the full MCP server loop. *)

val hermes_connection_env : broker_root:string option -> string array -> string array
(** Fresh connection identity and scrubbed environment for the Hermes stdio
    server's re-exec. Explicit process-wide mailbox prohibitions survive. *)

val connection_request : Yojson.Safe.t -> Yojson.Safe.t
(** Remove foreign per-turn metadata only in Hermes connection mode. *)

val handle_connection_request : broker_root:string -> Yojson.Safe.t -> Yojson.Safe.t option Lwt.t
(** Dispatch a request, refusing foreign session overrides in connection mode. *)
