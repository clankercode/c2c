(* Expose c2c_mcp_server_inner functions needed by tests and binaries. *)

val auto_drain_channel_enabled : unit -> bool
(** Returns true when auto-drain is enabled for channel-capable clients.
    Default is ON (#346 flip). Gated by client declaring [experimental.claude/channel]
    in the initialize handshake. *)

val run_inner_server : broker_root:string -> unit
(** Entry point — runs the full MCP server loop. *)
