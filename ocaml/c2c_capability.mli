(** Shared capability vocabulary for launcher/runtime planning. *)

type t =
  | Claude_channel
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
