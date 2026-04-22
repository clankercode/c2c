type t = {
  description : string;
  role : string;
  model : string option;
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
val parse_string : ?snippets_dir:string -> string -> t
val parse_file : string -> t

module OpenCode_renderer : sig
  val render : t -> string
end

module Claude_renderer : sig
  val render : t -> string
end
