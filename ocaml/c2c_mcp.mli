type registration =
  { session_id : string
  ; alias : string
  ; pid : int option
  ; pid_start_time : int option
  }
type message = { from_alias : string; to_alias : string; content : string }

module Broker : sig
  type t

  val create : root:string -> t
  val register :
    t
    -> session_id:string
    -> alias:string
    -> pid:int option
    -> pid_start_time:int option
    -> unit

  val list_registrations : t -> registration list
  val registration_is_alive : registration -> bool
  val read_pid_start_time : int -> int option
  val capture_pid_start_time : int option -> int option
  val enqueue_message : t -> from_alias:string -> to_alias:string -> content:string -> unit
  val read_inbox : t -> session_id:string -> message list
  val drain_inbox : t -> session_id:string -> message list
  val with_inbox_lock : t -> session_id:string -> (unit -> 'a) -> 'a

  type sweep_result =
    { dropped_regs : registration list
    ; deleted_inboxes : string list
    }

  val sweep : t -> sweep_result
end

val channel_notification : message -> Yojson.Safe.t
val handle_request : broker_root:string -> Yojson.Safe.t -> Yojson.Safe.t option Lwt.t
