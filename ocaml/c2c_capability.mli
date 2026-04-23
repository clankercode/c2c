(** Shared capability vocabulary for launcher/runtime planning. *)

type t =
  | Claude_channel
  | Opencode_plugin
  | Opencode_plugin_active
  | Pty_inject
  | Kimi_wire
  | Codex_xml_fd
  | Codex_headless_thread_id_fd

val to_string : t -> string
(** Stable serialized capability name used in role files and tests. *)

val of_string : string -> t option
(** Parse a stable serialized capability name. *)

val all : t list
(** All currently known capabilities. *)

val missing_required : required:string list -> available:string list -> string list
(** Return required capability names that are not present in [available].
    Unknown requirement names are treated as missing so callers fail closed. *)

val negotiated_in_initialize :
  current:string list -> Yojson.Safe.t -> string list
(** Update the negotiated runtime capability set from an MCP request.
    Only [initialize] currently changes the set. *)

val has : string list -> t -> bool
(** Membership check against a serialized capability set. *)
