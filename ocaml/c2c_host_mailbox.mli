(** Host mailbox transport v1. All operations fence registration and inbox
    access under the broker's registry lock. Rejected commands never drain. *)
exception Rejected of string
val identity : environment_id:string -> thread_id:string -> string * string
val response : (string * Yojson.Safe.t) list -> Yojson.Safe.t
val bind : environment_id:string -> thread_id:string -> workspace:string ->
  owner_id:string -> ?owner_pid:int -> ?alias:string -> ?broker_root:string -> unit -> Yojson.Safe.t
val peek : ?limit:int -> environment_id:string -> thread_id:string -> broker_root:string ->
  generation:string -> unit -> Yojson.Safe.t
val send : environment_id:string -> thread_id:string -> broker_root:string ->
  generation:string -> to_alias:string -> content:string -> Yojson.Safe.t
val ack : environment_id:string -> thread_id:string -> broker_root:string ->
  generation:string -> message_ids:string list -> Yojson.Safe.t
val unbind : environment_id:string -> thread_id:string -> broker_root:string ->
  generation:string -> Yojson.Safe.t

(** Fault-injection seam: invoked after state publication and before registry
    publication. Tests isolate it in a child process and kill that child. *)
val set_after_state_write_for_test : (unit -> unit) option -> unit
