(** Host mailbox transport v1. All operations fence registration and inbox
    access under the broker's registry lock. Rejected commands never drain. *)
exception Rejected of string
val identity : environment_id:string -> thread_id:string -> string * string
val response : (string * Yojson.Safe.t) list -> Yojson.Safe.t
val bind : environment_id:string -> thread_id:string -> workspace:string ->
  owner_id:string -> ?owner_pid:int -> ?alias:string -> ?broker_root:string -> unit -> Yojson.Safe.t
val peek : environment_id:string -> thread_id:string -> broker_root:string ->
  generation:string -> Yojson.Safe.t
val ack : environment_id:string -> thread_id:string -> broker_root:string ->
  generation:string -> message_ids:string list -> Yojson.Safe.t
val unbind : environment_id:string -> thread_id:string -> broker_root:string ->
  generation:string -> Yojson.Safe.t
