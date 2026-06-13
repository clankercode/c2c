(* Swarm-wide config thunks.

   Shared dependency-free home for [swarm] config keys that both the
   broker and [C2c_start] need to read. Keeping the implementations here
   avoids a module-dependency cycle between [C2c_broker] and [C2c_start]. *)

val repo_config_path : unit -> string
(** Path to [./.c2c/config.toml] relative to [Sys.getcwd ()]. *)

val read_toml_sections_with_prefix_from_path :
  string -> string -> (string * (string * string) list) list
(** [read_toml_sections_with_prefix_from_path path prefix] reads the TOML
    file at [path] and returns [(subsection, key-value pairs)] for every
    section matching [\[prefix\]] (returned with subsection ["default"])
    or [\[prefix.X\]] (returned with subsection ["X"]). *)

val read_toml_sections_with_prefix :
  string -> (string * (string * string) list) list
(** [read_toml_sections_with_prefix prefix] reads [.c2c/config.toml] in
    the current working directory. *)

val builtin_swarm_social_room : string
(** Built-in default social room ID. ["swarm-lounge"] today; may be
    inverted to empty in a future flat-mesh default slice. *)

val swarm_config_social_room : unit -> string
(** [swarm_config_social_room ()] reads the [swarm] [social_room] key from
    .c2c/config.toml, or returns [builtin_swarm_social_room] when the
    section/key is absent or empty. *)

val builtin_swarm_coordinator_alias : string
(** Built-in default coordinator alias. ["coordinator1"] today; may be
    inverted to empty in a future flat-mesh default slice. *)

val swarm_config_coordinator_alias : unit -> string
(** [swarm_config_coordinator_alias ()] reads the [swarm]
    [coordinator_alias] key from .c2c/config.toml, or returns
    [builtin_swarm_coordinator_alias] when the section/key is absent or
    empty. *)
