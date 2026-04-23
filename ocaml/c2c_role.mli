type t = {
  description : string;
  role : string;
  model : string option;
  pmodel : string option;
  role_class : string option;
  c2c_alias : string option;
  c2c_auto_join_rooms : string list;
  include_ : string list;
  compatible_clients : string list;
  required_capabilities : string list;
  opencode : (string * string) list;
  claude : (string * string) list;
  codex : (string * string) list;
  kimi : (string * string) list;
  body : string;
}

val empty : t
val parse_string : ?snippets_dir:string -> ?filename:string -> string -> t
val parse_file : string -> t

(* resolve_pmodel: return the effective "provider:model" string for a role.
   Resolution order:
     1. role-file frontmatter `pmodel:` (t.pmodel)
     2. class_lookup t.role_class (the [pmodel] table keyed by role class)
     3. class_lookup "default"
     4. None
   Callers pass a class_lookup such as one built on top of
   C2c_start.repo_config_pmodel_lookup. *)
val resolve_pmodel : t -> class_lookup:(string -> string option) -> string option

module OpenCode_renderer : sig
  val render : t -> string
end

module Claude_renderer : sig
  val render : t -> string
end

module Codex_renderer : sig
  val render : t -> string
end

module Kimi_renderer : sig
  val render : t -> string
end
