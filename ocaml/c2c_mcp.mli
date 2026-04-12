type registration = { session_id : string; alias : string }
type message = { from_alias : string; to_alias : string; content : string }

module Broker : sig
  type t

  val create : root:string -> t
  val register : t -> session_id:string -> alias:string -> unit
  val list_registrations : t -> registration list
  val enqueue_message : t -> from_alias:string -> to_alias:string -> content:string -> unit
  val read_inbox : t -> session_id:string -> message list
  val drain_inbox : t -> session_id:string -> message list
end

val channel_notification : message -> Yojson.Safe.t
val handle_request : broker_root:string -> Yojson.Safe.t -> Yojson.Safe.t option Lwt.t
